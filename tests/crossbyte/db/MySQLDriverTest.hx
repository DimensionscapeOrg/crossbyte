package crossbyte.db;

#if !js
import crossbyte.db.fakemysql.ScriptedConnection;
import crossbyte.db.mysql.MySQLConnection;
import crossbyte.db.mysql.MySQLConnectionError;
import crossbyte.db.mysql.MySQLError;
import crossbyte.db.mysql.MySQLSSLMode;
import crossbyte.db.mysql.MySQLStatement;
import crossbyte.db.sql.SQLResult;
import crossbyte.errors.IOError;
import crossbyte.errors.SQLError;
import crossbyte.events.SQLErrorEvent;
import crossbyte.events.SQLEvent;
import crossbyte.test.Require;
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
		// execute() throws as well as dispatching an SQLErrorEvent, so a caller
		// not listening (an AsyncDatabase task, a SchemaMigrator step) does not
		// see a failed INSERT as one that had run.
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
		// open. A connection that cannot read them (a target other than cpp)
		// follows the statements that open and close one instead, so a pool
		// still rolls back a START TRANSACTION sent as text.
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

	public function testAFailureThatIsNotAStringStillBecomesAnSQLError():Void {
		// The driver's failure is handed to SQLError and IOError as text, where
		// they take a String. On the jvm it is a java.sql.SQLException, and
		// passed as itself every failure would surface as a ClassCastException:
		// no SQLError, no listener, and the error number and SQLSTATE JDBC had lost.
		var wire:ScriptedConnection = new ScriptedConnection();
		var sql:String = "INSERT INTO users (email) VALUES ('a@example.com')";
		#if java
		wire.failures.set(sql, new java.sql.SQLException("Duplicate entry 'a@example.com' for key 'users.email'", "23000", 1062));
		#else
		wire.failures.set(sql, new haxe.Exception("Duplicate entry 'a@example.com' for key 'users.email'"));
		#end
		var statement:MySQLStatement = __statement(wire);
		var heard:Array<Dynamic> = [];
		statement.addEventListener(SQLErrorEvent.ERROR, e -> heard.push((cast e : SQLErrorEvent).error));
		statement.text = sql;

		var thrown:Dynamic = null;

		try {
			statement.execute();
		} catch (e:Dynamic) {
			thrown = e;
		}

		Assert.isTrue(Std.isOfType(thrown, MySQLError), "not a MySQLError: " + Std.string(thrown));
		Assert.equals(1, heard.length);

		if (Std.isOfType(thrown, MySQLError)) {
			var error:MySQLError = thrown;
			Assert.isTrue(error.message.indexOf("Duplicate entry") >= 0, error.message);
			#if java
			Assert.equals(1062, error.code);
			Assert.equals("23000", error.sqlState);
			#end
		}

		// And through a transaction step.
		var connection:MySQLConnection = new MySQLConnection();
		var failing:ScriptedConnection = new ScriptedConnection();
		#if java
		failing.failures.set("COMMIT;", new java.sql.SQLException("Deadlock found when trying to get lock", "40001", 1213));
		#else
		failing.failures.set("COMMIT;", new haxe.Exception("Deadlock found when trying to get lock"));
		#end
		connection.__connection = failing;
		connection.begin();
		var commitError:Dynamic = null;

		try {
			connection.commit();
		} catch (e:Dynamic) {
			commitError = e;
		}

		Assert.isTrue(Std.isOfType(commitError, MySQLError), "not a MySQLError: " + Std.string(commitError));
		#if java
		if (Std.isOfType(commitError, MySQLError)) {
			Assert.equals(1213, (commitError : MySQLError).code);
			Assert.equals("40001", (commitError : MySQLError).sqlState);
		}
		#end
	}

	public function testAFailedOpenIsAnIOError():Void {
		// A port nothing listens on. On the jvm there is not even a driver to
		// try it with, and the ClassNotFoundException that says so must not
		// become a ClassCastException on its way into IOError.
		//
		// Obtained rather than assumed: port 1 is closed only by convention,
		// and on a machine where something listens there the open would meet a
		// server that was not MySQL, a failure the hl client cannot see coming,
		// so HashLink's double free below would follow.
		var vacant:sys.net.Socket = new sys.net.Socket();
		vacant.bind(new sys.net.Host("127.0.0.1"), 0);
		vacant.listen(1);
		var port:Int = vacant.host().port;
		vacant.close();

		var connection:MySQLConnection = new MySQLConnection();
		var thrown:Dynamic = null;

		try {
			connection.open({
				host: "127.0.0.1",
				port: port,
				user: "app",
				password: "secret",
				database: "app",
				connectTimeout: 2.0
			});
		} catch (e:Dynamic) {
			thrown = e;
		}

		Assert.isTrue(Std.isOfType(thrown, IOError), "not an IOError: " + Std.string(thrown));
		Assert.isFalse(connection.connected);

		#if hl
		// HashLink's mysql library frees a connection that failed to open,
		// and leaves it to the collector with a finalizer that frees it
		// again. The next major collection does, into memory the heap may have
		// since given to someone else, and the hl suite would die of heap
		// corruption far from here. Collecting here makes a double free this
		// case's own.
		hl.Gc.major();
		#end
	}

	public function testParametersAreWrittenAsTheirTypes():Void {
		// Parameters of every type: an Int compiles, a number goes out as a
		// number (MySQL refuses LIMIT '50'), a null becomes NULL rather than
		// leaving :name in the SQL, and bytes are not cut at their first NUL.
		var wire:ScriptedConnection = new ScriptedConnection();
		var statement:MySQLStatement = __statement(wire);
		statement.text = "INSERT INTO t VALUES (:none, :count, :ratio, :yes, :big, :blob, :when, :text, :missing) LIMIT :limit";
		statement.parameters.none = null;
		statement.parameters.count = 42;
		statement.parameters.ratio = 1.5;
		statement.parameters.yes = true;
		statement.parameters.big = haxe.Int64.parseString("9007199254740993");
		statement.parameters.blob = haxe.io.Bytes.ofHex("0001ff");
		var when:Date = Date.fromTime(1790685296250.0);
		statement.parameters.when = when;
		statement.parameters.text = "it's";
		statement.parameters.limit = 50;
		statement.execute();

		// hl's and neko's Date keep whole seconds, so the .250 is gone before
		// the statement sees it; the milliseconds are written where the Date
		// has them.
		var fraction:String = when.getTime() % 1000 == 250 ? ".250" : "";
		Assert.equals("INSERT INTO t VALUES (NULL, 42, 1.5, TRUE, 9007199254740993, X'0001ff', '2026-09-29 12:34:56" + fraction
			+ "', 'it\\'s', :missing) LIMIT 50",
			wire.sent[wire.sent.length - 1]);

		statement.parameters.ratio = Math.NaN;
		var sent:Int = wire.sent.length;
		Assert.raises(() -> statement.execute(), crossbyte.errors.ArgumentError);
		Assert.equals(sent, wire.sent.length, "the statement went out with no literal for NaN");
		Assert.isFalse(statement.executing);
	}

	public function testABackslashEscapedQuoteDoesNotEndALiteral():Void {
		// MySQL reads \' inside a literal as a quote, so the scan must not end
		// the literal there and substitute the :name the server still reads as
		// part of it.
		var wire:ScriptedConnection = new ScriptedConnection();
		var statement:MySQLStatement = __statement(wire);
		statement.text = "SELECT 'it\\'s :name' AS label, :name AS value";
		statement.parameters.name = "x";
		statement.execute();

		Assert.equals("SELECT 'it\\'s :name' AS label, 'x' AS value", wire.sent[wire.sent.length - 1]);
	}

	public function testTheConnectionEscapesAndQuotesByTheSessionsMode():Void {
		// escape() and quote(), as SQLite and Postgres connections have them.
		var connection:MySQLConnection = new MySQLConnection();
		connection.__connection = new ScriptedConnection();

		Assert.equals("'it\\'s \\\"x\\\"\\n\\\\'", connection.quote("it's \"x\"\n\\"));
		Assert.equals("a\\0b", connection.escape("a" + String.fromCharCode(0) + "b"));

		// Under NO_BACKSLASH_ESCAPES a backslash is a backslash, and a quote
		// is escaped by doubling it.
		connection.request("SET SESSION sql_mode = 'STRICT_TRANS_TABLES,NO_BACKSLASH_ESCAPES'");
		Assert.equals("'it''s C:\\dir'", connection.quote("it's C:\\dir"));
		connection.request("SET SESSION sql_mode = 'STRICT_TRANS_TABLES'");
		Assert.equals("'it\\'s'", connection.quote("it's"));
	}

	public function testGeneratedSavepointNamesDoNotRepeat():Void {
		// Not named from haxe.Timer.stamp() in microseconds through Std.int:
		// names made that way collide back to back, and the value passes Int 36
		// minutes into a process.
		var connection:MySQLConnection = new MySQLConnection();
		var seen:Map<String, Bool> = new Map();
		var distinct:Int = 0;

		for (_ in 0...2000) {
			var name:String = connection.__sanitizeSavePoint(null);

			if (!seen.exists(name)) {
				seen.set(name, true);
				distinct++;
			}
		}

		Assert.equals(2000, distinct);
		Assert.equals("a__DROP_TABLE_t____", connection.__sanitizeSavePoint("a; DROP TABLE t; --"));
	}

	public function testSavepointsNestAndResolveWithoutANameToTheInnermost():Void {
		// setSavepoint() returns the name it made; releaseSavepoint(null)
		// releases the innermost rather than a name it has just made up; and
		// rollbackToSavepoint(null) rolls back to the innermost, not the whole
		// transaction.
		var wire:ScriptedConnection = new ScriptedConnection();
		var connection:MySQLConnection = new MySQLConnection();
		connection.__connection = wire;

		connection.begin();
		var outer:String = connection.setSavepoint();
		var inner:String = connection.setSavepoint();
		Assert.notEquals(outer, inner);

		connection.rollbackToSavepoint();
		Assert.equals("ROLLBACK TO SAVEPOINT " + inner + ";", wire.sent[wire.sent.length - 1]);

		// Still active after a rollback to it, so the next nameless release
		// is the same savepoint.
		connection.releaseSavepoint();
		Assert.equals("RELEASE SAVEPOINT " + inner + ";", wire.sent[wire.sent.length - 1]);
		connection.releaseSavepoint();
		Assert.equals("RELEASE SAVEPOINT " + outer + ";", wire.sent[wire.sent.length - 1]);

		// With none held: a release has nothing to name, and a rollback rolls
		// back the transaction.
		Assert.raises(() -> connection.releaseSavepoint(), crossbyte.errors.ArgumentError);
		connection.rollbackToSavepoint();
		Assert.equals("ROLLBACK;", wire.sent[wire.sent.length - 1]);
		Assert.isFalse(connection.inTransaction);
	}

	public function testAFailedSavepointIsNotRemembered():Void {
		var wire:ScriptedConnection = new ScriptedConnection();
		wire.failures.set("SAVEPOINT keep;", "Lost connection to MySQL server during query");
		var connection:MySQLConnection = new MySQLConnection();
		connection.__connection = wire;

		connection.begin();
		Assert.raises(() -> connection.setSavepoint("keep"), SQLError);
		Assert.raises(() -> connection.releaseSavepoint(), crossbyte.errors.ArgumentError);
	}

	public function testIsolationLevelReadsTheOlderVariableWhereTheNewOneIsMissing():Void {
		// @@transaction_isolation is MySQL 5.7.20's name; MariaDB before 11.1
		// knows only @@tx_isolation, so the getter falls back to it.
		var wire:ScriptedConnection = new ScriptedConnection();
		wire.failures.set("SELECT @@transaction_isolation AS lvl;", "Unknown system variable 'transaction_isolation'");
		wire.results.set("SELECT @@tx_isolation AS lvl;", [{lvl: "READ-COMMITTED"}]);
		var connection:MySQLConnection = new MySQLConnection();
		connection.__connection = wire;

		Assert.equals("READ COMMITTED", (connection.isolationLevel : String));
	}

	public function testAClientCharsetMySQLRefusesIsRefusedBeforeConnecting():Void {
		// ucs2, utf16 and utf32 are refused, as MySQL refuses each as a client
		// character set.
		for (charset in ["ucs2", "utf16", "utf32"]) {
			Assert.raises(() -> new MySQLConnection().open({
				host: "127.0.0.1",
				port: 1,
				user: "app",
				password: "secret",
				database: "app",
				charset: charset
			}), crossbyte.errors.ArgumentError);
		}
	}

	/**
		A timeout that is not a number of seconds is refused before
		connecting, on every target, as 0 (no limit) is taken. NaN would reach
		the native client as no limit at all, and a negative one as 50 seconds
		or five hours.
	**/
	public function testANaNOrNegativeTimeoutIsRefusedBeforeConnecting():Void {
		var bad:Array<Float> = [Math.NaN, -1];

		for (value in bad) {
			Assert.raises(() -> new MySQLConnection().open({host: "127.0.0.1", port: 1, user: "app", password: "secret", database: "app",
				connectTimeout: value}), crossbyte.errors.ArgumentError);
			Assert.raises(() -> new MySQLConnection().open({host: "127.0.0.1", port: 1, user: "app", password: "secret", database: "app",
				readTimeout: value}), crossbyte.errors.ArgumentError);
			Assert.raises(() -> new MySQLConnection().open({host: "127.0.0.1", port: 1, user: "app", password: "secret", database: "app",
				writeTimeout: value}), crossbyte.errors.ArgumentError);
		}

		// A negative keepalive timing is refused, not taken for the system's own.
		Assert.raises(() -> new MySQLConnection().open({host: "127.0.0.1", port: 1, user: "app", password: "secret", database: "app",
			keepAliveIdle: -1}), crossbyte.errors.ArgumentError);
	}

	#if !cpp
	public function testAnSslModeThatNeedsTlsIsRefusedWhereTheClientHasNone():Void {
		// Only the native client reads sslMode. Elsewhere REQUIRED and both
		// VERIFY modes would go unread, and the connection be made in the clear,
		// password and all, with nothing said. Refused, as the native client
		// refuses a server offering no TLS: with 2026, and before connecting
		// (a connect attempt to port 1 fails otherwise, and the jvm has no JDBC
		// driver to try one with).
		for (mode in [MySQLSSLMode.REQUIRED, MySQLSSLMode.VERIFY_CA, MySQLSSLMode.VERIFY_IDENTITY]) {
			var error:MySQLConnectionError = null;

			try {
				new MySQLConnection().open({
					host: "127.0.0.1",
					port: 1,
					user: "app",
					password: "secret",
					database: "app",
					sslMode: mode
				});
			} catch (e:MySQLConnectionError) {
				error = e;
			}

			Require.notNull(error);
			Assert.equals(2026, error.code, error.message);
		}
	}
	#end

	public function testPagesComeBackInTheOrderTheyWereRead():Void {
		// Off cpp the pages wait in order: read from an Array with pop(),
		// newest first, a result paged ahead of getResult() would come back last
		// page first on the jvm and in the interpreter. And only the last page
		// says it is complete.
		var wire:ScriptedConnection = new ScriptedConnection();
		wire.results.set("SELECT id FROM users", [for (id in 1...6) {id: id}]);
		var statement:MySQLStatement = __statement(wire);
		statement.text = "SELECT id FROM users";

		statement.execute(2);
		statement.next(2);
		statement.next(2);

		Assert.equals("1,2 3,4 5+", __pages(statement));
		Assert.isNull(statement.getResult());
	}

	/** Every page waiting, as its ids, with `+` after a complete one. **/
	private function __pages(statement:MySQLStatement):String {
		var pages:Array<String> = [];
		var page:SQLResult = statement.getResult();

		while (page != null) {
			pages.push([for (row in page.data) Std.string(row.id)].join(",") + (page.complete ? "+" : ""));
			page = statement.getResult();
		}

		return pages.join(" ");
	}

	public function testAStatementGivenItsConnectionBeforeOpenRuns():Void {
		// The statement reads its connection's handle when it runs, not when
		// sqlConnection is set: given its connection before open(), it would
		// hold none and refuse to run on the connection that was by then open.
		var connection:MySQLConnection = new MySQLConnection();
		var statement:MySQLStatement = new MySQLStatement();
		statement.sqlConnection = connection;
		var wire:ScriptedConnection = new ScriptedConnection();
		wire.results.set("SELECT 1 AS one", [{one: 1}]);
		connection.__connection = wire;

		statement.text = "SELECT 1 AS one";
		statement.execute();
		Assert.equals(1, (Reflect.field(statement.getResult().data[0], "one") : Int));
	}

	public function testAnIsolationLevelTheServerRefusesIsAMySQLError():Void {
		// The setter goes through request(), so what the driver throws arrives
		// as the MySQLError every other refusal is, not as itself (on the jvm a
		// java.sql.SQLException).
		var wire:ScriptedConnection = new ScriptedConnection();
		wire.failures.set("SET SESSION TRANSACTION ISOLATION LEVEL SERIALIZABLE;", "Transaction characteristics can't be changed while a transaction is in progress");
		var connection:MySQLConnection = new MySQLConnection();
		connection.__connection = wire;
		var thrown:Dynamic = null;

		try {
			connection.isolationLevel = crossbyte.db.mysql.IsolationLevel.SERIALIZABLE;
		} catch (e:Dynamic) {
			thrown = e;
		}

		Assert.isTrue(Std.isOfType(thrown, MySQLError), "the setter threw " + Std.string(thrown));
	}

	public function testAnInsertIdPastThirtyTwoBitsIsAskedForInSQL():Void {
		// Off cpp the id comes from sys.db.Connection.lastInsertId(), an Int:
		// wrapped past 2^31 on hl and neko, which read it with a 32-bit
		// getIntResult. As SQLite's driver does, an id that cannot be right
		// is asked for in SQL, as text, which no driver narrows.
		var wire:ScriptedConnection = new ScriptedConnection();
		wire.insertId = -1294967296; // 3,000,000,000 in 32 bits
		wire.results.set("SELECT CAST(LAST_INSERT_ID() AS CHAR) AS id", [{id: "3000000000"}]);
		var statement:MySQLStatement = __statement(wire);
		statement.text = "INSERT INTO t (x) VALUES (1)";
		statement.execute();

		Assert.equals(3000000000.0, statement.getResult().lastInsertRowID);
		// The connection's own, whole as well, not an Int held at 2^31 - 1.
		Assert.equals(3000000000.0, statement.sqlConnection.lastInsertRowID);

		// One in range is taken as it is, with nothing more asked, but on
		// hl and neko, where it is always asked in SQL; see below.
		wire.insertId = 7;
		wire.results.set("SELECT CAST(LAST_INSERT_ID() AS CHAR) AS id", [{id: "7"}]);
		var asked:Int = wire.sent.length;
		statement.execute();
		Assert.equals(7.0, statement.getResult().lastInsertRowID);
		#if (hl || neko)
		Assert.equals(asked + 2, wire.sent.length);
		#else
		Assert.equals(asked + 1, wire.sent.length, "an id in range was asked for in SQL");
		#end
	}

	#if (hl || neko)
	public function testAnInsertIdPastThirtyTwoBitsCannotWrapIntoRange():Void {
		// hl's and neko's lastInsertId() is a SELECT LAST_INSERT_ID() read in
		// 32 bits, so an id of 2^32 + 1 would read as 1, in range, and be taken
		// as it was. Asked in SQL as text every time there: the same round trip
		// their drivers make to answer it.
		var wire:ScriptedConnection = new ScriptedConnection();
		wire.insertId = 1;
		wire.results.set("SELECT CAST(LAST_INSERT_ID() AS CHAR) AS id", [{id: "4294967297"}]);
		var statement:MySQLStatement = __statement(wire);
		statement.text = "INSERT INTO t (x) VALUES (1)";
		statement.execute();

		Assert.equals(4294967297.0, statement.getResult().lastInsertRowID);
		Assert.equals(4294967297.0, statement.sqlConnection.lastInsertRowID);
	}
	#end

	public function testAffectedRowsPastThirtyTwoBitsAreWhole():Void {
		// Off the native client affectedRows asks SELECT ROW_COUNT(), and must
		// not read the answer with Std.parseInt, which past 2^31 answers
		// differently on every target and never the number. It is asked as text,
		// and read whole. Both questions are scripted, as a driver hands a BIGINT
		// back (a number) and as text.
		var wire:ScriptedConnection = new ScriptedConnection();
		var connection:MySQLConnection = __statement(wire).sqlConnection;
		wire.results.set("SELECT ROW_COUNT() AS n;", [{n: 3000000000.0}]);
		wire.results.set("SELECT CAST(ROW_COUNT() AS CHAR) AS n", [{n: "3000000000"}]);
		Assert.equals(3000000000.0, connection.affectedRows);

		// A statement that changes no rows, as MySQL counts it.
		wire.results.set("SELECT ROW_COUNT() AS n;", [{n: -1}]);
		wire.results.set("SELECT CAST(ROW_COUNT() AS CHAR) AS n", [{n: "-1"}]);
		Assert.equals(-1.0, connection.affectedRows);
	}

	public function testAStatementsRowsAffectedIsTheServersCountWhole():Void {
		// A statement's rowsAffected is not the length of the driver's result:
		// for a write, that is the driver's Int count, which hl's driver wraps
		// past 2^31 (three billion rows updated would read -1294967296), and for
		// a SELECT, its rows. A count that cannot be right is asked for in SQL.
		var wire:ScriptedConnection = new ScriptedConnection();
		var statement:MySQLStatement = __statement(wire);
		wire.writeCount = -1294967296;
		wire.results.set("SELECT CAST(ROW_COUNT() AS CHAR) AS n", [{n: "3000000000"}]);
		statement.text = "UPDATE t SET x = 1";
		statement.execute();
		Assert.equals(3000000000.0, statement.getResult().rowsAffected);

		// One that can be right is taken as it is, with nothing more asked.
		wire.writeCount = 7;
		var asked:Int = wire.sent.length;
		statement.execute();
		Assert.equals(asked + 1, wire.sent.length, "a count in range was asked for in SQL");
		Assert.equals(7.0, statement.getResult().rowsAffected);

		// A statement that returns rows changed none, as AIR's has it.
		wire.results.set("SELECT x FROM t", [{x: 1}, {x: 2}, {x: 3}]);
		statement.text = "SELECT x FROM t";
		statement.execute();
		var rows = Require.notNull(statement.getResult());
		Assert.equals(3, rows.data.length);
		Assert.equals(0.0, rows.rowsAffected);
	}

	#if (java || jvm)
	public function testAnInsertWhoseGeneratedKeyPassesThirtyTwoBitsIsNotReportedFailed():Void {
		// Haxe's JDBC binding reads a single insert's generated key with
		// getInt, after the INSERT has run, and Connector/J refuses a value
		// past 2^31 with SQLSTATE 22003: a committed insert must not throw.
		// (Shaped as Connector/J raises it; there is no Connector/J here to raise it.)
		var wire:ScriptedConnection = new ScriptedConnection();
		wire.failures.set("INSERT INTO t (x) VALUES (1)",
			new java.sql.SQLException("Value '3000000000' is outside of valid range for type java.lang.Integer", "22003", 0));
		wire.results.set("SELECT CAST(LAST_INSERT_ID() AS CHAR) AS id", [{id: "3000000000"}]);
		var statement:MySQLStatement = __statement(wire);
		statement.text = "INSERT INTO t (x) VALUES (1)";
		statement.execute();
		Assert.equals(3000000000.0, statement.getResult().lastInsertRowID);

		// The same SQLSTATE from the server (a value out of range for its
		// column, with MySQL's error number) is still a failure.
		wire.failures.set("INSERT INTO t (x) VALUES (2)", new java.sql.SQLException("Out of range value for column 'x' at row 1", "22003", 1264));
		statement.text = "INSERT INTO t (x) VALUES (2)";
		Assert.raises(() -> statement.execute(), SQLError);
	}
	#end

	private function __statement(wire:ScriptedConnection):MySQLStatement {
		var connection:MySQLConnection = new MySQLConnection();
		connection.__connection = wire;
		var statement:MySQLStatement = new MySQLStatement();
		statement.sqlConnection = connection;
		return statement;
	}
}
#end
