package crossbyte.db;

#if cpp
import crossbyte.db.sql.sqlite.SQLiteConnection;
import crossbyte.db.sql.sqlite.SQLiteMode;
import crossbyte.utils.Logger;
import haxe.io.Path;
import sys.FileSystem;
import utest.Assert;

/**
 * SQLite through the driver, natively, where the driver can open one.
 */
class SQLiteNativeTest extends utest.Test {
	private var __paths:Array<String> = [];

	public function teardown():Void {
		for (path in __paths) {
			for (suffix in ["", "-journal", "-wal", "-shm"]) {
				try {
					if (FileSystem.exists(path + suffix)) {
						FileSystem.deleteFile(path + suffix);
					}
				} catch (_:Dynamic) {}
			}
		}

		__paths = [];
	}

	public function testATransactionBegunAsSqlIsSeen():Void {
		// inTransaction changed only in begin(), commit() and rollback(), so
		// a BEGIN sent as SQL read as no transaction at all.
		var connection:SQLiteConnection = new SQLiteConnection();
		connection.open(null, SQLiteMode.CREATE, false, 4096);

		connection.request("BEGIN");
		Assert.isTrue(connection.inTransaction);

		connection.request("COMMIT");
		Assert.isFalse(connection.inTransaction);

		connection.begin();
		Assert.isTrue(connection.inTransaction);
		connection.request("ROLLBACK");
		Assert.isFalse(connection.inTransaction, "a ROLLBACK sent as SQL left the flag set");

		connection.close();
		Assert.isFalse(connection.inTransaction);
	}

	public function testThePoolRollsBackATransactionBegunAsSql():Void {
		var path:String = __path("pool-rollback");
		var setup:SQLiteConnection = new SQLiteConnection();
		setup.open(path, SQLiteMode.CREATE, false, 4096);
		setup.request("CREATE TABLE ledger (amount INTEGER)");
		setup.close();

		var pool:ConnectionPool<SQLiteConnection> = new ConnectionPool<SQLiteConnection>({
			factory: function():SQLiteConnection {
				var connection:SQLiteConnection = new SQLiteConnection();
				connection.open(path, SQLiteMode.UPDATE, false, 4096);
				return connection;
			},
			close: c -> c.close(),
			maxSize: 1
		});

		var first:SQLiteConnection = pool.acquire();
		first.request("BEGIN");
		first.request("INSERT INTO ledger (amount) VALUES (100)");
		Logger.recordSink = _ -> {};
		pool.release(first);
		Logger.recordSink = null;

		var rows:Int = pool.withConnection(function(c:SQLiteConnection):Int {
			var result = c.request("SELECT COUNT(*) AS n FROM ledger");
			return result.hasNext() ? Std.int(Reflect.field(result.next(), "n")) : -1;
		});

		Assert.equals(0, rows, "the write of an abandoned transaction survived its release");
		Assert.isFalse(pool.withConnection(c -> c.inTransaction));
		pool.close();
	}

	private function __path(name:String):String {
		var directory:String = Path.join([Sys.getCwd(), "export"]);

		if (!FileSystem.exists(directory)) {
			FileSystem.createDirectory(directory);
		}

		var path:String = Path.join([directory, "sqlite-native-" + name + "-" + Std.random(0x7FFFFFFF) + ".db"]);
		__paths.push(path);
		return path;
	}
}
#end
