package crossbyte.rpc;

import crossbyte.core.CrossByte;
import crossbyte.ipc.LocalConnection;
import crossbyte.net.INetConnection;
import crossbyte.net.NetHost;
import crossbyte.net.Reason;
import crossbyte.net.ServerSocket;
import crossbyte.test.Require;
import utest.Assert;

/**
	A client session that dials its peer, and dials again when the
	connection ends: `RPCSession.dial`.

	A gateway to a backend built this itself, about thirty lines of it,
	dial, back off, bind a new session to each connection, and check the
	backend was up before each call, since a call on a closed TCP connection
	threw out of its stub. And a call that failed as the backend went had a
	message and no cause, so a gateway could not tell a backend gone from a
	backend refusing.

	Not in the portable suite: these pump real sockets until something has
	happened, and on Node nothing happens until the pump returns.
**/
class RPCDialTest extends utest.Test {
	public function setup():Void {
		CrossByte.current().pump(0, 0);
	}

	public function testADialledSessionComesBackAfterItsConnectionDrops():Void {
		var server = new ServerSocket();
		var host:NetHost = null;
		var accepted:Array<INetConnection> = [];
		var session:RPCSession<DialCommands> = null;
		try {
			server.bind(0, "127.0.0.1");
			host = NetHost.fromServerSocket(server, connection -> {
				accepted.push(connection);
				var backend = new RPCSession(connection, null, new DialHandler());
			});
			host.listen();

			var commands = new DialCommands();
			var ups = 0;
			var downs:Array<String> = [];
			var duringOutage:RPCResponse<Int> = null;
			session = RPCSession.dial('tcp://127.0.0.1:${server.localPort}', commands);
			session.onUp = () -> ups++;
			session.onDown = reason -> {
				downs.push(Std.string(reason));
				// Down: a call now fails at once, saying why.
				duringOutage = commands.echo(9);
			};

			// Down until its first connection is up.
			var early = commands.echo(1);
			Assert.isTrue(early.completed, "a call before the first connection waited");
			Assert.isTrue(isReason(early.cause), "a call while down was not failed with a Reason: " + early.cause);

			pumpUntil(() -> session.up, 5.0);
			Assert.equals(1, ups, "onUp was not told of the first connection");
			Assert.equals(7, answerOf(commands.echo(7)));

			// The backend drops its connections: the session comes back.
			for (connection in accepted) {
				connection.close();
			}
			pumpUntil(() -> ups == 2 && session.up, 5.0);

			Assert.equals(1, downs.length, "onDown was not told once: " + downs.join(", "));
			Require.notNull(duringOutage, "onDown made no call");
			Assert.isTrue(duringOutage.completed, "a call while down waited");
			Assert.isTrue(isReason(duringOutage.cause), "a call while down was not failed with a Reason: " + duringOutage.cause);
			Assert.equals(2, ups, "the session did not come back");
			Assert.equals(8, answerOf(commands.echo(8)), "the session came back and did not answer");

			// Closed, it dials no more.
			session.close();
			var connections = accepted.length;
			pump(1.5);
			Assert.equals(connections, accepted.length, "a closed session dialled again");
			Assert.isFalse(session.up);
		} catch (e:Dynamic) {
			closeQuietly(session, host);
			throw e;
		}
		closeQuietly(session, host);
	}

	public function testACallInFlightWhenTheConnectionGoesCarriesItsReason():Void {
		var server = new ServerSocket();
		var host:NetHost = null;
		var accepted:Array<INetConnection> = [];
		var session:RPCSession<DialCommands> = null;
		var handler = new DialHandler();
		try {
			server.bind(0, "127.0.0.1");
			host = NetHost.fromServerSocket(server, connection -> {
				accepted.push(connection);
				var backend = new RPCSession(connection, null, handler);
			});
			host.listen();
			var commands = new DialCommands();
			session = RPCSession.dial('tcp://127.0.0.1:${server.localPort}', commands);
			pumpUntil(() -> session.up, 5.0);
			Assert.isTrue(session.up, "the session never connected");

			// Answered by nobody before the backend goes.
			var inFlight = commands.never();
			pumpUntil(() -> handler.pending > 0, 2.0);
			Assert.equals(1, handler.pending, "the call never reached the backend");
			Assert.isFalse(inFlight.completed);
			for (connection in accepted) {
				connection.close();
			}
			pumpUntil(() -> inFlight.completed, 5.0);

			Assert.isTrue(inFlight.completed);
			Assert.isTrue(isReason(inFlight.cause), "the call failed with no cause to decide by: " + inFlight.error);
			Assert.isFalse(Std.isOfType(inFlight.cause, RPCError), "a backend gone looked like a refusal");
		} catch (e:Dynamic) {
			closeQuietly(session, host);
			throw e;
		}
		closeQuietly(session, host);
	}

	public function testADialledSessionWaitsForALocalListener():Void {
		#if (cpp && (windows || linux || mac || macos))
		var name = '__crossbyte_rpc_dial_${Std.int(haxe.Timer.stamp() * 1000)}_${Std.random(1000000)}';
		var commands = new DialCommands();
		var session = RPCSession.dial('local://$name', commands);
		var server = new LocalConnection();
		try {
			// Nobody listening: down, and a dial does not wait for a listener
			// on this thread.
			var early = commands.echo(1);
			Assert.isTrue(early.completed);
			Assert.isTrue(isReason(early.cause));

			server.listen(name);
			var backend = new RPCSession(server, null, new DialHandler());
			pumpUntil(() -> session.up, 5.0);

			Assert.isTrue(session.up, "the session never reached the listener");
			Assert.equals(5, answerOf(commands.echo(5)));
		} catch (e:Dynamic) {
			session.close();
			server.close();
			throw e;
		}
		session.close();
		server.close();
		#else
		Assert.pass();
		#end
	}

	// ------------------------------------------------------------------

	private static function isReason(value:Dynamic):Bool {
		return value != null && Type.getEnum(value) == Reason;
	}

	private static function answerOf(response:RPCResponse<Int>):Null<Int> {
		pumpUntil(() -> response.completed, 2.0);
		return response.completed && response.succeeded ? response.result : null;
	}

	private static function pumpUntil(done:Void->Bool, timeout:Float):Void {
		var runtime = CrossByte.current();
		var deadline = haxe.Timer.stamp() + timeout;
		while (!done() && haxe.Timer.stamp() < deadline) {
			runtime.pump(1 / 60, 0);
			crossbyte.sys.System.sleep(0.001);
		}
	}

	private static function pump(seconds:Float):Void {
		pumpUntil(() -> false, seconds);
	}

	private static function closeQuietly(session:RPCSession<DialCommands>, host:NetHost):Void {
		try {
			if (session != null) {
				session.close();
			}
		} catch (_:Dynamic) {}
		try {
			if (host != null) {
				host.close();
			}
		} catch (_:Dynamic) {}
	}
}

private class DialCommands extends RPCCommands {
	public function new() {}

	@:rpc public function echo(value:Int):RPCResponse<Int> {}

	@:rpc public function never():RPCResponse<Int> {}
}

private class DialHandler extends RPCHandler {
	public var pending:Int = 0;

	public function new() {}

	@:rpc public function echo(value:Int):Int {
		return value;
	}

	@:rpc public function never():crossbyte.Future<Int> {
		pending++;
		return new crossbyte.Completer<Int>().future;
	}
}
