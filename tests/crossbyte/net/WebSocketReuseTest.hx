package crossbyte.net;

import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.events.WebSocketMessageEvent;
import crossbyte.events._internal.Arrivals;
import crossbyte.io.ByteArray;
import crossbyte.io.ByteArray.ByteArrayData;
import crossbyte.net.ObjectEncoding;
import utest.Assert;
import utest.Async;

/**
	The red team's cases against a WebSocket session's reused message and
	event: what the session goes on holding once a call has returned, and
	what one message's handling leaves behind for the next.
**/
@:access(crossbyte.net.WebSocket)
class WebSocketReuseTest extends utest.Test {
	#if (cpp || java || jvm || eval || nodejs)
	/**
		A compressed message is inflated into a buffer made for it, handed
		out in the session's one `WebSocketMessageEvent`, and left there once
		the call has returned: neither emptied, as `data`'s doc says every
		message is, nor let go past `Arrivals.KEEP`, as `Event`'s doc and the
		CHANGELOG say every payload is. The event keeps it until the next
		message, a whole `MAX_MESSAGE_SIZE` for each connection, for as
		long as its peer stays quiet, from a message of a few kilobytes on
		the wire.
	**/
	@:timeout(20000)
	public function testACompressedMessageIsLetGoOnceItsCallReturns(async:Async):Void {
		var server = new ServerWebSocket();
		server.perMessageDeflate = true;
		var sessions:Array<WebSocket> = [];
		server.addEventListener(ServerSocketConnectEvent.CONNECT, (e:ServerSocketConnectEvent) -> sessions.push(cast e.socket));
		server.bind(0, "127.0.0.1");
		server.listen();

		var length:Int = 512 * 1024;
		var heard:Array<Int> = [];
		var compressed:Array<Bool> = [];
		var kept:Array<ByteArray> = [];

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var client = new WebSocket();
			client.perMessageDeflate = true;
			client.connect("127.0.0.1", server.localPort);

			NetPump.until(() -> client.connected && sessions.length > 0, 5.0, function(_) {
				if (sessions.length == 0) {
					Assert.fail("no session");
					__finish(async, server, sessions, client);
					return;
				}
				var session = sessions[0];
				session.addEventListener(WebSocketMessageEvent.MESSAGE, function(e:WebSocketMessageEvent):Void {
					heard.push(e.data.length);
					compressed.push(session.compressed);
					kept.push(e.data);
				});

				// Half a megabyte of one letter: a couple of kilobytes once
				// compressed, and the whole of it once inflated.
				var text = new StringBuf();
				for (_ in 0...length) {
					text.addChar("a".code);
				}
				client.sendText(text.toString());

				NetPump.until(() -> heard.length >= 1, 10.0, function(_) {
					Assert.same([length], heard, "the message did not arrive whole");
					Assert.same([true], compressed, "the session did not agree to compression, so this proves nothing");
					#if !crossbyte_fresh_events
					// Emptied once its call returned, as data's doc says,
					// and killed under the check, which it is.
					Assert.equals(0, kept[0].length, "a compressed message kept past its call still read whole");
					#end
					#if !(crossbyte_fresh_events || crossbyte_check_events)
					// And nothing past KEEP held for the next message.
					var event:WebSocketMessageEvent = session.__messageEvent;
					var held:Int = event == null || event.data == null ? 0 : @:privateAccess (event.data : ByteArrayData).__length;
					Assert.isTrue(held <= Arrivals.KEEP, 'the session went on holding $held bytes of a message whose call had returned');
					#end
					__finish(async, server, sessions, client);
				});
			});
		});
	}
	#end

	/**
		Every message reads objects as a `ByteArray` made for it would, in
		`ByteArray.defaultObjectEncoding`, as every datagram does. A message
		is read into the session's one buffer, and its `objectEncoding` was
		never set again: one listener reading JSON left every message after
		it reading JSON, and an object sent in the default encoding was read
		as JSON.
	**/
	@:timeout(20000)
	public function testEveryMessageReadsObjectsInTheDefaultEncoding(async:Async):Void {
		var server = new ServerWebSocket();
		var sessions:Array<WebSocket> = [];
		server.addEventListener(ServerSocketConnectEvent.CONNECT, (e:ServerSocketConnectEvent) -> sessions.push(cast e.socket));
		server.bind(0, "127.0.0.1");
		server.listen();

		var encodings:Array<Int> = [];
		var objects:Array<String> = [];

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var client = new WebSocket();
			client.connect("127.0.0.1", server.localPort);

			NetPump.until(() -> client.connected && sessions.length > 0, 5.0, function(_) {
				if (sessions.length == 0) {
					Assert.fail("no session");
					__finish(async, server, sessions, client);
					return;
				}
				sessions[0].addEventListener(WebSocketMessageEvent.MESSAGE, function(e:WebSocketMessageEvent):Void {
					encodings.push(e.data.objectEncoding);
					// The first is a JSON message, and its listener says so.
					if (encodings.length == 1) {
						e.data.objectEncoding = ObjectEncoding.JSON;
					}
					try {
						objects.push(haxe.Json.stringify(e.data.readObject()));
					} catch (error:Dynamic) {
						objects.push("unreadable: " + Std.string(error));
					}
				});

				var json = new ByteArray();
				json.objectEncoding = ObjectEncoding.JSON;
				json.writeObject({kind: "json"});
				client.sendBinary(json);
				var plain = new ByteArray();
				plain.writeObject({kind: "default"});
				client.sendBinary(plain);

				NetPump.until(() -> objects.length >= 2, 10.0, function(_) {
					var standard:Int = ByteArray.defaultObjectEncoding;
					Assert.same([standard, standard], encodings, "a message did not start in the default object encoding: " + encodings.join(", "));
					Assert.same(['{"kind":"json"}', '{"kind":"default"}'], objects, "an object was read in another message's encoding: " + objects.join(" | "));
					__finish(async, server, sessions, client);
				});
			});
		});
	}

	private static function __finish(async:Async, server:ServerWebSocket, sessions:Array<WebSocket>, client:WebSocket):Void {
		try client.close() catch (_:Dynamic) {}
		for (session in sessions) {
			try session.close() catch (_:Dynamic) {}
		}
		try server.close() catch (_:Dynamic) {}
		NetPump.wait(0.1, () -> async.done());
	}
}
