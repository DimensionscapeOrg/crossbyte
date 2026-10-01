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
		// connection, all querying at once. Every connection and thread wrote
		// one process-wide result buffer, so a query could read another's rows
		// -- or the freed memory of a buffer another thread had just grown.
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

	public function testConcurrentFailedOpensEachReportTheirOwnError():Void {
		// The reason an open failed was one process-wide string too, read back
		// after the call returned, so a pool opening connections from several
		// workers could report another connection's failure.
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
		// A query waiting on the server sat inside PQexec with the thread still
		// registered as running Haxe code, so the next collection -- on any
		// thread -- waited for it. One slow report query stopped the runtime
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
		// and a pool opens connections on demand -- so a database host that
		// stopped answering stalled the process once per connection attempt.
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
		// stopping it is necessarily another thread's call. There was no way
		// to make it: no cancel, and no statement timeout either.
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
		var cancels:Int = 0;

		Thread.create(function():Void {
			while (!stop) {
				connection.cancel();
				cancels++;
			}

			done.release();
		});

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

	public function testACommitTheServerTurnedIntoARollbackThrows():Void {
		// After a statement fails inside a transaction, PostgreSQL answers the
		// COMMIT with success and the tag ROLLBACK, discarding everything. Only
		// the tag says so, and nothing read it: the commit reported success.
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
		// Still reported to listeners, as it always was.
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
		// The pattern AsyncDatabase.transaction documents for this driver. It
		// completed as success when the COMMIT had rolled everything back.
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
		// inTransaction changed only in begin(), commit() and rollback(), so a
		// transaction opened with request("BEGIN;") read as none, and a pool
		// returning the connection had nothing to roll back.
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
		// Aborted by a failed statement and returned that way, it went to the
		// next borrower, whose every statement then failed with "current
		// transaction is aborted" -- and no reset had been configured to stop
		// it, because the pool offered no rollback of its own.
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
		MySQL's does. It dispatched an `SQLErrorEvent` and returned, so to a
		caller not listening -- an `AsyncDatabase` task among them -- a failed
		statement read as one that had run.
	**/
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
		read, and only its last page says it is complete -- the last page of a
		result that divides evenly into pages as well.

		Off cpp the pages waited in an Array read with `pop()`, newest first.
		On every target a page's `complete` was `!executing` when it was taken,
		so once the last page had been read every page still waiting said it
		was the last; and the statement noticed the rows had run out only when
		a page came up short, so four rows in pages of two left no page that
		was complete.
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
		// autocommit stored a flag nothing read: set false, every statement
		// still committed on its own. PostgreSQL has no setting for it on the
		// server, so the driver begins the transaction itself, as MySQL's
		// server and JDBC do.
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
		// The setter swallowed the server's refusal: the level read as set,
		// and the session went on at the old one.
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
		// request() threw an IOError for a statement the server refused, where
		// requestParams() threw an SQLError -- and code catching SQLError, as
		// MongoError's doc says every driver's failures are caught, caught
		// nothing from request(). On a connection not open it threw a String.
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
		// open() on an open connection replaced its native handle and left
		// the first connection open, unreachable, for the life of the process
		// -- a server connection each time a pool factory or a reconnect
		// called it twice. MySQL's closes first; this does too now.
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

	@:noCompletion private static function __libraryPath():String {
		var name:String = crossbyte.sys.System.isWindows ? "crossbyte_fakepq.dll" : "crossbyte_fakepq.dso";
		return Path.join([Path.directory(Sys.programPath()), name]);
	}
}
#end
