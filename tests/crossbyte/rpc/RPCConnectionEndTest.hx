package crossbyte.rpc;

import crossbyte.core.CrossByte;
import crossbyte.ipc.LocalConnection;
import crossbyte.net.INetConnection;
import crossbyte.net.NetConnection;
import crossbyte.net.NetHost;
import crossbyte.net.ServerSocket;
import crossbyte.test.Require;
import utest.Assert;

/**
	A call waiting on an answer fails once its connection can carry none, over
	real transports, with the application's `onClose` set after the session.

	The session could not use `onClose` to hear of the end: it is the
	application's one callback, and set after the session was made it would
	replace the session's. So a call still waiting when the peer went away
	waited for good. The transports now tell the session themselves, before
	the application's callback, whenever that was set.

	Not in the portable suite: these pump real sockets until something has
	happened, and on Node nothing happens until the pump returns.
**/
class RPCConnectionEndTest extends utest.Test {
	public function testACallWaitingOverTcpFailsWhenThePeerHangsUp():Void {
		var server = new ServerSocket();
		var host:NetHost = null;
		var accepted:INetConnection = null;
		var connection:NetConnection = null;
		try {
			server.bind(0, "127.0.0.1");
			host = NetHost.fromServerSocket(server, c -> accepted = c);
			host.listen();
			connection = new NetConnection('tcp://127.0.0.1:${server.localPort}');
			var commands = new EndCommands();
			var session = new RPCSession<EndCommands>(connection, commands);
			var closed = false;
			// After the session, as an application naturally would.
			connection.onClose = _ -> closed = true;

			pumpUntil(() -> accepted != null && connection.connected, 2.0);
			var peer = Require.notNull(accepted, "the server never accepted");
			// The server side has no session, so neither call is ever
			// answered. It does read what it is sent before it hangs up, as a
			// peer that closes cleanly does: closing on unread bytes resets the
			// connection instead, and on interp a reset raised by a read is an
			// OCaml error no Haxe catch intercepts (see sys.net.Socket).
			var drained = 0;
			peer.onData = input -> {
				drained += input.bytesAvailable;
				input.position = input.length;
			};
			peer.readEnabled = true;

			// One call, so that the server having read anything means it has
			// read the call; both lanes are covered in RPCRobustnessTest.
			var waiting = commands.nameOf(1);
			pumpUntil(() -> drained > 0, 2.0);
			Assert.isTrue(drained > 0, "the call never reached the server");
			peer.close();
			pumpUntil(() -> waiting.completed, 2.0);

			Assert.isTrue(waiting.completed, "the call went on waiting");
			Assert.stringContains("RPC connection closed", waiting.error);
			Assert.isTrue(closed, "the application's onClose did not run");
		} catch (e:Dynamic) {
			closeQuietly(connection, host);
			throw e;
		}
		closeQuietly(connection, host);
	}

	public function testACallWaitingOverLocalIpcFailsWhenThePeerCloses():Void {
		#if (cpp && (windows || linux || mac || macos))
		var server = new LocalConnection();
		var client = new LocalConnection();
		try {
			var name = '__crossbyte_rpc_end_${Std.int(haxe.Timer.stamp() * 1000)}_${Std.random(1000000)}';
			server.listen(name);
			client.connect(name);
			var commands = new EndCommands();
			var session = new RPCSession<EndCommands>(client, commands);
			var closed = false;
			// On the LocalConnection itself, after the session: it tells the
			// session directly, so this does not take the close from it.
			client.onClose = _ -> closed = true;

			pumpUntil(() -> server.connected, 2.0);
			var compiled = commands.nameOf(1);
			server.close();
			pumpUntil(() -> compiled.completed, 2.0);

			Assert.isTrue(compiled.completed, "the call went on waiting");
			Assert.stringContains("RPC connection closed", compiled.error);
			Assert.isTrue(closed, "the application's onClose did not run");
		} catch (e:Dynamic) {
			client.close();
			server.close();
			throw e;
		}
		client.close();
		server.close();
		#else
		Assert.pass();
		#end
	}

	private static function pumpUntil(done:Void->Bool, timeout:Float):Void {
		var runtime = CrossByte.current();
		var deadline = haxe.Timer.stamp() + timeout;
		while (!done() && haxe.Timer.stamp() < deadline) {
			runtime.pump(1 / 60, 0);
			Sys.sleep(0.001);
		}
	}

	private static function closeQuietly(connection:NetConnection, host:NetHost):Void {
		try {
			if (connection != null) {
				connection.close();
			}
		} catch (_:Dynamic) {}
		try {
			if (host != null) {
				host.close();
			}
		} catch (_:Dynamic) {}
	}
}

private class EndCommands extends RPCCommands {
	public function new() {}

	@:rpc public function nameOf(id:Int):RPCResponse<String> {}
}
