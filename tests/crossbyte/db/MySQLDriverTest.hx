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
		// execute() dispatched an SQLErrorEvent and returned, so a caller not
		// listening, an AsyncDatabase task, a SchemaMigrator step, saw a
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
		// open. A connection that cannot read them, a target other than cpp,
		// follows the statements that open and close one instead, so a
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

	public function testAFailureThatIsNotAStringStillBecomesAnSQLError():Void {
		// The driver's failure was handed to SQLError and IOError where they
		// take a String. On the jvm that is a java.sql.SQLException, so every
		// failure surfaced as a ClassCastException: no SQLError, no listener,
		// and the error number and SQLSTATE JDBC had were lost.
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
		// Nothing listens on port 1. On the jvm there is not even a driver to
		// try it with, and the ClassNotFoundException that says so became a
		// ClassCastException on its way into IOError.
		var connection:MySQLConnection = new MySQLConnection();
		var thrown:Dynamic = null;

		try {
			connection.open({
				host: "127.0.0.1",
				port: 1,
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
	}

	public function testParametersAreWrittenAsTheirTypes():Void {
		// Parameters were strings only: an Int did not compile, "50" went out
		// as LIMIT '50' (which MySQL refuses), a null left :name in the SQL,
		// and bytes were cut at their first NUL.
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
		// MySQL reads \' inside a literal as a quote; the scan ended the
		// literal there, and substituted the :name the server still read as
		// part of it.
		var wire:ScriptedConnection = new ScriptedConnection();
		var statement:MySQLStatement = __statement(wire);
		statement.text = "SELECT 'it\\'s :name' AS label, :name AS value";
		statement.parameters.name = "x";
		statement.execute();

		Assert.equals("SELECT 'it\\'s :name' AS label, 'x' AS value", wire.sent[wire.sent.length - 1]);
	}

	public function testTheConnectionEscapesAndQuotesByTheSessionsMode():Void {
		// SQLite and Postgres connections had escape() and quote(); MySQL's
		// did not.
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
		// Named from haxe.Timer.stamp() in microseconds through Std.int, as
		// SQLite's and Postgres's were before the same fix: names made back to
		// back collided, and the value passes Int 36 minutes into a process.
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
		// setSavepoint() returned nothing; releaseSavepoint(null) released a
		// name it had just made up; rollbackToSavepoint(null) rolled the whole
		// transaction back.
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
		// knows only @@tx_isolation, and the getter failed there.
		var wire:ScriptedConnection = new ScriptedConnection();
		wire.failures.set("SELECT @@transaction_isolation AS lvl;", "Unknown system variable 'transaction_isolation'");
		wire.results.set("SELECT @@tx_isolation AS lvl;", [{lvl: "READ-COMMITTED"}]);
		var connection:MySQLConnection = new MySQLConnection();
		connection.__connection = wire;

		Assert.equals("READ COMMITTED", (connection.isolationLevel : String));
	}

	public function testAClientCharsetMySQLRefusesIsRefusedBeforeConnecting():Void {
		// ucs2, utf16 and utf32 were accepted, and MySQL refuses each as a
		// client character set.
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

	#if !cpp
	public function testAnSslModeThatNeedsTlsIsRefusedWhereTheClientHasNone():Void {
		// Only the native client reads sslMode. Elsewhere REQUIRED and both
		// VERIFY modes went unread, and the connection was made in the clear,
		// password and all, with nothing said. Refused now, as the native
		// client refuses a server offering no TLS: with 2026, and before
		// connecting, a connect attempt to port 1 fails otherwise, and the
		// jvm has no JDBC driver to try one with.
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
		// Off cpp the pages waited in an Array read with pop(), newest first,
		// so a result paged ahead of getResult() came back last page first on
		// the jvm and in the interpreter. And each page taken after the last
		// had been read said it was complete.
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

	private function __statement(wire:ScriptedConnection):MySQLStatement {
		var connection:MySQLConnection = new MySQLConnection();
		connection.__connection = wire;
		var statement:MySQLStatement = new MySQLStatement();
		statement.sqlConnection = connection;
		return statement;
	}
}
#end
