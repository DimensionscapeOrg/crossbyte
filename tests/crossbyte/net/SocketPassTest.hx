package crossbyte.net;

#if (sys && !(js || php))
import crossbyte.core.CrossByte;
import crossbyte.events.ProgressEvent;
import crossbyte.events.ServerSocketConnectEvent;
import haxe.io.Bytes;
import sys.net.Host;
#end
import utest.Assert;

/**
	What one pass of the runtime does for a socket and a listener: the raw
	write CrossByte's framers use, and how many waiting connections one pass
	takes.
**/
class SocketPassTest extends utest.Test {
	#if (sys && !(js || php))
	/**
		A frame held as `Bytes` goes out as it is, with no ByteArray made around
		it. HTTP/2 and the other framers wrapped every frame in one to write it.
		Did not compile before: there was no such write.
	**/
	public function testRawBytesGoOutAsWritten():Void {
		var server = new ServerSocket();
		var client = new Socket();
		var received:String = "";
		var accepted:Socket = null;

		try {
			server.addEventListener(ServerSocketConnectEvent.CONNECT, (e:ServerSocketConnectEvent) -> {
				accepted = e.socket;
				accepted.addEventListener(ProgressEvent.SOCKET_DATA, (_:ProgressEvent) -> {
					received += accepted.readUTFBytes(accepted.bytesAvailable);
				});
			});
			server.bind(0, "127.0.0.1");
			server.listen();

			var connected = false;
			client.addEventListener(crossbyte.events.Event.CONNECT, _ -> connected = true);
			client.connect("127.0.0.1", server.localPort);
			pumpUntil(() -> connected && accepted != null, 5.0);

			var frame = Bytes.ofString("..frame..");
			@:privateAccess client.__writeRawBytes(frame, 2, 5);
			pumpUntil(() -> received.length >= 5, 5.0);
			Assert.equals("frame", received);

			var outside:Dynamic = null;
			try {
				@:privateAccess client.__writeRawBytes(frame, 6, 5);
			} catch (e:crossbyte.errors.RangeError) {
				outside = e;
			}
			Assert.notNull(outside, "a range past the bytes was written");
		} catch (e:Dynamic) {
			Assert.fail("a raw write failed: " + Std.string(e));
		}

		closeQuietly(client);
		if (accepted != null) {
			closeQuietly(accepted);
		}
		try server.close() catch (_:Dynamic) {}
	}

	#if !eval
	/**
		Connections waiting in the listen queue past `maxAcceptsPerTick` are
		taken by another pass at once, before the runtime waits. It took the
		cap's worth and left the rest for the next frame, in which a storm
		filled the queue, 200 on a client edition of Windows, and the
		kernel refused what arrived meanwhile. Before, one pass here accepted
		the cap's 16 of 120.

		Not on eval, whose blocking sockets make a client's connect wait for
		the accept that only the pump below can make.
	**/
	public function testAQueuedBurstIsTakenWithinOnePass():Void {
		var server = new ServerSocket();
		var accepted:Array<Socket> = [];
		var waiting:Array<sys.net.Socket> = [];
		var runtime = CrossByte.current();

		try {
			server.maxAcceptsPerTick = 16;
			server.addEventListener(ServerSocketConnectEvent.CONNECT, (e:ServerSocketConnectEvent) -> accepted.push(e.socket));
			server.bind(0, "127.0.0.1");
			server.listen();

			// Connected by the kernel, in the listen queue, before any pump.
			for (_ in 0...120) {
				var peer = new sys.net.Socket();
				peer.connect(new Host("127.0.0.1"), server.localPort);
				waiting.push(peer);
			}

			runtime.pump(2.0, 0);
			Assert.equals(120, accepted.length, "one pass took only " + accepted.length + " of 120 waiting connections");
		} catch (e:Dynamic) {
			Assert.fail("the burst failed: " + Std.string(e));
		}

		for (socket in accepted) {
			closeQuietly(socket);
		}
		for (peer in waiting) {
			try peer.close() catch (_:Dynamic) {}
		}
		try server.close() catch (_:Dynamic) {}
	}
	#end

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
