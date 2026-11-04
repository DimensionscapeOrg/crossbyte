package crossbyte.http;

import crossbyte.events.Event;
import crossbyte.events.ProgressEvent;
import crossbyte.net.Socket;
import utest.Assert;
import utest.Async;

/**
 * `HTTPServerConfig.requestIdleTimeout`: silence is what ends a request, not
 * how long it takes, so an upload that keeps moving outlives it and one that
 * stops does not. `requestTimeout` still bounds the whole.
 */
@:timeout(20000)
class HTTPRequestIdleTimeoutTest extends utest.Test {
	public function testItIsOffByDefault():Void {
		Assert.equals(0.0, new HTTPServerConfig("127.0.0.1", 0).requestIdleTimeout);
	}

	/** A request that stops arriving is `408`, with `requestTimeout` off and nothing else to end it. **/
	public function testARequestThatFallsSilentIs408(async:Async):Void {
		var server:HTTPServer = __serve(config -> {
			config.requestTimeout = 0;
			config.requestIdleTimeout = 0.3;
		});

		__trickle(server, "POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\nhello", [], function(raw:String):Void {
			try server.close() catch (_:Dynamic) {}
			Assert.isTrue(StringTools.startsWith(raw, "HTTP/1.1 408 "), "a silent request was not timed out: " + raw);
			async.done();
		});
	}

	/** A connection that never speaks counts from accept, and on a listener that sniffs for HTTP/2 too. **/
	public function testAConnectionThatNeverSpeaksIsClosed(async:Async):Void {
		var server:HTTPServer = __serve(config -> {
			config.requestTimeout = 0;
			config.requestIdleTimeout = 0.3;
			config.http2Enabled = true;
		});
		var client:Socket = new Socket();
		var closed:Bool = false;
		client.addEventListener(Event.CLOSE, _ -> closed = true);

		HTTPTestSupport.connectThen(client, server, function():Void {
			HTTPTestSupport.pumpWallUntilAsync(() -> closed, 5.0, function(done:Bool):Void {
				try client.close() catch (_:Dynamic) {}
				try server.close() catch (_:Dynamic) {}
				Assert.isTrue(done, "a silent connection outlived requestIdleTimeout");
				async.done();
			});
		});
	}

	/**
		A body taking several times the idle timeout to arrive is served, as
		long as it keeps arriving. The case the setting is for: with
		`requestTimeout` alone it would be cut off, which the next case shows.
	**/
	public function testABodyThatKeepsMovingOutlivesIt(async:Async):Void {
		var server:HTTPServer = __serve(config -> {
			config.requestTimeout = 0;
			config.requestIdleTimeout = 0.5;
		});

		__trickle(server, "POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 12\r\n\r\n", ["ab", "cd", "ef", "gh", "ij", "kl"], function(raw:String):Void {
			try server.close() catch (_:Dynamic) {}
			Assert.isTrue(StringTools.startsWith(raw, "HTTP/1.1 200 "), "a moving body was cut off: " + raw);
			Assert.isTrue(raw.indexOf("got 12") >= 0, "the body did not arrive whole: " + raw);
			async.done();
		}, 0.2);
	}

	/** `requestTimeout` still bounds the whole, however lively the client. **/
	public function testRequestTimeoutStillBoundsTheWhole(async:Async):Void {
		var server:HTTPServer = __serve(config -> {
			config.requestTimeout = 0.5;
			config.requestIdleTimeout = 5;
		});

		__trickle(server, "POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 20\r\n\r\n", ["ab", "cd", "ef", "gh", "ij", "kl", "mn", "op", "qr", "st"],
			function(raw:String):Void {
				try server.close() catch (_:Dynamic) {}
				Assert.isTrue(StringTools.startsWith(raw, "HTTP/1.1 408 "), "the request outlived requestTimeout: " + raw);
				async.done();
			}, 0.2);
	}

	/** A connection between requests is `keepAliveTimeout`'s, and this does not touch it. **/
	public function testAKeptConnectionIsNotTimedOutByIt(async:Async):Void {
		var server:HTTPServer = __serve(config -> {
			config.requestTimeout = 0;
			config.requestIdleTimeout = 0.2;
			config.keepAliveTimeout = 5;
		});
		var client:Socket = new Socket();
		var raw:String = "";
		var closed:Bool = false;
		client.addEventListener(Event.CONNECT, function(_):Void {
			client.writeUtfBytes("POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\nhi");
			client.flush();
		});
		client.addEventListener(ProgressEvent.SOCKET_DATA, function(_):Void {
			while (client.bytesAvailable > 0) {
				raw += String.fromCharCode(client.readUnsignedByte());
			}
		});
		client.addEventListener(Event.CLOSE, _ -> closed = true);

		HTTPTestSupport.connectThen(client, server, function():Void {
			var until:Float = haxe.Timer.stamp() + 0.8;
			HTTPTestSupport.pumpWallUntilAsync(() -> closed || haxe.Timer.stamp() >= until, 5.0, function(_):Void {
				var stillOpen:Bool = !closed;
				try client.close() catch (_:Dynamic) {}
				try server.close() catch (_:Dynamic) {}
				Assert.isTrue(StringTools.startsWith(raw, "HTTP/1.1 200 "), "the request was not answered: " + raw);
				Assert.equals(1, HTTPTestSupport.countResponses(raw), "something was written to an idle connection: " + raw);
				Assert.isTrue(stillOpen, "an idle kept-alive connection was closed");
				async.done();
			});
		});
	}

	private function __serve(configure:HTTPServerConfig->Void):HTTPServer {
		var router:Router = new Router();
		router.post("/upload", ctx -> ctx.handler.respond(200, "text/plain", "got " + ctx.handler.requestBody.length));
		var config:HTTPServerConfig = new HTTPServerConfig("127.0.0.1", 0);
		configure(config);
		config.middleware.push(router.middleware());
		return new HTTPServer(config);
	}

	/**
		Sends `head`, then each of `pieces` `every` seconds apart, and calls
		`then` with what came back once the server has closed the connection
		or answered, or after 5 s.
	**/
	private function __trickle(server:HTTPServer, head:String, pieces:Array<String>, then:String->Void, every:Float = 0.1):Void {
		var client:Socket = new Socket();
		var raw:String = "";
		var closed:Bool = false;
		var nextAt:Float = 0;
		var sent:Int = 0;

		client.addEventListener(Event.CONNECT, function(_):Void {
			client.writeUtfBytes(head);
			client.flush();
			nextAt = haxe.Timer.stamp() + every;
		});
		client.addEventListener(ProgressEvent.SOCKET_DATA, function(_):Void {
			while (client.bytesAvailable > 0) {
				raw += String.fromCharCode(client.readUnsignedByte());
			}
		});
		client.addEventListener(Event.CLOSE, _ -> closed = true);

		function done():Bool {
			if (nextAt > 0 && sent < pieces.length && haxe.Timer.stamp() >= nextAt && client.connected) {
				client.writeUtfBytes(pieces[sent++]);
				client.flush();
				nextAt = haxe.Timer.stamp() + every;
			}
			return closed || HTTPTestSupport.countResponses(raw) > 0;
		}

		HTTPTestSupport.connectThen(client, server, function():Void {
			HTTPTestSupport.pumpWallUntilAsync(done, 5.0, function(_):Void {
				try client.close() catch (_:Dynamic) {}
				then(raw);
			});
		});
	}
}
