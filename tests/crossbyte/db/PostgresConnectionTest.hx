package crossbyte.db;

import crossbyte.db.postgres.PostgresConfig;
import crossbyte.db.postgres.PostgresConnection;
import crossbyte.db.postgres.PostgresStatement;
import utest.Assert;

@:access(crossbyte.db.postgres.PostgresConnection)
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

	public function testFallbackEscapeLeavesBackslashesAlone():Void {
		// escape() falls back to a hand-rolled implementation when there is no
		// libpq connection to ask. It doubled backslashes, which is right only
		// for a server with standard_conforming_strings off -- a setting
		// PostgreSQL has defaulted away from since 9.1. On any modern server a
		// backslash carries no meaning in an ordinary string literal, so
		// doubling it stores two where the caller wrote one: silent corruption
		// of paths, regular expressions and UNC names.
		var connection = new PostgresConnection();
		var backslash:String = String.fromCharCode(92);
		var path:String = "C:" + backslash + "Users" + backslash + "app";

		Assert.isFalse(connection.connected);
		Assert.equals(path, connection.escape(path));
		Assert.equals("'" + path + "'", connection.quote(path));
	}

	public function testFallbackEscapeStillDoublesQuotes():Void {
		// The half that was always right, and has to stay right: a quote ends
		// the literal unless it is doubled.
		var connection = new PostgresConnection();

		Assert.equals("O''Brien", connection.escape("O'Brien"));
		Assert.equals("''", connection.escape("'"));
	}

	public function testGeneratedSavepointNamesDoNotRepeat():Void {
		// The name came from haxe.Timer.stamp() in microseconds through
		// Std.int, the same scheme SQLiteConnection used: 2000 generated back
		// to back produced 47 duplicates there, and the value overflows Int
		// about 36 minutes into a process. Two savepoints sharing a name make
		// RELEASE and ROLLBACK TO act on the wrong one.
		var connection = new PostgresConnection();
		var seen = new Map<String, Bool>();
		var distinct:Int = 0;

		for (i in 0...2000) {
			var name:String = connection.__sanitizeSavePoint(null);

			if (!seen.exists(name)) {
				seen.set(name, true);
				distinct++;
			}
		}

		Assert.equals(2000, distinct);
	}

	public function testExplicitSavepointNameIsReducedToAnIdentifier():Void {
		// The name is interpolated into SAVEPOINT, RELEASE and ROLLBACK TO, so
		// it has to be an identifier and nothing else.
		var connection = new PostgresConnection();

		Assert.equals("keep_me_1", connection.__sanitizeSavePoint("keep_me_1"));
		Assert.equals("a__DROP_TABLE_t____", connection.__sanitizeSavePoint("a; DROP TABLE t; --"));
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
