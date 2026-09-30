package crossbyte.db.mongodb;

// Not built for any JavaScript target: it pages through a blocking connection.
#if !js
import haxe.Int64;

/**
	The documents a `find`, an `aggregate` or another cursor command returns,
	fetched a batch at a time.

	The first batch comes with the command; `hasNext` sends `getMore` for the
	next one when the batch in hand runs out, so a result far larger than
	memory can be walked without holding it. It is an `Iterator`, so it can
	be looped over:

	```haxe
	var cursor = connection.find("events", {kind: "login"}, {batchSize: 500});
	for (event in cursor) {
		audit(event);
	}
	```

	A cursor walked to its end is closed on the server by then. One left
	part-way should be closed with `close`, which tells the server with
	`killCursors`; otherwise the server keeps it for ten minutes. A cursor
	belongs to the connection that made it: use it on that connection's
	thread, and before the connection goes back to a pool.
**/
@:access(crossbyte.db.mongodb.MongoConnection)
class MongoCursor {
	/** The server's id for the cursor; zero once there is nothing more to fetch. **/
	public var id(default, null):Int64;

	/** The namespace, `database.collection`, the cursor reads. **/
	public var namespace(default, null):String;

	/** Whether the cursor has been closed, or run to its end. **/
	public var closed(get, never):Bool;

	@:noCompletion private var __connection:MongoConnection;
	@:noCompletion private var __database:String;
	@:noCompletion private var __collection:String;
	@:noCompletion private var __batch:Array<Dynamic>;
	@:noCompletion private var __index:Int = 0;
	@:noCompletion private var __batchSize:Int;
	@:noCompletion private var __maxTimeMS:Int;
	@:noCompletion private var __closed:Bool = false;

	@:noCompletion public function new(connection:MongoConnection, id:Int64, namespace:String, batch:Array<Dynamic>, batchSize:Int, maxTimeMS:Int) {
		__connection = connection;
		this.id = id;
		this.namespace = namespace == null ? "" : namespace;
		__batch = batch == null ? [] : batch;
		__batchSize = batchSize;
		__maxTimeMS = maxTimeMS;

		var dot:Int = this.namespace.indexOf(".");
		__database = dot > 0 ? this.namespace.substr(0, dot) : this.namespace;
		__collection = dot > 0 ? this.namespace.substr(dot + 1) : "";

		if (__isZero(id)) {
			__closed = true;
		}
	}

	/** Whether there is another document, fetching the next batch if the one in hand is spent. **/
	public function hasNext():Bool {
		while (__index >= __batch.length) {
			if (__isZero(id)) {
				return false;
			}

			__getMore();
		}

		return true;
	}

	/** The next document, or `null` when there are no more. **/
	public function next():Dynamic {
		if (!hasNext()) {
			return null;
		}

		return __batch[__index++];
	}

	/** Every remaining document, fetching as many batches as that takes. **/
	public function toArray():Array<Dynamic> {
		var out:Array<Dynamic> = [];

		while (hasNext()) {
			// The batch in hand in one go, rather than a call per document.
			while (__index < __batch.length) {
				out.push(__batch[__index++]);
			}
		}

		return out;
	}

	/**
		How many documents are in hand without another round trip. `0` does
		not mean the cursor is spent; `hasNext` fetches more.
	**/
	public var buffered(get, never):Int;

	private inline function get_buffered():Int {
		return __batch.length - __index;
	}

	/**
		Closes the cursor on the server, if it is still open there, and drops
		the documents in hand. Safe to call twice.
	**/
	public function close():Void {
		__batch = [];
		__index = 0;

		if (!__isZero(id) && __connection.connected) {
			var open:Int64 = id;
			id = Int64.ofInt(0);
			__connection.__killCursor(__database, __collection, open);
		}

		id = Int64.ofInt(0);
		__closed = true;
	}

	@:noCompletion private function __getMore():Void {
		var reply:Dynamic = __connection.__getMore(__database, __collection, id, __batchSize, __maxTimeMS);
		var cursor:Dynamic = Reflect.field(reply, "cursor");

		if (cursor == null) {
			throw new MongoError("getMore", "the reply carries no cursor", 0, "", null, null, null, null, reply);
		}

		var next:Dynamic = Reflect.field(cursor, "nextBatch");
		__batch = next == null ? [] : next;
		__index = 0;
		var nextId:Dynamic = Reflect.field(cursor, "id");
		id = MongoConnection.__toInt64(nextId);

		if (__isZero(id)) {
			__closed = true;
		}
	}

	private inline function get_closed():Bool {
		return __closed && __index >= __batch.length;
	}

	@:noCompletion private static inline function __isZero(value:Int64):Bool {
		return value.high == 0 && value.low == 0;
	}
}
#end
