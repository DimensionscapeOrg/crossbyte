package crossbyte.db;

#if cpp
import crossbyte.db.fakemysql.FakeMySQLServer;
import crossbyte.db.mysql.MySQLConfig;
import crossbyte.db.mysql.MySQLConnection;
import crossbyte.db.mysql.MySQLStatement;
import haxe.io.Bytes;
import utest.Assert;

/**
 * What the native MySQL client puts on the wire, against a server that logs
 * every byte it is sent (`fakemysql/FakeMySQLServer`).
 */
class MySQLNativeWireTest extends utest.Test {
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

	public function testANonAsciiQueryArrivesWhole():Void {
		// The client sent the query with its length in UTF-16 units rather
		// than UTF-8 bytes, so each extra byte of a non-ASCII character cut a
		// byte off the end. Measured against a logging server: this UPDATE
		// arrived as "... WHERE id = 1", changing another row.
		__server.start();
		var connection:MySQLConnection = __open();

		var sql:String = "UPDATE users SET city = 'Zürich' WHERE id = 12";
		connection.request(sql);

		Assert.equals(sql, __server.lastQuery());
		Assert.equals(Bytes.ofString(sql, UTF8).toHex(), __lastQueryBytes().toHex());

		connection.close();
	}

	public function testANonAsciiValueIsEscapedWhole():Void {
		// The escape buffer was sized the same way and escaped only the first
		// value.length bytes, so an escaped value lost its tail too: 'Zoë
		// \u{1F680}' went out followed by NUL bytes, with the quote and the
		// rest of the statement gone.
		__server.start();
		var connection:MySQLConnection = __open();

		var statement:MySQLStatement = new MySQLStatement();
		statement.sqlConnection = connection;
		statement.text = "UPDATE users SET name = :name WHERE id = 12345";
		statement.parameters.name = "Zoë \u{1F680} it's";

		try {
			statement.execute();
		} catch (_:Dynamic) {}

		Assert.equals("UPDATE users SET name = 'Zoë \u{1F680} it\\'s' WHERE id = 12345", __server.lastQuery());

		connection.close();
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

	private function __lastQueryBytes():Bytes {
		var queries = __server.eventsOf("query");
		return queries.length == 0 ? Bytes.alloc(0) : queries[queries.length - 1].bytes;
	}
}
#end
