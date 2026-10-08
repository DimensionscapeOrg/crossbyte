package crossbyte.net;

import crossbyte.core.CrossByte;
import crossbyte.errors.IllegalOperationError;
import crossbyte.errors.RangeError;
#if !(js && !nodejs)
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.io.ByteArray;
#end
import utest.Assert;

/**
	A TCP socket's kernel buffers: `Socket.receiveBufferSize` and
	`sendBufferSize`, and a `ServerSocket`'s for what it accepts. Natively
	and on the jvm they reach the system; elsewhere asking for one says it
	cannot be done.
**/
class SocketBufferSizeTest extends utest.Test {
	/**
		Natively and on the jvm the support flag says so; everywhere else it
		says not, and asking throws rather than taking a size that would
		never be applied.
	**/
	public function testTheFlagSaysWhereASizeCanBeAsked():Void {
		#if (cpp || java || jvm)
		Assert.isTrue(Socket.bufferSizeSupported);
		#else
		Assert.isFalse(Socket.bufferSizeSupported);
		var socket = new Socket();
		var refused:Dynamic = null;
		try {
			socket.receiveBufferSize = 32 * 1024;
		} catch (e:IllegalOperationError) {
			refused = e;
		}
		Assert.notNull(refused, "a receive buffer was taken where none can be applied");
		refused = null;
		try {
			socket.sendBufferSize = 32 * 1024;
		} catch (e:IllegalOperationError) {
			refused = e;
		}
		Assert.notNull(refused, "a send buffer was taken where none can be applied");
		Assert.equals(0, socket.receiveBufferSize);
		#if !(js && !nodejs)
		var server = new ServerSocket();
		refused = null;
		try {
			server.sendBufferSize = 32 * 1024;
		} catch (e:IllegalOperationError) {
			refused = e;
		}
		Assert.notNull(refused, "a server took a send buffer it cannot apply");
		#end
		#end
	}

	/** A buffer of nothing, or less, is refused on every target. **/
	public function testABufferOfNothingIsRefused():Void {
		var socket = new Socket();
		for (size in [0, -1]) {
			var refused:Dynamic = null;
			try {
				socket.receiveBufferSize = size;
			} catch (e:RangeError) {
				refused = e;
			}
			Assert.notNull(refused, "a receive buffer of " + size + " was taken");
		}
		#if !(js && !nodejs)
		var server = new ServerSocket();
		var refused:Dynamic = null;
		try {
			server.receiveBufferSize = 0;
		} catch (e:RangeError) {
			refused = e;
		}
		Assert.notNull(refused, "a server took a receive buffer of 0");
		#end
	}

	#if ((cpp || java || jvm) && !macro)
	/**
		Asked before `connect()`, a receive buffer is the connection's: it
		reads as asked until then, and once connected as the system granted
		it (what was asked, or twice that on Linux, which counts its own
		bookkeeping), not the system's default.
	**/
	public function testABufferAskedBeforeConnectingIsTheConnections():Void {
		var server = new ServerSocket();
		var accepted:Socket = null;
		var client = new Socket();
		try {
			server.addEventListener(ServerSocketConnectEvent.CONNECT, e -> accepted = e.socket);
			server.bind(0, "127.0.0.1");
			server.listen();

			Assert.equals(0, client.receiveBufferSize, "a socket asked for nothing read a size before it had a connection");
			client.receiveBufferSize = 24 * 1024;
			client.sendBufferSize = 20 * 1024;
			Assert.equals(24 * 1024, client.receiveBufferSize, "the size asked for did not read back before connecting");

			var connected = false;
			client.addEventListener(crossbyte.events.Event.CONNECT, _ -> connected = true);
			client.connect("127.0.0.1", server.localPort);
			pumpUntil(() -> connected && accepted != null, 5.0);
			Assert.isTrue(connected, "the client never connected");

			__granted(24 * 1024, client.receiveBufferSize, "the client's receive buffer");
			__granted(20 * 1024, client.sendBufferSize, "the client's send buffer");
		} catch (e:Dynamic) {
			Assert.fail("sizing a client's buffers failed: " + Std.string(e));
		}
		closeQuietly(client);
		closeQuietly(accepted);
		try server.close() catch (_:Dynamic) {}
	}

	/**
		A server's buffer sizes reach every connection it accepts, asked
		before `listen()` or after it.
	**/
	public function testAServersBuffersReachWhatItAccepts():Void {
		var server = new ServerSocket();
		var accepted:Array<Socket> = [];
		var clients:Array<Socket> = [];
		try {
			server.receiveBufferSize = 48 * 1024;
			server.sendBufferSize = 40 * 1024;
			Assert.equals(48 * 1024, server.receiveBufferSize);
			Assert.equals(40 * 1024, server.sendBufferSize);
			server.addEventListener(ServerSocketConnectEvent.CONNECT, e -> accepted.push(e.socket));
			server.bind(0, "127.0.0.1");
			server.listen();

			clients.push(__connect(server.localPort));
			pumpUntil(() -> accepted.length >= 1, 5.0);
			// Asked again once listening: the next connection takes it.
			server.sendBufferSize = 36 * 1024;
			clients.push(__connect(server.localPort));
			pumpUntil(() -> accepted.length >= 2, 5.0);

			Assert.equals(2, accepted.length, "the server did not accept both");
			if (accepted.length == 2) {
				__granted(48 * 1024, accepted[0].receiveBufferSize, "the first connection's receive buffer");
				__granted(40 * 1024, accepted[0].sendBufferSize, "the first connection's send buffer");
				__granted(36 * 1024, accepted[1].sendBufferSize, "the second connection's send buffer");
			}
		} catch (e:Dynamic) {
			Assert.fail("a server's buffer sizes failed: " + Std.string(e));
		}
		for (socket in clients.concat(accepted)) {
			closeQuietly(socket);
		}
		try server.close() catch (_:Dynamic) {}
	}

	/**
		What the sizes are for. A peer that reads nothing can make the system
		hold no more than the two buffers (its receive buffer and this side's
		send buffer), and everything past them waits in the socket's own
		output buffer, where `bytesPending` counts it and `maxOutputBufferSize`
		can bound it. Left to grow, Windows' loopback buffers would take all
		64 MB a test sends them.
	**/
	public function testASmallBufferKeepsASlowPeersBacklogWhereItIsCounted():Void {
		var server = new ServerSocket();
		var accepted:Socket = null;
		var peer = new sys.net.Socket();
		var total:Int = 8 * 1024 * 1024;
		try {
			server.sendBufferSize = 32 * 1024;
			server.addEventListener(ServerSocketConnectEvent.CONNECT, e -> accepted = e.socket);
			server.bind(0, "127.0.0.1");
			server.listen();

			// The peer never reads, and its own window is held small too.
			@:privateAccess peer.__askBufferSize(true, 32 * 1024);
			peer.connect(new sys.net.Host("127.0.0.1"), server.localPort);
			pumpUntil(() -> accepted != null, 5.0);
			Assert.notNull(accepted, "the server never accepted");
			if (accepted != null) {
				// In pieces, as a server sends a stream of messages: Windows
				// takes a single send whole whatever its buffer.
				var piece = new ByteArray();
				piece.length = 64 * 1024;
				var written:Int = 0;
				while (written < total) {
					accepted.writeBytes(piece);
					accepted.flush();
					written += piece.length;
					pumpUntil(() -> false, 0.002);
				}
				pumpUntil(() -> false, 0.3);
				var taken:Int = total - accepted.bytesPending;
				Assert.isTrue(taken < 1024 * 1024, "the system took " + taken + " of " + total
					+ " bytes a peer reading nothing was sent: the buffers asked for were not what held it");
				Assert.isTrue(accepted.bytesPending > 0, "nothing waited in the socket");
			}
		} catch (e:Dynamic) {
			Assert.fail("the held backlog failed: " + Std.string(e));
		}
		try peer.close() catch (_:Dynamic) {}
		closeQuietly(accepted);
		try server.close() catch (_:Dynamic) {}
	}

	/**
		Granted is what was asked, or as much again: Linux keeps twice what is
		asked. A system that rounds up a little is allowed for.
	**/
	private static function __granted(asked:Int, granted:Int, what:String):Void {
		Assert.isTrue(granted >= asked && granted <= asked * 2 + 4096, what + " was " + granted + " bytes where " + asked + " were asked");
	}

	private static function __connect(port:Int):Socket {
		var socket = new Socket();
		socket.connect("127.0.0.1", port);
		return socket;
	}

	private static function pumpUntil(done:Void->Bool, timeout:Float):Void {
		var runtime = CrossByte.current();
		var deadline = haxe.Timer.stamp() + timeout;
		while (!done() && haxe.Timer.stamp() < deadline) {
			runtime.pump(1 / 60, 0);
			crossbyte.sys.System.sleep(0.001);
		}
	}

	private static function closeQuietly(socket:Socket):Void {
		try {
			if (socket != null && @:privateAccess socket.__socket != null) {
				socket.close();
			}
		} catch (_:Dynamic) {}
	}
	#end
}
