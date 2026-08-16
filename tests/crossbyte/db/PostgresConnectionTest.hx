package crossbyte.db;

import crossbyte.db.postgres.PostgresConfig;
import crossbyte.db.postgres.PostgresConnection;
import crossbyte.db.postgres.PostgresStatement;
import utest.Assert;

class PostgresConnectionTest extends utest.Test {
	public function testSupportFlagHonorsBuildTarget():Void {
		// Postgres is native on cpp and PHP-backed on php; no other target
		// has a driver. This asserted `false` everywhere but php, which
		// stopped being true when the native bridge landed — and went
		// unnoticed because the suite was registered only in `addAll`,
		// where cpp cases compile out.
		#if cpp
		Assert.isTrue(PostgresConnection.isSupported);
		#elseif !php
		Assert.isFalse(PostgresConnection.isSupported);
		#end
	}

	public function testOpenThrowsWhenUnsupported():Void {
		if (!PostgresConnection.isSupported) {
			var connection = new PostgresConnection();
			Assert.isTrue(throws(function() {
				connection.open({host: "127.0.0.1", database: "postgres"});
			}));
		} else {
			Assert.pass();
		}
	}

	public function testStatementRequiresConnection():Void {
		var statement = new PostgresStatement();
		Assert.isTrue(throws(function() {
			statement.execute();
		}));
	}

	private static function throws(fn:Void->Void):Bool {
		try {
			fn();
			return false;
		} catch (_:Dynamic) {
			return true;
		}
	}
}
