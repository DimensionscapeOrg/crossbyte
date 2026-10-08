package crossbyte.db;

#if cpp
import crossbyte.db.fakemysql.FakeMySQLServer;
import crossbyte.db.mysql.MySQLConfig;
import crossbyte.db.mysql.MySQLConnection;
import crossbyte.db.mysql.MySQLStatement;
import crossbyte.utils.Logger;
import utest.Assert;

/**
 * The session state the native MySQL client reads from the server's replies
 * (transactions, autocommit, the escaping mode) and what a `ConnectionPool`
 * does with it. Against `fakemysql/FakeMySQLServer`, whose status flags
 * follow the statements it is sent the way MySQL's do.
 */
class MySQLNativeSessionTest extends utest.Test {
	private var __server:FakeMySQLServer;

	public function setup():Void {
		__server = new FakeMySQLServer();
	}

	public function teardown():Void {
		if (__server != null) {
			__server.stop();
			__server = null;
		}
	}

	public function testATransactionBegunAsSqlIsSeen():Void {
		// inTransaction follows the server, not only begin(), commit() and rollback().
		__server.start();
		var connection:MySQLConnection = __open();

		connection.request("START TRANSACTION");
		Assert.isTrue(connection.inTransaction);

		connection.request("UPDATE accounts SET balance = balance - 5 WHERE id = 1");
		Assert.isTrue(connection.inTransaction);

		connection.request("COMMIT");
		Assert.isFalse(connection.inTransaction);

		connection.close();
	}

	public function testAutocommitOffIsATransactionAndCostsNoQuery():Void {
		// MySQL documents a session with autocommit off as always having a
		// transaction open. And the flag arrives with every reply, so reading
		// it needs no SELECT @@autocommit.
		__server.start();
		var connection:MySQLConnection = __open();

		Assert.isTrue(connection.autocommit);
		connection.autocommit = false;
		Assert.isFalse(connection.autocommit);
		Assert.isTrue(connection.inTransaction);

		connection.autocommit = true;
		Assert.isFalse(connection.inTransaction);
		Assert.equals(0, __server.queries().filter(q -> q.toUpperCase().indexOf("@@AUTOCOMMIT") >= 0).length);

		connection.close();
	}

	public function testThePoolRollsBackATransactionBegunAsSql():Void {
		// START TRANSACTION sent as SQL, a write, release: the pool must see the
		// transaction and roll it back, or the next borrower's begin() would
		// commit the write implicitly.
		__server.start();
		var pool:ConnectionPool<MySQLConnection> = __pool();

		var first:MySQLConnection = pool.acquire();
		first.request("START TRANSACTION");
		first.request("UPDATE accounts SET balance = balance - 5 WHERE id = 1");
		__quietly(() -> pool.release(first));

		var queries:Array<String> = __server.queries();
		var update:Int = queries.indexOf("UPDATE accounts SET balance = balance - 5 WHERE id = 1");
		Assert.isTrue(update >= 0);
		Assert.isTrue(queries.indexOf("ROLLBACK;") > update, "the abandoned transaction was not rolled back: " + queries.join(" | "));

		// Rolled back cleanly, so it is the same connection that comes back.
		var second:MySQLConnection = pool.acquire();
		Assert.equals(first, second);
		Assert.isFalse(second.inTransaction);
		pool.release(second);
		pool.close();
	}

	public function testThePoolRetiresASessionLeftWithAutocommitOff():Void {
		// Autocommit off, a write, release: the connection is rolled back and
		// reset, not sent round the pool with autocommit off for good.
		__server.start();
		var pool:ConnectionPool<MySQLConnection> = __pool();

		var first:MySQLConnection = pool.acquire();
		first.autocommit = false;
		first.request("INSERT INTO ledger (amount) VALUES (100)");
		__quietly(() -> pool.release(first));

		var queries:Array<String> = __server.queries();
		Assert.isTrue(queries.indexOf("ROLLBACK;") > queries.indexOf("INSERT INTO ledger (amount) VALUES (100)"));
		Assert.isTrue(__server.waitFor(events -> events.filter(e -> e.kind == "quit").length == 1),
			"the session with autocommit off went back into the pool");

		var second:MySQLConnection = pool.acquire();
		Assert.notEquals(first, second);
		Assert.isTrue(second.autocommit);
		pool.release(second);
		pool.close();
	}

	public function testEscapingFollowsNoBackslashEscapes():Void {
		// The escaping mode is read from every reply, not only the greeting:
		// after the session switches it off, a quote escaped with a backslash
		// (which that mode reads as a backslash and the end of the string) would
		// close its literal and let the rest run as SQL.
		__server.start();
		var connection:MySQLConnection = __open();
		connection.request("SET SESSION sql_mode = 'NO_BACKSLASH_ESCAPES'");

		var statement:MySQLStatement = new MySQLStatement();
		statement.sqlConnection = connection;
		statement.text = "SELECT * FROM users WHERE name = :name";
		statement.parameters.name = "x' OR 1=1 -- ";
		statement.execute();

		Assert.equals("SELECT * FROM users WHERE name = 'x'' OR 1=1 -- '", __server.lastQuery());

		connection.request("SET SESSION sql_mode = ''");
		statement.execute();
		Assert.equals("SELECT * FROM users WHERE name = 'x\\' OR 1=1 -- '", __server.lastQuery());

		connection.close();
	}

	public function testTimeZoneAndSqlModeAreSent():Void {
		// Both are escaped into the statement sent, not a buffer then dropped,
		// which would send "SET time_zone = :tz;" (a syntax error) so that any
		// config naming either failed to open, every time.
		__server.start();
		var config:MySQLConfig = __config();
		config.timeZone = "+00:00";
		config.sqlMode = "STRICT_TRANS_TABLES,NO_BACKSLASH_ESCAPES";
		config.charset = "utf8mb4";
		var connection:MySQLConnection = new MySQLConnection();
		connection.open(config);

		var queries:Array<String> = __server.queries();
		Assert.isTrue(queries.indexOf("SET NAMES utf8mb4;") >= 0, queries.join(" | "));
		Assert.isTrue(queries.indexOf("SET time_zone = '+00:00';") >= 0, queries.join(" | "));
		Assert.isTrue(queries.indexOf("SET SESSION sql_mode = 'STRICT_TRANS_TABLES,NO_BACKSLASH_ESCAPES';") >= 0, queries.join(" | "));
		connection.close();
	}

	public function testASessionThatFailsToSetUpIsClosed():Void {
		// A setting that fails after connecting closes the connection, so a
		// pool factory retrying does not pile up server connections.
		__server.onQuery = function(session, sql) {
			if (StringTools.startsWith(sql, "SET time_zone")) {
				session.error(1298, "HY000", "Unknown or incorrect time zone: 'Mars/Olympus'");
				return true;
			}
			return false;
		};
		__server.start();
		var config:MySQLConfig = __config();
		config.timeZone = "Mars/Olympus";

		Assert.raises(() -> new MySQLConnection().open(config), crossbyte.errors.IOError);
		Assert.isTrue(__server.waitFor(events -> events.filter(e -> e.kind == "quit").length == 1),
			"the connection whose setup failed was left open");
	}

	public function testAnUnsupportedCharsetIsRefusedBeforeConnecting():Void {
		__server.start();
		var config:MySQLConfig = __config();
		config.charset = "klingon";

		Assert.raises(() -> new MySQLConnection().open(config), crossbyte.errors.ArgumentError);
		Assert.equals(0, __server.eventsOf("handshake").length);
	}

	private function __pool():ConnectionPool<MySQLConnection> {
		var config:MySQLConfig = __config();
		return new ConnectionPool<MySQLConnection>({
			factory: function():MySQLConnection {
				var connection:MySQLConnection = new MySQLConnection();
				connection.open(config);
				return connection;
			},
			close: c -> c.close(),
			maxSize: 1,
			acquireTimeout: 2.0
		});
	}

	private static function __quietly(fn:Void->Void):Void {
		// The pool logs a released transaction as the caller's bug, which it
		// is here on purpose.
		Logger.recordSink = _ -> {};

		try {
			fn();
		} catch (e:Dynamic) {
			Logger.recordSink = null;
			throw e;
		}

		Logger.recordSink = null;
	}

	private function __open():MySQLConnection {
		var connection:MySQLConnection = new MySQLConnection();
		connection.open(__config());
		return connection;
	}

	private function __config():MySQLConfig {
		return {
			host: "127.0.0.1",
			port: __server.port,
			user: "app",
			password: "secret",
			database: "app"
		};
	}
}
#end
