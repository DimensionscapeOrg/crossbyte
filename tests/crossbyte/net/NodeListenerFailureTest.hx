package crossbyte.net;

import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.events.Event;
import crossbyte.events.ProgressEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.events.WebSocketCloseEvent;
import crossbyte.io.ByteArray;
import utest.Assert;
import utest.Async;

/**
	On Node, a listener that throws while handling one connection costs that
	connection and nothing else.

	A socket's events arrive from Node's own event loop rather than from
	anything of CrossByte's, so an exception thrown by a listener had nowhere
	to go but Node, which ended the process: one client sending something its
	handler could not parse took every other client down with it. Before the
	fix each of these cases ended the whole test run.
**/
class NodeListenerFailureTest extends utest.Test {
	#if nodejs
	@:timeout(15000)
	public function testAThrowingDataListenerClosesOnlyItsConnection(async:Async):Void {
		var server = new ServerSocket();
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) {
			var socket = e.socket;
			socket.addEventListener(ProgressEvent.SOCKET_DATA, function(_) {
				var text = socket.readUTFBytes(socket.bytesAvailable);
				if (text == "boom") {
					throw "one client's message could not be parsed";
				}
				socket.writeUTFBytes(text.toUpperCase());
				socket.flush();
			});
		});
		server.bind(0, "127.0.0.1");
		server.listen();

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var healthy = new WirePeer(server.localPort);
			var bad = new WirePeer(server.localPort);

			NetPump.wait(0.2, function() {
				bad.send(haxe.io.Bytes.ofString("boom"));

				NetPump.until(() -> bad.ended, 5.0, function(_) {
					Assert.isTrue(bad.ended, "the connection whose listener threw was left open");

					// And the other one is still served.
					healthy.send(haxe.io.Bytes.ofString("still here"));
					NetPump.until(() -> __text(healthy) == "STILL HERE", 5.0, function(_) {
						Assert.equals("STILL HERE", __text(healthy), "the healthy connection stopped being served");
						healthy.close();
						bad.close();
						try server.close() catch (_:Dynamic) {}
						async.done();
					});
				});
			});
		});
	}

	@:timeout(15000)
	public function testAThrowingConnectListenerClosesThatConnection(async:Async):Void {
		var server = new ServerSocket();
		var calls:Int = 0;
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(_) {
			calls++;
			throw "the connect handler broke";
		});
		server.bind(0, "127.0.0.1");
		server.listen();

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var first = new WirePeer(server.localPort);
			var second = new WirePeer(server.localPort);

			NetPump.until(() -> first.ended && second.ended, 5.0, function(_) {
				Assert.equals(2, calls, "the server stopped accepting after one connect listener threw");
				Assert.isTrue(first.ended && second.ended, "a connection whose connect listener threw was left open");
				first.close();
				second.close();
				try server.close() catch (_:Dynamic) {}
				async.done();
			});
		});
	}

	@:timeout(15000)
	public function testAThrowingWebSocketListenerClosesItsSessionWith1011(async:Async):Void {
		var server = new ServerWebSocket();
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) {
			var session:WebSocket = cast e.socket;
			session.addEventListener(ProgressEvent.SOCKET_DATA, function(_) {
				if (session.readUTFBytes(session.bytesAvailable) == "boom") {
					throw "one session's message could not be parsed";
				}
			});
		});
		server.bind(0, "127.0.0.1");
		server.listen();

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var client = new WebSocket();
			var code:Int = -1;
			client.addEventListener(Event.CLOSE, function(e:Event) {
				var close = Std.downcast(e, WebSocketCloseEvent);
				code = close == null ? 0 : close.code;
			});
			client.addEventListener(Event.CONNECT, function(_) {
				client.writeUTFBytes("boom");
				client.flush();
			});
			client.connect("127.0.0.1", server.localPort);

			NetPump.until(() -> code != -1, 5.0, function(_) {
				Assert.equals(1011, code, "the session whose listener threw did not close as a server error");
				try server.close() catch (_:Dynamic) {}
				async.done();
			});
		});
	}

	@:timeout(15000)
	public function testAThrowingDatagramListenerLeavesTheSocketListening(async:Async):Void {
		var receiver = new DatagramSocket();
		var heard:Array<String> = [];
		receiver.addEventListener(DatagramSocketDataEvent.DATA, function(e:DatagramSocketDataEvent) {
			var text = e.data.readUTFBytes(e.data.length);
			heard.push(text);
			if (text == "boom") {
				throw "one datagram could not be parsed";
			}
		});
		receiver.bind(0, "127.0.0.1");
		receiver.receive();

		var sender = new DatagramSocket();
		NetPump.until(() -> receiver.localPort != 0, 5.0, function(_) {
			for (text in ["boom", "after"]) {
				var bytes = new ByteArray();
				bytes.writeUTFBytes(text);
				sender.send(bytes, 0, bytes.length, "127.0.0.1", receiver.localPort);
			}

			NetPump.until(() -> heard.length >= 2, 5.0, function(_) {
				Assert.same(["boom", "after"], heard, "the socket stopped listening after one listener threw");
				sender.close();
				receiver.close();
				async.done();
			});
		});
	}

	private static function __text(peer:WirePeer):String {
		var bytes = peer.received.getBytes();
		@:privateAccess peer.received = new haxe.io.BytesBuffer();
		peer.received.addBytes(bytes, 0, bytes.length);
		return bytes.toString();
	}
	#end
}
