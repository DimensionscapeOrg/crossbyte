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
@:cppFileCode('#include <locale.h>')
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
		// failed after the server had applied it -- and code that retries on
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

	public function testColumnValuesAreExact():Void {
		// Measured against the client before: BIGINT 1234567890123456789 read
		// as ...768 (a Float), DECIMAL(19,4) as a Float, INT UNSIGNED 3e9 as
		// 2147483647, DATE 2040-06-01 as 1904-04-26, DATE 1965 as -1000 ms
		// (and printing it ended the process on Windows), NULL columns missing
		// from the row, COUNT(*) renamed "???", and a VARCHAR with a _bin
		// collation read as Bytes.
		__server.onQuery = function(session, sql) {
			if (sql != "SELECT TYPES") {
				return false;
			}

			session.resultSet([
				{name: "id", type: FakeMySQLServer.TYPE_LONGLONG, flags: FakeMySQLServer.FLAG_UNSIGNED, charset: FakeMySQLServer.CHARSET_BINARY},
				{name: "snowflake", type: FakeMySQLServer.TYPE_LONGLONG, charset: FakeMySQLServer.CHARSET_BINARY},
				{name: "COUNT(*)", type: FakeMySQLServer.TYPE_LONGLONG, charset: FakeMySQLServer.CHARSET_BINARY},
				{name: "SUM(amount)", type: FakeMySQLServer.TYPE_NEWDECIMAL, charset: FakeMySQLServer.CHARSET_BINARY},
				{name: "balance", type: FakeMySQLServer.TYPE_NEWDECIMAL, charset: FakeMySQLServer.CHARSET_BINARY},
				{name: "uint_col", type: FakeMySQLServer.TYPE_LONG, flags: FakeMySQLServer.FLAG_UNSIGNED, charset: FakeMySQLServer.CHARSET_BINARY},
				{name: "int_col", type: FakeMySQLServer.TYPE_LONG, charset: FakeMySQLServer.CHARSET_BINARY},
				{name: "born", type: FakeMySQLServer.TYPE_DATE, charset: FakeMySQLServer.CHARSET_BINARY},
				{name: "expires", type: FakeMySQLServer.TYPE_DATE, charset: FakeMySQLServer.CHARSET_BINARY},
				{name: "created_at", type: FakeMySQLServer.TYPE_DATETIME, charset: FakeMySQLServer.CHARSET_BINARY},
				{name: "zeroed", type: FakeMySQLServer.TYPE_DATETIME, charset: FakeMySQLServer.CHARSET_BINARY},
				{name: "deleted_at", type: FakeMySQLServer.TYPE_DATETIME, charset: FakeMySQLServer.CHARSET_BINARY},
				{name: "token", type: FakeMySQLServer.TYPE_VAR_STRING, flags: FakeMySQLServer.FLAG_BINARY, charset: 46},
				{name: "blob", type: FakeMySQLServer.TYPE_BLOB, flags: FakeMySQLServer.FLAG_BINARY, charset: FakeMySQLServer.CHARSET_BINARY},
				{name: "nick", type: FakeMySQLServer.TYPE_VAR_STRING, charset: FakeMySQLServer.CHARSET_UTF8MB4_0900},
				{name: "flag", type: FakeMySQLServer.TYPE_TINY, length: 1, charset: FakeMySQLServer.CHARSET_BINARY},
				{name: "at", type: FakeMySQLServer.TYPE_TIME, flags: FakeMySQLServer.FLAG_BINARY, charset: FakeMySQLServer.CHARSET_BINARY}
			], [[
				"9007199254740993", "1234567890123456789", "7", "15.50", "12345678901234.5678", "3000000000", "-5", "1965-04-12", "2040-06-01",
				"2026-09-29 12:34:56.250000", "0000-00-00 00:00:00", null, "AbC", "\u0001\u0002", "Zoë \u{1F680}", "1", "12:00:00"
			]]);
			return true;
		};
		__server.start();
		var connection:MySQLConnection = __open();

		var rows = connection.request("SELECT TYPES");
		Assert.isTrue(rows.hasNext());
		var row:Dynamic = rows.next();

		var id:haxe.Int64 = Reflect.field(row, "id");
		Assert.equals("9007199254740993", haxe.Int64.toStr(id));
		var snowflake:haxe.Int64 = Reflect.field(row, "snowflake");
		Assert.equals("1234567890123456789", haxe.Int64.toStr(snowflake));

		// A count that fits an Int is an Int, as an INT column's always was.
		var count:Dynamic = Reflect.field(row, "COUNT(*)");
		Assert.isTrue(Std.isOfType(count, Int), "COUNT(*) came back as " + Std.string(count));
		Assert.equals(7, (count : Int));
		Assert.equals("15.50", Reflect.field(row, "SUM(amount)"));
		Assert.isFalse(Reflect.hasField(row, "???"));

		Assert.equals("12345678901234.5678", Reflect.field(row, "balance"));
		var unsigned:haxe.Int64 = Reflect.field(row, "uint_col");
		Assert.equals("3000000000", haxe.Int64.toStr(unsigned));
		Assert.equals(-5, (Reflect.field(row, "int_col") : Int));

		var born:Date = Reflect.field(row, "born");
		Assert.equals(-149040000000.0, born.getTime());
		// Printing it ended a Windows process: the CRT refused the time.
		Assert.isTrue(Std.string(born).indexOf("1965-04-1") == 0, Std.string(born));

		var expires:Date = Reflect.field(row, "expires");
		Assert.equals(2222121600000.0, expires.getTime());
		Assert.equals(2040, expires.getUTCFullYear());

		var created:Date = Reflect.field(row, "created_at");
		Assert.equals(1790685296250.0, created.getTime());

		Assert.isTrue(Reflect.hasField(row, "zeroed"));
		Assert.isNull(Reflect.field(row, "zeroed"));
		Assert.isTrue(Reflect.hasField(row, "deleted_at"), "a NULL column was left out of the row");
		Assert.isNull(Reflect.field(row, "deleted_at"));

		Assert.equals("AbC", Reflect.field(row, "token"));
		var blob:Dynamic = Reflect.field(row, "blob");
		Assert.isTrue(Std.isOfType(blob, haxe.io.Bytes));
		Assert.equals("0102", (blob : haxe.io.Bytes).toHex());
		Assert.equals("Zoë \u{1F680}", Reflect.field(row, "nick"));
		Assert.equals(true, Reflect.field(row, "flag"));
		Assert.equals("12:00:00", Reflect.field(row, "at"));

		connection.close();
	}

	public function testADateBeforeNineteenSeventyCanBePrinted():Void {
		// hxcpp's Date on Windows: localtime refused a negative time, the
		// zeroed fields it was replaced with went to strftime, and the CRT's
		// invalid-parameter handler ended the process (0xC0000409).
		var early:Date = Date.fromTime(-1000);
		Assert.equals(1969, early.getUTCFullYear());
		Assert.equals(23, early.getUTCHours());
		Assert.equals(59, early.getUTCSeconds());
		Assert.isTrue(Std.string(early).indexOf("1969-12-31") == 0 || Std.string(early).indexOf("1970-01-01") == 0, Std.string(early));

		// And made from local fields, where mktime fails the same way.
		var local:Date = new Date(1965, 3, 12, 10, 30, 0);
		Assert.equals(1965, local.getFullYear());
		Assert.equals(3, local.getMonth());
		Assert.equals(12, local.getDate());
		Assert.equals(10, local.getHours());
		Assert.equals(30, local.getMinutes());

		Assert.equals(-149040000000.0, DateTools.makeUtc(1965, 3, 12, 0, 0, 0));
	}

	public function testResultsCostNoExtraRoundTrips():Void {
		// Every getResult() sent SELECT LAST_INSERT_ID() -- 20 pages, 21
		// extra statements -- after which affectedRows, itself a SELECT
		// ROW_COUNT(), read -1. Both numbers are in the statement's own
		// answer.
		__server.onQuery = function(session, sql) {
			if (StringTools.startsWith(sql, "INSERT")) {
				session.ok(1, 3000000001.0);
				return true;
			}

			if (sql == "SELECT PAGES") {
				session.resultSet([{name: "n", type: FakeMySQLServer.TYPE_LONG, charset: FakeMySQLServer.CHARSET_BINARY}],
					[for (i in 0...20) [Std.string(i)]]);
				return true;
			}

			return false;
		};
		__server.start();
		var connection:MySQLConnection = __open();
		var statement:MySQLStatement = new MySQLStatement();
		statement.sqlConnection = connection;

		statement.text = "INSERT INTO users (email) VALUES ('a@example.com')";
		statement.execute();
		var inserted = Require.notNull(statement.getResult());
		// Past 2^31, where lastInsertId() -- an Int -- ran out.
		Assert.equals(3000000001.0, inserted.lastInsertRowID);
		Assert.equals(1.0, inserted.rowsAffected);
		Assert.equals(1, connection.affectedRows);

		statement.text = "SELECT PAGES";
		statement.execute(5);
		var rows:Int = Require.notNull(statement.getResult()).data.length;

		while (statement.executing) {
			statement.next(5);
			var page = statement.getResult();
			rows += page == null ? 0 : page.data.length;
		}

		Assert.equals(20, rows);
		var extra = __server.queries().filter(q -> q.indexOf("LAST_INSERT_ID") >= 0 || q.indexOf("ROW_COUNT") >= 0 || q.indexOf("VERSION()") >= 0);
		Assert.equals(0, extra.length, extra.join(" | "));
		Assert.equals(__server.serverVersion, connection.serverVersion);
		connection.close();
	}

	public function testTheFirstPageArrivesBeforeTheRestOfTheResult():Void {
		// The whole result was read before the first page was returned: a
		// million rows reached 190 MB first. Here the server pauses after ten
		// rows, and the first five must not wait for it.
		__server.onQuery = function(session, sql) {
			if (sql == "SELECT SLOW PAGES") {
				session.resultSet([{name: "n", type: FakeMySQLServer.TYPE_LONG, charset: FakeMySQLServer.CHARSET_BINARY}],
					[for (i in 0...30) [Std.string(i)]], 10, 2.0);
				return true;
			}

			return false;
		};
		__server.start();
		var connection:MySQLConnection = __open();
		var statement:MySQLStatement = new MySQLStatement();
		statement.sqlConnection = connection;
		statement.text = "SELECT SLOW PAGES";

		var started:Float = haxe.Timer.stamp();
		statement.execute(5);
		var first = Require.notNull(statement.getResult());
		Assert.equals(5, first.data.length);
		Assert.isTrue(haxe.Timer.stamp() - started < 1.5, "the first page waited for the whole result");
		Assert.isTrue(statement.executing);

		statement.next(-1);
		var rest = Require.notNull(statement.getResult());
		Assert.equals(25, rest.data.length);
		Assert.isFalse(statement.executing);
		Assert.equals("29", Std.string(Reflect.field(rest.data[24], "n")));
		connection.close();
	}

	public function testAPagedStatementSurvivesAnotherStatementOnItsConnection():Void {
		// The rest of a result read part way is read aside when the
		// connection is needed for something else, so the page after still
		// comes -- as it did when results were read whole first.
		__server.onQuery = function(session, sql) {
			if (sql == "SELECT TWENTY") {
				session.resultSet([{name: "n", type: FakeMySQLServer.TYPE_LONG, charset: FakeMySQLServer.CHARSET_BINARY}],
					[for (i in 0...20) [Std.string(i)]]);
				return true;
			}

			return false;
		};
		__server.start();
		var connection:MySQLConnection = __open();
		var statement:MySQLStatement = new MySQLStatement();
		statement.sqlConnection = connection;
		statement.text = "SELECT TWENTY";
		statement.execute(5);
		Assert.equals(5, Require.notNull(statement.getResult()).data.length);

		connection.request("UPDATE users SET seen = 1 WHERE id = 3");
		Assert.equals(1, connection.affectedRows);

		statement.next(-1);
		var rest = Require.notNull(statement.getResult());
		Assert.equals(15, rest.data.length);
		Assert.equals("19", Std.string(Reflect.field(rest.data[14], "n")));

		// And one abandoned part way does not hold the connection up.
		statement.execute(5);
		statement = null;
		Assert.isTrue(connection.ping());
		Assert.equals(1, Require.notNull(connection.request("SELECT 1")).length);
		connection.close();
	}

	public function testFloatsReadTheSameInAnyLocale():Void {
		// The client parsed DOUBLE with atof, which reads the process's
		// locale: under one with a decimal comma, 1.5 came back as 1.
		var decimalComma:Bool = untyped __cpp__('(setlocale(LC_NUMERIC, "de-DE") != 0 || setlocale(LC_NUMERIC, "de_DE.UTF-8") != 0 || setlocale(LC_NUMERIC, "German") != 0)');

		if (!decimalComma) {
			Assert.pass("no locale with a decimal comma to test under");
			return;
		}

		__server.onQuery = function(session, sql) {
			if (sql == "SELECT RATIO") {
				session.resultSet([{name: "ratio", type: FakeMySQLServer.TYPE_DOUBLE, charset: FakeMySQLServer.CHARSET_BINARY}], [["1.5"]]);
				return true;
			}

			return false;
		};

		try {
			__server.start();
			var connection:MySQLConnection = __open();
			var rows = connection.request("SELECT RATIO");
			Assert.isTrue(rows.hasNext());
			Assert.equals(1.5, (Reflect.field(rows.next(), "ratio") : Float));
			connection.close();
		} catch (e:Dynamic) {
			untyped __cpp__('setlocale(LC_NUMERIC, "C")');
			throw e;
		}

		untyped __cpp__('setlocale(LC_NUMERIC, "C")');
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
