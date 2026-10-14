package crossbyte.db.kv;

// Built where PostgresConnection is: not for the browser.
#if !(js && !nodejs)
import crossbyte.db.Migration;
import crossbyte.db.SchemaMigrator;
import crossbyte.db.kv._internal.KVKeys;
import crossbyte.db.kv._internal.KVWrites;
import crossbyte.db.kv._internal.KVWrites.PageReader;
import crossbyte.db.postgres.PostgresConfig;
import crossbyte.db.postgres.PostgresConnection;
import crossbyte.db.postgres.PostgresParameter;
import crossbyte.db.postgres.PostgresRawResult;
import crossbyte.db.postgres._internal.PostgresWire;
import crossbyte.errors.ArgumentError;
import crossbyte.errors.IllegalOperationError;
import haxe.io.Bytes;

/**
	A `KVStore` in PostgreSQL, natively: records several servers share.

	```haxe
	import crossbyte.db.kv.PostgresKVStore;
	import haxe.io.Bytes;

	var store = PostgresKVStore.open({host: "127.0.0.1", user: "game", password: "secret", database: "game"});
	store.put("users/alice", Bytes.ofString("{}"));
	store.close();
	```

	The records are rows of one table, `kv` unless `KVOptions.table` names
	another, which the store creates the first time it connects, through
	`SchemaMigrator.postgres()` (its advisory lock keeps instances starting
	together from both making it), recording it in `<table>_migrations`. The
	key is the table's primary key in the "C" collation, so keys sort by
	their bytes as on every other backend, and a scan is one index range.

	Every statement goes through `PostgresConnection.requestParams`, its
	values bound, a value as a binary `bytea`. Every write is one statement:
	an upsert, `INSERT ... ON CONFLICT DO UPDATE`, or an update, with the
	revision check in its `WHERE` and the record written back through
	`RETURNING`. At READ COMMITTED, PostgreSQL's default, a compare-and-set
	that another connection's write overtakes waits for it, finds the
	revision moved on and answers null. In a transaction at
	`REPEATABLE READ` or `SERIALIZABLE` (`PostgresConnection.isolationLevel`)
	the server fails it instead, with an `SQLError` saying it could not
	serialize: roll back and try the transaction again.

	**Threading.** One thread at a time, as its connection is; a
	`ConnectionPool` of them behind an `AsyncKVStore` for a server's
	runtimes. Not on PHP, whose driver has no bound parameters.
**/
class PostgresKVStore implements KVStore {
	/** Whether it runs here: natively, where the driver binds parameters. **/
	public static inline var isSupported:Bool = #if cpp true #else false #end;

	/** The connection it keeps its records through; the store's to close. **/
	public final connection:PostgresConnection;

	/** Its limits, table and clock. **/
	public final options:KVOptions;

	/** Whether a transaction is open on its connection, as the server says. **/
	public var inTransaction(get, null):Bool;

	@:noCompletion private var __closed:Bool = false;
	@:noCompletion private final __get:String;
	@:noCompletion private final __put:String;
	@:noCompletion private final __create:String;
	@:noCompletion private final __update:String;
	@:noCompletion private final __delete:String;
	@:noCompletion private final __deleteAt:String;
	@:noCompletion private final __scanLive:String;
	@:noCompletion private final __scanAll:String;
	@:noCompletion private final __purge:String;

	/**
		A store on `connection`, which must be open. Creates its table if the
		database has none. The connection is the store's from then on:
		`close()` closes it. Statements of your own on it may share a
		transaction with the store's writes.

		@throws ArgumentError When a limit or the table in `options` is not
		one, or the connection is not open.
		@throws IllegalOperationError When it does not run here.
		@throws SQLError When the table cannot be made.
	**/
	public function new(connection:PostgresConnection, ?options:KVOptions) {
		if (!isSupported) {
			throw new IllegalOperationError("PostgresKVStore needs the native PostgreSQL driver, which binds its values.");
		}

		if (connection == null || !connection.connected) {
			throw new ArgumentError("PostgresKVStore needs an open PostgresConnection.");
		}

		this.connection = connection;
		this.options = (options == null ? ({} : KVOptions) : options).__check();
		var t:String = this.options.table;
		var migrator:SchemaMigrator<PostgresConnection> = SchemaMigrator.postgres(t + "_migrations");
		migrator.addAll(migrations(t));
		migrator.migrate(connection);

		var written:String = " RETURNING revision, created_at, updated_at";
		var upsert:String = 'INSERT INTO $t AS r (record_key, record_value, revision, created_at, updated_at, deleted, value_schema) '
			+ 'VALUES ($$1, $$2, 1, $$3, $$3, FALSE, $$4) ON CONFLICT (record_key) DO UPDATE SET '
			+ 'record_value = EXCLUDED.record_value, revision = r.revision + 1, '
			+ 'created_at = CASE WHEN r.deleted THEN EXCLUDED.created_at ELSE r.created_at END, '
			+ 'updated_at = EXCLUDED.updated_at, deleted = FALSE, value_schema = EXCLUDED.value_schema';
		__put = upsert + written;
		__create = upsert + ' WHERE r.deleted' + written;
		__update = 'UPDATE $t SET record_value = $$2, revision = revision + 1, updated_at = $$3, value_schema = $$4 '
			+ 'WHERE record_key = $$1 AND NOT deleted AND revision = $$5' + written;
		var tombstone:String = 'UPDATE $t SET record_value = \'\'::bytea, revision = revision + 1, updated_at = $$2, deleted = TRUE, value_schema = 0 '
			+ 'WHERE record_key = $$1 AND NOT deleted';
		__delete = tombstone;
		__deleteAt = tombstone + ' AND revision = $$3';
		__get = 'SELECT revision, created_at, updated_at, value_schema, octet_length(record_value) AS size, '
			+ 'CASE WHEN octet_length(record_value) <= $$2 THEN record_value END AS value FROM $t WHERE record_key = $$1 AND NOT deleted';
		__scanLive = KVWrites.scanSql(t, "octet_length", "$1", "$2", "$3", "$4", "$5", "$6", "NOT deleted");
		__scanAll = KVWrites.scanSql(t, "octet_length", "$1", "$2", "$3", "$4", "$5", "$6", null);
		__purge = 'DELETE FROM $t WHERE deleted AND updated_at < $$1';
	}

	/**
		A store on a new connection to the server `config` names.

		@throws IOError When the server cannot be reached or refuses.
		@throws ArgumentError, IllegalOperationError, SQLError As the
		constructor.
	**/
	public static function open(config:PostgresConfig, ?options:KVOptions):PostgresKVStore {
		if (!isSupported) {
			throw new IllegalOperationError("PostgresKVStore needs the native PostgreSQL driver, which binds its values.");
		}

		var connection = new PostgresConnection();
		connection.open(config);

		try {
			return new PostgresKVStore(connection, options);
		} catch (e:Dynamic) {
			try {
				connection.close();
			} catch (_:Dynamic) {}

			#if cpp
			cpp.Lib.rethrow(e);
			#else
			throw e;
			#end
			return null;
		}
	}

	/**
		The migrations that make a store's table in PostgreSQL, for a
		migrator of your own; a store applies them itself, recorded in
		`<table>_migrations`.

		@throws ArgumentError When `table` is not a plain identifier of at
		most 48 characters.
	**/
	public static function migrations(table:String = KVOptions.DEFAULT_TABLE):Array<Migration<PostgresConnection>> {
		({table: table} : KVOptions).__check();
		return [
			Migration.ofStatements(1, 'create the key/value table $table', [
				'CREATE TABLE IF NOT EXISTS $table (record_key TEXT COLLATE "C" NOT NULL PRIMARY KEY, record_value BYTEA NOT NULL, '
				+ 'revision BIGINT NOT NULL, created_at DOUBLE PRECISION NOT NULL, updated_at DOUBLE PRECISION NOT NULL, '
				+ 'deleted BOOLEAN NOT NULL DEFAULT FALSE, value_schema INTEGER NOT NULL DEFAULT 0)',
				'CREATE INDEX IF NOT EXISTS ${table}_tombstones ON $table (updated_at) WHERE deleted'
			])
		];
	}

	public function get(key:String):Null<KVRecord> {
		KVKeys.check(key, options.maxKeyBytes, "A key", false);
		__requireOpen();
		var result:PostgresRawResult = connection.requestParams(__get, [Text(key), Text(Std.string(options.maxValueBytes))]);

		if (result.rows.length == 0) {
			return null;
		}

		var row = result.rows[0];
		KVWrites.checkSize(key, __float(row[4]), options.maxValueBytes);
		return new KVRecord(key, __bytea(row[5]), __float(row[0]), __float(row[1]), __float(row[2]), Std.int(__float(row[3])), false);
	}

	public function put(key:String, value:Bytes, schema:Int = 0):KVRecord {
		KVWrites.checkWrite(key, value, options);
		__requireOpen();
		return __written(key, value, schema, connection.requestParams(__put, [Text(key), Binary(value), __now(), Text(Std.string(schema))]));
	}

	public function compareAndSet(key:String, value:Bytes, expected:Float, schema:Int = 0):Null<KVRecord> {
		KVWrites.checkWrite(key, value, options);
		KVWrites.checkExpected(expected, false);
		__requireOpen();

		if (expected == 0) {
			return __written(key, value, schema, connection.requestParams(__create, [Text(key), Binary(value), __now(), Text(Std.string(schema))]));
		}

		return __written(key, value, schema,
			connection.requestParams(__update, [Text(key), Binary(value), __now(), Text(Std.string(schema)), Text(KVWrites.whole(expected))]));
	}

	public function delete(key:String):Bool {
		KVKeys.check(key, options.maxKeyBytes, "A key", false);
		__requireOpen();
		return connection.requestParams(__delete, [Text(key), __now()]).affectedRows > 0;
	}

	public function compareAndDelete(key:String, expected:Float):Bool {
		KVKeys.check(key, options.maxKeyBytes, "A key", false);
		KVWrites.checkExpected(expected, true);
		__requireOpen();
		return connection.requestParams(__deleteAt, [Text(key), __now(), Text(KVWrites.whole(expected))]).affectedRows > 0;
	}

	public function scan(?options:KVScanOptions):KVPage<KVRecord> {
		var scan:KVScanOptions = options == null ? ({} : KVScanOptions) : options;
		var range = KVKeys.rangeOf(scan, "", this.options.maxKeyBytes, this.options.maxScanLimit);
		__requireOpen();

		if (range == null) {
			return new KVPage([], false, null);
		}

		var result:PostgresRawResult = connection.requestParams(scan.includeTombstones ? __scanAll : __scanLive, [
			Text(range.low),
			Text(range.high),
			Text(Std.string(scan.limit + 1)),
			Text(Std.string(scan.limit)),
			Text(Std.string(this.options.maxValueBytes)),
			Text(Std.string(this.options.maxPageBytes))
		]);
		var page = new PageReader(scan.limit, this.options.maxValueBytes, this.options.maxPageBytes);

		for (row in result.rows) {
			var key:String = row[0].toString();

			if (!page.wants(Std.int(__float(row[7])), key, __float(row[6]), __float(row[8]))) {
				break;
			}

			var deleted:Bool = row[4] != null && row[4].toString() == "t";
			page.add(new KVRecord(key, deleted ? Bytes.alloc(0) : __bytea(row[9]), __float(row[1]), __float(row[2]), __float(row[3]),
				Std.int(__float(row[5])), deleted));
		}

		return page.finish();
	}

	public function purgeTombstones(before:Float):Int {
		__requireOpen();
		return Std.int(connection.requestParams(__purge, [Text(__floatText(before))]).affectedRows);
	}

	public function begin():Void {
		__requireOpen();

		if (connection.inTransaction) {
			throw new IllegalOperationError("PostgresKVStore: a transaction is open already, and they do not nest.");
		}

		connection.begin();
	}

	public function commit():Void {
		__requireOpen();

		if (!connection.inTransaction) {
			throw new IllegalOperationError("PostgresKVStore: commit() with no transaction open.");
		}

		connection.commit();
	}

	/** Rolls back the open transaction; does nothing when none is open, so it is safe in a `catch`. **/
	public function rollback():Void {
		if (__closed || !connection.inTransaction) {
			return;
		}

		connection.rollback();
	}

	public function close():Void {
		if (__closed) {
			return;
		}

		__closed = true;

		try {
			if (connection.inTransaction) {
				connection.rollback();
			}
		} catch (_:Dynamic) {}

		connection.close();
	}

	@:noCompletion private function get_inTransaction():Bool {
		return !__closed && connection.inTransaction;
	}

	/** The record a write answered with, or null when its condition held it back. **/
	@:noCompletion private static function __written(key:String, value:Bytes, schema:Int, result:PostgresRawResult):Null<KVRecord> {
		if (result.rows.length == 0) {
			return null;
		}

		var row = result.rows[0];
		return new KVRecord(key, value.sub(0, value.length), __float(row[0]), __float(row[1]), __float(row[2]), schema, false);
	}

	/** The clock's reading, as the text a `double precision` parameter takes. **/
	@:noCompletion private inline function __now():PostgresParameter {
		return Text(__floatText(options.__now()));
	}

	@:noCompletion private static function __floatText(value:Float):String {
		if (Math.isNaN(value) || !Math.isFinite(value)) {
			throw new ArgumentError('$value is not a time: the clock gave something other than seconds since the epoch.');
		}

		return Std.string(value);
	}

	@:noCompletion private static inline function __float(cell:Null<Bytes>):Float {
		return cell == null ? 0.0 : Std.parseFloat(cell.toString());
	}

	/** A `bytea` as the server sends it as text, `\x` and its hex. **/
	@:noCompletion private static inline function __bytea(cell:Null<Bytes>):Bytes {
		return cell == null ? Bytes.alloc(0) : PostgresWire.decodeByteaHex(cell);
	}

	@:noCompletion private inline function __requireOpen():Void {
		if (__closed) {
			throw new IllegalOperationError("PostgresKVStore: the store is closed.");
		}
	}
}
#end
