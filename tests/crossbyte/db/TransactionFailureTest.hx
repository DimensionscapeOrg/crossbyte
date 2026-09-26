package crossbyte.db;

#if !cpp
import crossbyte.db.mysql.MySQLConnection;
import crossbyte.db.postgres.PostgresConnection;
import crossbyte.errors.SQLError;
import crossbyte.events.SQLErrorEvent;
import sys.db.Connection;
import sys.db.ResultSet;
import utest.Assert;

/**
 * A transaction step that fails has to say so to a caller that is not
 * listening for events, because `AsyncDatabase.transaction` and
 * `SchemaMigrator` do not listen.
 *
 * PostgreSQL and MySQL `begin`, `commit` and `rollback` caught every failure
 * and dispatched an `SQLErrorEvent` instead: a failed COMMIT completed the
 * transaction task as success, and the migrator recorded a migration that had
 * been rolled back. SQLite always threw.
 *
 * Only the wire is fake here, the drivers, pool, facade and migrator are the
 * real ones, so this runs without a server. On cpp the Postgres driver talks
 * to libpq instead, and the same cases run against a stand-in for it in
 * `NativePostgresBridgeTest`, along with the COMMIT answered by ROLLBACK that
 * only libpq's command tag reveals.
 */
@:access(crossbyte.db.postgres.PostgresConnection)
@:access(crossbyte.db.mysql.MySQLConnection)
class TransactionFailureTest extends utest.Test {
	public function testAFailedCommitThrowsAndIsStillDispatched():Void {
		var connection = __postgres("COMMIT;");
		var events:Int = 0;
		connection.addEventListener(SQLErrorEvent.ERROR, _ -> events++);

		connection.begin();
		Assert.raises(() -> connection.commit(), SQLError);
		Assert.equals(1, events);
		// PostgreSQL ends the transaction on a failed COMMIT as surely as on a
		// successful one.
		Assert.isFalse(connection.inTransaction);
	}

	public function testAFailedBeginThrows():Void {
		var connection = __postgres("BEGIN;");

		Assert.raises(() -> connection.begin(), SQLError);
		Assert.isFalse(connection.inTransaction);
	}

	public function testAFailedRollbackThrows():Void {
		var connection = __postgres("ROLLBACK;");

		connection.begin();
		Assert.raises(() -> connection.rollback(), SQLError);
		Assert.isFalse(connection.inTransaction);
	}

	public function testAFailedSavepointThrowsAndIsNotRemembered():Void {
		var connection = __postgres("SAVEPOINT keep;");

		connection.begin();
		Assert.raises(() -> connection.setSavepoint("keep"), SQLError);
		// Not recorded, so a nameless release does not reach for a savepoint
		// the server never made.
		Assert.raises(() -> connection.releaseSavepoint());
	}

	public function testATransactionTaskFailsWhenItsCommitDoes():Void {
		// The pattern AsyncDatabase.transaction documents, as its docstring
		// spells it.
		var connection = __postgres("COMMIT;");
		var pool = new ConnectionPool<PostgresConnection>({factory: () -> connection, maxSize: 1});
		var db = AsyncDatabase.of(pool);

		var outcome:String = "pending";

		db.transaction(c -> c.begin(), c -> c.commit(), c -> c.rollback(), c -> {
			c.request("UPDATE accounts SET balance = balance - 25 WHERE id = 1;");
			return "transferred";
		}).onComplete(v -> outcome = "completed with " + v).onError(e -> outcome = "failed");

		var nextSees:Null<Bool> = null;
		db.submit(c -> c.inTransaction).onComplete(v -> nextSees = v);

		// The pool runs its jobs on threads wherever there are threads, jvm and
		// eval included, and hands results back through the runtime's post
		// queue, so the runtime has to be pumped for either to settle.
		crossbyte.http.HTTPTestSupport.pumpUntil(() -> outcome != "pending" && nextSees != null, 10.0);
		Assert.equals("failed", outcome);
		Assert.equals(false, nextSees, "the next borrower was handed a connection inside a transaction");
		// A rollback followed the failed commit.
		Assert.equals("ROLLBACK;", __sent[__sent.length - 1]);
	}

	public function testAPoolResetRollsBackWhatAFailedBodyLeftOpen():Void {
		// A body that begins, writes and throws. The pool's validate() passes
		// the connection, because an open transaction answers a ping, and the
		// next borrower's "autocommit" insert joined the abandoned
		// transaction.
		var connection = __postgres("never");
		var pool = new ConnectionPool<PostgresConnection>({
			factory: () -> connection,
			validate: c -> c.ping(),
			reset: c -> if (c.inTransaction) c.rollback(),
			maxSize: 1
		});
		var db = AsyncDatabase.of(pool);

		db.submit(function(c:PostgresConnection):Bool {
			c.begin();
			c.request("UPDATE accounts SET balance = 0 WHERE id = 7;");
			throw "application bug after the UPDATE";
		});

		var nextSees:Null<Bool> = null;
		db.submit(c -> c.inTransaction).onComplete(v -> nextSees = v);

		// Results come back through the runtime's post queue; see above.
		crossbyte.http.HTTPTestSupport.pumpUntil(() -> nextSees != null, 10.0);
		Assert.equals(false, nextSees, "the next borrower was handed the abandoned transaction");
		Assert.isTrue(__sent.indexOf("ROLLBACK;") > __sent.indexOf("UPDATE accounts SET balance = 0 WHERE id = 7;"));
	}

	public function testTheMigratorDoesNotReportAMigrationWhoseCommitFailed():Void {
		var connection = __postgres("COMMIT;");
		var migrator = new SchemaMigrator<PostgresConnection>({
			execute: (c, sql) -> c.request(sql),
			readApplied: c -> [],
			recordApplied: (c, m) -> c.request("INSERT INTO schema_migrations VALUES (" + m.version + ");"),
			ensureTable: c -> {},
			begin: c -> c.begin(),
			commit: c -> c.commit(),
			rollback: c -> c.rollback()
		});

		migrator.add(Migration.ofSql(1, "accounts", "CREATE TABLE accounts (id serial PRIMARY KEY);"));

		// It returned a report listing migration 1 as applied, when nothing
		// had been.
		Assert.raises(() -> migrator.migrate(connection), SQLError);
	}

	public function testMySQLFailedCommitThrows():Void {
		var wire = new FailingConnection("COMMIT;");
		var connection = new MySQLConnection();
		connection.__connection = wire;
		var events:Int = 0;
		connection.addEventListener(SQLErrorEvent.ERROR, _ -> events++);

		connection.begin();
		Assert.raises(() -> connection.commit(), SQLError);
		Assert.equals(1, events);
		// Left set: whether MySQL ended the transaction depends on why the
		// COMMIT failed, and a ROLLBACK sent to an idle connection is harmless
		// where one withheld from an open transaction is not.
		Assert.isTrue(connection.inTransaction);

		connection.rollback();
		Assert.isFalse(connection.inTransaction);
	}

	public function testMySQLFailedBeginAndRollbackThrow():Void {
		var beginFails = new MySQLConnection();
		beginFails.__connection = new FailingConnection("START TRANSACTION;");
		Assert.raises(() -> beginFails.begin(), SQLError);
		Assert.isFalse(beginFails.inTransaction);

		var rollbackFails = new MySQLConnection();
		rollbackFails.__connection = new FailingConnection("ROLLBACK;");
		rollbackFails.begin();
		Assert.raises(() -> rollbackFails.rollback(), SQLError);
		Assert.isFalse(rollbackFails.inTransaction);
	}

	private var __sent:Array<String>;

	/**
	 * A PostgresConnection whose wire fails the one statement named. The
	 * non-native request path calls `__connection.query(sql)`, so this stands
	 * in for the server exactly where PDO would.
	 */
	@:noCompletion private function __postgres(failOn:String):PostgresConnection {
		__sent = [];
		var sent = __sent;
		var connection = new PostgresConnection();

		connection.__connection = {
			query: function(sql:String):Dynamic {
				sent.push(sql);

				if (sql == failOn) {
					throw "server closed the connection unexpectedly";
				}

				return {fetchAll: () -> [], rowCount: () -> 0};
			},
			exec: function(sql:String):Dynamic {
				throw "exec not expected";
			},
			lastInsertId: () -> 0
		};

		return connection;
	}
}

/** A `sys.db.Connection` that fails the one statement named. **/
private class FailingConnection implements Connection {
	private var __failOn:String;

	public function new(failOn:String) {
		__failOn = failOn;
	}

	public function request(s:String):ResultSet {
		if (s == __failOn) {
			throw "Lost connection to MySQL server during query";
		}

		return null;
	}

	public function close():Void {}

	public function escape(s:String):String {
		return s;
	}

	public function quote(s:String):String {
		return "'" + s + "'";
	}

	public function addValue(s:StringBuf, v:Dynamic):Void {
		s.add(v);
	}

	public function lastInsertId():Int {
		return 0;
	}

	public function dbName():String {
		return "MySQL";
	}

	public function startTransaction():Void {}

	public function commit():Void {}

	public function rollback():Void {}
}
#end
