package crossbyte.net;

import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.events.WebSocketMessageEvent;
import haxe.io.Bytes;
import utest.Assert;
import utest.Async;

/**
	A WebSocket server's sessions need nothing a target may lack.

	Every accepted session drew a client's handshake key from `SecureRandom`
	before asking whether it was a client, and `SecureRandom` refuses on eval,
	hl and neko: each upgrade threw in the accept tick and the peer was reset,
	so a `ServerWebSocket` there accepted nothing at all. A server needs no
	randomness -- it answers a key, and sends its frames unmasked.
**/
class ServerWebSocketUpgradeTest extends utest.Test {
	#if (cpp || java || jvm || eval || hl || neko)
	@:timeout(15000)
	public function testARawClientUpgradesAndIsAnswered(async:Async):Void {
		var server = new ServerWebSocket();
		var sessions:Array<WebSocket> = [];
		var heard:Array<String> = [];
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) {
			var session:WebSocket = cast e.socket;
			sessions.push(session);
			session.addEventListener(WebSocketMessageEvent.MESSAGE, function(message:WebSocketMessageEvent) {
				heard.push(message.text);
				session.sendText("echo " + message.text);
			});
		});
		server.bind(0, "127.0.0.1");
		server.listen();

		var peer:WirePeer = null;
		function finish():Void {
			if (peer != null) {
				peer.close();
			}
			for (session in sessions) {
				try session.close() catch (_:Dynamic) {}
			}
			try server.close() catch (_:Dynamic) {}
			async.done();
		}

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			peer = new WirePeer(server.localPort);
			peer.upgrade("/");

			NetPump.until(() -> {
				peer.poll();
				return peer.head() != null || peer.ended;
			}, 5.0, function(_) {
				var head:Null<String> = peer.head();
				if (head == null || head.indexOf(" 101 ") < 0) {
					Assert.fail("the upgrade was not answered with 101: " + (head != null ? head : peer.ended ? "the connection was reset" : "nothing arrived"));
					finish();
					return;
				}

				peer.sendFrame(WirePeer.TEXT, Bytes.ofString("hello"));
				NetPump.until(() -> {
					peer.poll();
					return peer.framesOf(WirePeer.TEXT).length > 0 || peer.ended;
				}, 5.0, function(_) {
					Assert.equals(1, sessions.length, "the server never announced the session");
					Assert.same(["hello"], heard, "the session never heard the message");
					var echoed = peer.framesOf(WirePeer.TEXT);
					Assert.equals(1, echoed.length, "the session's answer never arrived");
					if (echoed.length > 0) {
						Assert.equals("echo hello", echoed[0].payload.toString());
					}
					finish();
				});
			});
		});
	}
	#end
}
