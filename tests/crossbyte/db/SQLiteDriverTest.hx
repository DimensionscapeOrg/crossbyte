package crossbyte.db;

#if !js
import crossbyte.db.fakemysql.ScriptedConnection;
import crossbyte.db.sql.SQLResult;
import crossbyte.db.sql.sqlite.SQLiteConnection;
import crossbyte.db.sql.sqlite.SQLiteStatement;
import crossbyte.errors.IllegalOperationError;
import crossbyte.errors.SQLError;
import crossbyte.events.SQLErrorEvent;
import crossbyte.events.SQLEvent;
import crossbyte.test.Require;
import utest.Assert;

/**
 * The SQLite statement's own logic, over a scripted connection rather than
 * SQLite, so it runs on every target the driver builds for; SQLite itself
 * opens only natively (`SQLiteNativeTest`).
 */
@:access(crossbyte.db.sql.sqlite.SQLiteConnection)
class SQLiteDriverTest extends utest.Test {
	public function testPagesComeBackInTheOrderTheyWereRead():Void {
		// Off cpp the pages waited in an Array read with pop(), newest first,
		// so a result paged ahead of getResult() came back last page first on
		// the jvm and in the interpreter. And each page taken after the last
		// had been read said it was complete.
		var wire:ScriptedConnection = new ScriptedConnection();
		wire.results.set("SELECT id FROM items", [for (id in 1...6) {id: id}]);
		var connection:SQLiteConnection = new SQLiteConnection();
		connection.__connection = wire;
		var statement:SQLiteStatement = new SQLiteStatement();
		statement.sqlConnection = connection;
		statement.text = "SELECT id FROM items";

		statement.execute(2);
		statement.next(2);
		statement.next(2);

		Assert.equals("1,2 3,4 5+", __pages(statement));
		Assert.isNull(statement.getResult());
	}

	public function testAStatementReportsItsResultAndThrowsWhatFailed():Void {
		// As MySQL's and Postgres's statements do. A synchronous statement
		// dispatched no RESULT at all, and a failed one let the driver's raw
		// String escape with no SQLErrorEvent: code catching SQLError, as
		// every other driver's failures are caught, caught nothing.
		var wire:ScriptedConnection = new ScriptedConnection();
		wire.failures.set("INSERT INTO nowhere VALUES (1)", "no such table: nowhere");
		var connection:SQLiteConnection = new SQLiteConnection();
		connection.__connection = wire;
		var statement:SQLiteStatement = new SQLiteStatement();
		statement.sqlConnection = connection;
		var heard:Array<String> = [];
		var caught:SQLError = null;
		statement.addEventListener(SQLEvent.RESULT, _ -> heard.push("result"));
		statement.addEventListener(SQLErrorEvent.ERROR, event -> caught = event.error);

		statement.text = "INSERT INTO t VALUES (1)";
		statement.execute();
		Assert.same(["result"], heard);

		statement.text = "INSERT INTO nowhere VALUES (1)";
		var thrown:Dynamic = null;

		try {
			statement.execute();
		} catch (e:Dynamic) {
			thrown = e;
		}

		Require.notNull(caught);
		Assert.equals(caught, thrown, "what was thrown and what was dispatched differ");
		Assert.isTrue(caught.details().indexOf("no such table") >= 0, caught.details());
		Assert.isFalse(statement.executing);
		Assert.same(["result"], heard, "a failed statement reported a result");
	}

	public function testAFailedOperationIsDispatchedAndThrownAsAnSQLError():Void {
		// The connection's own operations, likewise: a BEGIN SQLite refused
		// threw the driver's String and told no listener.
		var wire:ScriptedConnection = new ScriptedConnection();
		wire.failures.set("START TRANSACTION", "cannot start a transaction within a transaction");
		var connection:SQLiteConnection = new SQLiteConnection();
		connection.__connection = wire;
		var caught:SQLError = null;
		connection.addEventListener(SQLErrorEvent.ERROR, event -> caught = event.error);
		var thrown:Dynamic = null;

		try {
			connection.begin();
		} catch (e:Dynamic) {
			thrown = e;
		}

		Require.notNull(caught);
		Assert.equals(caught, thrown, "what was thrown and what was dispatched differ");
		Assert.equals(SQLEvent.BEGIN, caught.operation);

		// And request(), which dispatches nothing, as MySQL's does, but throws
		// the same type.
		var refused:Dynamic = null;

		try {
			connection.request("START TRANSACTION");
		} catch (e:Dynamic) {
			refused = e;
		}

		Assert.isTrue(Std.isOfType(refused, SQLError), "request() threw " + Std.string(refused));
	}

	public function testAStatementWithNoOpenConnectionIsRefused():Void {
		// It dereferenced the connection it did not have.
		var statement:SQLiteStatement = new SQLiteStatement();
		statement.text = "SELECT 1";
		Assert.raises(() -> statement.execute(), IllegalOperationError);
		statement.sqlConnection = new SQLiteConnection();
		Assert.raises(() -> statement.execute(), IllegalOperationError);
	}

	/** Every page waiting, as its ids, with `+` after a complete one. **/
	private function __pages(statement:SQLiteStatement):String {
		var pages:Array<String> = [];
		var page:SQLResult = statement.getResult();

		while (page != null) {
			pages.push([for (row in page.data) Std.string(row.id)].join(",") + (page.complete ? "+" : ""));
			page = statement.getResult();
		}

		return pages.join(" ");
	}
}
#end
