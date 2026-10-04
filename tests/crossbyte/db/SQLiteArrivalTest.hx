package crossbyte.db;

#if cpp
import crossbyte.db.sql.sqlite.SQLiteConnection;
import crossbyte.db.sql.sqlite.SQLiteMode;
import crossbyte.db.sql.sqlite.SQLiteStatement;
import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.events.SQLErrorEvent;
import crossbyte.events.SQLEvent;
import crossbyte.io.ByteArray;
import crossbyte.net.DatagramSocket;
import haxe.io.Bytes;
import utest.Assert;

/**
	"Copy it to keep it", from the side that is handed the payload: each
	datagram stored, from inside its `DATA` listener, as a blob through an
	asynchronous SQLite connection, a server logging what its players send.

	An asynchronous statement keeps its parameters, "the values as they
	are now, bound on the worker later", in a copy of the map, which holds
	the payload itself, and binds it on the worker after the listener has
	returned and the socket has emptied it and filled it with the next.
**/
class SQLiteArrivalTest extends utest.Test {
	public function testADatagramStoredFromItsListenerIsWhatArrived():Void {
		var connection = new SQLiteConnection();
		var failures:Array<String> = [];
		connection.addEventListener(SQLErrorEvent.ERROR, (e:SQLErrorEvent) -> failures.push(e.error.details()));
		connection.openAsync(null, SQLiteMode.CREATE, false, 4096);
		__statement(connection, "CREATE TABLE packets (n INTEGER, body BLOB)", failures).execute();

		var server = new DatagramSocket();
		var client = new DatagramSocket();
		server.bind(0, "127.0.0.1");
		client.bind(0, "127.0.0.1");
		server.receive();

		var sent:Array<String> = ["the first player's input", "a second, longer player input", "third"];
		var arrived:Int = 0;
		var stored:Int = 0;
		server.addEventListener(DatagramSocketDataEvent.DATA, function(e:DatagramSocketDataEvent):Void {
			var insert = __statement(connection, "INSERT INTO packets (n, body) VALUES (:n, :body)", failures);
			insert.addEventListener(SQLEvent.RESULT, _ -> stored++);
			insert.parameters.n = arrived++;
			insert.parameters.body = e.data;
			insert.execute();
		});

		for (text in sent) {
			client.send(__bytesOf(text), 0, 0, "127.0.0.1", server.localPort);
		}
		__pumpUntil(() -> stored >= sent.length || failures.length > 0, 10.0);

		var select = __statement(connection, "SELECT n, body FROM packets ORDER BY n", failures);
		var rows:Array<Dynamic> = null;
		select.addEventListener(SQLEvent.RESULT, _ -> rows = select.getResult().data);
		select.execute();
		__pumpUntil(() -> rows != null || failures.length > 0, 10.0);

		try client.close() catch (_:Dynamic) {}
		try server.close() catch (_:Dynamic) {}
		connection.close();
		__pumpUntil(() -> false, 0.1);

		Assert.same([], failures);
		Assert.equals(sent.length, arrived, "not every datagram arrived");
		if (rows == null || rows.length != sent.length) {
			Assert.fail("not every datagram was stored: " + (rows == null ? "no rows" : rows.length + " rows"));
			return;
		}
		var bodies:Array<String> = [for (row in rows) row.body == null ? null : Bytes.ofData(row.body).toString()];
		Assert.same(sent, bodies, "what was stored was not the datagrams the listener stored: " + [for (body in bodies) __printable(body)].join(" | "));
	}

	/** `text` with anything but printable ASCII shown as `?`: a killed payload reads 0xDB. **/
	private static function __printable(text:Null<String>):String {
		if (text == null) {
			return "null";
		}
		var out = new StringBuf();
		for (i in 0...text.length) {
			var code:Int = StringTools.fastCodeAt(text, i);
			out.addChar(code >= 0x20 && code < 0x7F ? code : "?".code);
		}
		return '"' + out.toString() + '"';
	}

	private static function __statement(connection:SQLiteConnection, text:String, failures:Array<String>):SQLiteStatement {
		var statement = new SQLiteStatement();
		statement.sqlConnection = connection;
		statement.text = text;
		statement.addEventListener(SQLErrorEvent.ERROR, (e:SQLErrorEvent) -> failures.push(e.error.details()));
		return statement;
	}

	private static function __bytesOf(text:String):ByteArray {
		var bytes = new ByteArray();
		bytes.writeUTFBytes(text);
		bytes.position = 0;
		return bytes;
	}

	private static function __pumpUntil(done:Void->Bool, seconds:Float):Void {
		var runtime = crossbyte.core.CrossByte.current();
		var deadline:Float = haxe.Timer.stamp() + seconds;
		while (!done() && haxe.Timer.stamp() < deadline) {
			runtime.pump(1 / 120, 0);
			crossbyte.sys.System.sleep(0.001);
		}
	}
}
#end
