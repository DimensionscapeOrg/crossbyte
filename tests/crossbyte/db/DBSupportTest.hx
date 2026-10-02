package crossbyte.db;

import crossbyte.db.mongodb.MongoConfig;
import crossbyte.db.mongodb.MongoConnection;
import crossbyte.db.mongodb.MongoStatement;
import crossbyte.db.mysql.IsolationLevel;
import crossbyte.db.mysql.MySQLConfig;
import crossbyte.db.mysql.MySQLConnection;
import crossbyte.db.mysql.MySQLStatement;
import crossbyte.db.postgres.PostgresConfig;
import crossbyte.db.postgres.PostgresConnection;
import crossbyte.db.postgres.PostgresIsolationLevel;
import crossbyte.db.postgres.PostgresStatement;
import crossbyte.db.sql.SQLResult;
import crossbyte.db.sql.sqlite.CheckpointMode;
import crossbyte.db.sql.sqlite.JournalMode;
import crossbyte.core.CrossByte;
import crossbyte.events.SQLEvent;
import crossbyte.db.sql.sqlite.SQLiteConnection;
import crossbyte.db.sql.sqlite.SQLiteMode;
import crossbyte.db.sql.sqlite.SQLiteStatement;
import crossbyte.db.sql.sqlite.SynchronousMode;
import crossbyte.db.sql.sqlite.TempStoreMode;
import crossbyte.errors.ArgumentError;
import haxe.io.Path;
import sys.FileSystem;
import utest.Assert;
import crossbyte.test.Require;

@:access(crossbyte.db.sql.sqlite.SQLiteConnection)
class DBSupportTest extends utest.Test {
	public function testSQLResultStoresRowsAndMetadata():Void {
		var rows = [{id: 1}, {id: 2}];
		var result = new SQLResult(rows, 4, false, 9);

		Assert.same(rows, result.data);
		Assert.equals(4.0, result.rowsAffected);
		Assert.isFalse(result.complete);
		Assert.equals(9.0, result.lastInsertRowID);
	}

	public function testConfigTypedefsAndEnumsHoldExpectedValues():Void {
		var mongo:MongoConfig = {
			host: "localhost",
			port: 27017,
			database: "app",
			username: "user",
			password: "pw"
		};
		Assert.equals("localhost", mongo.host);
		Assert.equals(27017, mongo.port);
		Assert.equals("app", mongo.database);

		var postgres:PostgresConfig = {
			host: "db",
			port: 5432,
			user: "postgres",
			password: "pw",
			database: "main",
			sslMode: "require",
			connectTimeout: 15
		};
		Assert.equals("db", postgres.host);
		Assert.equals("require", postgres.sslMode);
		Assert.equals(15, postgres.connectTimeout);

		var mysql:MySQLConfig = {
			host: "db",
			user: "root",
			password: "pw",
			database: "main",
			port: 3306,
			charset: "utf8mb4",
			timeZone: "+00:00",
			sqlMode: "STRICT_TRANS_TABLES"
		};
		Assert.equals("db", mysql.host);
		Assert.equals("utf8mb4", mysql.charset);
		Assert.equals("STRICT_TRANS_TABLES", mysql.sqlMode);

		Assert.equals("READ COMMITTED", IsolationLevel.READ_COMMITTED);
		Assert.equals("SERIALIZABLE", PostgresIsolationLevel.SERIALIZABLE);
		Assert.equals("create", SQLiteMode.CREATE);
		Assert.equals("read", SQLiteMode.READ);
		Assert.equals("WAL", JournalMode.WAL);
		Assert.equals(JournalMode.DELETE, JournalMode.fromString("unknown"));
		Assert.equals(2, SynchronousMode.FULL);
		Assert.equals(2, TempStoreMode.MEMORY);
		Assert.equals("TRUNCATE", CheckpointMode.TRUNCATE);
	}

	public function testStatementShellsCompileAndResetState():Void {
		var sqlite = new SQLiteStatement();
		sqlite.parameters.foo = "bar";
		sqlite.clearParameters();
		Assert.isFalse(sqlite.executing);

		var mysql = new MySQLStatement();
		mysql.parameters.foo = "bar";
		mysql.clearParameters();
		Assert.isFalse(mysql.executing);

		var postgres = new PostgresStatement();
		postgres.parameters.foo = "bar";
		postgres.clearParameters();
		Assert.isFalse(postgres.executing);

		var mongo = new MongoStatement();
		mongo.parameters.foo = "bar";
		mongo.clearParameters();
		Assert.isFalse(mongo.executing);
	}

	public function testDriversWithClientsOfTheirOwnAreSupportedOnCpp():Void {
		#if cpp
		// Mongo was PHP-only and refused to open here; it speaks the wire
		// protocol itself now, as MongoWireTest shows against a fake server.
		Assert.isTrue(MongoConnection.isSupported);

		// Postgres is not PHP-only any more — it has a native cpp bridge.
		// This case asserted otherwise until the suite was actually run.
		Assert.isTrue(PostgresConnection.isSupported);
		#else
		Assert.isTrue(true);
		#end
	}

	public function testGeneratedSavepointNamesDoNotRepeat():Void {
		// The name came from haxe.Timer.stamp() in microseconds through
		// Std.int. Measured on cpp: 2000 generated back to back produced 47
		// duplicates, and the value overflows Int about 36 minutes into a
		// process and wraps every 72, so a long-lived connection reissues
		// names it has already used. Two savepoints sharing a name make
		// RELEASE and ROLLBACK TO act on the wrong one.
		var connection = new SQLiteConnection();
		var seen = new Map<String, Bool>();
		var distinct:Int = 0;

		for (i in 0...2000) {
			var name:String = connection.__sanitizeSavePoint(null);

			if (!seen.exists(name)) {
				seen.set(name, true);
				distinct++;
			}
		}

		// Asserted once rather than per name, so the suite total stays a count
		// of behaviours rather than of loop iterations.
		Assert.equals(2000, distinct);
	}

	public function testExplicitSavepointNameIsReducedToAnIdentifier():Void {
		// The name is interpolated into SAVEPOINT/RELEASE/ROLLBACK TO, so it
		// has to be an identifier and nothing else.
		var connection = new SQLiteConnection();

		Assert.equals("keep_me_1", connection.__sanitizeSavePoint("keep_me_1"));
		Assert.equals("a__DROP_TABLE_t____", connection.__sanitizeSavePoint("a; DROP TABLE t; --"));
	}

	#if cpp
	public function testAsyncQueueRunsEveryJobInOrderAndClosesCleanly():Void {
		// The async queue had no coverage at all, which is how a change to it
		// passed the whole suite while making the very first queued job
		// recurse until the process died. Everything here goes through the
		// worker thread: the open, each statement, and the close that stops
		// the worker.
		var connection = new SQLiteConnection();
		var seen:Array<String> = [];

		for (type in [SQLEvent.OPEN, SQLEvent.BEGIN, SQLEvent.SET_SAVEPOINT, SQLEvent.RELEASE_SAVEPOINT, SQLEvent.COMMIT, SQLEvent.CLOSE]) {
			connection.addEventListener(type, event -> seen.push(event.type));
		}

		connection.openAsync(null, SQLiteMode.CREATE, false, 4096);
		connection.begin();
		connection.setSavepoint();
		connection.releaseSavepoint();
		connection.commit();
		connection.close();

		var runtime = CrossByte.current();
		var deadline:Float = haxe.Timer.stamp() + 10.0;

		while (haxe.Timer.stamp() < deadline && seen.indexOf(SQLEvent.CLOSE) < 0) {
			runtime.pump(1 / 120, 0);
		}

		// Order matters as much as arrival: the queue is FIFO, and a job that
		// ran out of turn would mean COMMIT before the savepoint it encloses.
		Assert.same([
			SQLEvent.OPEN,
			SQLEvent.BEGIN,
			SQLEvent.SET_SAVEPOINT,
			SQLEvent.RELEASE_SAVEPOINT,
			SQLEvent.COMMIT,
			SQLEvent.CLOSE
		], seen);
	}
	#end

	#if cpp
	public function testSavepointsNestAndReleaseByNameOrByOmission():Void {
		// setSavepoint() returned nothing, so a savepoint made without a name
		// could never be named again -- and releaseSavepoint() with no name
		// generated a fresh one and asked SQLite to release a savepoint that
		// had never existed. Measured against a real database before the fix:
		// "RELEASE sp_410; (Sqlite error : SQL logic error)".
		var connection = new SQLiteConnection();
		connection.open(null, SQLiteMode.CREATE, false, 4096);
		connection.begin();

		var outer:String = connection.setSavepoint();
		var inner:String = connection.setSavepoint();

		Assert.notNull(outer);
		Assert.notEquals(outer, inner);

		// No name means the innermost, which SQLite leaves active after a
		// rollback to it -- so releasing it by name still has to succeed.
		connection.rollbackToSavepoint();
		connection.releaseSavepoint(inner);

		// And releasing the outer one discards it and anything left inside.
		connection.releaseSavepoint(outer);

		connection.commit();
		Assert.isFalse(connection.inTransaction);

		connection.close();
		Assert.isFalse(connection.connected);
	}
	#end

	#if cpp
	public function testSQLiteInMemoryOpenPragmasAndQueries():Void {
		var connection = new SQLiteConnection();
		Assert.isFalse(connection.connected);

		connection.open(null, SQLiteMode.CREATE, false, 4096);
		Assert.isTrue(connection.connected);
		Assert.equals(4096, connection.pageSize);
		Assert.equals(2000, connection.cacheSize);
		Assert.isFalse(connection.inTransaction);

		connection.foreignKeys = true;
		Assert.isTrue(connection.foreignKeys);

		connection.secureDelete = true;
		Assert.isTrue(connection.secureDelete);

		connection.readUncommitted = false;
		Assert.isFalse(connection.readUncommitted);

		connection.busyTimeout = 250;
		Assert.equals(250, connection.busyTimeout);

		connection.tempStore = TempStoreMode.MEMORY;
		Assert.equals(TempStoreMode.MEMORY, connection.tempStore);

		var create = new SQLiteStatement();
		create.sqlConnection = connection;
		create.text = "CREATE TABLE items (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL);";
		create.execute();
		var createResult = create.getResult();
		Require.notNull(createResult);
		Assert.isTrue(createResult.complete);

		var insert = new SQLiteStatement();
		insert.sqlConnection = connection;
		insert.text = "INSERT INTO items (name) VALUES ('alpha');";
		insert.execute();
		var insertResult = insert.getResult();
		Assert.notNull(insertResult);
		Assert.isTrue(connection.lastInsertRowID > 0);
		Assert.equals(1, connection.totalChanges);

		var select = new SQLiteStatement();
		select.sqlConnection = connection;
		select.text = "SELECT name FROM items;";
		select.execute();
		var selectResult = select.getResult();
		Require.notNull(selectResult);
		Assert.equals(1, selectResult.data.length);
		Assert.equals("alpha", Reflect.field(selectResult.data[0], "name"));

		var tables = connection.tableList();
		Assert.equals(1, tables.length);
		Assert.equals("items", tables[0]);

		var stats = connection.stats();
		Assert.equals(4096, stats.pageSize);
		Assert.isTrue(stats.pageCount >= 1);
		Assert.isTrue(connection.compileOptions().length > 0);

		// `PRAGMA pragma_list` returns nothing on the SQLite hxcpp bundles
		// (3.23.1), so this cannot assert membership — it asserted
		// `page_size` was listed, and only never failed because the suite
		// was registered where its `#if cpp` body compiled out. What is
		// worth holding is that the call is safe and well-typed; if a
		// future SQLite does populate it, the contents are checked then.
		var pragmas = connection.pragmaList();
		Assert.notNull(pragmas);
		if (pragmas.length > 0) {
			Assert.isTrue(pragmas.indexOf("page_size") != -1);
		}
		Assert.equals("ok", connection.integrityCheck().toLowerCase());

		connection.close();

		Assert.isFalse(connection.connected);
	}

	public function testSQLiteReadModeRejectsMissingFile():Void {
		var path = Path.join([Sys.getCwd(), "export", "db-support-missing.sqlite"]);
		if (FileSystem.exists(path)) {
			FileSystem.deleteFile(path);
		}

		var connection = new SQLiteConnection();
		Assert.raises(() -> connection.open(path, SQLiteMode.READ), ArgumentError);
	}

	/**
		A rowid past 32 bits reads back whole. SQLite's are 64-bit and the
		connection's was an Int, held at 2^31 - 1 by hxcpp and wrapped by
		the other drivers: a Snowflake id or a millisecond timestamp used as
		a key came back as something else, from the connection and from
		every statement's result.
	**/
	public function testARowIdPastThirtyTwoBitsReadsBackWhole():Void {
		var connection = new SQLiteConnection();
		connection.open(null, SQLiteMode.CREATE, false, 4096);

		var create = new SQLiteStatement();
		create.sqlConnection = connection;
		create.text = "CREATE TABLE stamps (id INTEGER PRIMARY KEY, name TEXT);";
		create.execute();

		var insert = new SQLiteStatement();
		insert.sqlConnection = connection;
		insert.text = "INSERT INTO stamps (id, name) VALUES (1727600000000, 'now');";
		insert.execute();
		var result = insert.getResult();

		Require.notNull(result);
		Assert.equals(1727600000000.0, result.lastInsertRowID, "the statement's result");
		Assert.equals(1727600000000.0, connection.lastInsertRowID, "the connection");
		connection.close();
	}

	/**
		A database attached is reached as `name.table`, joins included, its
		schema read, and detached again. `SQLEvent.ATTACH`, `DETACH` and
		`SCHEMA` were declared, as AIR's `SQLConnection` has them, and
		nothing could make one: there was no attach, detach or schema.
	**/
	public function testAnAttachedDatabaseIsJoinedReadAndDetached():Void {
		var connection = new SQLiteConnection();
		connection.open(null, SQLiteMode.CREATE, false, 4096);
		var heard:Array<String> = [];
		for (type in [SQLEvent.ATTACH, SQLEvent.DETACH, SQLEvent.SCHEMA]) {
			connection.addEventListener(type, function(e:SQLEvent) heard.push(e.type));
		}

		sqlRun(connection, "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL DEFAULT 'anon');");
		connection.attach("extra");
		sqlRun(connection, "CREATE TABLE extra.scores (user INTEGER, points INTEGER);");
		sqlRun(connection, "CREATE INDEX extra.by_user ON scores(user);");
		sqlRun(connection, "INSERT INTO users (id, name) VALUES (1, 'ada');");
		sqlRun(connection, "INSERT INTO extra.scores VALUES (1, 42);");

		var joined = sqlRun(connection, "SELECT u.name AS name, s.points AS points FROM users u JOIN extra.scores s ON s.user = u.id;");
		Assert.equals(1, joined.length);
		if (joined.length == 1) {
			Assert.equals("ada", Std.string(Reflect.field(joined[0], "name")));
			Assert.equals(42, Std.parseInt(Std.string(Reflect.field(joined[0], "points"))));
		}

		connection.loadSchema("extra");
		var extra = connection.getSchemaResult();
		Require.notNull(extra);
		Assert.same(["scores"], [for (t in extra.tables) t.name]);
		Assert.same(["user", "points"], [for (c in extra.tables[0].columns) c.name]);
		Assert.same(["by_user"], [for (i in extra.indices) i.name]);
		Assert.equals("scores", extra.indices[0].table);

		connection.loadSchema();
		var main = connection.getSchemaResult();
		Require.notNull(main);
		Assert.same(["users"], [for (t in main.tables) t.name]);
		var columns = main.tables[0].columns;
		Assert.isTrue(columns[0].primaryKey, "id is the primary key");
		Assert.isFalse(columns[1].allowNull, "name is NOT NULL");
		Assert.equals("TEXT", columns[1].dataType);
		Assert.equals("'anon'", columns[1].defaultValue);

		connection.detach("extra");
		Assert.raises(() -> sqlRun(connection, "SELECT * FROM extra.scores;"), null, "a detached database still answered");
		Assert.same(["attach", "schema", "schema", "detach"], heard);
		connection.close();
	}

	/** Runs `sql` on `connection`, returning its rows. **/
	private static function sqlRun(connection:SQLiteConnection, sql:String):Array<Dynamic> {
		var statement = new SQLiteStatement();
		statement.sqlConnection = connection;
		statement.text = sql;
		statement.execute();
		var result = statement.getResult();
		return result == null || result.data == null ? [] : result.data;
	}

	/** Sizes past 2 GB, which multiplying two Ints wrapped before they reached the Int64. **/
	public function testADatabaseSizeIsNotMultipliedInThirtyTwoBits():Void {
		var size = @:privateAccess SQLiteConnection.__bytesOf(65536, 49152);
		Assert.equals("3221225472", haxe.Int64.toStr(size));
	}
	#end

	public function testAFailedSQLiteOpenIsAnIOError():Void {
		// A failed open is an IOError, whatever failed it. Where there is no
		// SQLite -- the jvm without its JDBC driver, eval -- that is the
		// missing driver: on the jvm the ClassNotFoundException that says so
		// was handed to IOError where a String belongs, a ClassCastException
		// instead. Where there is one, it is a database in a directory that
		// does not exist. This opened `null` once, which fails only where
		// there is no SQLite; hl and neko have one, and opened the in-memory
		// database `null` names.
		var directory:String = Path.join([Sys.getCwd(), "export", "db-support-absent"]);
		Assert.isFalse(FileSystem.exists(directory), directory + " exists, so the open below may not fail");

		var thrown:Dynamic = null;

		try {
			new SQLiteConnection().open(Path.join([directory, "absent.sqlite"]), SQLiteMode.CREATE);
		} catch (e:Dynamic) {
			thrown = e;
		}

		Assert.isTrue(Std.isOfType(thrown, crossbyte.errors.IOError), "not an IOError: " + Std.string(thrown));
	}

	private static function throwsDynamic(fn:Void->Void):Bool {
		try {
			fn();
			return false;
		} catch (_:Dynamic) {
			return true;
		}
	}
}
