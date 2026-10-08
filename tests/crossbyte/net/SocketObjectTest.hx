package crossbyte.net;

import crossbyte.events.Event;
import crossbyte.events.ProgressEvent;
import crossbyte.events.ServerSocketConnectEvent;
import utest.Assert;
import utest.Async;

/**
	A socket reads and writes objects without being told how first.

	`objectEncoding` starts in `ObjectEncoding.DEFAULT`, as it does for
	`ByteArray`, `FileStream` and `ReliableDatagramSocket`. Left unset it
	would read 0 natively and on the jvm, which is AMF0 and throws on a
	build without `-lib format`, and null on Node, eval and in a page,
	which throws too: `writeObject` and `readObject` would throw on every
	socket until the application chose an encoding.
**/
class SocketObjectTest extends utest.Test {
	public function testASocketStartsInTheDefaultEncoding():Void {
		Assert.equals(ObjectEncoding.DEFAULT, new Socket().objectEncoding);
	}

	#if (cpp || java || jvm || eval || nodejs)
	@:timeout(15000)
	public function testAnObjectCrossesASocketInTheDefaultEncoding(async:Async):Void {
		var server = new ServerSocket();
		var received:Dynamic = null;
		var acceptedEncoding:Null<ObjectEncoding> = null;
		var failure:String = null;

		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) {
			var socket = e.socket;
			acceptedEncoding = socket.objectEncoding;
			socket.addEventListener(ProgressEvent.SOCKET_DATA, function(_) {
				try {
					received = socket.readObject();
				} catch (error:Dynamic) {
					failure = "readObject threw: " + Std.string(error);
				}
			});
		});
		server.bind(0, "127.0.0.1");
		server.listen();

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var client = new Socket();
			client.addEventListener(Event.CONNECT, function(_) {
				try {
					client.writeObject({name: "crossbyte", values: [1, 2, 3]});
					client.flush();
				} catch (error:Dynamic) {
					failure = "writeObject threw: " + Std.string(error);
				}
			});
			client.connect("127.0.0.1", server.localPort);

			NetPump.until(() -> received != null || failure != null, 5.0, function(_) {
				Assert.isNull(failure, failure);
				Assert.equals(ObjectEncoding.DEFAULT, acceptedEncoding, "an accepted socket did not start in the default encoding");
				Assert.isTrue(received != null && received.name == "crossbyte", "the object did not arrive: " + Std.string(received));
				Assert.same([1, 2, 3], received == null ? null : received.values);
				try client.close() catch (_:Dynamic) {}
				try server.close() catch (_:Dynamic) {}
				async.done();
			});
		});
	}
	#end
}
