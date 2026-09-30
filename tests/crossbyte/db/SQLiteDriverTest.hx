package crossbyte.db;

#if !js
import crossbyte.db.fakemysql.ScriptedConnection;
import crossbyte.db.sql.SQLResult;
import crossbyte.db.sql.sqlite.SQLiteConnection;
import crossbyte.db.sql.sqlite.SQLiteStatement;
import utest.Assert;

/**
 * The SQLite statement's own logic, over a scripted connection rather than
 * SQLite, so it runs on every target the driver builds for; SQLite itself
 * opens only natively (`SQLiteNativeTest`).
 */
@:access(crossbyte.db.sql.sqlite.SQLiteConnection)
class SQLiteDriverTest extends utest.Test {
	public function testPagesComeBackInTheOrderTheyWereRead():Void {
		// Off cpp the pages waited in an Array read with pop(), newest first,
		// so a result paged ahead of getResult() came back last page first on
		// the jvm and in the interpreter. And each page taken after the last
		// had been read said it was complete.
		var wire:ScriptedConnection = new ScriptedConnection();
		wire.results.set("SELECT id FROM items", [for (id in 1...6) {id: id}]);
		var connection:SQLiteConnection = new SQLiteConnection();
		connection.__connection = wire;
		var statement:SQLiteStatement = new SQLiteStatement();
		statement.sqlConnection = connection;
		statement.text = "SELECT id FROM items";

		statement.execute(2);
		statement.next(2);
		statement.next(2);

		Assert.equals("1,2 3,4 5+", __pages(statement));
		Assert.isNull(statement.getResult());
	}

	/** Every page waiting, as its ids, with `+` after a complete one. **/
	private function __pages(statement:SQLiteStatement):String {
		var pages:Array<String> = [];
		var page:SQLResult = statement.getResult();

		while (page != null) {
			pages.push([for (row in page.data) Std.string(row.id)].join(",") + (page.complete ? "+" : ""));
			page = statement.getResult();
		}

		return pages.join(" ");
	}
}
#end
