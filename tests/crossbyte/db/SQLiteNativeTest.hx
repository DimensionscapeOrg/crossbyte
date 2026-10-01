package crossbyte.db;

#if cpp
import crossbyte.db.sql.sqlite.SQLiteConnection;
import crossbyte.db.sql.sqlite.SQLiteMode;
import crossbyte.db.sql.sqlite.SQLiteStatement;
import crossbyte.errors.SQLError;
import crossbyte.events.SQLErrorEvent;
import crossbyte.events.SQLEvent;
import crossbyte.test.Require;
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

	public function testIntegersAreReadAtSixtyFourBits():Void {
		// Every INTEGER column was read with sqlite3_column_int, which keeps
		// the low 32 bits: a millisecond timestamp, 1727600000000, came back
		// as 1023147008.
		var connection:SQLiteConnection = new SQLiteConnection();
		connection.open(null, SQLiteMode.CREATE, false, 4096);
		connection.request("CREATE TABLE t (ms INTEGER, big INTEGER, small INTEGER, negative INTEGER)");
		connection.request("INSERT INTO t VALUES (1727600000000, 9007199254740993, 5, -9223372036854775808)");

		var rows = connection.request("SELECT ms, big, small, negative FROM t");
		Assert.isTrue(rows.hasNext());
		var row:Dynamic = rows.next();

		var ms:haxe.Int64 = Reflect.field(row, "ms");
		Assert.equals("1727600000000", haxe.Int64.toStr(ms));
		// Past 2^53, where a Float would round it.
		var big:haxe.Int64 = Reflect.field(row, "big");
		Assert.equals("9007199254740993", haxe.Int64.toStr(big));
		var negative:haxe.Int64 = Reflect.field(row, "negative");
		Assert.equals("-9223372036854775808", haxe.Int64.toStr(negative));
		// One that fits an Int stays one.
		var small:Dynamic = Reflect.field(row, "small");
		Assert.isTrue(Std.isOfType(small, Int));
		Assert.equals(5, (small : Int));

		connection.close();
	}

	public function testAnAsyncBeginImmediateTakesItsLockAtOnce():Void {
		// The asynchronous begin() ignored its option and always began a
		// deferred transaction, which takes no lock until its first write,
		// and can fail with SQLITE_BUSY there, part way through.
		var path:String = __path("async-immediate");
		var setup:SQLiteConnection = new SQLiteConnection();
		setup.open(path, SQLiteMode.CREATE, false, 4096);
		setup.request("CREATE TABLE t (x INTEGER)");
		setup.close();

		var holder:SQLiteConnection = new SQLiteConnection();
		var events:Array<String> = [];

		for (type in [SQLEvent.OPEN, SQLEvent.BEGIN, SQLEvent.ROLLBACK, SQLEvent.CLOSE]) {
			holder.addEventListener(type, e -> events.push(e.type));
		}

		holder.addEventListener(SQLErrorEvent.ERROR, e -> events.push("error"));
		holder.openAsync(path, SQLiteMode.UPDATE, false, 4096);
		holder.begin("IMMEDIATE");
		__pumpUntil(() -> events.indexOf(SQLEvent.BEGIN) >= 0 || events.indexOf("error") >= 0);
		Assert.isTrue(events.indexOf(SQLEvent.BEGIN) >= 0, events.join(","));

		// A second connection cannot take the write lock now.
		var other:SQLiteConnection = new SQLiteConnection();
		other.open(path, SQLiteMode.UPDATE, false, 4096);
		var locked:Bool = false;

		try {
			other.request("BEGIN IMMEDIATE");
			other.request("ROLLBACK");
		} catch (_:Dynamic) {
			locked = true;
		}

		other.close();
		Assert.isTrue(locked, "the asynchronous BEGIN IMMEDIATE began deferred, holding no lock");

		holder.rollback();
		holder.close();
		__pumpUntil(() -> events.indexOf(SQLEvent.CLOSE) >= 0);
	}

	public function testAFailedStatementDoesNotFailTheNextOne():Void {
		// A statement whose step failed was finalized only when the next one
		// replaced it, and finalize returned the old failure again, which was
		// thrown as "Could not finalize request": after one constraint
		// violation, the connection's next statement failed too, and so did
		// close(). And the failure itself said only "SQL logic error".
		var connection:SQLiteConnection = new SQLiteConnection();
		connection.open(null, SQLiteMode.CREATE, false, 4096);
		connection.request("CREATE TABLE users (email TEXT UNIQUE)");
		connection.request("INSERT INTO users VALUES ('a@example.com')");

		var message:String = "";

		try {
			connection.request("INSERT INTO users VALUES ('a@example.com')");
		} catch (e:Dynamic) {
			message = Std.string(e);
		}

		Assert.isTrue(message.indexOf("UNIQUE") >= 0, message);

		var rows = connection.request("SELECT COUNT(*) AS n FROM users");
		Assert.isTrue(rows.hasNext());
		Assert.equals(1, (Reflect.field(rows.next(), "n") : Int));

		// The same through a failed step that leaves nothing after it.
		try {
			connection.request("INSERT INTO users VALUES ('a@example.com')");
		} catch (_:Dynamic) {}

		var closed:Bool = false;

		try {
			connection.close();
			closed = true;
		} catch (e:Dynamic) {
			message = Std.string(e);
		}

		Assert.isTrue(closed, message);
	}

	public function testWhatSQLiteRefusesIsAnSQLError():Void {
		// Against the engine itself: what hxcpp's glue throws is a String,
		// which escaped as one, and nothing was dispatched.
		var connection:SQLiteConnection = new SQLiteConnection();
		connection.open(null, SQLiteMode.CREATE, false, 4096);
		var heard:Array<SQLError> = [];
		connection.addEventListener(SQLErrorEvent.ERROR, event -> heard.push(event.error));
		connection.begin();

		var thrown:Dynamic = null;

		try {
			connection.begin();
		} catch (e:Dynamic) {
			thrown = e;
		}

		Assert.equals(1, heard.length);
		if (heard.length == 1) {
			Assert.equals(heard[0], thrown);
			Assert.equals(SQLEvent.BEGIN, heard[0].operation);
			Assert.isTrue(heard[0].details().indexOf("within a transaction") >= 0, heard[0].details());
		}

		connection.rollback();

		var refused:Dynamic = null;

		try {
			connection.request("SELECT * FROM nowhere");
		} catch (e:Dynamic) {
			refused = e;
		}

		Assert.isTrue(Std.isOfType(refused, SQLError), "request() threw " + Std.string(refused));

		var statement:SQLiteStatement = new SQLiteStatement();
		statement.sqlConnection = connection;
		statement.text = "SELECT * FROM nowhere";
		var failed:SQLError = null;
		statement.addEventListener(SQLErrorEvent.ERROR, event -> failed = event.error);
		Assert.raises(() -> statement.execute(), SQLError);
		Require.notNull(failed);
		Assert.isTrue(failed.details().indexOf("no such table") >= 0, failed.details());

		connection.close();
		// Closed already: a second close does nothing, as on the other drivers.
		connection.close();
	}

	private static function __pumpUntil(done:Void->Bool, seconds:Float = 10.0):Void {
		var runtime = crossbyte.core.CrossByte.current();
		var deadline:Float = haxe.Timer.stamp() + seconds;

		while (!done() && haxe.Timer.stamp() < deadline) {
			runtime.pump(1 / 120, 0);
			crossbyte.sys.System.sleep(0.001);
		}
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
