package crossbyte.rpc;

import crossbyte.core.CrossByte;
import crossbyte.ipc.LocalConnection;
import crossbyte.net.INetConnection;
import crossbyte.net.NetConnection;
import crossbyte.net.NetHost;
import haxe.io.Bytes;
import utest.Assert;

/**
	RPC over every transport CrossByte ships, a burst at a time: each session
	writes every frame in one buffer and hands it to its transport's `send`,
	which has to copy what it keeps (a TCP connection, a WebSocket, a
	reliable UDP session and a local IPC connection each send what one pass
	gathered when the pass ends, long after the buffer was written over).

	A burst of calls of different sizes, made in one pass, and the burst of
	answers the other side frames in one read: a transport that kept a frame
	rather than copying it sends some other call's bytes. Under
	`-D crossbyte_check_events` each frame is poisoned once its send
	returns, and one kept sends garbage.

	Not in the portable suite: these pump real sockets until something has
	happened, and on Node nothing happens until the pump returns.
**/
class RPCTransportTest extends utest.Test {
	static inline final BURST:Int = 24;

	public function setup():Void {
		CrossByte.current().pump(0, 0);
	}

	public function testABurstCrossesTcpWhole():Void {
		burstOver("tcp");
	}

	public function testABurstCrossesAWebSocketWhole():Void {
		// A client masks what it sends with secure random bytes, which the
		// interpreter, neko and HashLink have not got.
		#if (cpp || jvm || java)
		burstOver("ws");
		#else
		Assert.pass();
		#end
	}

	public function testABurstCrossesReliableUdpWhole():Void {
		if (!crossbyte.net.DatagramSocket.isSupported) {
			Assert.pass();
			return;
		}
		burstOver("rudp");
	}

	public function testABurstCrossesLocalIpcWhole():Void {
		#if (cpp && (windows || linux || mac || macos))
		var name = '__crossbyte_rpc_burst_${Std.int(haxe.Timer.stamp() * 1000)}_${Std.random(1000000)}';
		var server = new LocalConnection();
		var handler = new BurstHandler();
		var session:RPCSession<BurstCommands> = null;
		try {
			server.listen(name);
			var backend = new RPCSession(server, null, handler);
			var commands = new BurstCommands();
			session = RPCSession.dial('local://$name', commands);
			pumpUntil(() -> session.up, 5.0);
			Assert.isTrue(session.up, "the session never reached the listener");
			burst(commands, handler);
		} catch (e:Dynamic) {
			if (session != null) {
				session.close();
			}
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

	private static function burstOver(scheme:String):Void {
		var handler = new BurstHandler();
		var accepted:Array<RPCSession<Dynamic, Dynamic>> = [];
		var host:NetHost = null;
		var session:RPCSession<BurstCommands> = null;
		try {
			host = new NetHost(scheme + "://127.0.0.1:0", (connection:INetConnection) -> {
				accepted.push(new RPCSession(connection, null, handler));
			});
			host.listen();
			pumpUntil(() -> host.localPort != 0, 2.0);
			var commands = new BurstCommands();
			var connection = new NetConnection(scheme + "://127.0.0.1:" + host.localPort + (scheme == "ws" ? "/" : ""));
			session = new RPCSession<BurstCommands>(connection, commands);
			pumpUntil(() -> session.up && accepted.length > 0, 5.0);
			Assert.isTrue(session.up, '$scheme: the session never came up');
			burst(commands, handler);
		} catch (e:Dynamic) {
			closeQuietly(session, host);
			throw e;
		}
		closeQuietly(session, host);
	}

	/**
		`BURST` one-way calls and as many requests, each with bytes of a size
		and a pattern of its own, made without a pump between them, and then
		pumped until every answer is in.
	**/
	private static function burst(commands:BurstCommands, handler:BurstHandler):Void {
		var answers:Array<RPCResponse<Bytes>> = [];
		for (i in 0...BURST) {
			commands.store(i, blobOf(i));
			answers.push(commands.echo(i, blobOf(i + BURST)));
		}
		pumpUntil(() -> {
			for (answer in answers) {
				if (!answer.completed) {
					return false;
				}
			}
			return true;
		}, 10.0);

		for (i in 0...BURST) {
			Assert.isTrue(handler.stored.exists(i), 'call $i never arrived');
			if (handler.stored.exists(i)) {
				Assert.equals(0, handler.stored.get(i).compare(blobOf(i)), 'call $i arrived with another call\'s bytes');
			}
			final answer = answers[i];
			Assert.isTrue(answer.succeeded, 'request $i was not answered: ' + answer.error);
			if (answer.succeeded) {
				Assert.equals(0, answer.result.compare(blobOf(i + BURST)), 'request $i was answered with another answer\'s bytes');
			}
		}
	}

	/** Bytes of a length and a pattern that no other `i` has. **/
	private static function blobOf(i:Int):Bytes {
		final blob = Bytes.alloc(1 + (i * 97) % 700);
		for (k in 0...blob.length) {
			blob.set(k, (i * 31 + k) & 0xFF);
		}
		return blob;
	}

	private static function pumpUntil(done:Void->Bool, timeout:Float):Void {
		var runtime = CrossByte.current();
		var deadline = haxe.Timer.stamp() + timeout;
		while (!done() && haxe.Timer.stamp() < deadline) {
			runtime.pump(1 / 60, 0);
			crossbyte.sys.System.sleep(0.001);
		}
	}

	private static function closeQuietly(session:RPCSession<BurstCommands>, host:NetHost):Void {
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

private class BurstCommands extends RPCCommands {
	public function new() {}

	@:rpc public function store(id:Int, blob:Bytes):Void {}

	@:rpc public function echo(id:Int, blob:Bytes):RPCResponse<Bytes> {}
}

private class BurstHandler extends RPCHandler {
	public final stored:Map<Int, Bytes> = new Map();

	public function new() {}

	@:rpc public function store(id:Int, blob:Bytes):Void {
		stored.set(id, blob);
	}

	@:rpc public function echo(id:Int, blob:Bytes):Bytes {
		return blob;
	}
}
