package crossbyte.db;

#if cpp
import crossbyte.db.fakemysql.FakeMySQLServer;
import crossbyte.db.mysql.MySQLConfig;
import crossbyte.db.mysql.MySQLConnection;
import crossbyte.db.mysql.MySQLStatement;
import crossbyte.errors.SQLError;
import crossbyte.events.SQLErrorEvent;
import crossbyte.events.SQLEvent;
import utest.Assert;
import crossbyte.test.Require;

/**
 * What the native MySQL client makes of the server's answers: rows, the OK
 * packet of a write, and errors. Against `fakemysql/FakeMySQLServer`.
 */
class MySQLNativeResultTest extends utest.Test {
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

	public function testAWriteThroughAStatementSucceeds():Void {
		// A write is answered with an OK packet, whose result handle is the
		// affected-row count. Iterating it threw "Invalid result", so every
		// INSERT, UPDATE and DELETE run through a statement was reported as
		// failed after the server had applied it, and code that retries on
		// error wrote twice.
		__server.start();
		var connection:MySQLConnection = __open();
		var statement:MySQLStatement = new MySQLStatement();
		statement.sqlConnection = connection;
		var errors:Array<String> = [];
		statement.addEventListener(SQLErrorEvent.ERROR, e -> errors.push(Std.string((cast e : SQLErrorEvent).error)));

		statement.text = "INSERT INTO users (email) VALUES ('a@example.com')";
		statement.execute();

		Assert.same([], errors);
		var result = Require.notNull(statement.getResult());
		Assert.isTrue(result.complete);
		Assert.equals(0, result.data.length);
		Assert.equals(1.0, result.rowsAffected);

		connection.close();
	}

	public function testARefusedStatementThrowsFromExecute():Void {
		__server.onQuery = function(session, sql) {
			if (sql.indexOf("DUPLICATE") >= 0) {
				session.error(1062, "23000", "Duplicate entry 'a@example.com' for key 'users.email'");
				return true;
			}
			return false;
		};
		__server.start();
		var connection:MySQLConnection = __open();
		var statement:MySQLStatement = new MySQLStatement();
		statement.sqlConnection = connection;
		var events:Int = 0;
		statement.addEventListener(SQLErrorEvent.ERROR, _ -> events++);

		statement.text = "INSERT INTO users (email) VALUES ('a@example.com') -- DUPLICATE";

		Assert.raises(() -> statement.execute(), SQLError);
		Assert.equals(1, events);

		// The connection is still usable after the server refused one
		// statement.
		statement.text = "SELECT 1";
		statement.execute();
		var result = Require.notNull(statement.getResult());
		Assert.equals(1, result.data.length);

		connection.close();
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
