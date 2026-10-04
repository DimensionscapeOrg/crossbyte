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
		// And keepalive's timings, which libpq left to the system.
		Assert.equals("host='127.0.0.1' port='5432' dbname='postgres' connect_timeout='5' keepalives_idle='60' keepalives_interval='10' keepalives_count='6'",
			PostgresConnInfo.build({}));
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
		// tcp_user_timeout stays unset unless asked for: libpq before 12 does
		// not know it, and a keyword it does not know fails the connection.
		Assert.equals(-1, PostgresConnInfo.build({}).indexOf("tcp_user_timeout"));
	}

	/**
		Keepalive has MySQL's timings unless told otherwise. libpq turns it on
		but leaves the timings to the system, two hours before the first
		probe, so a pooled connection to a host gone silent held its worker
		that long. keepalives_* are libpq 9.0's, as old as anything that loads.
	**/
	public function testKeepAliveHasTimingsByDefault():Void {
		var conninfo:String = PostgresConnInfo.build({});

		Assert.isTrue(conninfo.indexOf("keepalives_idle='60'") >= 0, conninfo);
		Assert.isTrue(conninfo.indexOf("keepalives_interval='10'") >= 0, conninfo);
		Assert.isTrue(conninfo.indexOf("keepalives_count='6'") >= 0, conninfo);
		Assert.equals(-1, conninfo.indexOf("keepalives='0'"));

		// 0 is the system's own, passed on as libpq reads it.
		Assert.isTrue(PostgresConnInfo.build({keepAliveIdle: 0}).indexOf("keepalives_idle='0'") >= 0);

		// Off when asked, with no timings.
		var off:String = PostgresConnInfo.build({keepAlive: false});
		Assert.isTrue(off.indexOf("keepalives='0'") >= 0, off);
		Assert.equals(-1, off.indexOf("keepalives_idle"));

		// A keyword the caller passes itself is theirs, and not sent twice.
		var own:String = PostgresConnInfo.build({connectionParameters: ["keepalives_idle" => "300"]});
		Assert.equals(own.indexOf("keepalives_idle="), own.lastIndexOf("keepalives_idle="), own);
		Assert.isTrue(own.indexOf("keepalives_idle='300'") >= 0, own);
		Assert.isTrue(own.indexOf("keepalives_interval='10'") >= 0, own);
	}

	public function testNegativeLimitsAreRefused():Void {
		Assert.raises(() -> PostgresConnInfo.build({statementTimeout: -1}));
		Assert.raises(() -> PostgresConnInfo.build({tcpUserTimeout: -0.5}));
		Assert.raises(() -> PostgresConnInfo.build({keepAliveIdle: -1}));
		Assert.raises(() -> PostgresConnInfo.build({statementTimeout: Math.NaN}));
		// It was taken for no limit, without a word; 0 is that, asked for.
		Assert.raises(() -> PostgresConnInfo.build({connectTimeout: -1}), crossbyte.errors.ArgumentError);
		Assert.equals(-1, PostgresConnInfo.build({connectTimeout: 0}).indexOf("connect_timeout"));
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
