package crossbyte.db;

#if !js
import crossbyte.db.fakemysql.ScriptedConnection;
import crossbyte.db.mysql.MySQLConnection;
import crossbyte.db.mysql.MySQLStatement;
import crossbyte.errors.SQLError;
import crossbyte.events.SQLErrorEvent;
import crossbyte.events.SQLEvent;
import utest.Assert;

/**
 * The MySQL driver's own logic, over a scripted connection rather than a
 * client, so it runs on every target the driver builds for. What the native
 * client does on the wire is `MySQLNativeWireTest`'s, against a fake server.
 */
@:access(crossbyte.db.mysql.MySQLConnection)
@:access(crossbyte.db.mysql.MySQLStatement)
class MySQLDriverTest extends utest.Test {
	public function testARefusedStatementThrowsAndIsStillDispatched():Void {
		// execute() dispatched an SQLErrorEvent and returned, so a caller not
		// listening -- an AsyncDatabase task, a SchemaMigrator step -- saw a
		// failed INSERT as one that had run.
		var wire:ScriptedConnection = new ScriptedConnection();
		wire.failures.set("INSERT INTO users (email) VALUES ('a@example.com')", "Duplicate entry 'a@example.com' for key 'users.email'");
		var statement:MySQLStatement = __statement(wire);
		var events:Int = 0;
		var results:Int = 0;
		statement.addEventListener(SQLErrorEvent.ERROR, _ -> events++);
		statement.addEventListener(SQLEvent.RESULT, _ -> results++);

		statement.text = "INSERT INTO users (email) VALUES (:email)";
		statement.parameters.email = "a@example.com";

		Assert.raises(() -> statement.execute(), SQLError);
		Assert.equals(1, events);
		Assert.equals(0, results);
		Assert.isFalse(statement.executing);
	}

	public function testAWriteWithNoRowsCompletes():Void {
		var wire:ScriptedConnection = new ScriptedConnection();
		var statement:MySQLStatement = __statement(wire);
		var errors:Int = 0;
		statement.addEventListener(SQLErrorEvent.ERROR, _ -> errors++);

		statement.text = "UPDATE users SET name = 'x' WHERE id = 1";
		statement.execute();

		var result = statement.getResult();
		Assert.equals(0, errors);
		Assert.notNull(result);
		Assert.isTrue(result != null && result.complete);
		Assert.isTrue(result != null && result.data.length == 0);
	}

	public function testTransactionsSentAsSqlAreFollowedWithoutTheServerFlags():Void {
		// Natively the server's status flags say whether a transaction is
		// open. A connection that cannot read them -- a target other than cpp
		// -- follows the statements that open and close one instead, so a
		// pool still rolls back a START TRANSACTION sent as text.
		var connection:MySQLConnection = new MySQLConnection();
		connection.__connection = new ScriptedConnection();

		connection.request("START TRANSACTION");
		Assert.isTrue(connection.inTransaction);
		connection.request("ROLLBACK TO SAVEPOINT sp_1");
		Assert.isTrue(connection.inTransaction, "a rollback to a savepoint ended the transaction");
		connection.request("commit;");
		Assert.isFalse(connection.inTransaction);

		connection.request("  begin");
		Assert.isTrue(connection.inTransaction);
		connection.request("ROLLBACK");
		Assert.isFalse(connection.inTransaction);

		// A session with autocommit off always has a transaction open.
		connection.autocommit = false;
		Assert.isTrue(connection.inTransaction);
		connection.request("SET autocommit=1");
		Assert.isFalse(connection.inTransaction);
		connection.request("SET @@autocommit = OFF");
		Assert.isTrue(connection.inTransaction);
	}

	public function testARefusedBeginChangesNothing():Void {
		var wire:ScriptedConnection = new ScriptedConnection();
		wire.failures.set("START TRANSACTION", "Lost connection to MySQL server during query");
		var connection:MySQLConnection = new MySQLConnection();
		connection.__connection = wire;

		Assert.raises(() -> connection.request("START TRANSACTION"));
		Assert.isFalse(connection.inTransaction);
	}

	private function __statement(wire:ScriptedConnection):MySQLStatement {
		var connection:MySQLConnection = new MySQLConnection();
		connection.__connection = wire;
		var statement:MySQLStatement = new MySQLStatement();
		statement.sqlConnection = connection;
		return statement;
	}
}
#end
