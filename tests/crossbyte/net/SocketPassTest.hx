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
	A socket's raw write, which CrossByte's framers use, and how many
	connections a listener's queue holds before the system refuses one.
**/
class SocketPassTest extends utest.Test {
	#if (sys && !(js || php))
	/**
		A frame held as `Bytes` goes out as it is, with no ByteArray made around
		it, as HTTP/2 and the other framers write their frames.
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
		Connections past 200 wait in the listen queue on Windows rather than
		being refused. Windows grants 200 to a backlog asked as a number, the
		default's included, and refuses the 201st connection to arrive while
		none has been accepted; asked as `SOMAXCONN_HINT`, it holds them all.

		Elsewhere the system's own limit applies (`somaxconn` on Linux, 128
		on macOS), so only Windows is held to the number, and only where
		`listen()` can ask Windows that way: not the jvm or eval.
	**/
	public function testABurstPastTwoHundredWaitsInTheListenQueue():Void {
		#if (cpp || hl || neko)
		if (!crossbyte.sys.System.isWindows) {
			Assert.pass();
			return;
		}

		var server = new ServerSocket();
		var waiting:Array<sys.net.Socket> = [];
		var connected:Int = 0;
		var failure:String = null;

		try {
			server.bind(0, "127.0.0.1");
			server.listen();

			// Nothing is accepted (the runtime is never pumped), so every
			// one of these waits in the queue.
			for (_ in 0...300) {
				var peer = new sys.net.Socket();
				waiting.push(peer);
				peer.connect(new Host("127.0.0.1"), server.localPort);
				connected++;
			}
		} catch (e:Dynamic) {
			failure = Std.string(e);
		}
		Assert.equals(300, connected, "connection " + (connected + 1) + " of 300 was refused: " + failure);

		for (peer in waiting) {
			try peer.close() catch (_:Dynamic) {}
		}
		try server.close() catch (_:Dynamic) {}
		#else
		Assert.pass();
		#end
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
