package crossbyte.db.kv;

// Built where SQLiteConnection is: not for JavaScript.
#if !js
import crossbyte.db.Migration;
import crossbyte.db.SchemaMigrator;
import crossbyte.db.kv._internal.KVKeys;
import crossbyte.db.kv._internal.KVWrites;
import crossbyte.db.kv._internal.KVWrites.PageReader;
import crossbyte.db.sql.SQLRow;
import crossbyte.db.sql.sqlite.JournalMode;
import crossbyte.db.sql.sqlite.SQLiteConnection;
import crossbyte.db.sql.sqlite.SQLiteMode;
import crossbyte.db.sql.sqlite.SQLiteStatement;
import crossbyte.db.sql.sqlite.SynchronousMode;
import crossbyte.errors.ArgumentError;
import crossbyte.errors.IllegalOperationError;
import haxe.io.Bytes;

/**
	A `KVStore` in an SQLite database, natively and on PHP, where
	`SQLiteConnection` opens one: a server's records on its own disk.

	```haxe
	import crossbyte.db.kv.SQLiteKVStore;
	import haxe.io.Bytes;

	var store = SQLiteKVStore.open("data/app.db");
	store.put("users/alice", Bytes.ofString("{}"));
	store.close();
	```

	The records are rows of one table, `kv` unless `KVOptions.table` names
	another, which the store creates the first time it opens a database,
	through `SchemaMigrator.sqlite()`, recording it in `<table>_migrations`.
	Its key is the table's primary key, so a get is an index lookup and a
	scan an index range from the low key to the high one.

	Every write is one statement: an upsert, `INSERT ... ON CONFLICT DO
	UPDATE`, with the revision check in its `WHERE`, rather than a read and
	then a write that another connection could come between. Natively it
	answers the record written through `RETURNING`, and its statements are
	prepared once and kept, their values bound. PHP's `sqlite3` runs a
	statement with `RETURNING` a second time as its rows are read, so there a
	write runs without it, and the record written is read back inside the
	same transaction (`BEGIN IMMEDIATE` unless one is open).

	**Threading.** One thread at a time, as its connection is. For several
	threads, or a server's runtime that must not wait for the disk, use a
	`ConnectionPool` of them (each its own connection to the file) behind an
	`AsyncKVStore`. Several connections, in this process or others, may use
	one file: `open()` sets WAL, so readers do not wait for a writer, and a
	writer waits up to the connection's `lockWaitTimeout` (5 s) for another.
**/
class SQLiteKVStore implements KVStore {
	/** Whether a database can be opened here: natively, and on PHP. **/
	public static inline var isSupported:Bool = SQLiteConnection.isSupported;

	/** The connection it keeps its records through; the store's to close. **/
	public final connection:SQLiteConnection;

	/** Its limits, table and clock. **/
	public final options:KVOptions;

	/** Whether a transaction is open on its connection. **/
	public var inTransaction(get, null):Bool;

	@:noCompletion private var __closed:Bool = false;
	@:noCompletion private final __get:SQLiteStatement;
	@:noCompletion private final __put:SQLiteStatement;
	@:noCompletion private final __create:SQLiteStatement;
	@:noCompletion private final __update:SQLiteStatement;
	@:noCompletion private final __delete:SQLiteStatement;
	@:noCompletion private final __deleteAt:SQLiteStatement;
	@:noCompletion private final __scanLive:SQLiteStatement;
	@:noCompletion private final __scanAll:SQLiteStatement;
	@:noCompletion private final __purge:SQLiteStatement;
	#if php
	@:noCompletion private final __written:SQLiteStatement;
	#end

	/**
		A store on `connection`, which must be open, with `open()` (an
		`openAsync()` connection runs its statements on its worker). Creates
		its table if the database has none, so the first store on a database
		writes to it. The connection is the store's from then on: `close()`
		closes it. Statements of your own on it may share a transaction with
		the store's writes.

		@throws ArgumentError When a limit or the table in `options` is not
		one, or the connection is not open or is asynchronous.
		@throws IllegalOperationError When SQLite is not supported here.
		@throws SQLError When the table cannot be made.
	**/
	public function new(connection:SQLiteConnection, ?options:KVOptions) {
		if (!isSupported) {
			throw new IllegalOperationError("SQLiteKVStore needs SQLite, which is native and PHP only.");
		}

		if (connection == null || !connection.connected) {
			throw new ArgumentError("SQLiteKVStore needs an open SQLiteConnection.");
		}

		if (@:privateAccess connection.__async) {
			throw new ArgumentError("SQLiteKVStore needs a connection opened with open(): one from openAsync() runs its statements on its worker.");
		}

		this.connection = connection;
		this.options = (options == null ? ({} : KVOptions) : options).__check();
		__migrate(connection, this.options.table);

		var t:String = this.options.table;
		var written:String = #if php "" #else " RETURNING revision, created_at, updated_at" #end;
		// The record as a write sets it, the same for a new key and a key
		// whose tombstone it replaces, which starts a new life.
		var upsert:String = 'INSERT INTO $t (record_key, record_value, revision, created_at, updated_at, deleted, value_schema) '
			+ 'VALUES (:key, :value, 1, :now, :now, 0, :schema) ON CONFLICT (record_key) DO UPDATE SET '
			+ 'record_value = excluded.record_value, revision = $t.revision + 1, '
			+ 'created_at = CASE WHEN $t.deleted = 1 THEN excluded.created_at ELSE $t.created_at END, '
			+ 'updated_at = excluded.updated_at, deleted = 0, value_schema = excluded.value_schema';
		__put = __statement(upsert + written);
		__create = __statement(upsert + ' WHERE $t.deleted = 1' + written);
		__update = __statement('UPDATE $t SET record_value = :value, revision = revision + 1, updated_at = :now, value_schema = :schema '
			+ 'WHERE record_key = :key AND deleted = 0 AND revision = :expected' + written);
		var tombstone:String = 'UPDATE $t SET record_value = x\'\', revision = revision + 1, updated_at = :now, deleted = 1, value_schema = 0 '
			+ 'WHERE record_key = :key AND deleted = 0';
		__delete = __statement(tombstone);
		__deleteAt = __statement(tombstone + ' AND revision = :expected');
		// A value past the limit is not read, only its size.
		__get = __statement('SELECT revision, created_at, updated_at, value_schema, length(record_value) AS size, '
			+ 'CASE WHEN length(record_value) <= :maxValue THEN record_value END AS value FROM $t WHERE record_key = :key AND deleted = 0');
		__scanLive = __statement(KVWrites.scanSql(t, "length", ":low", ":high", ":fetch", ":limit", ":maxValue", ":pageBytes", "deleted = 0"));
		__scanAll = __statement(KVWrites.scanSql(t, "length", ":low", ":high", ":fetch", ":limit", ":maxValue", ":pageBytes", null));
		__purge = __statement('DELETE FROM $t WHERE deleted = 1 AND updated_at < :before');
		#if php
		__written = __statement('SELECT revision, created_at, updated_at FROM $t WHERE record_key = :key');
		#end
	}

	/**
		A store in the SQLite database at `path`, opened for it and made if
		absent, or a new in-memory one for null. A file is opened in WAL mode
		with `synchronous` NORMAL, as SQLite advises for a server: readers do
		not wait for the writer, and a commit survives the process, if not
		the machine losing power before its next checkpoint.

		@throws ArgumentError As the constructor.
		@throws SQLError When the database cannot be opened.
	**/
	public static function open(path:Null<String>, ?options:KVOptions):SQLiteKVStore {
		var connection = new SQLiteConnection();
		connection.open(path, SQLiteMode.CREATE, false, 4096);

		try {
			if (path != null) {
				__useWal(connection);
				connection.synchronous = SynchronousMode.NORMAL;
			}

			return new SQLiteKVStore(connection, options);
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
		Puts the file in WAL mode, which the file keeps: the first connection
		to a new file does it, and the rest find it done. Changing it needs
		the file to itself, and SQLite refuses at once, without waiting, a
		connection that asks while another is reading the file, as a pool's
		connections opening together on a new file do; so it is asked again,
		a few milliseconds apart, until the file is in WAL mode or the
		connection's `lockWaitTimeout` has passed.
	**/
	@:noCompletion private static function __useWal(connection:SQLiteConnection):Void {
		var deadline:Float = haxe.Timer.stamp() + connection.lockWaitTimeout;
		var pause:Float = 0.002;

		while (true) {
			try {
				if (connection.journalMode != JournalMode.WAL) {
					connection.journalMode = JournalMode.WAL;
				}

				return;
			} catch (e:Dynamic) {
				if (haxe.Timer.stamp() >= deadline) {
					#if cpp
					cpp.Lib.rethrow(e);
					#else
					throw e;
					#end
				}

				crossbyte.sys.System.sleep(pause);
				pause = Math.min(pause * 2, 0.05);
			}
		}
	}

	/**
		The migrations that make a store's table in SQLite, for a migrator of
		your own; a store applies them itself, recorded in
		`<table>_migrations`.

		@throws ArgumentError When `table` is not a plain identifier of at
		most 48 characters.
	**/
	public static function migrations(table:String = KVOptions.DEFAULT_TABLE):Array<Migration<SQLiteConnection>> {
		({table: table} : KVOptions).__check();
		return [
			Migration.ofStatements(1, 'create the key/value table $table', [
				'CREATE TABLE IF NOT EXISTS $table (record_key TEXT NOT NULL PRIMARY KEY COLLATE BINARY, record_value BLOB NOT NULL, '
				+ 'revision INTEGER NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL, '
				+ 'deleted INTEGER NOT NULL DEFAULT 0, value_schema INTEGER NOT NULL DEFAULT 0)',
				'CREATE INDEX IF NOT EXISTS ${table}_tombstones ON $table (updated_at) WHERE deleted = 1'
			])
		];
	}

	public function get(key:String):Null<KVRecord> {
		KVKeys.check(key, options.maxKeyBytes, "A key", false);
		__requireOpen();
		__get.parameters["key"] = key;
		__get.parameters["maxValue"] = options.maxValueBytes;
		var found:Null<KVRecord> = null;
		var maxValue:Int = options.maxValueBytes;

		#if php
		__get.execute();
		for (row in __rowsOf(__get)) {
			var size:Int = Std.int(__float(Reflect.field(row, "size")));
			KVWrites.checkSize(key, size, maxValue);
			found = new KVRecord(key, __bytes(Reflect.field(row, "value")), __float(Reflect.field(row, "revision")),
				__float(Reflect.field(row, "created_at")), __float(Reflect.field(row, "updated_at")), Std.int(__float(Reflect.field(row, "value_schema"))), false);
		}
		#else
		__get.executeEach(function(row:SQLRow):Void {
			KVWrites.checkSize(key, row.getInt(4), maxValue);
			var value:Null<Bytes> = row.getBytes(5);
			found = new KVRecord(key, value == null ? Bytes.alloc(0) : value, row.getFloat(0), row.getFloat(1), row.getFloat(2), row.getInt(3), false);
		});
		#end

		return found;
	}

	public function put(key:String, value:Bytes, schema:Int = 0):KVRecord {
		KVWrites.checkWrite(key, value, options);
		return __write(__put, key, value, schema, 0);
	}

	public function compareAndSet(key:String, value:Bytes, expected:Float, schema:Int = 0):Null<KVRecord> {
		KVWrites.checkWrite(key, value, options);
		KVWrites.checkExpected(expected, false);
		return __write(expected == 0 ? __create : __update, key, value, schema, expected);
	}

	public function delete(key:String):Bool {
		KVKeys.check(key, options.maxKeyBytes, "A key", false);
		return __tombstone(__delete, key, 0);
	}

	public function compareAndDelete(key:String, expected:Float):Bool {
		KVKeys.check(key, options.maxKeyBytes, "A key", false);
		KVWrites.checkExpected(expected, true);
		return __tombstone(__deleteAt, key, expected);
	}

	public function scan(?options:KVScanOptions):KVPage<KVRecord> {
		var scan:KVScanOptions = options == null ? ({} : KVScanOptions) : options;
		var range = KVKeys.rangeOf(scan, "", this.options.maxKeyBytes, this.options.maxScanLimit);
		__requireOpen();

		if (range == null) {
			return new KVPage([], false, null);
		}

		var statement:SQLiteStatement = scan.includeTombstones ? __scanAll : __scanLive;
		statement.parameters["low"] = range.low;
		statement.parameters["high"] = range.high;
		statement.parameters["fetch"] = scan.limit + 1;
		statement.parameters["limit"] = scan.limit;
		statement.parameters["maxValue"] = this.options.maxValueBytes;
		statement.parameters["pageBytes"] = this.options.maxPageBytes;
		var page = new PageReader(scan.limit, this.options.maxValueBytes, this.options.maxPageBytes);

		#if php
		statement.execute();
		for (row in __rowsOf(statement)) {
			if (!page.wants(Std.int(__float(Reflect.field(row, "n"))), Std.string(Reflect.field(row, "record_key")),
				Std.int(__float(Reflect.field(row, "size"))), __float(Reflect.field(row, "running")))) {
				break;
			}

			var deleted:Bool = __float(Reflect.field(row, "deleted")) != 0;
			page.add(new KVRecord(Std.string(Reflect.field(row, "record_key")), deleted ? Bytes.alloc(0) : __bytes(Reflect.field(row, "value")),
				__float(Reflect.field(row, "revision")), __float(Reflect.field(row, "created_at")), __float(Reflect.field(row, "updated_at")),
				Std.int(__float(Reflect.field(row, "value_schema"))), deleted));
		}
		#else
		statement.executeEach(function(row:SQLRow):Void {
			var key:String = row.getString(0);

			if (!page.wants(row.getInt(7), key, row.getInt(6), row.getFloat(8))) {
				return;
			}

			var deleted:Bool = row.getInt(4) != 0;
			var value:Null<Bytes> = deleted ? null : row.getBytes(9);
			page.add(new KVRecord(key, value == null ? Bytes.alloc(0) : value, row.getFloat(1), row.getFloat(2), row.getFloat(3), row.getInt(5), deleted));
		});
		#end

		return page.finish();
	}

	public function purgeTombstones(before:Float):Int {
		__requireOpen();
		__purge.parameters["before"] = before;
		return Std.int(__changed(__purge));
	}

	public function begin():Void {
		__requireOpen();

		if (connection.inTransaction) {
			throw new IllegalOperationError("SQLiteKVStore: a transaction is open already, and they do not nest.");
		}

		connection.begin("IMMEDIATE");
	}

	public function commit():Void {
		__requireOpen();

		if (!connection.inTransaction) {
			throw new IllegalOperationError("SQLiteKVStore: commit() with no transaction open.");
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

	/** Runs a write, `statement` set for `key`; the record written, or null when its condition held it back. **/
	@:noCompletion private function __write(statement:SQLiteStatement, key:String, value:Bytes, schema:Int, expected:Float):Null<KVRecord> {
		__requireOpen();
		var now:Float = options.__now();
		statement.parameters["key"] = key;
		statement.parameters["value"] = value;
		statement.parameters["now"] = now;
		statement.parameters["schema"] = schema;

		if (statement == __update) {
			statement.parameters["expected"] = expected;
		}

		var written:Null<KVRecord> = null;

		#if php
		var owned:Bool = !connection.inTransaction;

		if (owned) {
			connection.begin("IMMEDIATE");
		}

		try {
			if (__changed(statement) > 0) {
				__written.parameters["key"] = key;
				__written.execute();

				for (row in __rowsOf(__written)) {
					written = new KVRecord(key, value.sub(0, value.length), __float(Reflect.field(row, "revision")), __float(Reflect.field(row, "created_at")),
						__float(Reflect.field(row, "updated_at")), schema, false);
				}
			}

			if (owned) {
				connection.commit();
			}
		} catch (e:Dynamic) {
			if (owned) {
				try {
					connection.rollback();
				} catch (_:Dynamic) {}
			}

			throw e;
		}
		#else
		statement.executeEach(function(row:SQLRow):Void {
			written = new KVRecord(key, value.sub(0, value.length), row.getFloat(0), row.getFloat(1), row.getFloat(2), schema, false);
		});
		#end

		return written;
	}

	@:noCompletion private function __tombstone(statement:SQLiteStatement, key:String, expected:Float):Bool {
		__requireOpen();
		statement.parameters["key"] = key;
		statement.parameters["now"] = options.__now();

		if (statement == __deleteAt) {
			statement.parameters["expected"] = expected;
		}

		return __changed(statement) > 0;
	}

	/** Runs `statement`, which returns no rows, and answers the rows it changed. **/
	@:noCompletion private function __changed(statement:SQLiteStatement):Float {
		#if php
		statement.execute();
		var result = statement.getResult();
		return result == null ? 0 : result.rowsAffected;
		#else
		return statement.executeEach(__none);
		#end
	}

	@:noCompletion private static function __none(row:SQLRow):Void {}

	@:noCompletion private function __statement(text:String):SQLiteStatement {
		var statement = new SQLiteStatement();
		statement.sqlConnection = connection;
		statement.text = text;
		return statement;
	}

	@:noCompletion private inline function __requireOpen():Void {
		if (__closed) {
			throw new IllegalOperationError("SQLiteKVStore: the store is closed.");
		}
	}

	/**
		Applies the store's migrations. A store on each of a pool's
		connections may open at once: one applies them while the others wait
		for its write lock, and then find their own run refused (the table is
		there, its record taken). That is a store opened, not a failure.
	**/
	@:noCompletion private static function __migrate(connection:SQLiteConnection, table:String):Void {
		var migrator:SchemaMigrator<SQLiteConnection> = SchemaMigrator.sqlite(table + "_migrations");
		migrator.addAll(migrations(table));

		try {
			migrator.migrate(connection);
		} catch (e:Dynamic) {
			if (migrator.pending(connection).length > 0) {
				#if cpp
				cpp.Lib.rethrow(e);
				#else
				throw e;
				#end
			}
		}
	}

	#if php
	/** The rows `statement` read, as objects with a field per column: PHP's driver reads them so. **/
	@:noCompletion private static function __rowsOf(statement:SQLiteStatement):Array<Dynamic> {
		var result = statement.getResult();
		return result == null || result.data == null ? [] : result.data;
	}

	@:noCompletion private static function __float(value:Dynamic):Float {
		return value == null ? 0.0 : Std.parseFloat(Std.string(value));
	}

	/** A blob as PHP's driver gives it: a string of its bytes. **/
	@:noCompletion private static function __bytes(value:Dynamic):Bytes {
		return value == null ? Bytes.alloc(0) : Bytes.ofString(cast value);
	}
	#end
}
#end
