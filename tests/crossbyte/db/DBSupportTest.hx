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
import crossbyte.db.sql.sqlite.SQLiteConnection;
import crossbyte.db.sql.sqlite.SQLiteMode;
import crossbyte.db.sql.sqlite.SQLiteStatement;
import crossbyte.db.sql.sqlite.SynchronousMode;
import crossbyte.db.sql.sqlite.TempStoreMode;
import crossbyte.errors.ArgumentError;
import haxe.io.Path;
import sys.FileSystem;
import utest.Assert;

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

	public function testPhpBackedConnectionsStayUnsupportedOnCpp():Void {
		#if cpp
		Assert.isFalse(MongoConnection.isSupported);
		Assert.isFalse(PostgresConnection.isSupported);
		Assert.isTrue(throwsDynamic(() -> new MongoConnection().open({database: "app"})));
		Assert.isTrue(throwsDynamic(() -> new PostgresConnection().open({database: "app"})));
		#else
		Assert.isTrue(true);
		#end
	}

	#if windows
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
		Assert.notNull(createResult);
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
		Assert.notNull(selectResult);
		Assert.equals(1, selectResult.data.length);
		Assert.equals("alpha", Reflect.field(selectResult.data[0], "name"));

		var tables = connection.tableList();
		Assert.equals(1, tables.length);
		Assert.equals("items", tables[0]);

		var stats = connection.stats();
		Assert.equals(4096, stats.pageSize);
		Assert.isTrue(stats.pageCount >= 1);
		Assert.isTrue(connection.compileOptions().length > 0);
		Assert.isTrue(connection.pragmaList().indexOf("page_size") != -1);
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
	#end

	private static function throwsDynamic(fn:Void->Void):Bool {
		try {
			fn();
			return false;
		} catch (_:Dynamic) {
			return true;
		}
	}
}
