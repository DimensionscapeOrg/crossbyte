package crossbyte.db;

#if !js
import crossbyte.db.fakemysql.ScriptedConnection;
import crossbyte.db.mongodb.FakeMongoServer;
import crossbyte.db.mongodb.MongoConnection;
import crossbyte.db.mongodb.MongoStatement;
import crossbyte.db.mongodb.bson.BsonDocument;
import crossbyte.db.mysql.MySQLConnection;
import crossbyte.db.mysql.MySQLStatement;
import crossbyte.db.postgres.PostgresStatement;
import crossbyte.db.sql.SQLResult;
import crossbyte.db.sql.sqlite.SQLiteConnection;
import crossbyte.db.sql.sqlite.SQLiteStatement;
import crossbyte.errors.SQLError;
import crossbyte.test.Require;
import utest.Assert;

/**
	`itemClass`, on every driver's statement: each row an instance of the
	class, made with no arguments and each field set from the column of its
	name, as AIR's `SQLStatement.itemClass` makes them, and a column the
	class has no field for an error, as AIR has it. Every driver reads it,
	so a row is not an anonymous object whatever it says.
**/
@:access(crossbyte.db.sql.sqlite.SQLiteConnection)
@:access(crossbyte.db.mysql.MySQLConnection)
@:access(crossbyte.db.postgres.PostgresStatement)
class ItemClassTest extends utest.Test {
	public function testSQLiteRowsAreInstancesOfTheItemClass():Void {
		var connection:SQLiteConnection = new SQLiteConnection();
		connection.__connection = __wire();
		var statement:SQLiteStatement = new SQLiteStatement();
		statement.sqlConnection = connection;
		__check(sql -> {
			statement.text = sql;
			statement.execute();
			return statement.getResult();
		}, c -> statement.itemClass = c);
	}

	public function testMySQLRowsAreInstancesOfTheItemClass():Void {
		var connection:MySQLConnection = new MySQLConnection();
		connection.__connection = __wire();
		var statement:MySQLStatement = new MySQLStatement();
		statement.sqlConnection = connection;
		__check(sql -> {
			statement.text = sql;
			statement.execute();
			return statement.getResult();
		}, c -> statement.itemClass = c);
	}

	public function testPostgresRowsAreInstancesOfTheItemClass():Void {
		var statement:PostgresStatement = new PostgresStatement();
		// Any object with request() serves; this one answers from a script.
		statement.__connection = __wire();
		__check(sql -> {
			statement.text = sql;
			statement.execute();
			return statement.getResult();
		}, c -> statement.itemClass = c);
	}

	public function testMongoDocumentsAreInstancesOfTheItemClass():Void {
		var server:FakeMongoServer = new FakeMongoServer().start();
		var connection:MongoConnection = new MongoConnection();

		try {
			connection.open({host: "127.0.0.1", port: server.port, database: "app"});
			server.seed("app.accounts", [
				new BsonDocument().add("_id", 1).add("name", "ada"),
				new BsonDocument().add("_id", 2).add("name", "bob")
			]);
			var statement:MongoStatement = new MongoStatement();
			statement.sqlConnection = connection;
			statement.itemClass = MongoAccount;
			statement.text = '{"find": "accounts", "sort": {"_id": 1}}';
			statement.execute();
			var rows:Array<Dynamic> = statement.getResult().data;
			Assert.equals(2, rows.length);
			Assert.isTrue(Std.isOfType(rows[0], MongoAccount), "a document was not made a MongoAccount");

			if (Std.isOfType(rows[0], MongoAccount)) {
				var first:MongoAccount = rows[0];
				Assert.equals(1, first._id);
				Assert.equals("ada", first.name);
			}

			// A field the class does not have is an error.
			statement.itemClass = Account;
			Assert.raises(() -> statement.execute(), SQLError);
		} catch (e:Dynamic) {
			Assert.fail("escaped: " + Std.string(e));
		}

		try connection.close() catch (_:Dynamic) {}
		server.stop();
	}

	/** Runs the checks every SQL driver shares, through `run` and `setClass`. **/
	private static function __check(run:String->SQLResult, setClass:Class<Dynamic>->Void):Void {
		setClass(Account);
		var result:SQLResult = run("SELECT id, name FROM accounts");
		Require.notNull(result);
		Assert.equals(2, result.data.length);
		Assert.isTrue(Std.isOfType(result.data[0], Account), "a row was not made an Account");

		if (Std.isOfType(result.data[0], Account)) {
			var first:Account = result.data[0];
			Assert.equals(1, first.id);
			Assert.equals("ada", first.name);
			// Made with its constructor, not left half-initialised.
			Assert.isTrue(first.constructed);
		}

		// A column the class has no field for is an error, as in AIR.
		Assert.raises(() -> run("SELECT id, name, extra FROM accounts"), SQLError);

		// Without one, rows are anonymous objects.
		setClass(null);
		result = run("SELECT id, name FROM accounts");
		Require.notNull(result);
		Assert.isFalse(Std.isOfType(result.data[0], Account));
		Assert.equals("bob", Reflect.field(result.data[1], "name"));
	}

	private static function __wire():ScriptedConnection {
		var wire:ScriptedConnection = new ScriptedConnection();
		wire.results.set("SELECT id, name FROM accounts", [{id: 1, name: "ada"}, {id: 2, name: "bob"}]);
		wire.results.set("SELECT id, name, extra FROM accounts", [{id: 1, name: "ada", extra: "x"}]);
		return wire;
	}
}

private class Account {
	public var id:Int;
	public var name:String;
	public var constructed:Bool = false;

	public function new() {
		constructed = true;
	}
}

private class MongoAccount {
	public var _id:Dynamic;
	public var name:String;

	public function new() {}
}
#end
