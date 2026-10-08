package crossbyte.db;

#if (sys && !js)
import crossbyte.db._internal.SocketKeepAlive;
import crossbyte.db.mongodb.FakeMongoServer;
import crossbyte.db.mongodb.MongoConnection;
import crossbyte.test.Require;
import utest.Assert;
#if cpp
import crossbyte.db.fakemysql.FakeMySQLServer;
import crossbyte.db.mysql.MySQLConnection;
import crossbyte.db.mysql.MySQLError;
#end

/**
	TCP keepalive on the database clients, so a server that has gone silent
	(a partition, a host that died without closing) is noticed rather
	than waited on, and a pool worker waiting on it is let go.

	MySQL's client sets it at 60/10/6, and MongoDB's the same, since with no
	socket timeout by default a read waiting on such a server would wait
	for good. Postgres's is libpq's, whose timings are the system's: two hours.

	A server that only stops answering does not show it: its system still
	acknowledges every keepalive probe. `DeadPeerProbe` makes one that drops
	them, as a partition does, on Linux; elsewhere the cases that need it
	pass over it, and what is checked is the keepalive the socket has.
**/
@:access(crossbyte.db.mongodb.MongoConnection)
class DatabaseKeepAliveTest extends utest.Test {
	/** How long a silenced test server waits before closing, if keepalive never notices. **/
	private static inline var SILENCE_SECONDS:Float = 20.0;

	public function testMongoSetsKeepAliveOnItsSocket():Void {
		var server = new FakeMongoServer().start();

		try {
			var connection = new MongoConnection();
			connection.open({host: "127.0.0.1", port: server.port});
			var state:Array<Int> = SocketKeepAlive.state(connection.__wire.socket);
			connection.close();

			#if cpp
			Assert.equals(1, state[0], "keepalive is off");

			// Where the system reports them: Linux, and Windows 10 1709 on.
			if (Sys.systemName() == "Linux" || Sys.systemName() == "Windows") {
				Assert.equals("60 10 6", state.slice(1).join(" "));
			}
			#elseif jvm
			Assert.equals(1, state[0], "keepalive is off");

			// The timings need Java 11's ExtendedSocketOptions.
			if (state[1] != -1) {
				Assert.equals("60 10 6", state.slice(1).join(" "));
			}
			#else
			// The interpreter, hl and neko have no such option.
			Assert.equals("-1 -1 -1 -1", state.join(" "));
			#end

			var given = new MongoConnection();
			given.open({host: "127.0.0.1", port: server.port, keepAliveIdle: 45, keepAliveInterval: 7, keepAliveCount: 4});
			var asked:Array<Int> = SocketKeepAlive.state(given.__wire.socket);
			given.close();

			var off = new MongoConnection();
			off.open({host: "127.0.0.1", port: server.port, keepAlive: false});
			var none:Array<Int> = SocketKeepAlive.state(off.__wire.socket);
			off.close();

			#if cpp
			if (Sys.systemName() == "Linux" || Sys.systemName() == "Windows") {
				Assert.equals("45 7 4", asked.slice(1).join(" "));
			}

			Assert.equals(0, none[0], "keepalive is on when asked not to be");
			#elseif jvm
			Assert.equals(0, none[0], "keepalive is on when asked not to be");
			#else
			Assert.equals(-1, asked[0]);
			#end
		} catch (e:Dynamic) {
			Assert.fail("escaped: " + Std.string(e));
		}

		server.stop();
	}

	/**
		A MongoDB server that falls silent mid-command, as a partitioned host
		does, is found within the keepalive window (here a second idle, then
		two probes a second apart), rather than when the server itself gives
		up, 20 seconds on: for ever, with a real partition.
	**/
	public function testADeadMongoServerIsFoundWithinTheKeepAliveWindow():Void {
		if (!DeadPeerProbe.isSupported) {
			Assert.pass("needs a socket filter, which only Linux has");
			return;
		}

		var server = new FakeMongoServer().start();
		var silenced:Bool = false;

		server.handleNext("ping", function(client) {
			// After the command has arrived, and been acknowledged: the client
			// then waits on a connection with nothing in flight, which is
			// what keepalive probes.
			silenced = DeadPeerProbe.silence(client);
			var until:Float = haxe.Timer.stamp() + SILENCE_SECONDS;

			while (haxe.Timer.stamp() < until && !server.stopping()) {
				crossbyte.sys.System.sleep(0.05);
			}
		});

		var connection = new MongoConnection();
		connection.open({host: "127.0.0.1", port: server.port, keepAliveIdle: 1, keepAliveInterval: 1, keepAliveCount: 2});

		var started:Float = haxe.Timer.stamp();
		var answered:Bool = connection.ping();
		var took:Float = haxe.Timer.stamp() - started;

		Assert.isTrue(silenced, "the probe could not silence the server");
		Assert.isFalse(answered, "a silent server answered");
		Assert.isTrue(took < 10, 'a silent server was noticed after ${took}s, past its keepalive window of about 3 s');
		Assert.isFalse(connection.connected);

		server.stop();
	}

	#if cpp
	/**
		The same for MySQL, whose client keeps alive at 60/10/6: the model the
		others follow, shown working.
	**/
	public function testADeadMySQLServerIsFoundWithinTheKeepAliveWindow():Void {
		if (!DeadPeerProbe.isSupported) {
			Assert.pass("needs a socket filter, which only Linux has");
			return;
		}

		var server = new FakeMySQLServer();
		var silenced:Bool = false;

		server.onQuery = function(session, sql) {
			if (sql != "SELECT SILENT") {
				return false;
			}

			silenced = DeadPeerProbe.silence(@:privateAccess session.__socket);
			session.hang(SILENCE_SECONDS);
			session.__abort();
			return true;
		};
		server.start();

		var connection = new MySQLConnection();
		connection.open({
			host: "127.0.0.1",
			port: server.port,
			user: "app",
			password: "secret",
			database: "app",
			keepAliveIdle: 1,
			keepAliveInterval: 1,
			keepAliveCount: 2
		});

		var started:Float = haxe.Timer.stamp();
		var error:Null<MySQLError> = null;

		try {
			connection.request("SELECT SILENT");
		} catch (e:MySQLError) {
			error = e;
		}

		var took:Float = haxe.Timer.stamp() - started;
		connection.close();
		server.stop();

		Assert.isTrue(silenced, "the probe could not silence the server");
		Require.notNull(error);
		Assert.equals(2013, error.code, error.message);
		Assert.isTrue(took < 10, 'a silent server was noticed after ${took}s, past its keepalive window of about 3 s');
	}
	#end
}
#end
