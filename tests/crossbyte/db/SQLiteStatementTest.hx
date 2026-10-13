package crossbyte.db;

#if (cpp || php)
import crossbyte.db.sql.SQLResult;
import crossbyte.db.sql.sqlite.SQLiteConnection;
import crossbyte.db.sql.sqlite.SQLiteMode;
import crossbyte.db.sql.sqlite.SQLiteStatement;
import crossbyte.test.Require;
import utest.Assert;

/**
 * SQLite through the driver on every target where it opens a database:
 * natively and on PHP. What runs only natively (the asynchronous
 * connection, `cancel()`, bound parameters) is in `SQLiteNativeTest`.
 */
@:access(crossbyte.db.sql.sqlite.SQLiteConnection)
class SQLiteStatementTest extends utest.Test {
	private var __connection:SQLiteConnection;

	public function setup():Void {
		__connection = new SQLiteConnection();
		__connection.open(null, SQLiteMode.CREATE, false, 4096);
		__connection.request("CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER, s TEXT)");
	}

	public function teardown():Void {
		if (__connection != null && __connection.connected) {
			__connection.close();
		}

		__connection = null;
	}

	public function testAnInsertRunsOnce():Void {
		// On PHP, reading the result of a statement with no result columns
		// runs it again, and the statement read its result to count the
		// rows it changed: every INSERT inserted twice.
		var statement:SQLiteStatement = __statement("INSERT INTO t (v) VALUES (1)");
		statement.execute();
		var result:SQLResult = statement.getResult();

		Require.notNull(result);
		Assert.equals(1.0, result.rowsAffected);
		Assert.equals(1.0, result.lastInsertRowId);
		Assert.equals(1, __count());
	}

	public function testABeginThroughAStatementOpensOneTransaction():Void {
		// Run twice, the BEGIN failed with "cannot start a transaction within
		// a transaction".
		__statement("BEGIN").execute();
		__statement("INSERT INTO t (v) VALUES (1)").execute();
		__statement("ROLLBACK").execute();
		Assert.equals(0, __count(), "the ROLLBACK did not end the transaction the BEGIN began");

		__statement("BEGIN").execute();
		__statement("INSERT INTO t (v) VALUES (2)").execute();
		__statement("COMMIT").execute();
		Assert.equals(1, __count());
	}

	public function testUpdatesAndDeletesSayWhatTheyChanged():Void {
		for (i in 0...3) {
			__statement('INSERT INTO t (v) VALUES ($i)').execute();
		}

		// Run twice, v = v + 10 would add 20 to each.
		var update:SQLiteStatement = __statement("UPDATE t SET v = v + 10 WHERE v > 0");
		update.execute();
		Assert.equals(2.0, update.getResult().rowsAffected);
		Assert.equals(23, __value("SELECT SUM(v) AS n FROM t"));

		var delete:SQLiteStatement = __statement("DELETE FROM t");
		delete.execute();
		Assert.equals(3.0, delete.getResult().rowsAffected);
		Assert.equals(0, __count());
	}

	public function testARequestForAWriteRunsOnceAndCountsItsRows():Void {
		// A connection's own request answers the write's result, which a
		// caller may read: its length is the rows it changed, and asking it
		// for a row runs nothing again.
		__connection.request("INSERT INTO t (v) VALUES (1)");
		__connection.request("INSERT INTO t (v) VALUES (2)");
		var result = __connection.request("UPDATE t SET v = v + 1");

		Assert.equals(2, result.length);
		Assert.isFalse(result.hasNext());
		Assert.isFalse(result.hasNext());
		Assert.equals(5, __value("SELECT SUM(v) AS n FROM t"));
	}

	public function testAStatementReadsItsRowsWholeAndInPages():Void {
		for (i in 0...5) {
			__statement('INSERT INTO t (v, s) VALUES ($i, \'row $i\')').execute();
		}

		var select:SQLiteStatement = __statement("SELECT v, s FROM t ORDER BY v");
		select.execute();
		var whole:SQLResult = select.getResult();
		Require.notNull(whole);
		Assert.equals(5, whole.data.length);
		Assert.equals(0.0, whole.rowsAffected);
		Assert.equals("row 4", Reflect.field(whole.data[4], "s"));
		Assert.isTrue(whole.complete);

		select.execute(2);
		var seen:Array<Int> = [for (row in select.getResult().data) Reflect.field(row, "v")];

		while (select.executing) {
			select.next(2);
			var page:SQLResult = select.getResult();

			if (page != null) {
				for (row in page.data) {
					seen.push(Reflect.field(row, "v"));
				}
			}
		}

		Assert.same([0, 1, 2, 3, 4], seen);
	}

	public function testParametersAreWrittenOnce():Void {
		var insert:SQLiteStatement = __statement("INSERT INTO t (v, s) VALUES (:v, :s)");
		insert.parameters.v = 7;
		insert.parameters.s = "it's";
		insert.execute();

		var select:SQLiteStatement = __statement("SELECT v, s FROM t WHERE v = :v");
		select.parameters.v = 7;
		select.execute();
		var rows:Array<Dynamic> = select.getResult().data;

		Assert.equals(1, rows.length);
		Assert.equals("it's", Reflect.field(rows[0], "s"));
	}

	public function testTheConnectionsTransactionsCommitAndRollBack():Void {
		__connection.begin();
		__statement("INSERT INTO t (v) VALUES (1)").execute();
		__connection.rollback();
		Assert.equals(0, __count());

		__connection.begin();
		__statement("INSERT INTO t (v) VALUES (1)").execute();
		__connection.setSavepoint("inner");
		__statement("INSERT INTO t (v) VALUES (2)").execute();
		__connection.rollbackToSavepoint("inner");
		__connection.commit();
		Assert.equals(1, __count());
	}

	private function __statement(text:String):SQLiteStatement {
		var statement:SQLiteStatement = new SQLiteStatement();
		statement.sqlConnection = __connection;
		statement.text = text;
		return statement;
	}

	private function __count():Int {
		return __value("SELECT COUNT(*) AS n FROM t");
	}

	private function __value(sql:String):Int {
		var rows = __connection.request(sql);
		Assert.isTrue(rows.hasNext(), sql + " answered no row");
		return Std.int(Reflect.field(rows.next(), "n"));
	}
}
#end
