package crossbyte.rpc;

import crossbyte.core.CrossByte;
import crossbyte.net.INetConnection;
import crossbyte.net.NetConnection;
import crossbyte.net.NetHost;
import crossbyte.net.Reason;
import crossbyte.net.Socket;
import haxe.io.Bytes;
import utest.Assert;

/**
	A peer that sends calls and never reads their answers, over TCP: the
	side answering stops holding answers for it once `maxOutputPending` wait
	unsent, and closes the connection saying why.

	Before, nothing bounded it. A TCP host's sockets have no output limit of
	their own, so every answer waited in the server's memory: one client
	flooding requests without reading took a server past 2 GB in twelve
	seconds.

	Not in the portable suite: it pumps real sockets.
**/
class RPCSlowPeerTest extends utest.Test {
	public function setup():Void {
		CrossByte.current().pump(0, 0);
	}

	public function testAPeerThatDoesNotReadItsAnswersIsClosed():Void {
		final handler = new SlowPeerHandler();
		var server:Null<RPCSession<Dynamic, Dynamic>> = null;
		var ended:Null<Reason> = null;
		var host:NetHost = null;
		var client:RPCSession<SlowPeerCommands> = null;
		try {
			host = new NetHost("tcp://127.0.0.1:0", (connection:INetConnection) -> {
				server = new RPCSession(connection, null, handler);
				server.maxOutputPending = 64 * 1024;
				server.onDown = reason -> ended = reason;
			});
			host.listen();
			pumpUntil(() -> host.localPort != 0, 2.0);
			// A client that takes in at most 16 KB it has not read, and reads
			// nothing: past that its socket stops reading, and the kernel's
			// buffers between the two fill.
			final socket = new Socket();
			socket.maxInputBufferSize = 16 * 1024;
			final connection = NetConnection.fromSocket(socket);
			final commands = new SlowPeerCommands();
			client = new RPCSession<SlowPeerCommands>(connection, commands);
			socket.connect("127.0.0.1", host.localPort);
			pumpUntil(() -> client.up && server != null, 5.0);
			Assert.isTrue(client.up, "the client never connected");
			connection.readEnabled = false;
			client.onDown = _ -> {};
			final blob = Bytes.alloc(1024);
			var sent:Int = 0;
			// Each call answered with 1 KB: 64 MB of answers, a burst a pass.
			while (ended == null && sent < 65536) {
				for (_ in 0...256) {
					commands.echo(blob).catchError(_ -> {});
					sent++;
				}
				pumpUntil(() -> false, 0.005);
			}
			pumpUntil(() -> ended != null, 2.0);
			Assert.notNull(ended, "a peer that read none of its answers was never closed: " + sent + " calls answered");
			if (ended != null) {
				Assert.stringContains("not reading", Std.string(ended));
			}
			Assert.isTrue(handler.echoes < 65536, "every call was answered for a peer that read none of them");
		} catch (error:Dynamic) {
			closeQuietly(client, host);
			throw error;
		}
		closeQuietly(client, host);
	}

	private static function pumpUntil(done:Void->Bool, timeout:Float):Void {
		final runtime = CrossByte.current();
		final deadline = haxe.Timer.stamp() + timeout;
		while (!done() && haxe.Timer.stamp() < deadline) {
			runtime.pump(1 / 60, 0);
			crossbyte.sys.System.sleep(0.001);
		}
	}

	private static function closeQuietly(session:Null<RPCSession<SlowPeerCommands>>, host:Null<NetHost>):Void {
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

private class SlowPeerCommands extends RPCCommands {
	public function new() {}

	@:rpc public function echo(blob:Bytes):RPCResponse<Bytes> {}
}

private class SlowPeerHandler extends RPCHandler {
	public var echoes:Int = 0;

	public function new() {}

	@:rpc public function echo(blob:Bytes):Bytes {
		echoes++;
		return blob;
	}
}
