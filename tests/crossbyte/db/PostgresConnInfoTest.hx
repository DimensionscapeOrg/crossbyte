package crossbyte.db;

import crossbyte.db.postgres._internal.PostgresConnInfo;
import utest.Assert;

/**
 * The libpq connection string a `PostgresConfig` becomes. Pure string work, so
 * it runs on every target; what it produces is checked against libpq itself,
 * through a stand-in, by `NativePostgresBridgeTest`.
 */
class PostgresConnInfoTest extends utest.Test {
	public function testDefaultsAreWhatTheDriverAlwaysSent():Void {
		Assert.equals("host='127.0.0.1' port='5432' dbname='postgres' connect_timeout='5'", PostgresConnInfo.build({}));
	}

	public function testAValueCannotEndItsQuotesEarly():Void {
		// A quote or backslash in a password would otherwise close the value
		// and let the rest of it write keywords of its own.
		var conninfo:String = PostgresConnInfo.build({password: "a'b\\c host=evil"});

		Assert.isTrue(conninfo.indexOf("password='a\\'b\\\\c host=evil'") >= 0, conninfo);
		Assert.equals("'it\\'s'", PostgresConnInfo.quote("it's"));
	}

	public function testStatementTimeoutIsSentInMillisecondsThroughOptions():Void {
		Assert.isTrue(PostgresConnInfo.build({statementTimeout: 2.5}).indexOf("options='-c statement_timeout=2500'") >= 0);
		// Not 1101: 1.1 * 1000 is 1100.0000000000002.
		Assert.isTrue(PostgresConnInfo.build({statementTimeout: 1.1}).indexOf("statement_timeout=1100'") >= 0);
		// A limit too small to be a whole millisecond still limits: rounding
		// it to zero would switch statement_timeout off.
		Assert.isTrue(PostgresConnInfo.build({statementTimeout: 0.0001}).indexOf("statement_timeout=1'") >= 0);
		Assert.isTrue(PostgresConnInfo.build({statementTimeout: 0.0}).indexOf("statement_timeout=0'") >= 0);
		// Clamped where an Int runs out, rather than wrapping negative.
		Assert.isTrue(PostgresConnInfo.build({statementTimeout: 1e12}).indexOf("statement_timeout=2147483647'") >= 0);
		Assert.equals(-1, PostgresConnInfo.build({}).indexOf("statement_timeout"));
	}

	public function testStatementTimeoutJoinsOptionsTheCallerPassed():Void {
		// libpq keeps the last of a repeated keyword, so writing options twice
		// would silently drop one of them.
		var conninfo:String = PostgresConnInfo.build({
			statementTimeout: 5,
			connectionParameters: ["options" => "-c search_path=app"]
		});

		Assert.isTrue(conninfo.indexOf("options='-c search_path=app -c statement_timeout=5000'") >= 0, conninfo);
		Assert.equals(conninfo.indexOf("options="), conninfo.lastIndexOf("options="));
	}

	public function testKeepAliveAndUserTimeout():Void {
		var conninfo:String = PostgresConnInfo.build({
			keepAliveIdle: 30,
			keepAliveInterval: 5,
			keepAliveCount: 3,
			tcpUserTimeout: 10
		});

		Assert.isTrue(conninfo.indexOf("keepalives_idle='30'") >= 0, conninfo);
		Assert.isTrue(conninfo.indexOf("keepalives_interval='5'") >= 0, conninfo);
		Assert.isTrue(conninfo.indexOf("keepalives_count='3'") >= 0, conninfo);
		Assert.isTrue(conninfo.indexOf("tcp_user_timeout='10000'") >= 0, conninfo);
		// Unset stays unset: a keyword an older libpq does not know fails the
		// connection, so nothing is sent that was not asked for.
		Assert.equals(-1, PostgresConnInfo.build({}).indexOf("keepalives"));
		Assert.equals(-1, PostgresConnInfo.build({}).indexOf("tcp_user_timeout"));
	}

	public function testNegativeLimitsAreRefused():Void {
		Assert.raises(() -> PostgresConnInfo.build({statementTimeout: -1}));
		Assert.raises(() -> PostgresConnInfo.build({tcpUserTimeout: -0.5}));
		Assert.raises(() -> PostgresConnInfo.build({keepAliveIdle: -1}));
		Assert.raises(() -> PostgresConnInfo.build({statementTimeout: Math.NaN}));
	}

	public function testParametersAreSortedAndTheirKeywordsChecked():Void {
		var conninfo:String = PostgresConnInfo.build({connectionParameters: ["target_session_attrs" => "read-write", "application_name" => "app"]});

		Assert.isTrue(conninfo.indexOf("application_name='app'") < conninfo.indexOf("target_session_attrs='read-write'"), conninfo);

		// A keyword is not quoted, so one carrying a space or an equals sign
		// could write a second keyword into the string.
		Assert.raises(() -> PostgresConnInfo.build({connectionParameters: ["application_name host" => "x"]}));
		Assert.raises(() -> PostgresConnInfo.build({connectionParameters: ["a=b" => "x"]}));
	}
}
