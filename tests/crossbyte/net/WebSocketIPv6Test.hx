package crossbyte.net;

import crossbyte._internal.websocket.WebSocketHost;
import utest.Assert;
#if !(js && !nodejs)
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.events.WebSocketMessageEvent;
import utest.Async;
#end

/**
	A WebSocket client dials an IPv6 literal.

	The host it was given had to be a run of letters, digits, dots and
	hyphens, so `WebSocket.connect("::1", port)` threw "Invalid host" before a
	socket existed, on every target -- and a page's `Socket` read the same
	pattern.
**/
class WebSocketIPv6Test extends utest.Test {
	public function testAnIPv6LiteralIsAHost():Void {
		__splits("::1", "::1", "");
		__splits("[::1]", "::1", "");
		__splits("[::1]/chat", "::1", "chat");
		__splits("ws://[2001:db8::1]/a/b", "2001:db8::1", "a/b");
		__splits("2001:db8::1/chat?room=4", "2001:db8::1", "chat?room=4");
		__splits("fe80::1%eth0", "fe80::1%eth0", "");
		__splits("::ffff:127.0.0.1", "::ffff:127.0.0.1", "");

		// Names and IPv4 addresses read as they always did.
		__splits("example.com", "example.com", "");
		__splits("wss://example.com/socket", "example.com", "socket");
		__splits("127.0.0.1/x", "127.0.0.1", "x");

		Assert.isNull(WebSocketHost.split("[::1"), "an unclosed bracket was taken as a host");
		Assert.isNull(WebSocketHost.split("[example.com]"), "a bracketed name was taken as an IPv6 literal");
		Assert.isNull(WebSocketHost.split("[::1]:8080"), "a port after the literal was taken, though the port is given apart");
		Assert.isNull(WebSocketHost.split(""), "nothing was taken as a host");
	}

	public function testAnIPv6LiteralIsBracketedInAUrl():Void {
		Assert.equals("[::1]", WebSocketHost.forUrl("::1"));
		Assert.equals("[2001:db8::1]", WebSocketHost.forUrl("2001:db8::1"));
		Assert.equals("example.com", WebSocketHost.forUrl("example.com"));
		Assert.equals("127.0.0.1", WebSocketHost.forUrl("127.0.0.1"));
	}

	#if (cpp || java || jvm || nodejs)
	@:timeout(15000)
	public function testAClientDialsAnIPv6Loopback(async:Async):Void {
		var server = new ServerWebSocket();
		try {
			server.bind(0, "::1");
		} catch (e:Dynamic) {
			// No IPv6 loopback on this machine: nothing to dial.
			Assert.pass();
			async.done();
			return;
		}

		var sessions:Array<WebSocket> = [];
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) {
			var session:WebSocket = cast e.socket;
			sessions.push(session);
			session.addEventListener(WebSocketMessageEvent.MESSAGE, function(message:WebSocketMessageEvent) {
				session.sendText("echo " + message.text);
			});
		});
		server.listen();

		var client = new WebSocket();
		var opened:Bool = false;
		var failure:String = null;
		var echoed:String = null;
		client.addEventListener(Event.CONNECT, _ -> {
			opened = true;
			client.sendText("over six");
		});
		client.addEventListener(IOErrorEvent.IO_ERROR, (e:IOErrorEvent) -> failure = e.text);
		client.addEventListener(WebSocketMessageEvent.MESSAGE, (m:WebSocketMessageEvent) -> echoed = m.text);

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var refused:String = null;
			try {
				client.connect("::1", server.localPort);
			} catch (e:Dynamic) {
				refused = Std.string(e);
			}
			Assert.isNull(refused, "connect() refused an IPv6 literal: " + refused);

			NetPump.until(() -> echoed != null || failure != null || refused != null, 10.0, function(_) {
				Assert.isNull(failure, "the session failed: " + failure);
				Assert.isTrue(opened, "the session over IPv6 never opened");
				Assert.equals("echo over six", echoed);
				try client.close() catch (_:Dynamic) {}
				for (session in sessions) {
					try session.close() catch (_:Dynamic) {}
				}
				try server.close() catch (_:Dynamic) {}
				async.done();
			});
		});
	}
	#end

	private static function __splits(target:String, host:String, path:String, ?pos:haxe.PosInfos):Void {
		var split = WebSocketHost.split(target);
		Assert.notNull(split, '"$target" was refused as a host', pos);
		if (split != null) {
			Assert.equals(host, split.host, 'the host of "$target"', pos);
			Assert.equals(path, split.path, 'the path of "$target"', pos);
		}
	}
}
