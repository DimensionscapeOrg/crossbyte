package crossbyte.net;

import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.ReliableDatagramSocketConnectEvent;
import crossbyte.events.ServerSocketConnectEvent;
import utest.Assert;
import utest.Async;

/**
	On Node, a session a child runtime's server accepted keeps its timers on
	that runtime.

	There is one thread, and a socket's callbacks run as the application's
	runtime, not the child's. A WebSocket session and a reliable one took
	their timers from whichever runtime was current: one armed in a
	callback, a heartbeat as the upgrade completed, a keepalive as the
	session connected, went on the application's scheduler, and was
	cleared on the child's, by handle, where the same number named some
	other timer or none.

	Node only: elsewhere a child has a thread of its own, and its callbacks
	run there.
**/
@:access(crossbyte.core.CrossByte)
@:access(crossbyte.net.WebSocket)
@:access(crossbyte._internal.websocket.WebSocket)
@:access(crossbyte.net.ReliableDatagramSocket)
class ChildRuntimeSessionTest extends utest.Test {
	#if nodejs
	private static inline var DEADLINE:Float = 10.0;

	@:timeout(20000)
	public function testAChildsWebSocketSessionKeepsItsHeartbeatOnTheChild(async:Async):Void {
		var server:ServerWebSocket = null;
		var accepted:WebSocket = null;
		var child = CrossByte.make(DEFAULT, HEAP, configured -> {
			configured.tps = 100;
			configured.addEventListener(Event.INIT, function(_) {
				server = new ServerWebSocket();
				server.addEventListener(ServerSocketConnectEvent.CONNECT, e -> accepted = cast e.socket);
				server.bind(0, "127.0.0.1");
				server.listen();
			});
		});

		var client = new Socket();
		NetPump.until(() -> server != null && server.localPort != 0, DEADLINE, function(_) {
			client.addEventListener(Event.CONNECT, function(_) {
				client.writeUTFBytes("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
					+ "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n");
				client.flush();
			});
			client.connect("127.0.0.1", server.localPort);

			NetPump.until(() -> accepted != null, DEADLINE, function(_) {
				Assert.notNull(accepted, "the child's server accepted no session");
				if (accepted != null) {
					var heartbeat:Int = accepted.__webSocket.__heartbeat;
					Assert.isTrue(accepted.__webSocket.__heartbeatArmed, "the session has no heartbeat");
					Assert.isTrue(child.__timer.isActive(heartbeat), "the child's session armed its heartbeat on another runtime");
				}
				__end(child, () -> {
					try client.close() catch (_:Dynamic) {}
					try server.close() catch (_:Dynamic) {}
				}, async);
			});
		});
	}

	@:timeout(20000)
	public function testAChildsReliableSessionKeepsItsKeepaliveOnTheChild(async:Async):Void {
		var server:ReliableDatagramServerSocket = null;
		var accepted:ReliableDatagramSocket = null;
		var child = CrossByte.make(DEFAULT, HEAP, configured -> {
			configured.tps = 100;
			configured.addEventListener(Event.INIT, function(_) {
				server = new ReliableDatagramServerSocket();
				server.addEventListener(ReliableDatagramSocketConnectEvent.CONNECT, e -> accepted = e.socket);
				server.bind(0, "127.0.0.1");
				server.listen();
			});
		});

		var client = new ReliableDatagramSocket();
		NetPump.until(() -> server != null && server.localPort != 0, DEADLINE, function(_) {
			client.connect("127.0.0.1", server.localPort);

			NetPump.until(() -> accepted != null, DEADLINE, function(_) {
				Assert.notNull(accepted, "the child's server accepted no session");
				if (accepted != null) {
					var keepAlive:Int = accepted.__keepAliveHandle;
					Assert.isTrue(keepAlive != -1, "the session has no keepalive");
					Assert.isTrue(child.__timer.isActive(keepAlive), "the child's session armed its keepalive on another runtime");
				}
				__end(child, () -> {
					try client.abort() catch (_:Dynamic) {}
					try server.close() catch (_:Dynamic) {}
				}, async);
			});
		});
	}

	/** Closes what `close` closes on the child, ends it, and waits for it to end. **/
	private static function __end(child:CrossByte, close:Void->Void, async:Async):Void {
		child.post(function():Void {
			close();
			child.exit();
		});
		NetPump.until(() -> child.__didExit, DEADLINE, _ -> async.done());
	}
	#end
}
