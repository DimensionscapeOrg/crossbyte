package crossbyte.net;

#if (sys && !(js || php) && !eval)
import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.ProgressEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.io.ByteArray;
import crossbyte.test.Require;
#end
import utest.Assert;

/**
	What a TCP connection holds once its traffic is over.

	Each buffer kept the largest it had ever needed for as long as the
	connection was open: after one 16 KB message each way an idle connection
	held about 51 KB natively, where it held 1.5 KB before any. A connection
	now keeps its storage while it is busy, so a message read or written
	allocates nothing, and lets go of it once it has read and written
	nothing for a sweep of its registry; a buffer past 64 KB lets go as soon
	as it empties.

	Natively, on the jvm, and on neko and HashLink; not on eval, whose
	blocking sockets the echo below would stall.
**/
@:access(crossbyte.net.Socket)
@:access(crossbyte.core.CrossByte)
class SocketMemoryTest extends utest.Test {
	#if (sys && !(js || php) && !eval)
	/**
		After a 16 KB message each way both ends hold their storage while the
		connection is busy, and let go of all of it once it has been quiet
		for a sweep: one sweep finds it was busy, the next that it was not.
	**/
	public function testAQuietConnectionLetsGoOfItsBuffers():Void {
		__pair(function(server:ServerSocket, client:Socket, accepted:Socket):Void {
			__exchange(client, accepted, 16 * 1024);
			// The registry's own sweep held off, so the two below are the only
			// ones, and the connection busy again just before them.
			var registry = @:privateAccess CrossByte.current().__socketRegistry;
			@:privateAccess registry.__nextQuietSweep = haxe.Timer.stamp() + 1000;
			__exchange(client, accepted, 16 * 1024);
			Assert.isTrue(__storage(accepted.__input) > 0, "the busy connection kept nothing to read into");
			Assert.isTrue(__storage(accepted.__output) > 0, "the busy connection kept nothing to write from");
			Assert.isTrue(__held(accepted), "a connection holding storage was not watched for going quiet");

			// The sweep that finds it was busy keeps everything.
			__sweep();
			Assert.isTrue(__storage(accepted.__input) > 0, "a connection busy since the last sweep let go of its storage");

			// The next finds it quiet.
			__sweep();
			Assert.equals(0, __storage(accepted.__input), "a quiet connection kept what it read into");
			Assert.equals(0, __storage(accepted.__output), "a quiet connection kept what it wrote from");
			Assert.equals(0, __storage(client.__input), "a quiet client kept what it read into");
			Assert.equals(0, __storage(client.__output), "a quiet client kept what it wrote from");
			Assert.isFalse(__held(accepted), "a connection holding nothing was still watched");

			// And works as before.
			__exchange(client, accepted, 1000);
			Assert.isTrue(accepted.connected && client.connected);
			@:privateAccess registry.__nextQuietSweep = haxe.Timer.stamp();
		});
	}

	/**
		What the application has not read, or the peer not taken, is kept
		however quiet the connection.
	**/
	public function testWhatIsUnreadIsKeptHoweverQuiet():Void {
		__pair(function(server:ServerSocket, client:Socket, accepted:Socket):Void {
			var message = new ByteArray();
			message.length = 5000;
			client.writeBytes(message);
			client.flush();
			__pumpUntil(() -> accepted.bytesAvailable >= 5000, 5.0);
			Assert.equals(5000, accepted.bytesAvailable);
			__sweep();
			__sweep();
			__sweep();
			Assert.equals(5000, accepted.bytesAvailable, "unread bytes were let go of");
			var read = new ByteArray();
			accepted.readBytes(read, 0, 5000);
			Assert.equals(5000, read.length);
		});
	}

	/**
		A buffer grown past 64 KB lets go as soon as it empties, rather than
		holding what one large message made it grow to while smaller ones
		follow.
	**/
	public function testALargeBufferLetsGoAsSoonAsItEmpties():Void {
		__pair(function(server:ServerSocket, client:Socket, accepted:Socket):Void {
			var size:Int = 200 * 1024;
			var message = new ByteArray();
			message.length = size;
			client.writeBytes(message);
			client.flush();
			var received:Int = 0;
			var most:Int = 0;
			var sink = new ByteArray();
			accepted.addEventListener(ProgressEvent.SOCKET_DATA, _ -> {
				var storage:Int = __storage(accepted.__input);
				if (storage > most) {
					most = storage;
				}
				received += accepted.bytesAvailable;
				sink.clear();
				accepted.readBytes(sink, 0, accepted.bytesAvailable);
			});
			// One read pass takes up to 1 MB: read it all before draining it.
			__pumpUntil(() -> received >= size, 10.0);
			Assert.equals(size, received);
			// Drained: the next pass finds it empty and lets go.
			client.writeUTFBytes("x");
			client.flush();
			__pumpUntil(() -> received >= size + 1, 5.0);
			Assert.isTrue(__storage(accepted.__input) <= 64 * 1024, "a buffer past 64 KB kept " + __storage(accepted.__input) + " bytes once it had emptied");
		});
	}

	private static function __exchange(client:Socket, accepted:Socket, size:Int):Void {
		var message = new ByteArray();
		message.length = size;
		var echoed:Int = 0;
		var echo = (_:ProgressEvent) -> {
			if (accepted.bytesAvailable >= size) {
				var got = new ByteArray();
				accepted.readBytes(got, 0, size);
				accepted.writeBytes(got);
				accepted.flush();
			}
		};
		var back = (_:ProgressEvent) -> {
			if (client.bytesAvailable >= size) {
				var got = new ByteArray();
				client.readBytes(got, 0, size);
				echoed++;
			}
		};
		accepted.addEventListener(ProgressEvent.SOCKET_DATA, echo);
		client.addEventListener(ProgressEvent.SOCKET_DATA, back);
		client.writeBytes(message);
		client.flush();
		__pumpUntil(() -> echoed > 0, 5.0);
		accepted.removeEventListener(ProgressEvent.SOCKET_DATA, echo);
		client.removeEventListener(ProgressEvent.SOCKET_DATA, back);
		Assert.equals(1, echoed, "the message did not come back");
	}

	private static function __pair(run:(ServerSocket, Socket, Socket) -> Void):Void {
		var server = new ServerSocket();
		var accepted:Socket = null;
		var client = new Socket();
		try {
			server.addEventListener(ServerSocketConnectEvent.CONNECT, e -> accepted = e.socket);
			server.bind(0, "127.0.0.1");
			server.listen();
			var connected:Bool = false;
			client.addEventListener(Event.CONNECT, _ -> connected = true);
			client.connect("127.0.0.1", server.localPort);
			__pumpUntil(() -> connected && accepted != null, 5.0);
			Require.notNull(accepted);
			run(server, client, accepted);
		} catch (e:Dynamic) {
			Assert.fail("the connection failed: " + Std.string(e));
		}
		try client.close() catch (_:Dynamic) {}
		if (accepted != null) {
			try accepted.close() catch (_:Dynamic) {}
		}
		try server.close() catch (_:Dynamic) {}
	}

	/** One sweep of the runtime's registry for sockets gone quiet, as its clock would run. **/
	private static function __sweep():Void {
		@:privateAccess CrossByte.current().__socketRegistry.__sweepQuiet();
	}

	private static function __held(socket:Socket):Bool {
		return socket.__holdingStorage;
	}

	private static function __storage(buffer:ByteArray):Int {
		return buffer == null ? 0 : @:privateAccess (buffer : crossbyte.io.ByteArray.ByteArrayData).__length;
	}

	private static function __pumpUntil(done:Void->Bool, timeout:Float):Void {
		var runtime = CrossByte.current();
		var deadline = haxe.Timer.stamp() + timeout;
		while (!done() && haxe.Timer.stamp() < deadline) {
			runtime.pump(1 / 60, 0);
			crossbyte.sys.System.sleep(0.001);
		}
	}
	#end
}
