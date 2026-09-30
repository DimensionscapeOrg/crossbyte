package crossbyte.db.mongodb;

// Not built for any JavaScript target: it runs on a blocking connection.
#if !js
import crossbyte.FieldStruct;
import crossbyte.db.mongodb.bson.BsonDocument;
import crossbyte.db.mongodb.bson.ExtendedJson;
import crossbyte.db.sql.SQLResult;
import crossbyte.errors.SQLError;
import crossbyte.events.EventDispatcher;
import crossbyte.events.SQLErrorEvent;
import crossbyte.events.SQLEvent;

/**
	A MongoDB command written as Extended JSON, run the way the other drivers'
	statements run SQL: `execute`, then `getResult` a page at a time.

	```haxe
	// Given connection:MongoConnection.
	var statement = new MongoStatement();
	statement.sqlConnection = connection;
	// In a single-quoted Haxe string $ interpolates, so $gt is written $$gt.
	statement.text = '{"find": "sessions", "filter": {"userId": :user, "expiresAt": {"$$gt": :now}}}';
	statement.parameters.user = 42;
	statement.parameters.now = Date.now();
	statement.execute(100);
	var page = statement.getResult();
	```

	`:name` placeholders are bound to `parameters` as values -- a date stays a
	BSON date, an `Int64` an int64 -- never spliced into the text, so no value
	can change what the command does. A command answering with a cursor
	(`find`, `aggregate`) pages through it: `execute(n)` and `next(n)` fetch `n`
	documents at a time, sending `getMore` as the server's batches run out.
	Any other command's result is its reply, as a single row.

	A failure is dispatched as an `SQLErrorEvent`, whose error is the
	`MongoError` with the server's code, and then thrown, as MySQL's and
	Postgres's statements do.
**/
@:access(crossbyte.db.mongodb.MongoConnection)
class MongoStatement extends EventDispatcher {
	public var executing(get, null):Bool;
	public var itemClass:Class<Dynamic>;

	/** Values for the `:name` placeholders in `text`, bound as BSON values. **/
	public var parameters(default, null):FieldStruct<Dynamic>;

	public var sqlConnection(get, set):MongoConnection;

	/** The command, as Extended JSON. **/
	public var text:String;

	@:noCompletion private var __sqlConnection:MongoConnection;
	@:noCompletion private var __cursor:MongoCursor;
	@:noCompletion private var __prefetch:Int = 0;
	@:noCompletion private var __executing:Bool = false;
	@:noCompletion private var __affected:Int = 0;

	// Pages read and not yet taken, oldest first. A statement runs on the
	// thread that calls it, so a plain Array serves every target, as the SQL
	// drivers' do; a Deque cannot say whether a page is the last one waiting.
	@:noCompletion private var __resultQueue:Array<Array<Dynamic>>;

	public function new() {
		super();
		parameters = new FieldStruct();
		__resetQueue();
	}

	public function clearParameters():Void {
		parameters = new FieldStruct();
	}

	/**
		Stops paging: the cursor, if one is open, is closed on the server, and
		the results not yet taken are dropped.
	**/
	public function cancel():Void {
		if (__executing) {
			__executing = false;
			__prefetch = 0;
			__resetQueue();
			__closeCursor();
			text = "";
			clearParameters();
		}
	}

	/**
		Runs the command. With `prefetch` of -1, the default, every document is
		fetched at once; with a positive count, that many, and `next` fetches
		more.

		@throws String When no connection is set.
	**/
	public function execute(prefetch:Int = -1):Void {
		if (__sqlConnection == null) {
			throw "MongoStatement: no connection set.";
		}

		__executing = true;
		__resetQueue();
		__closeCursor();
		__prefetch = prefetch;

		try {
			var params:FieldStruct<Dynamic> = parameters;
			var command:Dynamic = ExtendedJson.parse(text, name -> FieldStruct.exists(params, name) ? FieldStruct.get(params, name) : null);

			if (!Std.isOfType(command, BsonDocument)) {
				throw new SQLError(SQLEvent.RESULT, "A command is a JSON object.", "Execution failed: a command is a JSON object.");
			}

			var reply:Dynamic = __sqlConnection.runCommand(command);
			__affected = __affectedOf(reply);
			__cursor = __sqlConnection.__cursorOf(reply, (command : BsonDocument).keyAt(0));
			__queueResult();
		} catch (e:Dynamic) {
			__executing = false;
			__prefetch = 0;
			__fail(e);
		}

		// Outside the try: a RESULT listener that throws has not made the
		// command fail, and must not be reported as though it had.
		__dispatchEvent(new SQLEvent(SQLEvent.RESULT));
	}

	/** Fetches the next `prefetch` documents, or all that remain with -1. **/
	public function next(prefetch:Int = -1):Void {
		if (__cursor == null) {
			throw "MongoDB Error - invalid result set";
		}

		__prefetch = prefetch;

		try {
			if (__cursor.hasNext()) {
				__queueResult();
			} else {
				__executing = false;
				__prefetch = 0;
			}
		} catch (e:Dynamic) {
			__executing = false;
			__prefetch = 0;
			__fail(e);
		}

		__dispatchEvent(new SQLEvent(SQLEvent.RESULT));
	}

	/**
		Reports a failure both ways: as the `SQLErrorEvent` it always was, and
		as the error it now throws. It dispatched the event and returned, so to
		a caller not listening -- an `AsyncDatabase` task among them -- a
		refused command read as one that had run.
	**/
	@:noCompletion private function __fail(e:Dynamic):Void {
		var error:SQLError = __asSQLError(e);
		__dispatchEvent(new SQLErrorEvent(SQLErrorEvent.ERROR, error));
		throw error;
	}

	/**
		The next page fetched, or `null`. `rowsAffected` is what the command
		reported writing -- `n` from an insert, update or delete -- and
		`complete` whether the documents have all been taken.
	**/
	public function getResult():SQLResult {
		var results:Array<Dynamic> = __resultQueue.shift();

		if (results != null) {
			// The last page is the one read as the documents ran out, with none
			// behind it. This was !__executing alone, which called every page
			// still waiting complete once the last had been read.
			return new SQLResult(results, __affected, !__executing && __resultQueue.length == 0, 0);
		}

		return null;
	}

	@:noCompletion private function __queueResult():Void {
		var rows:Array<Dynamic> = [];

		if (__prefetch == -1) {
			while (__cursor.hasNext()) {
				rows.push(__cursor.next());
			}

			__executing = false;
		} else if (__prefetch > 0) {
			for (_ in 0...__prefetch) {
				if (__cursor.hasNext()) {
					rows.push(__cursor.next());
				} else {
					break;
				}
			}

			// Spent when the last document is taken, whether or not this page
			// filled: asking the cursor answers without a round trip unless
			// the server holds more.
			if (!__cursor.hasNext()) {
				__executing = false;
			}
		}

		__push(rows);
		__prefetch = 0;
	}

	@:noCompletion private function __closeCursor():Void {
		if (__cursor != null) {
			var cursor:MongoCursor = __cursor;
			__cursor = null;

			try {
				cursor.close();
			} catch (_:Dynamic) {}
		}
	}

	@:noCompletion private static function __affectedOf(reply:Dynamic):Int {
		var n:Dynamic = Reflect.field(reply, "n");
		return n == null || Reflect.hasField(reply, "cursor") ? 0 : MongoConnection.__int(n);
	}

	/**
		The failure as an `SQLError`, whatever was thrown. A `MongoError` is
		one already and keeps its code; anything else is carried as text,
		never as itself -- a native exception where `SQLError` wants a
		`String` was a ClassCastException on the jvm, which escaped `execute`
		and left every listener unrun.
	**/
	@:noCompletion private static function __asSQLError(e:Dynamic):SQLError {
		if (Std.isOfType(e, SQLError)) {
			return e;
		}

		var detail:String = Std.string(e);
		return new SQLError(SQLEvent.RESULT, detail, "Execution failed: " + detail);
	}

	private function get_executing():Bool {
		return __executing;
	}

	private function set_sqlConnection(v:MongoConnection):MongoConnection {
		__sqlConnection = v;
		return v;
	}

	private function get_sqlConnection():MongoConnection {
		return __sqlConnection;
	}

	@:noCompletion private inline function __resetQueue():Void {
		__resultQueue = [];
	}

	@:noCompletion private inline function __push(a:Array<Dynamic>):Void {
		__resultQueue.push(a);
	}
}
#end
