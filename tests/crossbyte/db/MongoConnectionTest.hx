package crossbyte.db;

import crossbyte.db.mongodb.MongoConfig;
import crossbyte.db.mongodb.MongoConnection;
import crossbyte.db.mongodb.MongoStatement;
import utest.Assert;

class MongoConnectionTest extends utest.Test {
	public function testSupportFlagIsFalseInNonPHPBuilds():Void {
		#if !php
		Assert.isFalse(MongoConnection.isSupported);
		#end
	}

	public function testOpenThrowsWhenUnsupported():Void {
		if (!MongoConnection.isSupported) {
			var connection = new MongoConnection();
			Assert.isTrue(throws(function() {
				connection.open({host: "127.0.0.1", database: "admin"});
			}));
		} else {
			Assert.pass();
		}
	}

	public function testStatementRequiresConnection():Void {
		var statement = new MongoStatement();
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
