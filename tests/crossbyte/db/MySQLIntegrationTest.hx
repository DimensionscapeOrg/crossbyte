package crossbyte.db;

import utest.Assert;
#if cpp
import crossbyte.db.mysql.IsolationLevel;
import crossbyte.db.mysql.MySQLConfig;
import crossbyte.db.mysql.MySQLConnection;
import crossbyte.db.mysql.MySQLError;
import crossbyte.db.mysql.MySQLSSLMode;
import crossbyte.db.mysql.MySQLStatement;
import crossbyte.test.Require;
import crossbyte.utils.Logger;
import haxe.io.Bytes;
import sys.thread.Lock;
import sys.thread.Thread;
#end

/**
 * The native MySQL driver against a real MySQL or MariaDB server.
 *
 * The native suite covers the client against a fake server that logs every
 * byte (`MySQLNativeWireTest` and its siblings), which is where each fix is
 * proved; this is the check that the fake agrees with a real server --
 * caching_sha2_password against MySQL 8's own, TLS against its generated
 * certificate, a result paged as it arrives, KILL QUERY interrupting a
 * statement.
 *
 * `@:suiteExempt` because it needs a live server. The `Data | MySQL` CI job
 * (`.github/workflows/mysql.yml`) runs it against MySQL 8.4 and MariaDB 11,
 * with `CROSSBYTE_MYSQL_REQUIRED` set so an unreachable server fails rather
 * than skips; anywhere `CROSSBYTE_MYSQL_HOST` is unset every case passes.
 */
@:suiteExempt("needs a live MySQL or MariaDB server; run by the Data | MySQL CI job")
class MySQLIntegrationTest extends utest.Test {
	#if cpp
	private var connection:MySQLConnection;
	private var table:String;
	#end

	public function setup():Void {
		#if cpp
		if (!__configured()) {
			return;
		}

		connection = new MySQLConnection();
		connection.open(__config());
		// Unique per run, so a run that left a table behind cannot fail the
		// next for an unrelated reason.
		table = "crossbyte_it_" + Std.string(Std.random(0x7FFFFFF));
		connection.request('CREATE TABLE $table (id BIGINT UNSIGNED PRIMARY KEY AUTO_INCREMENT, email VARCHAR(190) UNIQUE, '
			+ 'name VARCHAR(100), balance DECIMAL(19,4), big BIGINT, born DATE, seen DATETIME(3), data BLOB, flag TINYINT(1), '
			+ 'counter INT UNSIGNED) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4');
		#end
	}

	public function teardown():Void {
		#if cpp
		if (connection == null) {
			return;
		}

		try {
			connection.request('DROP TABLE IF EXISTS $table');
		} catch (_:Dynamic) {}

		try {
			connection.close();
		} catch (_:Dynamic) {}

		connection = null;
		#end
	}

	public function testConnectsAndSaysWhatItConnectedTo():Void {
		#if cpp
		if (__skip()) {
			return;
		}

		Assert.isTrue(connection.ping());
		Assert.isTrue(connection.serverVersion.length > 0);
		Assert.isFalse(connection.inTransaction);
		Assert.isTrue(connection.autocommit);
		// MySQL generates a TLS certificate by default and PREFERRED uses it;
		// the MariaDB image has none.
		if (!__mariadb()) {
			Assert.isTrue(connection.encrypted, "a default MySQL 8 server offers TLS, and it was not used");
		}
		Assert.notNull((connection.isolationLevel : String));
		#else
		Assert.pass();
		#end
	}

	public function testANonAsciiStatementChangesTheRowItNames():Void {
		#if cpp
		if (__skip()) {
			return;
		}

		for (i in 1...13) {
			connection.request('INSERT INTO $table (email, name) VALUES (\'user$i@example.com\', \'user $i\')');
		}

		// Sent short by one byte per extra UTF-8 byte, this was WHERE id = 1.
		connection.request('UPDATE $table SET name = \'Z\u00FCrich \u{1F680}\' WHERE id = 12');
		Assert.equals(1, connection.affectedRows);

		var twelve:Array<Dynamic> = __rows('SELECT name FROM $table WHERE id = 12');
		Assert.equals("Z\u00FCrich \u{1F680}", Reflect.field(twelve[0], "name"));
		var one:Array<Dynamic> = __rows('SELECT name FROM $table WHERE id = 1');
		Assert.equals("user 1", Reflect.field(one[0], "name"));
		#else
		Assert.pass();
		#end
	}

	public function testValuesGoInAndComeBackExactly():Void {
		#if cpp
		if (__skip()) {
			return;
		}

		var statement:MySQLStatement = __statement();
		statement.text = 'INSERT INTO $table (email, name, balance, big, born, seen, data, flag, counter) '
			+ 'VALUES (:email, :name, :balance, :big, :born, :seen, :data, :flag, :counter)';
		statement.parameters.email = "values@example.com";
		statement.parameters.name = null;
		statement.parameters.balance = "12345678901234.5678";
		statement.parameters.big = haxe.Int64.parseString("1234567890123456789");
		statement.parameters.born = Date.fromTime(-149040000000.0);
		statement.parameters.seen = Date.fromTime(1790685296250.0);
		statement.parameters.data = Bytes.ofHex("00ff0027005c");
		statement.parameters.flag = true;
		statement.parameters.counter = haxe.Int64.parseString("3000000000");
		statement.execute();

		var inserted = Require.notNull(statement.getResult());
		Assert.isTrue(inserted.lastInsertRowID > 0);

		var row:Dynamic = __rows('SELECT * FROM $table WHERE email = \'values@example.com\'')[0];
		Assert.isTrue(Reflect.hasField(row, "name"));
		Assert.isNull(Reflect.field(row, "name"));
		Assert.equals("12345678901234.5678", Reflect.field(row, "balance"));
		var big:haxe.Int64 = Reflect.field(row, "big");
		Assert.equals("1234567890123456789", haxe.Int64.toStr(big));
		var counter:haxe.Int64 = Reflect.field(row, "counter");
		Assert.equals("3000000000", haxe.Int64.toStr(counter));
		Assert.equals(-149040000000.0, (Reflect.field(row, "born") : Date).getTime());
		Assert.equals(1790685296250.0, (Reflect.field(row, "seen") : Date).getTime());
		Assert.equals("00ff0027005c", (Reflect.field(row, "data") : Bytes).toHex());
		Assert.equals(true, Reflect.field(row, "flag"));
		#else
		Assert.pass();
		#end
	}

	public function testAFailureCarriesItsNumberAndStateButNotTheStatement():Void {
		#if cpp
		if (__skip()) {
			return;
		}

		connection.request('INSERT INTO $table (email, name) VALUES (\'dup@example.com\', \'first\')');
		var error:MySQLError = null;

		try {
			connection.request('INSERT INTO $table (email, name) VALUES (\'dup@example.com\', \'tok_live_9f8e7d6c5b4a\')');
		} catch (e:MySQLError) {
			error = e;
		}

		Require.notNull(error);
		Assert.equals(1062, error.code);
		Assert.equals("23000", error.sqlState);
		Assert.equals(-1, error.message.indexOf("tok_live"), error.message);
		#else
		Assert.pass();
		#end
	}

	public function testAPoolRollsBackWhatABorrowerLeftOpen():Void {
		#if cpp
		if (__skip()) {
			return;
		}

		var pool:ConnectionPool<MySQLConnection> = new ConnectionPool<MySQLConnection>({
			factory: function():MySQLConnection {
				var opened:MySQLConnection = new MySQLConnection();
				opened.open(__config());
				return opened;
			},
			close: c -> c.close(),
			maxSize: 1,
			acquireTimeout: 5.0
		});

		Logger.recordSink = _ -> {};

		var first:MySQLConnection = pool.acquire();
		first.request("START TRANSACTION");
		first.request('INSERT INTO $table (email) VALUES (\'open@example.com\')');
		Assert.isTrue(first.inTransaction);
		pool.release(first);

		var second:MySQLConnection = pool.acquire();
		Assert.isFalse(second.inTransaction);
		second.autocommit = false;
		second.request('INSERT INTO $table (email) VALUES (\'autocommit-off@example.com\')');
		pool.release(second);

		var third:MySQLConnection = pool.acquire();
		Assert.isTrue(third.autocommit, "a session with autocommit off went back into the pool");
		Assert.notEquals(second, third);
		pool.release(third);
		pool.close();

		Logger.recordSink = null;

		Assert.equals(0, __rows('SELECT email FROM $table WHERE email IN (\'open@example.com\', \'autocommit-off@example.com\')').length);
		#else
		Assert.pass();
		#end
	}

	public function testQuotingFollowsTheSessionsEscapingMode():Void {
		#if cpp
		if (__skip()) {
			return;
		}

		connection.request('INSERT INTO $table (email, name) VALUES (\'quoted@example.com\', \'safe\')');
		connection.request("SET SESSION sql_mode = 'NO_BACKSLASH_ESCAPES'");

		var statement:MySQLStatement = __statement();
		statement.text = 'SELECT COUNT(*) AS n FROM $table WHERE name = :name';
		statement.parameters.name = "x' OR 1=1 -- ";
		statement.execute();
		Assert.equals(0, (Reflect.field(Require.notNull(statement.getResult()).data[0], "n") : Int), "the value ran as SQL");

		statement.text = 'UPDATE $table SET name = :name WHERE email = \'quoted@example.com\'';
		statement.parameters.name = "C:\\dir\\it's";
		statement.execute();
		Assert.equals("C:\\dir\\it's", Reflect.field(__rows('SELECT name FROM $table WHERE email = \'quoted@example.com\'')[0], "name"));
		#else
		Assert.pass();
		#end
	}

	public function testTheConfiguredTimeZoneAndSqlModeAreSet():Void {
		#if cpp
		if (__skip()) {
			return;
		}

		var config:MySQLConfig = __config();
		config.timeZone = "+00:00";
		config.sqlMode = "STRICT_TRANS_TABLES";
		config.charset = "utf8mb4";
		var configured:MySQLConnection = new MySQLConnection();
		configured.open(config);
		var row:Dynamic = __rowsOf(configured, "SELECT @@session.time_zone AS tz, @@session.sql_mode AS mode")[0];
		Assert.equals("+00:00", Reflect.field(row, "tz"));
		Assert.isTrue(Std.string(Reflect.field(row, "mode")).indexOf("STRICT_TRANS_TABLES") >= 0);
		configured.close();
		#else
		Assert.pass();
		#end
	}

	public function testSavepointsNest():Void {
		#if cpp
		if (__skip()) {
			return;
		}

		connection.begin();
		connection.request('INSERT INTO $table (email) VALUES (\'kept@example.com\')');
		var outer:String = connection.setSavepoint();
		connection.request('INSERT INTO $table (email) VALUES (\'undone@example.com\')');
		connection.setSavepoint();
		connection.rollbackToSavepoint();
		connection.rollbackToSavepoint(outer);
		connection.releaseSavepoint(outer);
		connection.commit();
		Assert.isFalse(connection.inTransaction);

		Assert.equals(1, __rows('SELECT email FROM $table WHERE email = \'kept@example.com\'').length);
		Assert.equals(0, __rows('SELECT email FROM $table WHERE email = \'undone@example.com\'').length);
		#else
		Assert.pass();
		#end
	}

	public function testAPageArrivesBeforeTheWholeResult():Void {
		#if cpp
		if (__skip()) {
			return;
		}

		var digits:String = "(SELECT 0 AS n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 "
			+ "UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9)";
		var statement:MySQLStatement = __statement();
		statement.text = 'SELECT a.n + b.n * 10 + c.n * 100 + d.n * 1000 AS n FROM $digits a, $digits b, $digits c, $digits d';
		statement.execute(1000);
		var total:Int = Require.notNull(statement.getResult()).data.length;
		// Another statement between pages reads the rest aside.
		Assert.isTrue(connection.ping());

		while (statement.executing) {
			statement.next(1000);
			var page = statement.getResult();
			total += page == null ? 0 : page.data.length;
		}

		Assert.equals(10000, total);
		#else
		Assert.pass();
		#end
	}

	public function testCancelAndReadTimeoutStopAStatement():Void {
		#if cpp
		if (__skip()) {
			return;
		}

		// Interrupted, SLEEP() alone returns 1 with no error; as part of a
		// query it fails with 1317. Either way it comes back early.
		var outcome:String = null;
		var done:Lock = new Lock();
		var started:Float = haxe.Timer.stamp();

		Thread.create(function():Void {
			try {
				connection.request("SELECT 1 FROM DUAL WHERE SLEEP(10) = 0");
				outcome = "returned";
			} catch (e:MySQLError) {
				outcome = "error " + e.code;
			} catch (e:Dynamic) {
				outcome = "threw " + Std.string(e);
			}

			done.release();
		});

		Sys.sleep(0.5);
		Assert.isTrue(connection.cancel());

		if (!done.wait(8.0)) {
			// The other thread still has the connection; teardown must not
			// use it at the same time.
			connection = null;
			Assert.fail("the statement ran on after the cancel");
			return;
		}

		Assert.isTrue(haxe.Timer.stamp() - started < 8.0);
		Assert.isTrue(outcome == "error 1317" || outcome == "returned", outcome);

		var config:MySQLConfig = __config();
		config.readTimeout = 1.0;
		var bounded:MySQLConnection = new MySQLConnection();
		bounded.open(config);
		var error:MySQLError = null;
		started = haxe.Timer.stamp();

		try {
			bounded.request("SELECT SLEEP(5)");
		} catch (e:MySQLError) {
			error = e;
		}

		Require.notNull(error);
		Assert.equals(2013, error.code);
		Assert.isTrue(haxe.Timer.stamp() - started < 4.0);
		bounded.close();
		#else
		Assert.pass();
		#end
	}

	public function testMySQL8AccountsLogInWithAndWithoutTls():Void {
		#if cpp
		if (__skip()) {
			return;
		}

		if (__mariadb()) {
			// MariaDB has no caching_sha2_password.
			Assert.pass();
			return;
		}

		var suffix:String = Std.string(Std.random(0x7FFFFFF));
		var rsaUser:String = 'cb_rsa_$suffix';
		var tlsUser:String = 'cb_tls_$suffix';
		var password:String = 'pw-$suffix';

		for (user in [rsaUser, tlsUser]) {
			connection.request('CREATE USER \'$user\'@\'%\' IDENTIFIED WITH caching_sha2_password BY \'$password\'');
		}

		try {
			// A new account is not in the server's cache, so its first login
			// is full authentication: the password itself, here encrypted
			// with the server's RSA key since the connection has no TLS.
			var config:MySQLConfig = __config();
			config.user = rsaUser;
			config.password = password;
			config.database = null;
			config.sslMode = MySQLSSLMode.DISABLED;
			config.allowPublicKeyRetrieval = true;
			var rsa:MySQLConnection = new MySQLConnection();
			rsa.open(config);
			Assert.isFalse(rsa.encrypted);
			Assert.isTrue(rsa.ping());
			rsa.close();

			// Cached now: the next login is the fast path, which needs no key.
			config.allowPublicKeyRetrieval = false;
			var fast:MySQLConnection = new MySQLConnection();
			fast.open(config);
			fast.close();

			// Full authentication over TLS sends the password inside it.
			config.user = tlsUser;
			config.sslMode = MySQLSSLMode.REQUIRED;
			var tls:MySQLConnection = new MySQLConnection();
			tls.open(config);
			Assert.isTrue(tls.encrypted);
			tls.close();
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		for (user in [rsaUser, tlsUser]) {
			try {
				connection.request('DROP USER \'$user\'@\'%\'');
			} catch (_:Dynamic) {}
		}
		#else
		Assert.pass();
		#end
	}

	#if cpp
	@:noCompletion private function __skip():Bool {
		if (__configured()) {
			return false;
		}

		if (Sys.getEnv("CROSSBYTE_MYSQL_REQUIRED") != null) {
			// The CI job sets this, so a broken service container or a
			// mistyped variable fails the job instead of skipping every case
			// into a green run that proves nothing.
			Assert.fail("CROSSBYTE_MYSQL_REQUIRED is set but CROSSBYTE_MYSQL_HOST is not: the server this job exists to test was never reached.");
			return true;
		}

		Assert.pass();
		return true;
	}

	@:noCompletion private function __mariadb():Bool {
		return connection.serverVersion.toLowerCase().indexOf("mariadb") >= 0;
	}

	@:noCompletion private function __statement():MySQLStatement {
		var statement:MySQLStatement = new MySQLStatement();
		statement.sqlConnection = connection;
		return statement;
	}

	@:noCompletion private function __rows(sql:String):Array<Dynamic> {
		return __rowsOf(connection, sql);
	}

	@:noCompletion private static function __rowsOf(on:MySQLConnection, sql:String):Array<Dynamic> {
		var result = on.request(sql);
		var out:Array<Dynamic> = [];

		while (result.hasNext()) {
			out.push(result.next());
		}

		return out;
	}

	@:noCompletion private static function __configured():Bool {
		var host:String = Sys.getEnv("CROSSBYTE_MYSQL_HOST");
		return host != null && host != "";
	}

	@:noCompletion private static function __config():MySQLConfig {
		var port:Null<Int> = Std.parseInt(__env("CROSSBYTE_MYSQL_PORT", "3306"));

		return {
			host: __env("CROSSBYTE_MYSQL_HOST", "127.0.0.1"),
			port: port == null ? 3306 : port,
			user: __env("CROSSBYTE_MYSQL_USER", "root"),
			password: __env("CROSSBYTE_MYSQL_PASSWORD", "root"),
			database: __env("CROSSBYTE_MYSQL_DATABASE", "crossbyte")
		};
	}

	@:noCompletion private static function __env(name:String, fallback:String):String {
		var value:String = Sys.getEnv(name);
		return value == null || value == "" ? fallback : value;
	}
	#end
}
