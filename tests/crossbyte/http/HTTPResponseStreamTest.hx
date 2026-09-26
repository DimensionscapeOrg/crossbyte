package crossbyte.http;

import crossbyte.events.Event;
import crossbyte.events.ProgressEvent;
import crossbyte.io.ByteArray;
import crossbyte.net.Socket;
import crossbyte.url.URLRequestHeader;
import utest.Assert;
import utest.Async;

/**
 * A response written as it is produced, `beginResponse` and the
 * `HTTPResponseStream` it returns, and the close event that tells a producer
 * its client left.
 *
 * `respond` took the whole body at once, as a String, with a Content-Length,
 * so there was no way to send server-sent events, a download produced as it
 * went, or bytes that were not text; the audit's SSE and download programs
 * needed `@:privateAccess`. The HTTP/2 half of this is in `HTTPServerH2Test`.
 */
@:timeout(20000)
class HTTPResponseStreamTest extends utest.Test {
	public function testAResponseIsWrittenAsItGoes(async:Async):Void {
		var held:HTTPResponseStream = null;
		var server = __serve(handler -> {
			if (handler.requestPath == "/next") {
				handler.respond(200, "text/plain", "next");
				return;
			}
			held = handler.beginResponse(200, "text/event-stream", [new URLRequestHeader("Cache-Control", "no-cache")]);
			held.writeText("data: one\n\n");
		});
		var client = new RawClient(server);

		client.request("GET /events HTTP/1.1\r\nHost: x\r\n\r\n", () -> {
			client.until(() -> client.text.indexOf("data: one") >= 0, () -> {
				// Out before the response has ended.
				var early:Bool = client.text.indexOf("data: one") >= 0 && __dechunked(client.text) == null;
				held.writeText("data: two\n\n");
				held.end();

				client.until(() -> __dechunked(client.text) != null, () -> {
					var head = HTTPTestSupport.parseResponse(client.text);
					Assert.isTrue(early, "the first event did not arrive before the response ended");
					Assert.equals(200, head.status);
					Assert.equals("chunked", head.headers.get("transfer-encoding"));
					Assert.isNull(head.headers.get("content-length"));
					Assert.equals("no-cache", head.headers.get("cache-control"));
					Assert.equals("data: one\n\ndata: two\n\n", __dechunked(client.text));

					// Framed by its chunks, so the connection carries on.
					var before:Int = client.text.length;
					client.send("GET /next HTTP/1.1\r\nHost: x\r\n\r\n");
					client.until(() -> client.text.indexOf("next", before) >= 0, () -> {
						Assert.isTrue(client.text.indexOf("HTTP/1.1 200", before) >= 0, "the connection did not carry the next request");
						client.close();
						server.close();
						async.done();
					});
				});
			});
		});
	}

	public function testAnHttp10ClientReadsUntilTheClose(async:Async):Void {
		// HTTP/1.0 has no chunked coding, so the body ends with the connection.
		var server = __serve(handler -> {
			var body = handler.beginResponse(200, "text/plain");
			body.writeText("all ");
			body.writeText("of it");
			body.end();
		});
		var client = new RawClient(server);

		client.request("GET / HTTP/1.0\r\n\r\n", () -> {
			client.until(() -> client.closed, () -> {
				var head = HTTPTestSupport.parseResponse(client.text);
				Assert.equals(200, head.status);
				Assert.isNull(head.headers.get("transfer-encoding"));
				Assert.isNull(head.headers.get("content-length"));
				Assert.equals("close", head.headers.get("connection"));
				Assert.equals("all of it", head.body);
				client.close();
				server.close();
				async.done();
			});
		});
	}

	public function testTheProducerHearsItsClientLeave(async:Async):Void {
		// There was no close event: a producer writing to a client that had
		// gone found out only by writing into a closed socket.
		var held:HTTPRequestHandler = null;
		var events:HTTPResponseStream = null;
		var heardClose:Bool = false;
		var server = __serve(handler -> {
			held = handler;
			handler.addEventListener(Event.CLOSE, _ -> heardClose = true);
			events = handler.beginResponse(200, "text/event-stream");
			events.writeText("data: one\n\n");
		});
		var client = new RawClient(server);

		client.request("GET /events HTTP/1.1\r\nHost: x\r\n\r\n", () -> {
			client.until(() -> client.text.indexOf("data: one") >= 0, () -> {
				client.close();
				client.until(() -> heardClose, () -> {
					Assert.isTrue(heardClose, "the producer was not told its client left");
					Assert.isFalse(held.connected);
					Assert.isFalse(events.connected);
					Assert.isFalse(events.writeText("data: two\n\n"));
					server.close();
					async.done();
				});
			});
		});
	}

	public function testWritingPastTheOutputCapEndsTheResponse(async:Async):Void {
		// A producer that ignores write()'s answer is stopped at the cap,
		// with an error, rather than holding whatever it writes.
		var accepted:Null<Bool> = null;
		var heardClose:Bool = false;
		var server = __serve(handler -> {
			handler.addEventListener(Event.CLOSE, _ -> heardClose = true);
			var body = handler.beginResponse(200, "application/octet-stream");
			var big = new ByteArray();
			big.length = 64 * 1024;
			accepted = body.write(big);
		}, config -> config.maxOutputBufferSize = 16 * 1024);
		var client = new RawClient(server);

		client.request("GET /flood HTTP/1.1\r\nHost: x\r\n\r\n", () -> {
			client.until(() -> client.closed, () -> {
				Assert.isFalse(accepted);
				Assert.isTrue(client.closed, "the response was not ended");
				Assert.isTrue(heardClose);
				client.close();
				server.close();
				async.done();
			});
		});
	}

	public function testAProducerWaitsForDrain(async:Async):Void {
		// Two megabytes in 64 KB pieces, each written only when write() or
		// onDrain says there is room: the whole of it arrives, in order.
		var piece:Int = 64 * 1024;
		var total:Int = 2 * 1024 * 1024;
		var server = __serve(handler -> {
			var sent:Int = 0;
			var body:HTTPResponseStream = null;
			function produce():Void {
				while (sent < total) {
					var chunk = new ByteArray();
					for (i in 0...piece) {
						chunk.writeByte(__patternAt(sent + i));
					}
					sent += piece;
					if (!body.write(chunk)) {
						return;
					}
				}
				body.end();
			}
			body = handler.beginResponse(200, "application/octet-stream");
			body.onDrain = produce;
			produce();
		});
		var client = new RawClient(server);

		client.request("GET /download HTTP/1.1\r\nHost: x\r\n\r\n", () -> {
			client.until(() -> StringTools.endsWith(client.text, "\r\n0\r\n\r\n"), () -> {
				var body:Null<String> = __dechunked(client.text);
				Assert.equals(total, body == null ? -1 : body.length);
				var mismatches:Int = 0;
				if (body != null) {
					for (i in 0...body.length) {
						if (StringTools.fastCodeAt(body, i) != __patternAt(i)) {
							mismatches++;
						}
					}
				}
				Assert.equals(0, mismatches);
				client.close();
				server.close();
				async.done();
			}, 15.0);
		});
	}

	public function testRespondBytesSendsBytes(async:Async):Void {
		var body = new ByteArray();
		for (i in 0...1024) {
			body.writeByte(i & 0xFF);
		}
		var server = __serve(handler -> handler.respondBytes(200, "application/octet-stream", body));
		var client = new RawClient(server);

		client.request("GET /bytes HTTP/1.1\r\nHost: x\r\n\r\n", () -> {
			client.until(() -> client.bytes.length >= 1024 && HTTPTestSupport.isResponseComplete(client.text), () -> {
				var response = HTTPTestSupport.parseResponse(client.text);
				Assert.equals(200, response.status);
				Assert.equals("1024", response.headers.get("content-length"));
				// Compared as bytes: the text view is for the head.
				var bodyStart:Int = client.bytes.length - 1024;
				var mismatches:Int = 0;
				for (i in 0...1024) {
					if (client.bytes[bodyStart + i] != (i & 0xFF)) {
						mismatches++;
					}
				}
				Assert.equals(0, mismatches);
				client.close();
				server.close();
				async.done();
			});
		});
	}

	public function testAHeadOfAStreamedResponseCarriesNoBody(async:Async):Void {
		var discarded:Null<Bool> = null;
		var server = __serve(handler -> {
			if (handler.requestPath == "/next") {
				handler.respond(200, "text/plain", "next");
				return;
			}
			var events = handler.beginResponse(200, "text/event-stream");
			// Accepted and dropped: a HEAD has no body to put it in.
			discarded = events.writeText("data: one\n\n");
			events.end();
		});
		var client = new RawClient(server);

		client.request("HEAD /events HTTP/1.1\r\nHost: x\r\n\r\n", () -> {
			client.until(() -> client.text.indexOf("\r\n\r\n") >= 0, () -> {
				client.send("GET /next HTTP/1.1\r\nHost: x\r\n\r\n");
				client.until(() -> client.text.indexOf("next") >= 0 || client.closed, () -> {
					Assert.isTrue(discarded);
					Assert.equals(-1, client.text.indexOf("data: one"), "a HEAD carried a body");
					Assert.isTrue(client.text.indexOf("\r\n\r\nnext") >= 0, "the next response was not clean: " + client.text);
					client.close();
					server.close();
					async.done();
				});
			});
		});
	}

	/** Printable, with a long period. */
	private static inline function __patternAt(i:Int):Int {
		return 0x30 + ((i ^ (i >> 8) ^ (i >> 16)) & 0x3F);
	}

	/**
	 * The body of the first response in `raw`, decoded from its chunks, or
	 * null until the last chunk has arrived.
	 */
	private static function __dechunked(raw:String):Null<String> {
		var at:Int = raw.indexOf("\r\n\r\n");
		if (at < 0) {
			return null;
		}
		at += 4;

		var body:StringBuf = new StringBuf();
		while (true) {
			var lineEnd:Int = raw.indexOf("\r\n", at);
			if (lineEnd < 0) {
				return null;
			}
			var size:Int = crossbyte.utils.IntParse.hex(raw.substring(at, lineEnd));
			if (size < 0) {
				return null;
			}
			at = lineEnd + 2;
			if (size == 0) {
				return raw.indexOf("\r\n", at) == at ? body.toString() : null;
			}
			if (raw.length < at + size + 2) {
				return null;
			}
			body.addSub(raw, at, size);
			at += size + 2;
		}
	}

	private static function __serve(route:HTTPRequestHandler->Void, ?configure:HTTPServerConfig->Void):HTTPServer {
		var config = new HTTPServerConfig("127.0.0.1", 0);
		if (configure != null) {
			configure(config);
		}
		config.middleware.push(function(handler:HTTPRequestHandler, next:?Dynamic->Void):Void {
			route(handler);
		});
		return new HTTPServer(config);
	}
}

/**
 * One connection's worth of client: what arrived, byte for character, and
 * whether the server closed it. Writes go out between pumps, never from the
 * socket's own data dispatch.
 */
private class RawClient {
	public var text(default, null):String = "";
	public var bytes(default, null):ByteArray = new ByteArray();
	public var closed(default, null):Bool = false;

	private final __server:HTTPServer;
	private final __socket:Socket = new Socket();
	private var __closing:Bool = false;

	public function new(server:HTTPServer) {
		__server = server;
		__socket.addEventListener(ProgressEvent.SOCKET_DATA, _ -> {
			if (__socket.bytesAvailable > 0) {
				var chunk = new ByteArray();
				__socket.readBytes(chunk, 0, __socket.bytesAvailable);
				bytes.writeBytes(chunk, 0, chunk.length);
				var out = new StringBuf();
				out.add(text);
				for (i in 0...chunk.length) {
					out.addChar(chunk[i]);
				}
				text = out.toString();
			}
		});
		__socket.addEventListener(Event.CLOSE, _ -> {
			if (!__closing) {
				closed = true;
			}
		});
	}

	/** Connects, sends `request`, and continues. */
	public function request(request:String, then:Void->Void):Void {
		__socket.addEventListener(Event.CONNECT, _ -> {
			__socket.writeUTFBytes(request);
			__socket.flush();
		});
		HTTPTestSupport.connectThen(__socket, __server, then);
	}

	public function send(request:String):Void {
		__socket.writeUTFBytes(request);
		__socket.flush();
	}

	public function until(done:Void->Bool, then:Void->Void, timeout:Float = 5.0):Void {
		HTTPTestSupport.pumpUntilAsync(done, timeout, _ -> then());
	}

	public function close():Void {
		__closing = true;
		try {
			__socket.close();
		} catch (_:Dynamic) {}
	}
}
