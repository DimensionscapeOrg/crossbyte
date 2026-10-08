package crossbyte.db;

#if cpp
import crossbyte.db.postgres.PostgresConfig;
import crossbyte.db.postgres.PostgresConnection;
import crossbyte.db.postgres.PostgresIsolationLevel;
import crossbyte.db.postgres.PostgresParameter;
import crossbyte.errors.SQLError;
import crossbyte.events.SQLErrorEvent;
import haxe.io.Path;
import sys.thread.Lock;
import sys.thread.Mutex;
import sys.thread.Thread;
import utest.Assert;
import crossbyte.test.Require;

/**
 * The native libpq bridge, driven against a stand-in libpq rather than a
 * server, so it runs in the ordinary native suite.
 *
 * `PostgresIntegrationTest` covers the driver against a real PostgreSQL, but
 * only in the one CI job that has a database. What this covers is the bridge
 * itself: its state, its threading and what it does to the collector, none of
 * which a server is needed to observe. The stand-in is `fakepq/fake_libpq.c`,
 * built beside the test binary as a shared library and loaded through
 * `libraryPath` exactly as the real one is.
 */
@:buildXml('<include name="${haxelib:crossbyte}/tests/crossbyte/db/fakepq/FakeLibPQBuild.xml"/>')
class NativePostgresBridgeTest extends utest.Test {
	public function testConcurrentQueriesEachGetTheirOwnRows():Void {
		// The shape AsyncDatabase produces by default: a worker per pooled
		// connection, all querying at once. With one process-wide result buffer,
		// a query could read another's rows, or the freed memory of a buffer
		// another thread had just grown.
		var config = __config("localhost");
		var pool = new ConnectionPool<PostgresConnection>({
			factory: () -> __open(config),
			close: c -> c.close(),
			maxSize: 8
		});
		var db = AsyncDatabase.of(pool);
		var tasks = [];

		for (worker in 0...8) {
			tasks.push(db.submit(function(connection:PostgresConnection):Int {
				var wrong:Int = 0;

				for (n in 0...400) {
					var value:String = 'worker-$worker-query-$n';
					var result = connection.requestParams("SELECT $1::text", [Text(value)]);

					if (result.rows.length != 1 || result.rows[0][0] == null || result.rows[0][0].toString() != value) {
						wrong++;
					}
				}

				return wrong;
			}));
		}

		var wrong:Int = 0;
		var failures:Array<String> = [];

		for (task in tasks) {
			try {
				wrong += task.await();
			} catch (e:Dynamic) {
				failures.push(Std.string(e));
			}
		}

		db.shutdown();

		Assert.equals(0, wrong, 'answers that belonged to another query: $wrong of 3200');
		Assert.equals(0, failures.length, failures.length == 0 ? "" : '${failures.length} of 8 workers threw, the first with: ${failures[0]}');
	}

	public function testLibpqIsLookedForWhereEachSystemKeepsIt():Void {
		// macOS names it libpq.5.dylib, which the driver looks for as well as
		// libpq.so.5 and libpq.so: otherwise a Mac could load libpq from nowhere
		// but a path given in full.
		var connection = new PostgresConnection();
		var mac:Array<String> = @:privateAccess connection.__libraryCandidates({}, "mac");

		for (expected in [
			"libpq.5.dylib",
			"libpq.dylib",
			"/opt/homebrew/opt/libpq/lib/libpq.5.dylib",
			"/usr/local/opt/libpq/lib/libpq.5.dylib",
			"/Applications/Postgres.app/Contents/Versions/latest/lib/libpq.5.dylib"
		]) {
			Assert.isTrue(mac.indexOf(expected) >= 0, '$expected is not looked for on macOS: $mac');
		}

		Assert.same([], [for (path in mac) if (path.indexOf(".so") >= 0 || path.indexOf(".dll") >= 0) path]);
		Assert.same(["libpq.so.5", "libpq.so"], @:privateAccess connection.__libraryCandidates({}, "linux"));
		Assert.equals("libpq.dll", @:privateAccess connection.__libraryCandidates({}, "windows").pop());

		// A directory stands for the names libpq has in it there, not
		// libpq.so alone, which only a development package installs: a
		// directory holding the runtime's libpq.so.5 must be found.
		var directory:String = Path.join([Sys.getCwd(), "export", "pq-lib-" + Std.random(0x7FFFFFFF)]);
		sys.FileSystem.createDirectory(directory);
		var given:PostgresConfig = {libraryPath: directory};
		var linux:Array<String> = @:privateAccess connection.__libraryCandidates(given, "linux");
		var macos:Array<String> = @:privateAccess connection.__libraryCandidates(given, "mac");
		var windows:Array<String> = @:privateAccess connection.__libraryCandidates(given, "windows");

		// The installers' directories, the newest PostgreSQL first.
		for (version in ["9.6", "16", "notes", "13"]) {
			sys.FileSystem.createDirectory(Path.join([directory, version, "lib"]));
		}

		var installs:Array<String> = [];
		@:privateAccess connection.__pushInstalls(installs, directory, "", "/lib/libpq.5.dylib", "mac");

		for (version in ["9.6", "16", "notes", "13"]) {
			sys.FileSystem.deleteDirectory(Path.join([directory, version, "lib"]));
			sys.FileSystem.deleteDirectory(Path.join([directory, version]));
		}

		sys.FileSystem.deleteDirectory(directory);
		Assert.same([Path.join([directory, "libpq.so.5"]), Path.join([directory, "libpq.so"])], linux.slice(0, 2));
		Assert.same([Path.join([directory, "libpq.5.dylib"]), Path.join([directory, "libpq.dylib"])], macos.slice(0, 2));
		Assert.equals(Path.join([directory, "libpq.dll"]), windows[0]);
		Assert.same([for (version in ["16", "13", "9.6"]) directory + "/" + version + "/lib/libpq.5.dylib"], installs);
	}

	public function testConcurrentFailedOpensEachReportTheirOwnError():Void {
		// The reason an open failed is the connection's own, not one
		// process-wide string read back after the call returned, which would let
		// a pool opening connections from several workers report another
		// connection's failure.
		var failures:Array<String> = [];
		var guard = new Mutex();
		var done = new Lock();
		var threads:Int = 4;

		for (t in 0...threads) {
			Thread.create(function():Void {
				var host:String = 'fail-host$t';

				for (n in 0...200) {
					try {
						__open(__config(host));
						guard.acquire();
						failures.push('$host opened');
						guard.release();
					} catch (e:Dynamic) {
						var message:String = Std.string(e);

						if (message.indexOf('"$host"') < 0) {
							guard.acquire();
							failures.push('$host was told: $message');
							guard.release();
						}
					}
				}

				done.release();
			});
		}

		for (_ in 0...threads) {
			Assert.isTrue(done.wait(30.0));
		}

		Assert.equals(0, failures.length, failures.length == 0 ? "" : failures[0]);
	}

	public function testABlockedQueryDoesNotStallTheCollector():Void {
		// A query waiting on the server inside PQexec must not leave the thread
		// registered as running Haxe code, or the next collection, on any thread,
		// would wait for it, and one slow report query would stop the runtime
		// thread and every socket it served.
		var connection = __open(__config("localhost"));
		var done = new Lock();

		Thread.create(function():Void {
			try {
				connection.request("fake:sleep 1500");
			} catch (_:Dynamic) {}

			done.release();
		});

		var elapsed:Float = __timeCollectionWhileBlocked();

		Assert.isTrue(done.wait(10.0));
		connection.close();

		Assert.isTrue(elapsed < 0.5, 'a collection waited ${elapsed}s for a thread blocked in a query');
	}

	public function testABlockedBoundQueryDoesNotStallTheCollector():Void {
		var connection = __open(__config("localhost"));
		var done = new Lock();

		Thread.create(function():Void {
			try {
				connection.requestParams("fake:sleep 1500", []);
			} catch (_:Dynamic) {}

			done.release();
		});

		var elapsed:Float = __timeCollectionWhileBlocked();

		Assert.isTrue(done.wait(10.0));
		connection.close();

		Assert.isTrue(elapsed < 0.5, 'a collection waited ${elapsed}s for a thread blocked in a bound query');
	}

	public function testASlowConnectDoesNotStallTheCollector():Void {
		// Connecting blocks for up to connectTimeout, five seconds by default,
		// and a pool opens connections on demand, so a database host that
		// stops answering must not stall the process once per connection attempt.
		var done = new Lock();
		var opened:PostgresConnection = null;

		Thread.create(function():Void {
			try {
				opened = __open(__config("slow-connect"));
			} catch (_:Dynamic) {}

			done.release();
		});

		var elapsed:Float = __timeCollectionWhileBlocked();

		Assert.isTrue(done.wait(10.0));

		if (opened != null) {
			opened.close();
		}

		Assert.isTrue(elapsed < 0.5, 'a collection waited ${elapsed}s for a thread blocked connecting');
	}

	public function testCancelStopsAStatementFromAnotherThread():Void {
		// The thread running a statement is blocked waiting for its answer, so
		// stopping it is necessarily another thread's call: cancel, or a
		// statement timeout.
		var connection = __open(__config("localhost"));
		var done = new Lock();
		var failure:String = null;

		Thread.create(function():Void {
			try {
				connection.request("fake:sleep 10000");
			} catch (e:Dynamic) {
				failure = Std.string(e);
			}

			done.release();
		});

		crossbyte.sys.System.sleep(0.25);

		var started:Float = haxe.Timer.stamp();
		Assert.isTrue(connection.cancel());
		Assert.isTrue(done.wait(5.0));
		var elapsed:Float = haxe.Timer.stamp() - started;

		Require.notNull(failure);
		Assert.isTrue(failure.indexOf("canceling statement due to user request") >= 0, failure);
		Assert.isTrue(elapsed < 2.0, 'the statement ran on for ${elapsed}s after it was cancelled');

		// Cancelled, not broken: the connection answers the next statement.
		Assert.isTrue(connection.ping());
		connection.close();
	}

	public function testCancelRacingCloseNeverUsesAFreedConnection():Void {
		// cancel() comes from another thread by design, so it can land while
		// the owner closes the connection. The handle it needs must not be
		// freed under it.
		var connection = new PostgresConnection();
		var config = __config("localhost");
		var stop:Bool = false;
		var done = new Lock();
		var started = new Lock();
		var cancels:Int = 0;

		Thread.create(function():Void {
			started.release();
			while (!stop) {
				connection.cancel();
				cancels++;
			}

			done.release();
		});

		// Running before the first open: on a four-core CI runner the 300 opens
		// and closes can be over before the thread has started, cancelling
		// nothing at all.
		Assert.isTrue(started.wait(5.0));
		for (_ in 0...300) {
			connection.open(config);
			connection.close();
		}

		stop = true;
		Assert.isTrue(done.wait(5.0));
		Assert.isFalse(connection.cancel(), "a closed connection has nothing to cancel");
		Assert.isTrue(cancels > 0);
	}

	public function testLimitsReachLibpq():Void {
		// The settings ride in the connection string, so what libpq was handed
		// is what the stand-in echoes back.
		var config = __config("localhost");
		config.statementTimeout = 2.5;
		config.keepAliveIdle = 30;
		config.keepAliveInterval = 5;
		config.keepAliveCount = 3;
		config.tcpUserTimeout = 10;
		config.connectionParameters = ["application_name" => "crossbyte tests"];

		var connection = __open(config);
		var rows = connection.requestParams("fake:conninfo", []).rows;
		connection.close();

		Assert.equals(1, rows.length);

		var conninfo:String = rows[0][0].toString();

		for (expected in [
			"options='-c statement_timeout=2500'",
			"keepalives_idle='30'",
			"keepalives_interval='5'",
			"keepalives_count='3'",
			"tcp_user_timeout='10000'",
			"application_name='crossbyte tests'"
		]) {
			Assert.isTrue(conninfo.indexOf(expected) >= 0, 'missing $expected in $conninfo');
		}
	}

	/**
		A connection made with no keepalive settings reaches libpq with
		MySQL's timings, 60/10/6. libpq turns keepalive on but leaves the
		timings to the system (two hours before the first probe), so a query
		waiting on a host gone silent would hold its worker that long.
	**/
	public function testKeepAliveReachesLibpqWithTimingsByDefault():Void {
		var connection = __open(__config("localhost"));
		var rows = connection.requestParams("fake:conninfo", []).rows;
		connection.close();

		var conninfo:String = rows[0][0].toString();

		for (expected in ["keepalives_idle='60'", "keepalives_interval='10'", "keepalives_count='6'"]) {
			Assert.isTrue(conninfo.indexOf(expected) >= 0, 'missing $expected in $conninfo');
		}

		var config = __config("localhost");
		config.keepAlive = false;
		connection = __open(config);
		conninfo = connection.requestParams("fake:conninfo", []).rows[0][0].toString();
		connection.close();
		Assert.isTrue(conninfo.indexOf("keepalives='0'") >= 0, conninfo);
	}

	public function testACommitTheServerTurnedIntoARollbackThrows():Void {
		// After a statement fails inside a transaction, PostgreSQL answers the
		// COMMIT with success and the tag ROLLBACK, discarding everything. Only
		// the tag says so, so it is read, and the commit does not report success.
		var connection = __open(__config("localhost"));
		var events:Int = 0;
		connection.addEventListener(SQLErrorEvent.ERROR, _ -> events++);

		connection.begin();

		try {
			connection.request("fake:fail");
		} catch (_:Dynamic) {}

		var thrown:Dynamic = null;

		try {
			connection.commit();
		} catch (e:Dynamic) {
			thrown = e;
		}

		Require.notNull(thrown);
		Assert.isTrue(Std.isOfType(thrown, SQLError), Std.string(thrown));
		Assert.isTrue(Std.string(thrown).indexOf("rolled it back") >= 0, Std.string(thrown));
		// Still reported to listeners.
		Assert.equals(1, events);
		// The transaction is over either way, and the connection usable.
		Assert.isFalse(connection.inTransaction);
		Assert.isTrue(connection.ping());
		connection.close();
	}

	public function testAFailedCommitThrows():Void {
		var connection = __open(__config("localhost"));

		connection.begin();
		connection.request("fake:fail-next-commit");

		Assert.raises(() -> connection.commit(), SQLError);
		Assert.isFalse(connection.inTransaction);
		connection.close();
	}

	public function testATransactionTaskFailsWhenItsCommitDoes():Void {
		// The pattern AsyncDatabase.transaction documents for this driver, which
		// must not complete as success when the COMMIT rolled everything back.
		var config = __config("localhost");
		var pool = new ConnectionPool<PostgresConnection>({factory: () -> __open(config), close: c -> c.close(), maxSize: 1});
		var db = AsyncDatabase.of(pool);

		var swallowed = db.transaction(c -> c.begin(), c -> c.commit(), c -> c.rollback(), function(c:PostgresConnection):String {
			try {
				c.request("fake:fail");
			} catch (_:Dynamic) {}

			return "transferred";
		});

		var refused = db.transaction(c -> c.begin(), c -> c.commit(), c -> c.rollback(), function(c:PostgresConnection):String {
			c.request("fake:fail-next-commit");
			return "transferred";
		});

		var afterwards = db.submit(c -> c.inTransaction);

		Assert.raises(() -> swallowed.await());
		Assert.raises(() -> refused.await());
		Assert.isFalse(afterwards.await(), "the connection went back to the pool inside a transaction");

		db.shutdown();
	}

	public function testTheMigratorDoesNotReportAMigrationWhoseCommitFailed():Void {
		var connection = __open(__config("localhost"));
		var migrator = new SchemaMigrator<PostgresConnection>({
			execute: (c, sql) -> c.request(sql),
			readApplied: c -> [],
			recordApplied: (c, m) -> c.request("INSERT INTO schema_migrations VALUES (" + m.version + ")"),
			ensureTable: c -> {},
			begin: c -> c.begin(),
			commit: c -> c.commit(),
			rollback: c -> c.rollback()
		});

		migrator.add(Migration.ofSql(1, "accounts", "fake:fail-next-commit"));

		Assert.raises(() -> migrator.migrate(connection));
		Assert.isFalse(connection.inTransaction);
		connection.close();
	}

	public function testATransactionBegunAsTextIsReported():Void {
		// inTransaction follows the server, not only begin(), commit() and
		// rollback(), so a transaction opened with request("BEGIN;") reads as
		// one, and a pool returning the connection has something to roll back.
		var connection = __open(__config("localhost"));

		connection.request("BEGIN;");
		Assert.isTrue(connection.inTransaction, "BEGIN sent as text");

		// A statement that fails leaves the transaction open, and aborted,
		// until it is rolled back.
		try {
			connection.request("fake:fail");
		} catch (_:Dynamic) {}
		Assert.isTrue(connection.inTransaction, "aborted by a failed statement");

		connection.request("ROLLBACK;");
		Assert.isFalse(connection.inTransaction, "ROLLBACK sent as text");

		// Bound statements are the other native path.
		connection.requestParams("BEGIN");
		Assert.isTrue(connection.inTransaction, "BEGIN through requestParams");
		connection.requestParams("COMMIT");
		Assert.isFalse(connection.inTransaction, "COMMIT through requestParams");

		connection.close();
	}

	public function testThePoolRollsBackATransactionABorrowerLeftOpen():Void {
		// Aborted by a failed statement and returned that way, it would go to
		// the next borrower, whose every statement would then fail with
		// "current transaction is aborted", so the pool rolls it back itself,
		// with no reset configured.
		var config = __config("localhost");
		var pool = new ConnectionPool<PostgresConnection>({factory: () -> __open(config), close: c -> c.close(), maxSize: 1});

		crossbyte.utils.Logger.recordSink = _ -> {};
		pool.withConnection(function(c:PostgresConnection):Void {
			c.request("BEGIN;");

			try {
				c.request("fake:fail");
			} catch (_:Dynamic) {}
		});
		crossbyte.utils.Logger.recordSink = null;

		Assert.isTrue(pool.withConnection(c -> c.ping()), "the next borrower inherited the aborted transaction");
		Assert.equals(1, pool.size(), "rolled back and reused, not retired");
		pool.close();
	}

	/**
	 * Gives the other thread time to enter its native call, then times one
	 * full collection from this one.
	 */
	@:noCompletion private function __timeCollectionWhileBlocked():Float {
		crossbyte.sys.System.sleep(0.25);

		var started:Float = haxe.Timer.stamp();
		cpp.vm.Gc.run(true);
		return haxe.Timer.stamp() - started;
	}

	/**
		A statement the server refuses throws as well as dispatching, as
		MySQL's does, so to a caller not listening (an `AsyncDatabase` task
		among them) a failed statement does not read as one that had run.
	**/
	/**
		`request()` answers a `PostgresResultSet`, a `sys.db.ResultSet`, with
		field names and reading by position, not a `Dynamic` with rows built
		from JSON the bridge rendered.
	**/
	public function testRequestAnswersATypedResultSet():Void {
		var connection = __open(__config("localhost"));
		var rows:crossbyte.db.postgres.PostgresResultSet = connection.request("fake:count 3");
		Assert.equals(3, rows.length);
		Assert.equals("n", rows.getFieldsNames().join(","));
		Assert.equals(1, rows.nfields);
		Assert.equals("1", rows.next().n);
		Assert.equals(1, rows.getIntResult(0));
		Assert.equals("2", rows.next().n);
		Assert.equals("2", rows.getResult(0));
		Assert.equals(3.0, connection.affectedRows);
		connection.close();
	}

	/** Rows read by column, from the result block itself. **/
	public function testExecuteEachReadsTheRowsByColumn():Void {
		var connection = __open(__config("localhost"));
		var statement = new crossbyte.db.postgres.PostgresStatement();
		statement.sqlConnection = connection;
		statement.text = "fake:count 4";
		var read:Array<Int> = [];
		var names:Array<String> = [];
		Assert.equals(0.0, statement.executeEach(row -> {
			read.push(row.getInt(0));
			names.push(row.columnName(0));
		}));
		Assert.equals("1,2,3,4", read.join(","));
		Assert.equals("n,n,n,n", names.join(","));

		statement.text = "fake:affect 7";
		Assert.equals(7.0, statement.executeEach(_ -> Assert.fail("a write has no rows")));

		statement.text = "fake:fail";
		var heard:SQLError = null;
		statement.addEventListener(SQLErrorEvent.ERROR, event -> heard = event.error);
		Assert.raises(() -> statement.executeEach(_ -> {}), SQLError);
		Require.notNull(heard);
		connection.close();
	}

	public function testAFailedStatementThrowsAsWellAsDispatching():Void {
		var connection = __open(__config("localhost"));
		var statement = new crossbyte.db.postgres.PostgresStatement();
		statement.sqlConnection = connection;
		statement.text = "fake:fail";
		var heard:SQLError = null;
		statement.addEventListener(SQLErrorEvent.ERROR, event -> heard = event.error);

		var thrown:Dynamic = null;
		try {
			statement.execute();
		} catch (e:Dynamic) {
			thrown = e;
		}

		Assert.isTrue(Std.isOfType(thrown, SQLError), "a refused statement did not throw an SQLError: " + thrown);
		Assert.notNull(heard, "a refused statement was not dispatched either");
		Assert.equals(heard, thrown, "what was thrown and what was dispatched differ");
		Assert.isFalse(statement.executing);
		connection.close();
	}

	/**
		A result paged ahead of `getResult()` comes back in the order it was
		read, and only its last page says it is complete, the last page of a
		result that divides evenly into pages as well.

		Off cpp the pages are not kept in an Array read with `pop()`, newest
		first. On every target a page's `complete` is not `!executing` when it
		is taken, which once the last page had been read would make every page
		still waiting say it was the last; and the statement notices the rows
		have run out without waiting for a page to come up short, which for
		four rows in pages of two would leave no page complete.
	**/
	public function testPagesComeBackInOrderAndOnlyTheLastIsComplete():Void {
		var connection = __open(__config("localhost"));

		try {
			Assert.equals("1,2 3,4 5+", __pages(connection, 5));
			Assert.equals("1,2 3,4+", __pages(connection, 4));
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		connection.close();
	}

	public function testCountsPastThirtyTwoBitsAreWhole():Void {
		// The bridge reads a statement's count in 64 bits, not with atoi into
		// 32, where a write of three billion rows would read 2147483647 (MSVC
		// clamps; glibc wraps it negative), on both of its paths. And a
		// statement's rowsAffected is the count, not the rows its result holds,
		// which for every write is 0.
		var connection = __open(__config("localhost"));

		connection.request("fake:affect 3000000000");
		Assert.equals(3000000000.0, connection.affectedRows);

		// Bound parameters take the bridge's other path.
		connection.requestParams("fake:affect 5000000001", []);
		Assert.equals(5000000001.0, connection.affectedRows);

		var statement = new crossbyte.db.postgres.PostgresStatement();
		statement.sqlConnection = connection;
		statement.text = "fake:affect 4000000000";
		statement.execute();
		Assert.equals(4000000000.0, statement.getResult().rowsAffected);
		statement.executeParams([]);
		Assert.equals(4000000000.0, statement.getResult().rowsAffected);

		// A SELECT's is the rows it returned, as PostgreSQL counts it.
		statement.text = "fake:count 3";
		statement.execute();
		Assert.equals(3.0, statement.getResult().rowsAffected);
		connection.close();
	}

	// Pages `rows` rows two at a time, reading ahead of getResult(), and
	// writes each page as its values, "+" marking one called complete.
	@:noCompletion private static function __pages(connection:PostgresConnection, rows:Int):String {
		var statement = new crossbyte.db.postgres.PostgresStatement();
		statement.sqlConnection = connection;
		statement.text = "fake:count " + rows;
		statement.execute(2);
		while (statement.executing) {
			statement.next(2);
		}

		var pages:Array<String> = [];
		var page = statement.getResult();
		while (page != null) {
			pages.push([for (row in page.data) Std.string(Reflect.field(row, "n"))].join(",") + (page.complete ? "+" : ""));
			page = statement.getResult();
		}

		return pages.join(" ");
	}

	public function testAutocommitOffKeepsATransactionOpenUntilCommit():Void {
		// autocommit is read: set false, statements do not commit on their own.
		// PostgreSQL has no setting for it on the server, so the driver begins
		// the transaction itself, as MySQL's server and JDBC do.
		var connection:PostgresConnection = __open(__config("localhost"));
		Assert.isTrue(connection.autocommit);
		connection.autocommit = false;
		Assert.isFalse(connection.autocommit);

		connection.request("SELECT 1");
		Assert.equals(IN_TRANSACTION, __serverTransaction(connection), "the statement ran, and committed, on its own");
		Assert.isTrue(connection.inTransaction);
		connection.commit();
		Assert.equals(IDLE, __serverTransaction(connection));
		// Still off: the next statement begins the next transaction.
		Assert.isTrue(connection.inTransaction, "autocommit off reads as a transaction open, as on MySQL");
		connection.requestParams("SELECT $1::text", [Text("x")]);
		Assert.equals(IN_TRANSACTION, __serverTransaction(connection));
		connection.rollback();
		Assert.equals(IDLE, __serverTransaction(connection));
		Assert.isTrue(connection.ping());
		Assert.equals(IDLE, __serverTransaction(connection), "ping() began a transaction");

		// Turned back on, what is open is committed, as MySQL does.
		connection.request("SELECT 1");
		var commits:Int = 0;
		connection.addEventListener(crossbyte.events.SQLEvent.COMMIT, _ -> commits++);
		connection.autocommit = true;
		Assert.equals(1, commits);
		Assert.equals(IDLE, __serverTransaction(connection));
		connection.request("SELECT 1");
		Assert.equals(IDLE, __serverTransaction(connection));
		Assert.isFalse(connection.inTransaction);
		connection.close();
	}

	public function testAnIsolationLevelTheServerRefusesThrows():Void {
		// The setter reports the server's refusal, rather than the level
		// reading as set while the session goes on at the old one.
		var connection:PostgresConnection = __open(__config("localhost"));
		connection.begin();

		try {
			// Aborts the transaction: the stand-in, as the server, refuses
			// everything else until it ends.
			connection.request("fake:fail");
		} catch (_:Dynamic) {}

		var thrown:Dynamic = null;

		try {
			connection.isolationLevel = PostgresIsolationLevel.SERIALIZABLE;
		} catch (e:Dynamic) {
			thrown = e;
		}

		Assert.isTrue(Std.isOfType(thrown, SQLError), "the refusal was swallowed: " + Std.string(thrown));
		connection.rollback();
		connection.isolationLevel = PostgresIsolationLevel.SERIALIZABLE;
		Assert.equals(IDLE, __serverTransaction(connection), "setting the level began a transaction");
		connection.close();
	}

	@:noCompletion private static inline var IDLE:Int = 0;
	@:noCompletion private static inline var IN_TRANSACTION:Int = 2;

	/** The transaction as the stand-in server holds it: libpq's PQtransactionStatus. **/
	@:noCompletion private static function __serverTransaction(connection:PostgresConnection):Int {
		return crossbyte.db.postgres._internal.NativePostgres.transactionStatus(@:privateAccess connection.__nativeHandle);
	}

	public function testWhatRequestIsRefusedIsAnSQLError():Void {
		// request() throws an SQLError for a statement the server refused, as
		// requestParams() does, not an IOError, so code catching SQLError, as
		// MongoError's doc says every driver's failures are caught, catches it.
		// On a connection not open it throws an error, not a String.
		var connection:PostgresConnection = __open(__config("localhost"));
		var thrown:Dynamic = null;

		try {
			connection.request("fake:fail");
		} catch (e:Dynamic) {
			thrown = e;
		}

		Assert.isTrue(Std.isOfType(thrown, SQLError), "request() threw " + Std.string(thrown));

		if (Std.isOfType(thrown, SQLError)) {
			var error:SQLError = thrown;
			Assert.isTrue(error.details().indexOf("fake failure") >= 0, error.details());
		}

		Assert.isTrue(connection.ping(), "the connection did not survive a refused statement");
		connection.close();

		var refused:Dynamic = null;

		try {
			new PostgresConnection().request("SELECT 1");
		} catch (e:Dynamic) {
			refused = e;
		}

		Assert.isTrue(Std.isOfType(refused, SQLError), "a connection not open threw " + Std.string(refused));
	}

	public function testOpeningAgainClosesTheConnectionItHad():Void {
		// open() on an open connection closes the first, as MySQL's does,
		// rather than replacing its native handle and leaving it open,
		// unreachable, for the life of the process (a server connection each
		// time a pool factory or a reconnect called it twice).
		var connection:PostgresConnection = __open(__config("localhost"));
		var closes:Int = 0;
		connection.addEventListener(crossbyte.events.SQLEvent.CLOSE, _ -> closes++);
		var before:Int = __live(connection);

		connection.open(__config("localhost"));

		Assert.equals(before, __live(connection), "the first connection was left open");
		Assert.equals(1, closes);
		Assert.isTrue(connection.ping(), "the second connection is not the one in use");
		connection.close();
	}

	/** The connections the stand-in has open, process-wide. **/
	@:noCompletion private static function __live(connection:PostgresConnection):Int {
		var rows:Dynamic = connection.request("fake:live");
		return Std.parseInt(Std.string(Reflect.field(rows.next(), "live")));
	}

	@:noCompletion private static function __open(config:PostgresConfig):PostgresConnection {
		var connection = new PostgresConnection();
		connection.open(config);
		return connection;
	}

	@:noCompletion private static function __config(host:String):PostgresConfig {
		return {
			host: host,
			port: 5432,
			user: "tester",
			password: "secret",
			database: "fake",
			libraryPath: __libraryPath()
		};
	}

	/**
		The stand-in, as hxcpp's linker names a shared library on each
		system: `.dll`, `.dylib` on macOS, `.dso` elsewhere.
	**/
	@:noCompletion private static function __libraryPath():String {
		var name:String = switch (crossbyte.sys.System.PLATFORM) {
			case "windows": "crossbyte_fakepq.dll";
			case "mac": "crossbyte_fakepq.dylib";
			default: "crossbyte_fakepq.dso";
		};
		return Path.join([Path.directory(Sys.programPath()), name]);
	}
}
#end
