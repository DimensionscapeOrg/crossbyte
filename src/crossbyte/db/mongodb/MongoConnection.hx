package crossbyte.db.mongodb;

// The client is not built for any JavaScript target, where an unsupported shell
// stands in (at the end of this file). Every call here blocks its thread until
// the server answers, which is the shape of all of CrossByte's database drivers,
// they run on a worker, through ConnectionPool and AsyncDatabase. Node has no
// synchronous socket to block on, nor a second thread to do the blocking on; and
// the browser has no TCP. The BSON codec in crossbyte.db.mongodb.bson builds and
// runs everywhere.
#if !js
import crossbyte._internal.socket.FlexSocket;
import crossbyte.db.ITransactionalConnection;
import crossbyte.db.mongodb.MongoConfig.MongoWriteConcern;
import crossbyte.db.mongodb.MongoError.MongoWriteError;
import crossbyte.db.mongodb.MongoOptions;
import crossbyte.db.mongodb._internal.BsonReader;
import crossbyte.db.mongodb._internal.BsonWriter;
import crossbyte.db.mongodb._internal.MongoUri;
import crossbyte.db.mongodb._internal.MongoWire;
import crossbyte.db.mongodb._internal.Scram;
import crossbyte.db.mongodb.bson.BsonBinary;
import crossbyte.db.mongodb.bson.BsonDocument;
import crossbyte.db.mongodb.bson.BsonInt64;
import crossbyte.db.mongodb.bson.ExtendedJson;
import crossbyte.errors.ArgumentError;
import crossbyte.errors.IOError;
import crossbyte.errors.IllegalOperationError;
import crossbyte.errors.SQLError;
import crossbyte.events.EventDispatcher;
import crossbyte.events.SQLErrorEvent;
import crossbyte.events.SQLEvent;
import haxe.Int64;
import haxe.io.Bytes;

/**
	A connection to a MongoDB server, speaking its wire protocol over a
	CrossByte socket: OP_MSG, the `hello` handshake, SCRAM-SHA-256 and
	SCRAM-SHA-1 (or X.509 or PLAIN) authentication, and TLS.

	Every call blocks until the server answers, as with the other drivers
	here, so run it on a worker, `AsyncDatabase` over a `ConnectionPool` is
	the usual way, never on a runtime's own thread.

	```haxe
	import crossbyte.db.AsyncDatabase;
	import crossbyte.db.ConnectionPool;
	import crossbyte.db.mongodb.bson.ObjectId;

	// Given secret:String, id:ObjectId.
	var pool = new ConnectionPool<MongoConnection>({
		factory: () -> {
			var c = new MongoConnection();
			c.open({uri: "mongodb://app@db.example.com/app?tls=true", password: secret});
			c;
		},
		close: c -> c.close(),
		validate: c -> c.ping()
	});
	var db = AsyncDatabase.of(pool);

	db.submit(c -> c.insertOne("sessions", {userId: 42, expiresAt: Date.fromTime(Date.now().getTime() + 3600000)}));
	db.submit(c -> c.findOne("sessions", {_id: id})).onComplete(session -> trace(session));
	```

	Documents are anonymous objects both ways, with the BSON types in
	`crossbyte.db.mongodb.bson` for what plain Haxe values cannot say; see
	`Bson` for the mapping. A command the server refuses throws a
	`MongoError` carrying its code; a connection that fails throws an
	`IOError`, and is closed.

	**Transactions** need a replica set or a sharded cluster. `begin`,
	`commit` and `rollback` run one on this connection's own session, and
	`inTransaction` is true from `begin` until `commit` or `rollback` ends it,
	including after a statement in it failed, MongoDB aborts the transaction
	then, and it still has to be ended here. `ConnectionPool` rolls back a
	transaction a borrower left open.

	One thread at a time: a connection, and the cursors it makes, belong to
	whichever thread is using it.
**/
@:access(crossbyte.db.mongodb.MongoCursor)
class MongoConnection extends EventDispatcher implements ITransactionalConnection {
	/**
		Whether this target has the blocking sockets the client needs: every
		one but JavaScript. Its tests run on hxcpp, the jvm, the interpreter,
		hl and neko. On php it builds, SCRAM through PHP's own hash functions,
		and has not yet been run: nothing here has a PHP to run it on.
	**/
	public static final isSupported:Bool = true;

	/** The newest wire protocol version this client knows (MongoDB 8.2). **/
	public static inline var MAX_WIRE_VERSION:Int = 27;

	/** The oldest it can speak: 6, MongoDB 3.6, the first with OP_MSG. **/
	public static inline var MIN_WIRE_VERSION:Int = 6;

	/** Whether the connection is open. Asks nothing of the server; `ping` does. **/
	public var connected(get, null):Bool;

	/**
		Whether a transaction begun here is open: from `begin` until `commit`
		or `rollback` ends it. `ConnectionPool` reads it to roll back what a
		borrower left open.
	**/
	public var inTransaction(get, null):Bool;

	/** Documents the last write inserted, matched or deleted, as the server counted them. **/
	public var affectedRows(get, null):Int;

	/**
		The `_id` of the last document this connection inserted, the one it
		had, or the `ObjectId` made for it, or `null`. MongoDB has no row ids;
		this replaces the `lastInsertRowID` the other drivers have, which here
		could only ever have read 0.
	**/
	public var lastInsertId(get, null):Dynamic;

	/** The server's version, such as `7.0.14`, asked for once and kept. **/
	public var serverVersion(get, null):String;

	/** The database commands go to when they name none. **/
	public var database(get, null):String;

	/** The server's `hello` reply: its role, limits and wire version. `null` until open. **/
	public var serverInfo(get, null):Dynamic;

	/** The write concern writes use when they give none. **/
	public var writeConcern:Null<MongoWriteConcern>;

	@:noCompletion private static final LOG:crossbyte.utils.LogCategory = crossbyte.utils.Logger.category("db.mongodb");

	@:noCompletion private static inline var TXN_NONE:Int = 0;
	@:noCompletion private static inline var TXN_STARTING:Int = 1;
	@:noCompletion private static inline var TXN_IN_PROGRESS:Int = 2;

	@:noCompletion private var __wire:MongoWire;
	@:noCompletion private var __writer:BsonWriter;
	@:noCompletion private var __reader:BsonReader;
	@:noCompletion private var __settings:MongoSettings;
	@:noCompletion private var __hello:Dynamic;
	@:noCompletion private var __requestId:Int = 0;
	@:noCompletion private var __bodyStart:Int = 0;
	@:noCompletion private var __maxWireVersion:Int = 0;
	@:noCompletion private var __maxBsonObjectSize:Int = 16777216;
	@:noCompletion private var __maxWriteBatchSize:Int = 100000;
	@:noCompletion private var __database:String = "test";
	@:noCompletion private var __lastAffected:Int = 0;
	@:noCompletion private var __lastInsertId:Dynamic = null;
	@:noCompletion private var __serverVersion:String = null;

	// The logical session transactions run on: made at the first begin(),
	// and ended with the connection.
	@:noCompletion private var __sessionId:BsonDocument = null;
	@:noCompletion private var __txnNumber:Int64 = Int64.ofInt(0);
	@:noCompletion private var __txnState:Int = TXN_NONE;
	// Whether the message being built carries startTransaction.
	@:noCompletion private var __startsTransaction:Bool = false;

	public function new() {
		super();
	}

	/**
		Connects, says hello, and authenticates when the config names a user.

		With several hosts, each is tried in turn until one is a primary, a
		`mongos` or a standalone server; a secondary that names its primary is
		followed there, unless `directConnection` asks for the server named.

		@throws ArgumentError When the config is malformed or asks for
		something unsupported, before anything is sent.
		@throws IOError When no server can be reached or the handshake fails.
		@throws MongoError When the server refuses the credentials.
	**/
	public function open(cfg:MongoConfig):Void {
		if (cfg == null) {
			throw new ArgumentError("MongoConnection.open needs a config.");
		}

		if (__wire != null) {
			throw new IllegalOperationError("This MongoConnection is already open; close it first.");
		}

		var settings:MongoSettings = MongoUri.settings(cfg);

		if (settings.ignored.length > 0) {
			LOG.warn("Connection string options with no effect here were ignored: " + settings.ignored.join(", ") + ".");
		}

		__settings = settings;
		__database = settings.database;
		writeConcern = settings.writeConcern;
		__reader = new BsonReader();
		__reader.exactDates = settings.exactDates;
		__writer = new BsonWriter(4096);

		var failures:Array<String> = [];
		var candidates:Array<MongoHost> = settings.hosts.copy();
		var followed:Bool = false;
		var i:Int = 0;

		while (i < candidates.length) {
			var host:MongoHost = candidates[i++];
			var verdict:String;

			try {
				verdict = __connectTo(host, settings);
			} catch (e:SQLError) {
				// The server answered and refused: another host would too.
				__drop();
				__rethrow(e);
				return;
			} catch (e:ArgumentError) {
				__drop();
				__rethrow(e);
				return;
			} catch (e:Dynamic) {
				__drop();
				failures.push(host.host + ":" + host.port + ": " + Std.string(e));
				continue;
			}

			if (verdict == null) {
				__dispatchEvent(new SQLEvent(SQLEvent.OPEN));
				return;
			}

			__drop();
			failures.push(host.host + ":" + host.port + ": " + verdict);

			// A secondary knows its primary; go there, once.
			var primary:Dynamic = __hello != null ? Reflect.field(__hello, "primary") : null;

			if (!followed && Std.isOfType(primary, String)) {
				var parsed:MongoSettings = new MongoSettings();

				try {
					MongoUri.parseInto("mongodb://" + primary, parsed);
					candidates.insert(i, parsed.hosts[0]);
					followed = true;
				} catch (_:Dynamic) {}
			}
		}

		__hello = null;
		throw new IOError("No usable MongoDB server: " + failures.join("; "));
	}

	/**
		Closes the connection, ending its session on the server first, which
		aborts a transaction still open in it. Safe to call twice.
	**/
	public function close():Void {
		if (__wire == null) {
			return;
		}

		if (__sessionId != null && !__wire.closed) {
			try {
				__begin("endSessions", [__sessionId]);
				__endBody("admin", null, false);
				__send(false);
			} catch (_:Dynamic) {
				// The session times out on the server by itself.
			}
		}

		__drop();
		__dispatchEvent(new SQLEvent(SQLEvent.CLOSE));
	}

	/** Whether the server answers a `ping`; `false` rather than a throw when it does not. **/
	public function ping():Bool {
		if (__wire == null || __wire.closed) {
			return false;
		}

		try {
			__begin("ping", 1);
			__endBody("admin", null, false);
			__check("ping", __send(true));
			return true;
		} catch (_:Dynamic) {
			return false;
		}
	}

	/**
		Runs a command document and answers the server's reply, throwing a
		`MongoError` when the server reports failure.

		The command's first field names it, so `command` is a `BsonDocument`,
		or an anonymous object of a single field such as `{ping: 1}`: one with
		several fields is refused, since most targets do not keep their order.
		Inside a transaction the command runs in it.
	**/
	public function runCommand(command:Dynamic, ?database:String):Dynamic {
		var document:BsonDocument = __commandDocument(command);
		var name:String = document.keyAt(0);
		var w:BsonWriter = __begin(name, document.valueAt(0));

		for (k in 1...document.length) {
			var key:String = document.keyAt(k);

			if (key == "$db") {
				database = Std.string(document.valueAt(k));
				continue;
			}

			w.value(key, document.valueAt(k), 1);
		}

		__endBody(database != null ? database : __database, null, true);
		return __check(name, __send(true));
	}

	/**
		Runs a command written as Extended JSON, the way the other drivers take
		SQL text, and answers its documents: a cursor's, fetched in batches as
		they are read, or the reply itself as the only one.

		`:name` placeholders are bound to `parameters`' values, as values, not
		text, so a date stays a date and a value cannot change the command.

		```haxe
		// Given connection:MongoConnection, sid:String.
		for (doc in connection.request('{"find": "sessions", "filter": {"_id": :sid}}', ["sid" => sid]))
			trace(doc);
		```
	**/
	public function request(command:String, ?parameters:Map<String, Dynamic>):MongoCursor {
		var parsed:Dynamic = ExtendedJson.parse(command, parameters == null ? null : name -> parameters.get(name));

		if (!Std.isOfType(parsed, BsonDocument)) {
			throw new ArgumentError("A command is a JSON object.");
		}

		return __cursorOf(runCommand(parsed), (parsed : BsonDocument).keyAt(0));
	}

	/**
		Inserts documents, in batches as the server's limits require. A
		document without an `_id` is given an `ObjectId`, written first.

		@throws MongoError When any document is refused, a duplicate key,
		a failed validation. Its `result` counts what was inserted; with
		`ordered: false` every document was tried.
	**/
	public function insert(collection:String, documents:Array<Dynamic>, ?options:MongoInsertOptions):MongoWriteResult {
		if (documents == null || documents.length == 0) {
			throw new ArgumentError("insert needs at least one document.");
		}

		var ordered:Bool = options == null || options.ordered != false;
		var concern:Null<MongoWriteConcern> = options != null && options.writeConcern != null ? options.writeConcern : writeConcern;
		var result:MongoWriteResult = new MongoWriteResult(!__unacknowledged(concern));
		var ids:Array<Dynamic> = result.insertedIds;
		var errors:Array<MongoWriteError> = [];
		var concernError:MongoWriteError = null;
		var next:Int = 0;

		while (next < documents.length) {
			var batchStart:Int = next;
			var w:BsonWriter = __begin("insert", collection);
			w.value("ordered", ordered, 1);

			if (options != null && options.bypassDocumentValidation == true) {
				w.value("bypassDocumentValidation", true, 1);
			}

			__endBody(__database, concern, true);
			var sequence:Int = __beginSequence("documents");

			while (next < documents.length && next - batchStart < __maxWriteBatchSize) {
				var before:Int = w.length;
				var id:Dynamic = w.documentWithId(documents[next]);
				var size:Int = w.length - before;

				if (size > __maxBsonObjectSize) {
					// Found only once encoded, so batches before it may have
					// gone already; the message says how many were stored.
					throw new ArgumentError('Document $next is $size bytes; the server takes at most $__maxBsonObjectSize. ${result.inserted} document(s) before it were inserted.');
				}

				if (w.length > __wire.maxMessageSize && next > batchStart) {
					// Over the message limit: this document starts the next
					// batch instead. An _id made for it here was never sent,
					// so the one it is given there is its only one.
					__rewind(before);
					break;
				}

				if (ids.length == next) {
					ids.push(id);
				}

				next++;
			}

			__endSequence(sequence);
			var reply:Dynamic = __send(result.acknowledged);

			if (!result.acknowledged) {
				continue;
			}

			if (!__isOk(reply)) {
				// Refused whole, after earlier batches may have been stored,
				// which the error says through its result.
				throw __errorOf("insert", reply, result);
			}

			result.__add(__int(Reflect.field(reply, "n")), 0, 0, 0);
			__collectWriteErrors(reply, batchStart, errors);

			if (concernError == null) {
				concernError = __writeConcernError(reply);
			}

			if (errors.length > 0 && ordered) {
				break;
			}
		}

		__lastAffected = result.inserted;

		// The last document stored: before the first failure when ordered,
		// the last that did not fail otherwise. Unacknowledged, the last sent.
		var last:Int = ids.length - 1;

		if (result.acknowledged && errors.length > 0) {
			if (ordered) {
				last = errors[0].index - 1;
			} else {
				var failed:Map<Int, Bool> = [for (error in errors) error.index => true];

				while (last >= 0 && failed.exists(last)) {
					last--;
				}
			}
		}

		if (last >= 0) {
			__lastInsertId = ids[last];
		}

		__raiseWriteFailure("insert", errors, concernError, result);
		return result;
	}

	/** Inserts one document, and answers its `_id`. **/
	public function insertOne(collection:String, document:Dynamic, ?options:MongoInsertOptions):Dynamic {
		return insert(collection, [document], options).insertedIds[0];
	}

	/**
		Finds documents matching `filter`, all of them when it is `null`,
		and answers a cursor over them.
	**/
	public function find(collection:String, ?filter:Dynamic, ?options:MongoFindOptions):MongoCursor {
		var w:BsonWriter = __begin("find", collection);

		if (filter != null) {
			w.value("filter", filter, 1);
		}

		var batchSize:Int = -1;
		var maxTimeMS:Int = -1;

		if (options != null) {
			if (options.sort != null) {
				w.value("sort", __ordered(options.sort, "sort"), 1);
			}

			if (options.projection != null) {
				w.value("projection", options.projection, 1);
			}

			if (options.skip != null && options.skip > 0) {
				w.value("skip", options.skip, 1);
			}

			if (options.limit != null && options.limit > 0) {
				w.value("limit", options.limit, 1);
			}

			if (options.batchSize != null && options.batchSize >= 0) {
				batchSize = options.batchSize;
				w.value("batchSize", batchSize, 1);
			}

			if (options.hint != null) {
				w.value("hint", __ordered(options.hint, "hint"), 1);
			}

			if (options.maxTimeMS != null && options.maxTimeMS > 0) {
				maxTimeMS = options.maxTimeMS;
				w.value("maxTimeMS", maxTimeMS, 1);
			}

			if (options.collation != null) {
				w.value("collation", options.collation, 1);
			}

			if (options.comment != null) {
				w.value("comment", options.comment, 1);
			}
		}

		__endBody(__database, null, true);
		return __cursorFrom(__check("find", __send(true)), batchSize, maxTimeMS);
	}

	/** The first document matching `filter`, or `null` when none does. **/
	public function findOne(collection:String, ?filter:Dynamic, ?options:MongoFindOptions):Dynamic {
		var single:MongoFindOptions = {
			limit: 1,
			batchSize: 1
		};

		if (options != null) {
			single.sort = options.sort;
			single.projection = options.projection;
			single.skip = options.skip;
			single.hint = options.hint;
			single.maxTimeMS = options.maxTimeMS;
			single.collation = options.collation;
			single.comment = options.comment;
		}

		var cursor:MongoCursor = find(collection, filter, single);
		var document:Dynamic = cursor.next();
		cursor.close();
		return document;
	}

	/**
		Applies `update`, operators such as `{"$set": {...}}`, a replacement
		document, or a pipeline array, to the first document matching
		`filter`, or to every one with `multi`.
	**/
	public function update(collection:String, filter:Dynamic, update:Dynamic, ?options:MongoUpdateOptions):MongoWriteResult {
		if (filter == null) {
			throw new ArgumentError("update needs a filter; {} matches every document.");
		}

		if (update == null) {
			throw new ArgumentError("update needs an update document.");
		}

		var statement:BsonDocument = new BsonDocument().add("q", filter).add("u", update);

		if (options != null) {
			if (options.upsert == true) {
				statement.add("upsert", true);
			}

			if (options.multi == true) {
				statement.add("multi", true);
			}

			if (options.arrayFilters != null) {
				statement.add("arrayFilters", options.arrayFilters);
			}

			if (options.hint != null) {
				statement.add("hint", __ordered(options.hint, "hint"));
			}

			if (options.collation != null) {
				statement.add("collation", options.collation);
			}
		}

		return __write("update", "updates", collection, [statement], options != null ? options.writeConcern : null);
	}

	/**
		Deletes every document matching `filter`, or only the first with
		`justOne`. An empty filter `{}` matches every document; `null` is
		refused rather than read as that.
	**/
	public function delete(collection:String, filter:Dynamic, ?options:MongoDeleteOptions):MongoWriteResult {
		if (filter == null) {
			throw new ArgumentError("delete needs a filter; {} matches every document.");
		}

		var statement:BsonDocument = new BsonDocument().add("q", filter).add("limit", options != null && options.justOne == true ? 1 : 0);

		if (options != null) {
			if (options.hint != null) {
				statement.add("hint", __ordered(options.hint, "hint"));
			}

			if (options.collation != null) {
				statement.add("collation", options.collation);
			}
		}

		return __write("delete", "deletes", collection, [statement], options != null ? options.writeConcern : null);
	}

	/** Runs an aggregation pipeline and answers a cursor over its output. **/
	public function aggregate(collection:String, pipeline:Array<Dynamic>, ?options:MongoAggregateOptions):MongoCursor {
		if (pipeline == null) {
			throw new ArgumentError("aggregate needs a pipeline; [] passes every document through.");
		}

		var w:BsonWriter = __begin("aggregate", collection);
		w.value("pipeline", pipeline, 1);
		var cursor:BsonDocument = new BsonDocument();
		var batchSize:Int = -1;
		var maxTimeMS:Int = -1;
		var concern:Null<MongoWriteConcern> = null;

		if (options != null) {
			if (options.batchSize != null && options.batchSize >= 0) {
				batchSize = options.batchSize;
				cursor.add("batchSize", batchSize);
			}

			if (options.maxTimeMS != null && options.maxTimeMS > 0) {
				maxTimeMS = options.maxTimeMS;
				w.value("maxTimeMS", maxTimeMS, 1);
			}

			if (options.allowDiskUse != null) {
				w.value("allowDiskUse", options.allowDiskUse, 1);
			}

			if (options.hint != null) {
				w.value("hint", __ordered(options.hint, "hint"), 1);
			}

			if (options.collation != null) {
				w.value("collation", options.collation, 1);
			}

			if (options.comment != null) {
				w.value("comment", options.comment, 1);
			}

			concern = options.writeConcern;
		}

		w.value("cursor", cursor, 1);
		__endBody(__database, concern, true);
		return __cursorFrom(__check("aggregate", __send(true)), batchSize, maxTimeMS);
	}

	/**
		Counts the documents matching `filter`, with the `count` command. Not
		allowed inside a transaction; there, aggregate with `$count`.
	**/
	public function count(collection:String, ?filter:Dynamic, ?options:MongoCountOptions):Int {
		var w:BsonWriter = __begin("count", collection);

		if (filter != null) {
			w.value("query", filter, 1);
		}

		if (options != null) {
			if (options.skip != null && options.skip > 0) {
				w.value("skip", options.skip, 1);
			}

			if (options.limit != null && options.limit > 0) {
				w.value("limit", options.limit, 1);
			}

			if (options.hint != null) {
				w.value("hint", __ordered(options.hint, "hint"), 1);
			}

			if (options.maxTimeMS != null && options.maxTimeMS > 0) {
				w.value("maxTimeMS", options.maxTimeMS, 1);
			}
		}

		__endBody(__database, null, true);
		return __int(Reflect.field(__check("count", __send(true)), "n"));
	}

	/** Creates indexes on a collection, which the server makes if it does not exist. **/
	public function createIndexes(collection:String, indexes:Array<MongoIndex>):Void {
		if (indexes == null || indexes.length == 0) {
			throw new ArgumentError("createIndexes needs at least one index.");
		}

		var specs:Array<Dynamic> = [];

		for (index in indexes) {
			if (index.key == null) {
				throw new ArgumentError("An index needs a key.");
			}

			var key:Dynamic = __ordered(index.key, "an index key");
			var spec:BsonDocument = new BsonDocument().add("key", key).add("name", index.name != null ? index.name : __indexName(key));

			if (index.unique == true) {
				spec.add("unique", true);
			}

			if (index.sparse == true) {
				spec.add("sparse", true);
			}

			if (index.expireAfterSeconds != null) {
				spec.add("expireAfterSeconds", index.expireAfterSeconds);
			}

			if (index.partialFilterExpression != null) {
				spec.add("partialFilterExpression", index.partialFilterExpression);
			}

			if (index.collation != null) {
				spec.add("collation", index.collation);
			}

			specs.push(spec);
		}

		var w:BsonWriter = __begin("createIndexes", collection);
		w.value("indexes", specs, 1);
		__endBody(__database, writeConcern, true);
		__check("createIndexes", __send(true), true);
	}

	/** Creates one index and answers its name. **/
	public function createIndex(collection:String, key:Dynamic, ?options:{?name:String, ?unique:Bool, ?sparse:Bool, ?expireAfterSeconds:Int,
		?partialFilterExpression:Dynamic, ?collation:Dynamic}):String {
		var index:MongoIndex = {key: key};

		if (options != null) {
			index.name = options.name;
			index.unique = options.unique;
			index.sparse = options.sparse;
			index.expireAfterSeconds = options.expireAfterSeconds;
			index.partialFilterExpression = options.partialFilterExpression;
			index.collation = options.collation;
		}

		createIndexes(collection, [index]);
		return index.name != null ? index.name : __indexName(__ordered(key, "an index key"));
	}

	/**
		Drops a collection. Answers `false` when the server says there was
		none to drop, which a server before MongoDB 7.0 does. From 7.0 a
		server reports success for a collection that is not there, so this
		answers `true` from those either way.
	**/
	public function drop(collection:String):Bool {
		__begin("drop", collection);
		__endBody(__database, writeConcern, true);
		var reply:Dynamic = __send(true);

		if (!__isOk(reply) && __int(Reflect.field(reply, "code")) == MongoError.NAMESPACE_NOT_FOUND) {
			return false;
		}

		__check("drop", reply, true);
		return true;
	}

	/**
		Starts a transaction on this connection's session. Nothing is sent
		until the first command, which carries it to the server.

		@throws SQLError When one is already open, or the server cannot run
		transactions, a standalone server cannot; they need a replica set
		or a sharded cluster.
	**/
	public function begin():Void {
		__requireConnected();

		if (__txnState != TXN_NONE) {
			__fail(SQLEvent.BEGIN, "Begin failed", "a transaction is already open on this connection");
		}

		var why:String = __transactionsUnavailable();

		if (why != null) {
			__fail(SQLEvent.BEGIN, "Begin failed", why);
		}

		if (__sessionId == null) {
			__sessionId = new BsonDocument().add("id", BsonBinary.randomUuid());
		}

		__txnNumber = __txnNumber + Int64.ofInt(1);
		__txnState = TXN_STARTING;
		__dispatchEvent(new SQLEvent(SQLEvent.BEGIN));
	}

	/**
		Commits the transaction, or throws an `SQLError` saying why not, a
		`MongoError` when the server refused, with its labels:
		`UnknownTransactionCommitResult` means the commit may have happened
		and may be retried, `TransientTransactionError` that the whole
		transaction may be.

		After a failed commit `inTransaction` stays `true`: the transaction may
		still be open on the server, and a `rollback` ends it either way. A
		commit with nothing sent since `begin` sends nothing.
	**/
	public function commit():Void {
		if (__txnState == TXN_NONE) {
			__fail(SQLEvent.COMMIT, "Commit failed", "no transaction is open on this connection");
		}

		if (__txnState == TXN_STARTING) {
			__txnState = TXN_NONE;
			__dispatchEvent(new SQLEvent(SQLEvent.COMMIT));
			return;
		}

		try {
			__endTransaction("commitTransaction");
		} catch (e:Dynamic) {
			if (__wire == null || __wire.closed) {
				// The connection is gone, and the session's transaction with it.
				__txnState = TXN_NONE;
			}

			__failWith(SQLEvent.COMMIT, "Commit failed", e);
		}

		__txnState = TXN_NONE;
		__dispatchEvent(new SQLEvent(SQLEvent.COMMIT));
	}

	/**
		Aborts the transaction. A server that has already ended it, after a
		failed statement, or its time limit, is not an error: the transaction
		is over either way, which is what was asked. A connection that fails
		under it is, since its state is then unknown; it is closed.
	**/
	public function rollback():Void {
		if (__txnState == TXN_NONE) {
			__dispatchEvent(new SQLEvent(SQLEvent.ROLLBACK));
			return;
		}

		if (__txnState == TXN_STARTING) {
			__txnState = TXN_NONE;
			__dispatchEvent(new SQLEvent(SQLEvent.ROLLBACK));
			return;
		}

		var failure:Dynamic = null;

		try {
			__endTransaction("abortTransaction");
		} catch (e:MongoError) {
			// NoSuchTransaction and its kin: already over on the server.
		} catch (e:Dynamic) {
			failure = e;
		}

		__txnState = TXN_NONE;

		if (failure != null) {
			__failWith(SQLEvent.ROLLBACK, "Rollback failed", failure);
		}

		__dispatchEvent(new SQLEvent(SQLEvent.ROLLBACK));
	}

	private function get_connected():Bool {
		return __wire != null && !__wire.closed;
	}

	private function get_inTransaction():Bool {
		return __txnState != TXN_NONE;
	}

	private function get_affectedRows():Int {
		return __lastAffected;
	}

	private function get_lastInsertId():Dynamic {
		return __lastInsertId;
	}

	private function get_database():String {
		return __database;
	}

	private function get_serverInfo():Dynamic {
		return __hello;
	}

	private function get_serverVersion():String {
		if (__serverVersion != null) {
			return __serverVersion;
		}

		try {
			__begin("buildInfo", 1);
			__endBody("admin", null, false);
			var reply:Dynamic = __check("buildInfo", __send(true));
			var version:Dynamic = Reflect.field(reply, "version");
			__serverVersion = version == null ? "" : Std.string(version);
			return __serverVersion;
		} catch (_:Dynamic) {
			return "";
		}
	}

	// ------------------------------------------------------------ handshake

	/**
		Connects to one host, says hello and authenticates. Answers `null` when
		the host will do, or why it will not.
	**/
	@:noCompletion private function __connectTo(host:MongoHost, settings:MongoSettings):String {
		var socket:FlexSocket = new FlexSocket(settings.tls);
		var peer:String = host.host + ":" + host.port;

		try {
			if (settings.tls) {
				__configureTls(socket, settings, host.host);
			}

			// Not on eval, which raises an expired socket timeout as a native
			// error no Haxe catch intercepts: the interpreter aborts instead of
			// the call failing.
			#if !eval
			if (settings.connectTimeout > 0) {
				socket.setTimeout(settings.connectTimeout);
			}
			#end

			socket.connect(host.host, host.port);

			if (settings.tls) {
				socket.handshake();
			}

			// Unlimited unless asked: a read timing out mid-reply leaves the
			// connection out of step, so it is closed, and a long aggregation
			// is a legitimate wait. The server bounds an operation with
			// maxTimeMS instead.
			#if !eval
			socket.setTimeout(settings.socketTimeout);
			#end

			// Replies are waited on one at a time, so Nagle's delay would be paid on
			// every command. Best effort: a socket that cannot say is still usable.
			try {
				socket.setFastSend(true);
			} catch (_:Dynamic) {}
		} catch (e:Dynamic) {
			try {
				socket.close();
			} catch (_:Dynamic) {}

			throw new IOError('Connecting to MongoDB at $peer failed: ${Std.string(e)}');
		}

		__wire = new MongoWire(socket, __reader, peer);

		var scram:Scram = null;
		var mechanism:String = settings.authMechanism;
		var credentials:Bool = settings.username != null || mechanism == "MONGODB-X509";
		var authSource:String = settings.effectiveAuthSource();

		var w:BsonWriter = __begin("hello", 1);
		__clientMetadata(w, settings);
		w.value("compression", [], 1);

		if (credentials && mechanism == null) {
			w.value("saslSupportedMechs", authSource + "." + settings.username, 1);
		}

		// The first step of authentication rides along with the hello, which
		// saves a round trip on every connection a pool opens.
		if (credentials) {
			var speculative:BsonDocument = null;

			if (mechanism == null || mechanism == Scram.SHA256 || mechanism == Scram.SHA1) {
				scram = new Scram(mechanism == null ? Scram.SHA256 : mechanism, settings.username, settings.password);
				speculative = new BsonDocument()
					.add("saslStart", 1)
					.add("mechanism", scram.mechanism)
					.add("payload", scram.clientFirst())
					.add("options", new BsonDocument().add("skipEmptyExchange", true))
					.add("db", authSource);
			} else if (mechanism == "MONGODB-X509") {
				speculative = new BsonDocument().add("authenticate", 1).add("mechanism", "MONGODB-X509").add("db", "$external");
			}

			if (speculative != null) {
				w.value("speculativeAuthenticate", speculative, 1);
			}
		}

		__endBody("admin", null, false);
		var hello:Dynamic = __send(true);

		if (!__isOk(hello) && __int(Reflect.field(hello, "code")) == MongoError.COMMAND_NOT_FOUND) {
			// Before 4.4.2 the command was isMaster.
			scram = null;
			w = __begin("isMaster", 1);
			__clientMetadata(w, settings);

			if (credentials && mechanism == null) {
				w.value("saslSupportedMechs", authSource + "." + settings.username, 1);
			}

			__endBody("admin", null, false);
			hello = __send(true);
		}

		__check("hello", hello);
		__hello = hello;

		var maxWire:Int = __int(Reflect.field(hello, "maxWireVersion"));
		var minWire:Int = __int(Reflect.field(hello, "minWireVersion"));

		if (maxWire < MIN_WIRE_VERSION) {
			return 'the server speaks wire version $maxWire; this client needs $MIN_WIRE_VERSION (MongoDB 3.6) or newer';
		}

		if (minWire > MAX_WIRE_VERSION) {
			return 'the server needs wire version $minWire; this client speaks up to $MAX_WIRE_VERSION';
		}

		__maxWireVersion = maxWire;
		__maxBsonObjectSize = __positive(Reflect.field(hello, "maxBsonObjectSize"), 16777216);
		__maxWriteBatchSize = __positive(Reflect.field(hello, "maxWriteBatchSize"), 100000);
		__wire.maxMessageSize = __positive(Reflect.field(hello, "maxMessageSizeBytes"), 48000000);

		var setName:Dynamic = Reflect.field(hello, "setName");

		if (settings.replicaSet != null && setName != settings.replicaSet) {
			return 'it is ${setName == null ? "not in a replica set" : "in replica set " + setName}, not ${settings.replicaSet}';
		}

		if (!settings.directConnection && !__writable(hello)) {
			return "it is not the primary";
		}

		if (credentials) {
			__authenticate(settings, mechanism, scram, authSource, Reflect.field(hello, "speculativeAuthenticate"));
		}

		return null;
	}

	@:noCompletion private function __clientMetadata(w:BsonWriter, settings:MongoSettings):Void {
		var client:BsonDocument = new BsonDocument()
			.add("driver", new BsonDocument().add("name", "crossbyte").add("version", "1.0"))
			.add("os", new BsonDocument().add("type", __osType()))
			.add("platform", "Haxe " + __target());

		if (settings.appName != null && settings.appName != "") {
			client.add("application", new BsonDocument().add("name", settings.appName.substr(0, 128)));
		}

		w.value("client", client, 1);
	}

	/** Whether the server takes writes: a primary, a mongos, or a standalone. **/
	@:noCompletion private static function __writable(hello:Dynamic):Bool {
		return __isTrue(Reflect.field(hello, "isWritablePrimary")) || __isTrue(Reflect.field(hello, "ismaster")) || Reflect.field(hello, "msg") == "isdbgrid";
	}

	@:noCompletion private function __authenticate(settings:MongoSettings, mechanism:String, scram:Scram, authSource:String, speculative:Dynamic):Void {
		if (mechanism == "MONGODB-X509") {
			if (speculative != null) {
				return;
			}

			var w:BsonWriter = __begin("authenticate", 1);
			w.value("mechanism", "MONGODB-X509", 1);

			if (settings.username != null) {
				w.value("user", settings.username, 1);
			}

			__endBody("$external", null, false);
			__checkAuth(__send(true));
			return;
		}

		if (mechanism == "PLAIN") {
			// RFC 4616: an empty authorization identity, the user, the
			// password, each after a NUL.
			var plain:haxe.io.BytesBuffer = new haxe.io.BytesBuffer();
			plain.addByte(0);
			plain.add(Bytes.ofString(settings.username));
			plain.addByte(0);
			plain.add(Bytes.ofString(settings.password == null ? "" : settings.password));
			var payload:Bytes = plain.getBytes();
			__begin("saslStart", 1);
			__writer.value("mechanism", "PLAIN", 1);
			__writer.value("payload", payload, 1);
			__writer.value("autoAuthorize", 1, 1);
			__endBody(authSource, null, false);
			__checkAuth(__send(true));
			return;
		}

		// The server's answer to the speculative start is the saslStart reply
		// itself, without an ok field; one it could not take is simply absent.
		var reply:Dynamic = speculative;

		if (reply == null || scram == null) {
			// Negotiate. The server's list of the user's mechanisms decides
			// between SHA-256 and SHA-1 when the config did not, and a server
			// that sends no list, older than 4.0, or no such user, gets
			// SHA-1, as the MongoDB authentication specification has it.
			var chosen:String = mechanism;

			if (chosen == null) {
				var mechanisms:Dynamic = __hello != null ? Reflect.field(__hello, "saslSupportedMechs") : null;
				chosen = Std.isOfType(mechanisms, Array) && (mechanisms : Array<Dynamic>).indexOf(Scram.SHA256) >= 0 ? Scram.SHA256 : Scram.SHA1;
			}

			scram = new Scram(chosen, settings.username, settings.password);
			__begin("saslStart", 1);
			__writer.value("mechanism", chosen, 1);
			__writer.value("payload", scram.clientFirst(), 1);
			__writer.value("autoAuthorize", 1, 1);
			__writer.value("options", new BsonDocument().add("skipEmptyExchange", true), 1);
			__endBody(authSource, null, false);
			reply = __checkAuth(__send(true));
		}

		var conversation:Dynamic = Reflect.field(reply, "conversationId");
		var proof:Bytes = scram.clientFinal(__payload(reply));
		__begin("saslContinue", 1);
		__writer.value("conversationId", conversation, 1);
		__writer.value("payload", proof, 1);
		__endBody(authSource, null, false);
		reply = __checkAuth(__send(true));
		scram.verifyServer(__payload(reply));

		// A server that does not honour skipEmptyExchange wants one more,
		// empty, turn before it says done.
		var turns:Int = 0;

		while (!__isTrue(Reflect.field(reply, "done"))) {
			if (++turns > 2) {
				throw new IOError("The server did not finish the SCRAM exchange.");
			}

			__begin("saslContinue", 1);
			__writer.value("conversationId", conversation, 1);
			__writer.value("payload", Bytes.alloc(0), 1);
			__endBody(authSource, null, false);
			reply = __checkAuth(__send(true));
		}
	}

	@:noCompletion private function __checkAuth(reply:Dynamic):Dynamic {
		if (!__isOk(reply)) {
			var error:MongoError = __errorOf("authenticate", reply);
			// Authentication failed: the connection is done with.
			__drop();
			throw error;
		}

		return reply;
	}

	@:noCompletion private static function __payload(reply:Dynamic):Bytes {
		var payload:Dynamic = Reflect.field(reply, "payload");

		if (Std.isOfType(payload, Bytes)) {
			return payload;
		}

		if (Std.isOfType(payload, BsonBinary)) {
			return (payload : BsonBinary).data;
		}

		throw new IOError("The server's SASL reply carries no payload.");
	}

	@:noCompletion private function __configureTls(socket:FlexSocket, settings:MongoSettings, host:String):Void {
		if (settings.tlsAllowInvalidCertificates) {
			socket.verifyCert = false;
		}

		if (settings.tlsCAFile != null) {
			socket.setCA(__loadCertificate(settings.tlsCAFile));
		}

		if (settings.tlsCertificateKeyFile != null) {
			socket.setCertificate(__loadCertificate(settings.tlsCertificateKeyFile), __loadKey(settings.tlsCertificateKeyFile, settings.tlsCertificateKeyFilePassword));
		}

		socket.setHostname(host);
	}

	#if (java || jvm)
	@:noCompletion private static function __loadCertificate(path:String) {
		return crossbyte._internal.socket._jvm.JvmSsl.JvmSslCertificate.loadFile(path);
	}

	@:noCompletion private static function __loadKey(path:String, password:String) {
		return crossbyte._internal.socket._jvm.JvmSsl.JvmSslKey.loadFile(path, false, password);
	}
	#else
	@:noCompletion private static function __loadCertificate(path:String):sys.ssl.Certificate {
		return sys.ssl.Certificate.loadFile(path);
	}

	@:noCompletion private static function __loadKey(path:String, password:String):sys.ssl.Key {
		return sys.ssl.Key.loadFile(path, false, password);
	}
	#end

	// ------------------------------------------------------------ messages

	/**
		Starts a command message in the connection's writer: the header, the
		flags, and the body document with the command's own field first.
		Answers the writer, positioned for the command's other fields.
	**/
	@:noCompletion private function __begin(name:String, value:Dynamic):BsonWriter {
		__requireConnected();
		var w:BsonWriter = __writer;
		w.reset();
		__requestId = __wire.nextRequestId();
		w.int32(0);
		w.int32(__requestId);
		w.int32(0);
		w.int32(MongoWire.OP_MSG);
		w.int32(0);
		w.byte(0);
		__bodyStart = w.beginDocument();
		w.value(name, value, 1);
		return w;
	}

	/**
		Ends the body: the transaction's fields when one is open and the
		command belongs in it, the write concern (never inside a transaction,
		where only the commit carries one), and `$db`.
	**/
	@:noCompletion private function __endBody(database:String, concern:Null<MongoWriteConcern>, transactional:Bool):Void {
		var w:BsonWriter = __writer;

		__startsTransaction = false;

		if (transactional && __txnState != TXN_NONE) {
			w.value("lsid", __sessionId, 1);
			w.int64Field("txnNumber", __txnNumber);

			if (__txnState == TXN_STARTING) {
				w.value("startTransaction", true, 1);
				// Started once this is sent, see __send, and not before: a
				// command refused here, too large to send, starts nothing.
				__startsTransaction = true;
			}

			w.value("autocommit", false, 1);
		} else if (concern != null) {
			w.value("writeConcern", __concernDocument(concern), 1);
		}

		w.value("$db", database, 1);
		w.endDocument(__bodyStart);

		var size:Int = w.length - __bodyStart;

		// A command may exceed a document's limit by the room the server
		// allows for its own fields.
		if (size > __maxBsonObjectSize + 16 * 1024) {
			throw new ArgumentError('The command is $size bytes; the server takes at most ${__maxBsonObjectSize + 16 * 1024}.');
		}
	}

	/** Starts a kind 1 section: a named sequence of documents after the body. **/
	@:noCompletion private function __beginSequence(name:String):Int {
		var w:BsonWriter = __writer;
		w.byte(1);
		var at:Int = w.length;
		w.int32(0);
		w.cstring(name);
		return at;
	}

	@:noCompletion private function __endSequence(at:Int):Void {
		__writer.patchInt32(at, __writer.length - at);
	}

	/** Undoes the writer to `length`, for a document that goes in the next message. **/
	@:noCompletion private inline function __rewind(length:Int):Void {
		@:privateAccess __writer.length = length;
	}

	/**
		Sends the message the writer holds and answers the reply's body, or
		`null` when no reply is wanted, a write with `w: 0`, sent with
		moreToCome, which the server does not answer.
	**/
	@:noCompletion private function __send(expectReply:Bool):Dynamic {
		var w:BsonWriter = __writer;
		w.patchInt32(0, w.length);

		if (!expectReply) {
			w.patchInt32(16, MongoWire.MORE_TO_COME);
		}

		if (w.length > __wire.maxMessageSize) {
			throw new ArgumentError('The message is ${w.length} bytes; the server takes at most ${__wire.maxMessageSize}.');
		}

		__wire.send(w);

		if (__startsTransaction) {
			// The server may hold the transaction from here, whether or not
			// this command succeeds, so it has to be ended.
			__startsTransaction = false;
			__txnState = TXN_IN_PROGRESS;
		}

		if (!expectReply) {
			return null;
		}

		return __wire.receive(__requestId);
	}

	/**
		The reply when the server reports success; otherwise the `MongoError`
		it describes, thrown. With `writes`, a write concern error or write
		errors in a successful reply are left for the caller, which knows what
		was applied.
	**/
	@:noCompletion private function __check(operation:String, reply:Dynamic, writes:Bool = false):Dynamic {
		if (!__isOk(reply)) {
			throw __errorOf(operation, reply);
		}

		if (!writes) {
			return reply;
		}

		var concern:MongoWriteError = __writeConcernError(reply);
		var errors:Array<MongoWriteError> = [];
		__collectWriteErrors(reply, 0, errors);

		if (operation != "insert" && operation != "update" && operation != "delete" && (concern != null || errors.length > 0)) {
			__raiseWriteFailure(operation, errors, concern, null);
		}

		return reply;
	}

	@:noCompletion private function __write(operation:String, sequenceName:String, collection:String, statements:Array<BsonDocument>,
			concern:Null<MongoWriteConcern>):MongoWriteResult {
		if (concern == null) {
			concern = writeConcern;
		}

		var result:MongoWriteResult = new MongoWriteResult(!__unacknowledged(concern));
		__begin(operation, collection);
		__writer.value("ordered", true, 1);
		__endBody(__database, concern, true);
		var sequence:Int = __beginSequence(sequenceName);

		for (statement in statements) {
			__writer.document(statement, 0);
		}

		__endSequence(sequence);
		var reply:Dynamic = __send(result.acknowledged);

		if (!result.acknowledged) {
			__lastAffected = 0;
			return result;
		}

		__check(operation, reply, true);
		var n:Int = __int(Reflect.field(reply, "n"));

		if (operation == "update") {
			var upserted:Dynamic = Reflect.field(reply, "upserted");

			if (Std.isOfType(upserted, Array)) {
				for (entry in (upserted : Array<Dynamic>)) {
					result.upserted.push({index: __int(Reflect.field(entry, "index")), id: Reflect.field(entry, "_id")});
				}
			}

			result.__add(0, n - result.upserted.length, __int(Reflect.field(reply, "nModified")), 0);

			if (result.upserted.length > 0) {
				__lastInsertId = result.upserted[result.upserted.length - 1].id;
			}
		} else {
			result.__add(0, 0, 0, n);
		}

		__lastAffected = n;
		var errors:Array<MongoWriteError> = [];
		__collectWriteErrors(reply, 0, errors);
		__raiseWriteFailure(operation, errors, __writeConcernError(reply), result);
		return result;
	}

	@:noCompletion private function __raiseWriteFailure(operation:String, errors:Array<MongoWriteError>, concern:MongoWriteError, result:MongoWriteResult):Void {
		if (errors.length > 0) {
			var first:MongoWriteError = errors[0];
			var message:String = errors.length == 1 ? first.message : '${first.message} (and ${errors.length - 1} more)';
			throw new MongoError(operation, message, first.code, first.codeName, null, errors, concern, result);
		}

		if (concern != null) {
			throw new MongoError(operation, "the write was applied, but not with the write concern asked for: " + concern.message, concern.code,
				concern.codeName, null, [], concern, result);
		}
	}

	@:noCompletion private static function __collectWriteErrors(reply:Dynamic, offset:Int, into:Array<MongoWriteError>):Void {
		var errors:Dynamic = Reflect.field(reply, "writeErrors");

		if (!Std.isOfType(errors, Array)) {
			return;
		}

		for (entry in (errors : Array<Dynamic>)) {
			into.push({
				index: offset + __int(Reflect.field(entry, "index")),
				code: __int(Reflect.field(entry, "code")),
				codeName: __text(Reflect.field(entry, "codeName")),
				message: __text(Reflect.field(entry, "errmsg"))
			});
		}
	}

	@:noCompletion private static function __writeConcernError(reply:Dynamic):Null<MongoWriteError> {
		var error:Dynamic = Reflect.field(reply, "writeConcernError");

		if (error == null) {
			return null;
		}

		return {
			index: -1,
			code: __int(Reflect.field(error, "code")),
			codeName: __text(Reflect.field(error, "codeName")),
			message: __text(Reflect.field(error, "errmsg"))
		};
	}

	@:noCompletion private static function __errorOf(operation:String, reply:Dynamic, ?result:MongoWriteResult):MongoError {
		var labels:Array<String> = [];
		var raw:Dynamic = Reflect.field(reply, "errorLabels");

		if (Std.isOfType(raw, Array)) {
			for (label in (raw : Array<Dynamic>)) {
				labels.push(Std.string(label));
			}
		}

		var message:String = __text(Reflect.field(reply, "errmsg"));
		return new MongoError(operation, message == "" ? "the server reported failure" : message, __int(Reflect.field(reply, "code")),
			__text(Reflect.field(reply, "codeName")), labels, null, null, result, reply);
	}

	@:noCompletion private static function __concernDocument(concern:MongoWriteConcern):BsonDocument {
		var document:BsonDocument = new BsonDocument();

		if (concern.w != null) {
			document.add("w", concern.w);
		}

		if (concern.journal != null) {
			document.add("j", concern.journal);
		}

		if (concern.wtimeout != null) {
			document.add("wtimeout", concern.wtimeout);
		}

		return document;
	}

	@:noCompletion private function __unacknowledged(concern:Null<MongoWriteConcern>):Bool {
		// Only outside a transaction: inside one, writes are acknowledged by
		// the commit, and the statements themselves always answer.
		// `w` may be a number or a tag such as "majority": typed before it is
		// compared, since on the jvm comparing it with 0 casts it to Number.
		var w:Dynamic = concern != null ? concern.w : null;
		return __txnState == TXN_NONE && w != null && !Std.isOfType(w, String) && __number(w) == 0 && concern.journal != true;
	}

	// ------------------------------------------------------------ cursors

	@:noCompletion private function __cursorFrom(reply:Dynamic, batchSize:Int, maxTimeMS:Int):MongoCursor {
		var cursor:Dynamic = Reflect.field(reply, "cursor");

		if (cursor == null) {
			throw new MongoError("cursor", "the reply carries no cursor", 0, "", null, null, null, null, reply);
		}

		return new MongoCursor(this, __toInt64(Reflect.field(cursor, "id")), __text(Reflect.field(cursor, "ns")), Reflect.field(cursor, "firstBatch"),
			batchSize, maxTimeMS);
	}

	/** A cursor over a command's documents: its cursor's, or the reply itself. **/
	@:noCompletion private function __cursorOf(reply:Dynamic, name:String):MongoCursor {
		var cursor:Dynamic = Reflect.field(reply, "cursor");

		if (cursor != null && Reflect.hasField(cursor, "firstBatch")) {
			return __cursorFrom(reply, -1, -1);
		}

		return new MongoCursor(this, Int64.ofInt(0), "", [reply], -1, -1);
	}

	@:noCompletion private function __getMore(database:String, collection:String, id:Int64, batchSize:Int, maxTimeMS:Int):Dynamic {
		var w:BsonWriter = __begin("getMore", new BsonInt64(id));
		w.value("collection", collection, 1);

		if (batchSize > 0) {
			w.value("batchSize", batchSize, 1);
		}

		if (maxTimeMS > 0) {
			w.value("maxTimeMS", maxTimeMS, 1);
		}

		__endBody(database, null, true);
		return __check("getMore", __send(true));
	}

	@:noCompletion private function __killCursor(database:String, collection:String, id:Int64):Void {
		var w:BsonWriter = __begin("killCursors", collection);
		w.value("cursors", [new BsonInt64(id)], 1);
		__endBody(database, null, true);
		__check("killCursors", __send(true));
	}

	// ------------------------------------------------------------ transactions

	@:noCompletion private function __endTransaction(command:String):Void {
		var w:BsonWriter = __begin(command, 1);
		w.value("lsid", __sessionId, 1);
		w.int64Field("txnNumber", __txnNumber);
		w.value("autocommit", false, 1);

		if (writeConcern != null && command == "commitTransaction") {
			w.value("writeConcern", __concernDocument(writeConcern), 1);
		}

		__endBody("admin", null, false);
		__check(command, __send(true), true);
	}

	@:noCompletion private function __transactionsUnavailable():String {
		if (__hello == null) {
			return "the connection is not open";
		}

		if (Reflect.field(__hello, "logicalSessionTimeoutMinutes") == null) {
			return "the server does not support sessions";
		}

		var sharded:Bool = Reflect.field(__hello, "msg") == "isdbgrid";

		if (!sharded && Reflect.field(__hello, "setName") == null) {
			return "transactions need a replica set or a sharded cluster, and this server is a standalone";
		}

		if (__maxWireVersion < (sharded ? 8 : 7)) {
			return "the server is too old for transactions";
		}

		return null;
	}

	// ------------------------------------------------------------ helpers

	/** The config as a connection string; see `MongoUri.format`. **/
	@:noCompletion private function __buildUri(cfg:MongoConfig):String {
		return MongoUri.format(cfg);
	}

	@:noCompletion private function __requireConnected():Void {
		if (__wire == null || __wire.closed) {
			throw new IOError("The MongoConnection is not open.");
		}
	}

	/** Closes the socket and forgets the session: after a failure, or on close. **/
	@:noCompletion private function __drop():Void {
		if (__wire != null) {
			__wire.close();
			__wire = null;
		}

		__txnState = TXN_NONE;
		__sessionId = null;
		__serverVersion = null;
	}

	/**
		A command as a `BsonDocument`, whose first field is its name. An
		anonymous object of several fields would name whichever the target put
		first, so only one of a single field is taken.
	**/
	@:noCompletion private static function __commandDocument(command:Dynamic):BsonDocument {
		if (Std.isOfType(command, BsonDocument)) {
			if ((command : BsonDocument).length == 0) {
				throw new ArgumentError("A command document cannot be empty.");
			}

			return command;
		}

		if (Std.isOfType(command, String)) {
			var parsed:Dynamic = ExtendedJson.parse(command);

			if (!Std.isOfType(parsed, BsonDocument)) {
				throw new ArgumentError("A command is a JSON object.");
			}

			return __commandDocument(parsed);
		}

		if (BsonWriter.isPlainObject(command)) {
			var fields:Array<String> = Reflect.fields(command);

			if (fields.length == 1) {
				return new BsonDocument().add(fields[0], Reflect.field(command, fields[0]));
			}

			throw new ArgumentError('A command of ${fields.length} fields must be a BsonDocument or Extended JSON text: its first field names the command, and an anonymous object\'s order is not kept.');
		}

		throw new ArgumentError("A command is a BsonDocument, Extended JSON text, or an object of one field.");
	}

	/**
		`value` when its field order cannot matter or is kept, a
		`BsonDocument`, a name, an object of one field, and a refusal
		otherwise, rather than a sort by whichever field the target lists
		first.
	**/
	@:noCompletion private static function __ordered(value:Dynamic, what:String):Dynamic {
		if (value == null || Std.isOfType(value, BsonDocument) || Std.isOfType(value, String)) {
			return value;
		}

		if (BsonWriter.isPlainObject(value) && Reflect.fields(value).length > 1) {
			throw new ArgumentError('The order of $what\'s fields matters, and an anonymous object does not keep it on most targets; pass a BsonDocument: new BsonDocument().add(...).add(...).');
		}

		if (Std.isOfType(value, haxe.ds.StringMap) && Lambda.count((value : haxe.ds.StringMap<Dynamic>)) > 1) {
			throw new ArgumentError('The order of $what\'s fields matters, and a StringMap does not keep it; pass a BsonDocument.');
		}

		return value;
	}

	/** The name MongoDB gives an index by default: `field_1_other_-1`. **/
	@:noCompletion private static function __indexName(key:Dynamic):String {
		var parts:Array<String> = [];

		if (Std.isOfType(key, BsonDocument)) {
			var document:BsonDocument = key;

			for (i in 0...document.length) {
				parts.push(document.keyAt(i) + "_" + Std.string(document.valueAt(i)));
			}
		} else {
			for (name in Reflect.fields(key)) {
				parts.push(name + "_" + Std.string(Reflect.field(key, name)));
			}
		}

		return parts.join("_");
	}

	/**
		Whether a reply's field is the boolean `true`. Not `value == true`: on
		the jvm that casts the value to Boolean first, and a server's `1`,
		an Integer, then throws ClassCastException.
	**/
	@:noCompletion private static inline function __isTrue(value:Dynamic):Bool {
		return value != null && Std.isOfType(value, Bool) && (value : Bool);
	}

	@:noCompletion private static function __isOk(reply:Dynamic):Bool {
		if (reply == null) {
			return false;
		}

		var ok:Dynamic = Reflect.field(reply, "ok");
		return __isTrue(ok) || (ok != null && !Std.isOfType(ok, Bool) && !Std.isOfType(ok, String) && __number(ok) == 1);
	}

	/** A reply's number, whichever BSON number type it came as; 0 for anything else. **/
	@:noCompletion private static function __int(value:Dynamic):Int {
		if (value == null) {
			return 0;
		}

		if (Int64.isInt64(value)) {
			var wide:Int64 = value;
			return wide.high == (wide.low >> 31) ? wide.low : (wide.high < 0 ? -2147483648 : 2147483647);
		}

		if (Std.isOfType(value, Int)) {
			return Std.int(value);
		}

		if (Std.isOfType(value, Float)) {
			var number:Float = value;
			return number > 2147483647.0 ? 2147483647 : (number < -2147483648.0 ? -2147483648 : Std.int(number));
		}

		return 0;
	}

	@:noCompletion private static function __number(value:Dynamic):Float {
		if (Int64.isInt64(value)) {
			return crossbyte.db.mongodb._internal.Int64Float.toFloat(value);
		}

		if (Std.isOfType(value, Float) || Std.isOfType(value, Int)) {
			return value;
		}

		return Math.NaN;
	}

	/** A cursor id, which travels as an int64 but may come back as a smaller number. **/
	@:noCompletion private static function __toInt64(value:Dynamic):Int64 {
		if (value == null) {
			return Int64.ofInt(0);
		}

		if (Int64.isInt64(value)) {
			return value;
		}

		if (Std.isOfType(value, Int)) {
			return Int64.ofInt(Std.int(value));
		}

		if (Std.isOfType(value, Float)) {
			return Int64.fromFloat(value);
		}

		return Int64.ofInt(0);
	}

	@:noCompletion private static function __positive(value:Dynamic, fallback:Int):Int {
		var n:Int = __int(value);
		return n > 0 ? n : fallback;
	}

	@:noCompletion private static inline function __text(value:Dynamic):String {
		return value == null ? "" : Std.string(value);
	}

	@:noCompletion private static function __osType():String {
		var name:String = Sys.systemName();
		return name == "Mac" ? "Darwin" : name;
	}

	@:noCompletion private static function __target():String {
		#if cpp
		return "hxcpp";
		#elseif (java || jvm)
		return "jvm";
		#elseif eval
		return "eval";
		#elseif hl
		return "hl";
		#elseif neko
		return "neko";
		#elseif php
		return "php";
		#else
		return "sys";
		#end
	}

	/**
		Reports a failed transaction step both ways, as the other drivers do:
		as the `SQLErrorEvent` listeners expect, and as the `SQLError` thrown
		so a caller that does not listen cannot mistake it for success. The
		cause is carried as text, a Java exception passed where a `String`
		belongs is a ClassCastException on the jvm.
	**/
	@:noCompletion private function __fail(operation:String, message:String, reason:String):Void {
		var error:SQLError = new SQLError(operation, reason, message + ": " + reason);
		__dispatchEvent(new SQLErrorEvent(SQLErrorEvent.ERROR, error));
		throw error;
	}

	/** As `__fail`, keeping a `MongoError` as it is, so its code and labels reach the caller. **/
	@:noCompletion private function __failWith(operation:String, message:String, cause:Dynamic):Void {
		if (Std.isOfType(cause, SQLError)) {
			var error:SQLError = cause;
			__dispatchEvent(new SQLErrorEvent(SQLErrorEvent.ERROR, error));
			__rethrow(error);
			return;
		}

		__fail(operation, message, Std.string(cause));
	}

	@:noCompletion private static function __rethrow(e:Dynamic):Void {
		#if cpp
		cpp.Lib.rethrow(e);
		#else
		throw e;
		#end
	}
}
#else
/**
	Not on JavaScript. The driver's every call blocks its thread until the
	server answers, and JavaScript has neither a socket that can block nor,
	on Node, a second thread to block on; the browser has no TCP at all. The
	class is here so code naming it builds, as it did; it opens nothing.
	The BSON codec in `crossbyte.db.mongodb.bson` is built everywhere.
**/
class MongoConnection extends crossbyte.events.EventDispatcher {
	public static final isSupported:Bool = false;

	public function new() {
		super();
	}

	/** @throws crossbyte.errors.IOError Always: there is nothing here to connect with. **/
	public function open(cfg:MongoConfig):Void {
		throw new crossbyte.errors.IOError("MongoDB needs blocking sockets, which JavaScript does not have.");
	}

	/** The config as a connection string; see `MongoUri.format`. **/
	@:noCompletion private function __buildUri(cfg:MongoConfig):String {
		return crossbyte.db.mongodb._internal.MongoUri.format(cfg);
	}
}
#end
