package crossbyte.db;

#if cpp
import crossbyte.db.sql.sqlite.SQLiteConnection;
import crossbyte.db.sql.sqlite.SQLiteMode;
import crossbyte.db.sql.sqlite.SQLiteStatement;
import crossbyte.errors.IllegalOperationError;
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
		// deferred transaction, which takes no lock until its first write --
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

	public function testASelectKeepsItsRowsOnceARowIdHasPassedThirtyTwoBits():Void {
		// A statement read the connection's last rowid as soon as it had
		// started, and past 2^31 that is a query of its own -- which hxcpp's
		// glue answers by finalizing the statement before it: every SELECT
		// after the first rowid past 2^31 came back with its first row only.
		var connection:SQLiteConnection = new SQLiteConnection();
		connection.open(null, SQLiteMode.CREATE, false, 4096);
		connection.request("CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)");

		for (i in 0...50) {
			connection.request('INSERT INTO t (v) VALUES ($i)');
		}

		connection.request("INSERT INTO t (id, v) VALUES (3000000000, 99)");

		var select:SQLiteStatement = new SQLiteStatement();
		select.sqlConnection = connection;
		select.text = "SELECT v FROM t";
		select.execute();
		var whole = select.getResult();
		Require.notNull(whole);
		Assert.equals(51, whole.data.length);

		// Paged, the rows still all arrive.
		select.execute(20);
		var rows:Int = select.getResult().data.length;

		while (select.executing) {
			select.next(20);
			var page = select.getResult();
			rows += page == null ? 0 : page.data.length;
		}

		Assert.equals(51, rows);

		// And an insert's own rowid is still whole.
		var insert:SQLiteStatement = new SQLiteStatement();
		insert.sqlConnection = connection;
		insert.text = "INSERT INTO t (id, v) VALUES (3000000001, 100)";
		insert.execute();
		Assert.equals(3000000001.0, insert.getResult().lastInsertRowID);
		connection.close();
	}

	public function testAnAsynchronousFailureReachesItsListener():Void {
		// Every failure on an asynchronous connection killed the process: the
		// connection's own errors were taken for a statement's message, and a
		// statement's error had its absent result set read.
		var connection:SQLiteConnection = new SQLiteConnection();
		var events:Array<String> = [];

		for (type in [SQLEvent.OPEN, SQLEvent.BEGIN, SQLEvent.ROLLBACK, SQLEvent.CLOSE]) {
			connection.addEventListener(type, e -> events.push(e.type));
		}

		connection.addEventListener(SQLErrorEvent.ERROR, e -> events.push("error:" + e.error.operation));
		connection.openAsync(null, SQLiteMode.CREATE, false, 4096);
		connection.begin();
		// SQLite refuses a transaction inside one.
		connection.begin();
		connection.rollback();

		var statement:SQLiteStatement = new SQLiteStatement();
		statement.sqlConnection = connection;
		statement.text = "SELECT * FROM nowhere";
		var failed:SQLError = null;
		statement.addEventListener(SQLErrorEvent.ERROR, e -> failed = e.error);
		statement.execute();

		var after:SQLiteStatement = new SQLiteStatement();
		after.sqlConnection = connection;
		after.text = "SELECT 7 AS seven";
		var seven:Dynamic = null;
		after.addEventListener(SQLEvent.RESULT, _ -> seven = Reflect.field(after.getResult().data[0], "seven"));
		after.execute();
		connection.close();

		__pumpUntil(() -> events.indexOf(SQLEvent.CLOSE) >= 0);
		Assert.same([SQLEvent.OPEN, SQLEvent.BEGIN, "error:" + SQLEvent.BEGIN, SQLEvent.ROLLBACK, SQLEvent.CLOSE], events);
		Require.notNull(failed);
		Assert.isTrue(failed.details().indexOf("no such table") >= 0, failed.details());
		Assert.isFalse(statement.executing);
		Assert.equals(7, seven, "the connection stopped answering after a failure");
	}

	public function testAsynchronousStatementsQueuedTogetherEachGetEveryRow():Void {
		// The worker handed each statement its result set and went on to the
		// next statement, while the runtime's thread read the rows -- and
		// hxcpp's glue starts a statement by finalizing the one before it. Of
		// two SELECTs of 5000 rows queued together, the first got one row.
		var connection:SQLiteConnection = new SQLiteConnection();
		var opened:Bool = false;
		connection.addEventListener(SQLEvent.OPEN, _ -> opened = true);
		connection.openAsync(null, SQLiteMode.CREATE, false, 4096);

		var setup:SQLiteStatement = new SQLiteStatement();
		setup.sqlConnection = connection;
		setup.text = "CREATE TABLE t AS WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 5000) SELECT i FROM n";
		setup.execute();

		var counts:Array<String> = [];
		var first:SQLiteStatement = new SQLiteStatement();
		first.sqlConnection = connection;
		first.text = "SELECT i FROM t";
		first.addEventListener(SQLEvent.RESULT, _ -> counts.push("first:" + first.getResult().data.length));
		var second:SQLiteStatement = new SQLiteStatement();
		second.sqlConnection = connection;
		second.text = "SELECT i FROM t";
		second.addEventListener(SQLEvent.RESULT, _ -> counts.push("second:" + second.getResult().data.length));
		first.execute();
		second.execute();

		// And paged, with a rowid past 2^31 making each statement's rowid a
		// query of its own.
		var insert:SQLiteStatement = new SQLiteStatement();
		insert.sqlConnection = connection;
		insert.text = "INSERT INTO t (rowid, i) VALUES (3000000000, 0)";
		insert.execute();
		var paged:SQLiteStatement = new SQLiteStatement();
		paged.sqlConnection = connection;
		paged.text = "SELECT i FROM t";
		var pagedRows:Int = 0;
		paged.addEventListener(SQLEvent.RESULT, function(_) {
			var page = paged.getResult();
			pagedRows += page == null ? 0 : page.data.length;

			if (paged.executing) {
				paged.next(1000);
			}
		});
		paged.execute(1000);

		__pumpUntil(() -> counts.length >= 2 && !paged.executing);
		connection.close();
		__pumpUntil(() -> false, 0.2);

		Assert.isTrue(opened);
		Assert.same(["first:5000", "second:5000"], counts);
		Assert.equals(5001, pagedRows);
	}

	public function testOpeningAnOpenConnectionAgainIsRefused():Void {
		// open() on an open connection replaced its handle and left the first
		// open -- unreachable, and holding whatever locks it had. AIR's open()
		// throws IllegalOperationError then; so does this, and a statement
		// kept across close() and open() runs on the open one.
		var path:String = __path("reopen");
		var connection:SQLiteConnection = new SQLiteConnection();
		connection.open(path, SQLiteMode.CREATE, false, 4096);
		connection.request("CREATE TABLE t (x INTEGER)");
		connection.request("BEGIN IMMEDIATE");

		var refused:Bool = false;

		try {
			connection.open(path, SQLiteMode.UPDATE, false, 4096);
		} catch (_:IllegalOperationError) {
			refused = true;
		}

		if (!Assert.isTrue(refused, "a second open() was taken, and the first connection left open")) {
			return;
		}

		Assert.raises(() -> connection.openAsync(path, SQLiteMode.UPDATE, false, 4096), IllegalOperationError);
		Assert.isTrue(connection.inTransaction, "the connection in use is not the first");
		connection.request("ROLLBACK");

		var count:SQLiteStatement = new SQLiteStatement();
		count.sqlConnection = connection;
		count.text = "SELECT COUNT(*) AS n FROM t";
		connection.close();

		// Closed: refused, where each dereferenced the connection it had not.
		Assert.raises(() -> count.execute(), IllegalOperationError);
		Assert.raises(() -> connection.begin(), IllegalOperationError);
		Assert.raises(() -> connection.request("SELECT 1"), IllegalOperationError);
		Assert.raises(function() {
			var id:Float = connection.lastInsertRowID;
		}, IllegalOperationError);

		connection.open(path, SQLiteMode.UPDATE, false, 4096);
		count.execute();
		Assert.equals(0, (Reflect.field(count.getResult().data[0], "n") : Int));

		// Nothing was left behind holding the write lock.
		var other:SQLiteConnection = new SQLiteConnection();
		other.open(path, SQLiteMode.UPDATE, false, 4096);
		other.request("BEGIN IMMEDIATE");
		other.request("ROLLBACK");
		other.close();
		connection.close();

		// Asynchronously the same, and a close is over once CLOSE arrives:
		// until then the old worker still holds its connection.
		var events:Array<String> = [];
		connection.addEventListener(SQLEvent.OPEN, _ -> events.push("open"));
		connection.addEventListener(SQLEvent.CLOSE, _ -> events.push("close"));
		connection.openAsync(path, SQLiteMode.UPDATE, false, 4096);
		Assert.raises(() -> connection.openAsync(path, SQLiteMode.UPDATE, false, 4096), IllegalOperationError);
		connection.close();
		Assert.raises(() -> connection.openAsync(path, SQLiteMode.UPDATE, false, 4096), IllegalOperationError);
		Assert.raises(() -> connection.begin(), IllegalOperationError);
		__pumpUntil(() -> events.indexOf("close") >= 0);
		connection.openAsync(path, SQLiteMode.UPDATE, false, 4096);
		connection.close();
		__pumpUntil(() -> events.length >= 4);
		Assert.same(["open", "close", "open", "close"], events);
	}

	public function testDeanalyzeRemovesTheStatisticsAndKeepsTheConnection():Void {
		// deanalyze() closed the connection and opened it again, and touched
		// no statistics: an in-memory database lost every table, a file kept
		// its sqlite_stat1, and what the session held -- a transaction, an
		// attached database, busy_timeout -- was lost on the way.
		var connection:SQLiteConnection = new SQLiteConnection();
		var events:Array<String> = [];

		for (type in [SQLEvent.OPEN, SQLEvent.CLOSE, SQLEvent.ANALYZE, SQLEvent.DEANALYZE]) {
			connection.addEventListener(type, e -> events.push(e.type));
		}

		connection.open(null, SQLiteMode.CREATE, false, 4096);
		connection.request("CREATE TABLE t (x INTEGER, y INTEGER)");
		connection.request("CREATE INDEX t_x ON t (x)");

		for (i in 0...50) {
			connection.request('INSERT INTO t VALUES ($i, $i)');
		}

		connection.attach("extra");
		connection.request("CREATE TABLE extra.u (z INTEGER)");
		connection.request("CREATE INDEX extra.u_z ON u (z)");
		connection.request("INSERT INTO extra.u VALUES (1)");
		connection.analyze();
		Assert.isTrue(__count(connection, "main.sqlite_stat1") > 0, "analyze() gathered nothing to remove");
		Assert.isTrue(__count(connection, "extra.sqlite_stat1") > 0, "analyze() gathered nothing to remove");

		connection.busyTimeout = 1234;
		connection.begin();
		connection.deanalyze();

		Assert.equals(0, __count(connection, "main.sqlite_stat1"));
		Assert.equals(0, __count(connection, "extra.sqlite_stat1"), "an attached database kept its statistics");
		Assert.equals(50, __count(connection, "t"), "the tables went with the statistics");
		Assert.equals(1234, connection.busyTimeout);
		Assert.isTrue(connection.inTransaction, "the open transaction was ended");
		Assert.same([SQLEvent.OPEN, SQLEvent.ANALYZE, SQLEvent.DEANALYZE], events);
		connection.rollback();
		connection.close();
	}

	public function testAnAsynchronousDeanalyzeReportsOnceItIsDone():Void {
		// DEANALYZE was dispatched as the call returned, before any work, and
		// the work then reopened the connection from the worker's thread,
		// which has no runtime: nothing on the connection answered again.
		var path:String = __path("deanalyze");
		var setup:SQLiteConnection = new SQLiteConnection();
		setup.open(path, SQLiteMode.CREATE, false, 4096);
		setup.request("CREATE TABLE t (x INTEGER)");
		setup.request("CREATE INDEX t_x ON t (x)");

		for (i in 0...50) {
			setup.request('INSERT INTO t VALUES ($i)');
		}

		setup.analyze();
		setup.close();

		var connection:SQLiteConnection = new SQLiteConnection();
		var events:Array<String> = [];

		for (type in [SQLEvent.OPEN, SQLEvent.DEANALYZE, SQLEvent.CLOSE]) {
			connection.addEventListener(type, e -> events.push(e.type));
		}

		connection.addEventListener(SQLErrorEvent.ERROR, e -> events.push("error: " + e.error.details()));
		connection.openAsync(path, SQLiteMode.UPDATE, false, 4096);
		connection.deanalyze();
		Assert.same([], events, "dispatched before the work was done");

		var count:SQLiteStatement = new SQLiteStatement();
		count.sqlConnection = connection;
		count.text = "SELECT COUNT(*) AS n FROM sqlite_stat1";
		var rows:Dynamic = null;
		count.addEventListener(SQLEvent.RESULT, _ -> rows = Reflect.field(count.getResult().data[0], "n"));
		count.execute();
		__pumpUntil(() -> rows != null || events.length > 2);
		connection.close();
		__pumpUntil(() -> events.indexOf(SQLEvent.CLOSE) >= 0);

		Assert.same([SQLEvent.OPEN, SQLEvent.DEANALYZE, SQLEvent.CLOSE], events);
		Assert.equals(0, rows);
	}

	/** The rows in `table`. **/
	private static function __count(connection:SQLiteConnection, table:String):Int {
		return Std.int(Reflect.field(connection.request("SELECT COUNT(*) AS n FROM " + table).next(), "n"));
	}

	public function testCancelStopsTheWorkAndKeepsTheConnection():Void {
		// cancel() cancelled the connection's worker: the statement running
		// went on to its end with nothing left to report it, the work queued
		// behind it was dropped without a word, CANCEL came at once, and
		// close() never closed -- the connection and its file were held for
		// the life of the process.
		var path:String = __path("cancel");
		var connection:SQLiteConnection = new SQLiteConnection();
		var events:Array<String> = [];
		var errors:Map<String, SQLError> = new Map();

		for (type in [SQLEvent.OPEN, SQLEvent.BEGIN, SQLEvent.CANCEL, SQLEvent.CLOSE]) {
			connection.addEventListener(type, e -> events.push(e.type));
		}

		connection.addEventListener(SQLErrorEvent.ERROR, e -> events.push("error:" + e.error.operation));
		connection.openAsync(path, SQLiteMode.CREATE, false, 4096);

		var first:SQLiteStatement = __watched(connection, "first", "SELECT 1 AS one", events, errors);
		// Hours of work, which only an interrupt ends.
		var long:SQLiteStatement = __watched(connection, "long",
			"WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 100000000000) SELECT COUNT(*) AS c FROM n", events, errors);
		var queued:SQLiteStatement = __watched(connection, "queued", "SELECT 2 AS two", events, errors);
		first.execute();
		long.execute();
		queued.execute();
		connection.begin();

		// The worker takes up the long statement as soon as the first is done.
		__pumpUntil(() -> events.indexOf("first") >= 0);
		__pumpUntil(() -> false, 0.2);

		var asked:Float = haxe.Timer.stamp();
		connection.cancel();
		__pumpUntil(() -> events.indexOf(SQLEvent.CANCEL) >= 0);
		var took:Float = haxe.Timer.stamp() - asked;

		Assert.same([SQLEvent.OPEN, "first", "long:error", "queued:error", "error:" + SQLEvent.BEGIN, SQLEvent.CANCEL], events);
		Assert.isTrue(took < 5, 'the cancel took $took s');
		Assert.isTrue(errors.exists("long") && errors.get("long").details().indexOf("interrupt") >= 0,
			"the running statement was not interrupted: " + (errors.exists("long") ? errors.get("long").details() : "no error"));
		Assert.isTrue(errors.exists("queued") && errors.get("queued").details().indexOf("Cancelled") >= 0,
			"the queued statement was not dropped: " + (errors.exists("queued") ? errors.get("queued").details() : "no error"));
		Assert.isFalse(long.executing);
		Assert.isFalse(queued.executing);

		// Still open, and answering.
		var after:SQLiteStatement = __watched(connection, "after", "SELECT 3 AS three", events, errors);
		after.execute();
		__pumpUntil(() -> events.indexOf("after") >= 0 || events.indexOf("after:error") >= 0);
		Assert.isTrue(events.indexOf("after") >= 0, "the connection did not answer after cancel()");

		connection.close();
		__pumpUntil(() -> events.indexOf(SQLEvent.CLOSE) >= 0);
		Assert.isTrue(events.indexOf(SQLEvent.CLOSE) >= 0, "close() never closed");

		// Nothing holds the file.
		var other:SQLiteConnection = new SQLiteConnection();
		other.open(path, SQLiteMode.UPDATE, false, 4096);
		other.request("BEGIN IMMEDIATE");
		other.request("ROLLBACK");
		other.close();
	}

	public function testCancelInterruptsAStatementRunningOnAnotherThread():Void {
		// A synchronous connection queues nothing, so cancel() has only the
		// statement running -- on whichever thread called it -- to stop.
		var connection:SQLiteConnection = new SQLiteConnection();
		connection.open(null, SQLiteMode.CREATE, false, 4096);
		var cancels:Int = 0;
		connection.addEventListener(SQLEvent.CANCEL, _ -> cancels++);
		var failure:String = null;
		var done:sys.thread.Lock = new sys.thread.Lock();

		sys.thread.Thread.create(function() {
			try {
				connection.request("WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 100000000000) SELECT COUNT(*) AS c FROM n");
			} catch (e:Dynamic) {
				failure = Std.string(e);
			}

			done.release();
		});

		// Long enough for the statement to be stepping.
		crossbyte.sys.System.sleep(0.3);
		connection.cancel();
		var stopped:Bool = done.wait(10.0);

		if (!Assert.isTrue(stopped, "the statement was not interrupted")) {
			// Still running on the other thread: nothing more is safe to ask.
			return;
		}

		Assert.isTrue(failure != null && failure.indexOf("interrupt") >= 0, "it failed with " + failure);
		Assert.equals(1, cancels);

		// And the connection still answers.
		Assert.equals(1, __count(connection, "(SELECT 1)"));
		connection.close();
	}

	/** A statement whose result or failure is pushed to `events` as `name` or `name:error`. **/
	private static function __watched(connection:SQLiteConnection, name:String, sql:String, events:Array<String>, errors:Map<String, SQLError>):SQLiteStatement {
		var statement:SQLiteStatement = new SQLiteStatement();
		statement.sqlConnection = connection;
		statement.text = sql;
		statement.addEventListener(SQLEvent.RESULT, _ -> events.push(name));
		statement.addEventListener(SQLErrorEvent.ERROR, function(e:SQLErrorEvent) {
			errors.set(name, e.error);
			events.push(name + ":error");
		});
		return statement;
	}

	public function testAReadConnectionCannotWrite():Void {
		// SQLiteMode.READ only checked that the file existed and then opened
		// it read-write: an INSERT through it succeeded. AIR's READ is
		// read-only.
		var path:String = __path("read");
		var setup:SQLiteConnection = new SQLiteConnection();
		setup.open(path, SQLiteMode.CREATE, false, 4096);
		setup.request("CREATE TABLE t (x INTEGER)");
		setup.request("INSERT INTO t VALUES (1)");
		setup.close();

		var reader:SQLiteConnection = new SQLiteConnection();
		reader.open(path, SQLiteMode.READ, false, 4096);
		Assert.equals(1, __count(reader, "t"));
		Assert.raises(() -> reader.request("INSERT INTO t VALUES (2)"), SQLError);
		Assert.raises(() -> reader.request("CREATE TABLE u (y INTEGER)"), SQLError);
		reader.close();

		// Asynchronously the same.
		var events:Array<String> = [];
		var asynchronous:SQLiteConnection = new SQLiteConnection();
		asynchronous.addEventListener(SQLEvent.OPEN, _ -> events.push("open"));
		asynchronous.addEventListener(SQLEvent.CLOSE, _ -> events.push("close"));
		asynchronous.openAsync(path, SQLiteMode.READ, false, 4096);
		var insert:SQLiteStatement = __watched(asynchronous, "insert", "INSERT INTO t VALUES (3)", events, new Map());
		insert.execute();
		asynchronous.close();
		__pumpUntil(() -> events.indexOf("close") >= 0);
		Assert.same(["open", "insert:error", "close"], events);

		var check:SQLiteConnection = new SQLiteConnection();
		check.open(path, SQLiteMode.UPDATE, false, 4096);
		Assert.equals(1, __count(check, "t"), "a READ connection wrote");
		check.close();
	}

	public function testAutoCompactShrinksTheFileAsRowsGo():Void {
		// autoCompact set auto_vacuum to INCREMENTAL, which gives nothing back
		// until PRAGMA incremental_vacuum runs, and nothing ran it: after 200
		// rows of 8 KiB were deleted the file stayed 1.6 MB, its pages free.
		// AIR's autoCompact gives the space back at each commit, which is
		// SQLite's FULL.
		var path:String = __path("compact");
		var connection:SQLiteConnection = new SQLiteConnection();
		connection.open(path, SQLiteMode.CREATE, true, 4096);
		Assert.isTrue(connection.autoCompact);
		connection.request("CREATE TABLE blobs (b BLOB)");
		connection.begin();

		for (i in 0...200) {
			connection.request("INSERT INTO blobs VALUES (zeroblob(8192))");
		}

		connection.commit();
		var full:Float = FileSystem.stat(path).size;
		connection.request("DELETE FROM blobs");
		var after:Float = FileSystem.stat(path).size;
		Assert.isTrue(after < full / 4, 'the file stayed $after bytes of $full');
		Assert.equals(0.0, connection.stats().freeListCount);
		connection.close();

		// A database that gives nothing back by itself does not say it does --
		// an incremental one included, as earlier versions made them.
		var incremental:String = __path("incremental");
		var plain:SQLiteConnection = new SQLiteConnection();
		plain.open(incremental, SQLiteMode.CREATE, false, 4096);
		Assert.isFalse(plain.autoCompact);
		plain.request("PRAGMA auto_vacuum = 2");
		plain.request("VACUUM");
		Assert.isFalse(plain.autoCompact, "an incremental database reported compacting by itself");
		plain.close();
	}

	public function testAForeignKeyViolationReportsItsWholeRowId():Void {
		// The rowid was parsed into an Int: a violation at rowid 3,000,000,000
		// was reported at 2147483647, the row a repair script would then touch.
		var connection:SQLiteConnection = new SQLiteConnection();
		connection.open(null, SQLiteMode.CREATE, false, 4096);
		connection.request("CREATE TABLE parent (id INTEGER PRIMARY KEY)");
		connection.request("CREATE TABLE child (pid INTEGER REFERENCES parent(id))");
		connection.request("INSERT INTO child (rowid, pid) VALUES (3000000000, 7)");

		var violations = connection.foreignKeyCheck();
		Assert.equals(1, violations.length);
		if (violations.length == 1) {
			Assert.equals(3000000000.0, violations[0].rowid);
			Assert.equals("child", violations[0].table);
			Assert.equals("parent", violations[0].parent);
		}

		// A WITHOUT ROWID table has none to report.
		connection.request("CREATE TABLE keyed (k TEXT PRIMARY KEY, pid INTEGER REFERENCES parent(id)) WITHOUT ROWID");
		connection.request("INSERT INTO keyed VALUES ('a', 9)");
		var keyed = [for (v in connection.foreignKeyCheck()) if (v.table == "keyed") v];
		Assert.equals(1, keyed.length);
		if (keyed.length == 1) {
			Assert.isNull(keyed[0].rowid);
		}
		connection.close();
	}

	public function testWorkQueuedBehindAFailedOpenIsToldItWillNotRun():Void {
		// An asynchronous open that fails leaves nothing for the work queued
		// behind it to run on: each is refused, where it ran against no
		// connection, and the connection can be opened again.
		var missing:String = Path.join([Sys.getCwd(), "export", "sqlite-native-absent-" + Std.random(0x7FFFFFFF), "db.sqlite"]);
		var connection:SQLiteConnection = new SQLiteConnection();
		var events:Array<String> = [];
		connection.addEventListener(SQLEvent.OPEN, _ -> events.push("open"));
		connection.addEventListener(SQLErrorEvent.ERROR, e -> events.push("error:" + e.error.operation));
		connection.openAsync(missing, SQLiteMode.CREATE, false, 4096);
		var queued:SQLiteStatement = __watched(connection, "queued", "SELECT 1", events, new Map());
		queued.execute();
		connection.begin();

		__pumpUntil(() -> events.length >= 3);
		Assert.same(["error:" + SQLEvent.OPEN, "queued:error", "error:" + SQLEvent.BEGIN], events);
		Assert.isFalse(queued.executing);

		// Closed by the failure: it opens again.
		connection.openAsync(null, SQLiteMode.CREATE, false, 4096);
		__pumpUntil(() -> events.indexOf("open") >= 0);
		Assert.isTrue(events.indexOf("open") >= 0, "the connection could not be opened again");
		connection.close();
		__pumpUntil(() -> false, 0.2);
	}

	public function testAPagedStatementKeepsItsRowsWhenAnotherRunsBetweenPages():Void {
		// hxcpp's glue keeps one live result per connection and finalizes it
		// as the next request starts. A statement read a page at a time while
		// others ran on the same connection -- a cursor whose rows are each
		// written elsewhere -- stopped after its first page, and the rest was
		// reported as an empty page, complete.
		var connection:SQLiteConnection = new SQLiteConnection();
		connection.open(null, SQLiteMode.CREATE, false, 4096);
		connection.request("CREATE TABLE t AS WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 100) SELECT i FROM n");
		connection.request("CREATE TABLE copied (i INTEGER)");

		var reader:SQLiteStatement = new SQLiteStatement();
		reader.sqlConnection = connection;
		reader.text = "SELECT i FROM t ORDER BY i";
		reader.execute(10);
		var read:Int = 0;

		while (true) {
			var page = reader.getResult();

			if (page != null) {
				for (row in page.data) {
					connection.request("INSERT INTO copied VALUES (" + Reflect.field(row, "i") + ")");
					read++;
				}
			}

			if (!reader.executing) {
				break;
			}

			reader.next(10);
		}

		Assert.equals(100, read, "the paged statement lost its rows to the statements run between its pages");
		Assert.equals(100, __count(connection, "copied"));
		connection.close();

		// And on the worker, where another statement queued between two
		// pages of the first runs between them.
		var asynchronous:SQLiteConnection = new SQLiteConnection();
		asynchronous.openAsync(null, SQLiteMode.CREATE, false, 4096);
		var setup:SQLiteStatement = new SQLiteStatement();
		setup.sqlConnection = asynchronous;
		setup.text = "CREATE TABLE t AS WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 100) SELECT i FROM n";
		setup.execute();
		var paged:SQLiteStatement = new SQLiteStatement();
		paged.sqlConnection = asynchronous;
		paged.text = "SELECT i FROM t ORDER BY i";
		var other:SQLiteStatement = new SQLiteStatement();
		other.sqlConnection = asynchronous;
		other.text = "SELECT COUNT(*) AS n FROM t";
		var pagedRows:Int = 0;
		var done:Bool = false;
		paged.addEventListener(SQLEvent.RESULT, function(_) {
			var page = paged.getResult();
			pagedRows += page == null ? 0 : page.data.length;

			if (paged.executing) {
				other.execute();
				paged.next(10);
			} else {
				done = true;
			}
		});
		paged.execute(10);
		__pumpUntil(() -> done);
		asynchronous.close();
		__pumpUntil(() -> false, 0.2);
		Assert.equals(100, pagedRows, "the paged statement lost its rows to the one queued between its pages");
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

	public function testTheCallingThreadsReadsDoNotRaceTheWorker():Void {
		// On an asynchronous connection request(), and the properties that ask
		// SQLite, ran on the calling thread while the worker ran statements on
		// the same connection -- and hxcpp's glue keeps one live result per
		// connection, finalized as the next request starts: a read on the
		// calling thread stepped and finalized the statement the worker was
		// reading.
		var connection:SQLiteConnection = new SQLiteConnection();
		var opened:Bool = false;
		var closed:Bool = false;
		connection.addEventListener(SQLEvent.OPEN, _ -> opened = true);
		connection.addEventListener(SQLEvent.CLOSE, _ -> closed = true);
		connection.openAsync(null, SQLiteMode.CREATE, false, 4096);
		// The open first, so what races below is the worker's statements.
		__pumpUntil(() -> opened);

		var setup:SQLiteStatement = new SQLiteStatement();
		setup.sqlConnection = connection;
		setup.text = "CREATE TABLE t AS WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 20000) SELECT i FROM n";
		var made:Bool = false;
		setup.addEventListener(SQLEvent.RESULT, _ -> made = true);
		setup.execute();
		__pumpUntil(() -> made);

		var short:Array<Int> = [];
		var wrong:Array<String> = [];
		var failures:Array<String> = [];

		for (round in 0...20) {
			var select:SQLiteStatement = new SQLiteStatement();
			select.sqlConnection = connection;
			select.text = "SELECT i FROM t";
			var rows:Int = -1;
			var failed:Bool = false;
			select.addEventListener(SQLEvent.RESULT, _ -> rows = select.getResult().data.length);
			select.addEventListener(SQLErrorEvent.ERROR, function(e:SQLErrorEvent) {
				failed = true;
				failures.push("select: " + e.error.details());
			});
			select.execute();

			// Asked while the worker reads its 20000 rows.
			for (k in 0...20) {
				try {
					var count:Dynamic = Reflect.field(connection.request("SELECT COUNT(*) AS n FROM t").next(), "n");

					if (count != 20000) {
						wrong.push("count " + count);
					}

					if (connection.foreignKeys) {
						wrong.push("foreign keys on");
					}
				} catch (e:Dynamic) {
					failures.push("calling thread: " + Std.string(e));
				}
			}

			__pumpUntil(() -> rows >= 0 || failed);

			if (rows != 20000) {
				short.push(rows);
			}
		}

		connection.close();
		__pumpUntil(() -> closed);
		Assert.same([], short, "a statement on the worker lost rows to the calling thread's reads");
		Assert.same([], wrong);
		Assert.same([], failures);
	}

	public function testACallOnAnAsynchronousConnectionAnswersInTurn():Void {
		// What answers at once is run by the worker behind the work queued
		// before it. It ran on the calling thread at once, on the connection
		// as the worker had it then: right after openAsync() there was none
		// ("not open"), and a statement queued just before had not run.
		var path:String = __path("in-turn");
		var connection:SQLiteConnection = new SQLiteConnection();
		var events:Array<String> = [];
		connection.addEventListener(SQLEvent.OPEN, _ -> events.push("open"));
		connection.addEventListener(SQLEvent.CLOSE, _ -> events.push("close"));
		connection.openAsync(path, SQLiteMode.CREATE, false, 4096);

		// Before the worker has opened anything: these wait for the open.
		connection.foreignKeys = true;
		Assert.isTrue(connection.foreignKeys);
		connection.request("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)");

		var insert:SQLiteStatement = new SQLiteStatement();
		insert.sqlConnection = connection;
		insert.text = "INSERT INTO t (id, v) VALUES (3000000000, 'a')";
		insert.execute();
		// The insert queued just before has run when these answer.
		Assert.equals(3000000000.0, connection.lastInsertRowID);
		Assert.equals(1.0, connection.totalChanges);
		Assert.same(["t"], connection.tableList());
		Assert.equals(1, __count(connection, "t"));

		Assert.isFalse(connection.inTransaction);
		connection.begin();
		Assert.isTrue(connection.inTransaction, "the BEGIN queued before it had not run");
		connection.rollback();
		Assert.isFalse(connection.inTransaction);

		// connected answers from the events, and asks nothing.
		Assert.isFalse(connection.connected, "connected before OPEN was dispatched");
		__pumpUntil(() -> events.indexOf("open") >= 0);
		Assert.isTrue(connection.connected);
		connection.close();
		Assert.isFalse(connection.connected);
		Assert.raises(() -> connection.request("SELECT 1"), IllegalOperationError);
		__pumpUntil(() -> events.indexOf("close") >= 0);
		Assert.same(["open", "close"], events);
	}

	public function testACallTheWorkerDoesNotReachInTimeIsWithdrawn():Void {
		// Every wait ends: a call waits for its turn for queueTimeout, and one
		// not started by then is withdrawn and never runs.
		var connection:SQLiteConnection = new SQLiteConnection();
		var events:Array<String> = [];
		connection.addEventListener(SQLEvent.CANCEL, _ -> events.push("cancel"));
		connection.addEventListener(SQLEvent.CLOSE, _ -> events.push("close"));
		connection.openAsync(null, SQLiteMode.CREATE, false, 4096);
		connection.request("CREATE TABLE t (x INTEGER)");
		connection.queueTimeout = 0.3;

		// Hours of work, which only an interrupt ends.
		var long:SQLiteStatement = __watched(connection, "long",
			"WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 100000000000) SELECT COUNT(*) AS c FROM n", events, new Map());
		long.execute();

		var asked:Float = haxe.Timer.stamp();
		var refused:SQLError = null;

		try {
			connection.request("INSERT INTO t VALUES (1)");
		} catch (e:SQLError) {
			refused = e;
		}

		var took:Float = haxe.Timer.stamp() - asked;
		Require.notNull(refused);
		Assert.isTrue(took >= 0.25 && took < 5, 'the call waited $took s');
		Assert.isTrue(refused.details().indexOf("Timed out") >= 0, refused.details());

		connection.cancel();
		__pumpUntil(() -> events.indexOf("cancel") >= 0);
		connection.queueTimeout = 10;
		Assert.equals(0, __count(connection, "t"), "the withdrawn call ran after all");

		// 0 waits without limit; a negative is refused.
		connection.queueTimeout = 0;
		Assert.equals(1, __count(connection, "(SELECT 1)"));
		Assert.raises(() -> connection.queueTimeout = -1, crossbyte.errors.ArgumentError);
		Assert.raises(() -> connection.queueTimeout = Math.NaN, crossbyte.errors.ArgumentError);
		connection.close();
		__pumpUntil(() -> events.indexOf("close") >= 0);

		// A call queued behind an open that fails is told so at once, as a
		// call on a closed connection is.
		var missing:String = Path.join([Sys.getCwd(), "export", "sqlite-native-absent-" + Std.random(0x7FFFFFFF), "db.sqlite"]);
		var failed:SQLiteConnection = new SQLiteConnection();
		failed.addEventListener(SQLErrorEvent.ERROR, _ -> {});
		failed.openAsync(missing, SQLiteMode.CREATE, false, 4096);
		asked = haxe.Timer.stamp();
		Assert.raises(() -> failed.request("SELECT 1"), IllegalOperationError);
		Assert.isTrue(haxe.Timer.stamp() - asked < 5);
		__pumpUntil(() -> false, 0.2);
	}

	public function testCodeTheWorkerRunsCanAskTheConnection():Void {
		// An itemClass is made on the worker, and its setters run there: one
		// that asks the connection is answered at once, rather than queued
		// behind the statement it is part of, waiting for itself.
		var connection:SQLiteConnection = new SQLiteConnection();
		connection.openAsync(null, SQLiteMode.CREATE, false, 4096);
		connection.queueTimeout = 1;
		AskingItem.connection = connection;
		AskingItem.asked = [];

		var select:SQLiteStatement = new SQLiteStatement();
		select.sqlConnection = connection;
		select.itemClass = AskingItem;
		select.text = "SELECT 7 AS i";
		var item:AskingItem = null;
		var failure:String = null;
		select.addEventListener(SQLEvent.RESULT, _ -> item = select.getResult().data[0]);
		select.addEventListener(SQLErrorEvent.ERROR, e -> failure = e.error.details());
		select.execute();
		__pumpUntil(() -> item != null || failure != null);

		Assert.isNull(failure);
		Require.notNull(item);
		Assert.equals(7, item.i);
		Assert.same(["MEMORY"], AskingItem.asked);
		AskingItem.connection = null;
		connection.close();
		__pumpUntil(() -> false, 0.2);
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

/** A row type whose setter asks the connection, from the worker that makes it. **/
private class AskingItem {
	public static var connection:SQLiteConnection;
	public static var asked:Array<String> = [];

	public var i(default, set):Int;

	public function new() {}

	private function set_i(value:Int):Int {
		asked.push(Std.string(connection.journalMode));
		return i = value;
	}
}
#end
