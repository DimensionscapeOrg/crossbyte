package crossbyte.http;

import crossbyte.events.Event;
import crossbyte.events.ProgressEvent;
import crossbyte.io.ByteArray;
import crossbyte.net.Socket;
import utest.Assert;
import utest.Async;

/**
 * `HTTPServerConfig.maxRequestBodyMemory` under HTTP/1.1: what every
 * connection holds of request bodies together, and what a client sees once it
 * is reached. `HTTPServerH2Test` has the same over HTTP/2.
 *
 * Each case holds requests unanswered in its middleware, so their bodies stay
 * counted, and answers them when it chooses.
 */
@:timeout(30000)
@:access(crossbyte.http.HTTPRequestHandler)
@:access(crossbyte.http.HTTPServerConfig)
class HTTPRequestBodyMemoryTest extends utest.Test {
	static inline var LIMIT:Int = 64 * 1024;

	/** A body that finds no room waits, reading stopped, and arrives whole once one ahead of it is answered. **/
	public function testABodyWaitsForRoomAndArrivesWholeOnceThereIsSome(async:Async):Void {
		var held:Array<HTTPRequestHandler> = [];
		var server:HTTPServer = __serve(held);
		var first:Client = new Client(server, __post("/a", LIMIT));
		first.run(() -> held.length == 1, function():Void {
			var second:Client = new Client(server, __post("/b", LIMIT));
			second.run(() -> false, function():Void {
				var routedWhileFull:Int = held.length;
				var heldWhileFull:Float = server.heldRequestBodyBytes;
				__answer(held[0]);
				second.run(() -> held.length == 2, function():Void {
					__answer(held[1]);
					second.run(() -> first.answered && second.answered, function():Void {
						var heldAfter:Float = server.heldRequestBodyBytes;
						try server.close() catch (_:Dynamic) {}
						Assert.equals(1, routedWhileFull, "a body went to the chain with no room for it");
						Assert.isTrue(heldWhileFull <= LIMIT, 'the server held $heldWhileFull bytes of body, past the limit');
						Assert.isTrue(heldWhileFull >= LIMIT - 1024, 'only $heldWhileFull bytes were held, so the limit was not reached');
						Assert.isTrue(first.raw.indexOf("got " + LIMIT) >= 0, first.raw);
						Assert.isTrue(second.raw.indexOf("got " + LIMIT) >= 0, "the body that waited did not arrive whole: " + second.raw);
						Assert.equals(0.0, heldAfter, "what was answered stayed counted");
						async.done();
					});
				});
			}, 0.5);
		});
	}

	/** A request whose requestTimeout passes while it waits is answered 503 with Retry-After, not 408, and its connection closes. **/
	public function testALateRequestThatWaitedForRoomIs503(async:Async):Void {
		var held:Array<HTTPRequestHandler> = [];
		var server:HTTPServer = __serve(held, config -> config.requestTimeout = 0.5);
		var first:Client = new Client(server, __post("/a", LIMIT));
		first.run(() -> held.length == 1, function():Void {
			var second:Client = new Client(server, __post("/b", LIMIT));
			second.run(() -> second.answered && second.closed, function():Void {
				var refused = HTTPTestSupport.parseResponse(second.raw);
				__answer(held[0]);
				first.run(() -> first.answered, function():Void {
					var heldAfter:Float = server.heldRequestBodyBytes;
					try server.close() catch (_:Dynamic) {}
					Assert.equals(503, refused.status, second.raw);
					Assert.isTrue(second.raw.indexOf("Retry-After: 1") >= 0, "no Retry-After: " + second.raw);
					Assert.isTrue(second.closed, "the connection stayed open with its body unread");
					Assert.equals(1, held.length, "the request refused was handed to the chain");
					Assert.isTrue(first.raw.indexOf("got " + LIMIT) >= 0, first.raw);
					Assert.equals(0.0, heldAfter, "what was answered or refused stayed counted");
					async.done();
				});
			}, 5.0);
		});
	}

	/** While a body waits for room its silence is the server's: requestIdleTimeout does not end it. **/
	public function testRequestIdleTimeoutStopsWhileABodyWaitsForRoom(async:Async):Void {
		var held:Array<HTTPRequestHandler> = [];
		var server:HTTPServer = __serve(held, config -> {
			config.requestIdleTimeout = 0.3;
			config.requestTimeout = 20;
		});
		var first:Client = new Client(server, __post("/a", LIMIT));
		first.run(() -> held.length == 1, function():Void {
			var second:Client = new Client(server, __post("/b", LIMIT));
			second.run(() -> second.answered, function():Void {
				var answeredWhileWaiting:Bool = second.answered;
				__answer(held[0]);
				second.run(() -> held.length == 2, function():Void {
					__answer(held[1]);
					second.run(() -> second.answered, function():Void {
						try server.close() catch (_:Dynamic) {}
						Assert.isFalse(answeredWhileWaiting, "a body waiting for room was answered: " + second.raw);
						Assert.isTrue(second.raw.indexOf("got " + LIMIT) >= 0, second.raw);
						async.done();
					});
				});
			}, 1.2);
		});
	}

	/** A request expecting 100-continue is told to go on once there is room for its body, not before. **/
	public function testA100ContinueWaitsForRoom(async:Async):Void {
		var held:Array<HTTPRequestHandler> = [];
		var server:HTTPServer = __serve(held);
		var first:Client = new Client(server, __post("/a", LIMIT));
		first.run(() -> held.length == 1, function():Void {
			var second:Client = new Client(server, "POST /b HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: " + LIMIT + "\r\n\r\n");
			second.run(() -> false, function():Void {
				var continuedWhileFull:Bool = second.raw.indexOf("100 Continue") >= 0;
				__answer(held[0]);
				second.run(() -> second.raw.indexOf("100 Continue") >= 0, function():Void {
					var continued:Bool = second.raw.indexOf("100 Continue") >= 0;
					second.send(__fill(LIMIT));
					second.run(() -> held.length == 2, function():Void {
						__answer(held[1]);
						second.run(() -> second.raw.indexOf("got " + LIMIT) >= 0, function():Void {
							try server.close() catch (_:Dynamic) {}
							Assert.isFalse(continuedWhileFull, "100 Continue was sent with no room for the body");
							Assert.isTrue(continued, "100 Continue was never sent once there was room");
							Assert.isTrue(second.raw.indexOf("got " + LIMIT) >= 0, second.raw);
							async.done();
						});
					});
				});
			}, 0.4);
		});
	}

	/** Every body is given back: answered, chunked, decoded, refused, and cut off by its client. **/
	public function testWhatEachRequestHeldIsGivenBack(async:Async):Void {
		var held:Array<HTTPRequestHandler> = [];
		var server:HTTPServer = __serve(held);
		var gzip:ByteArray = new ByteArray();
		gzip.writeUtfBytes(__fill(1000));
		gzip.compress(crossbyte.utils.CompressionAlgorithm.GZIP);

		var plain:Client = new Client(server, __post("/plain", 1000));
		var chunked:Client = new Client(server, "POST /chunked HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n3e8\r\n" + __fill(1000) + "\r\n0\r\n\r\n");
		var decoded:Client = new Client(server, "POST /decoded HTTP/1.1\r\nHost: x\r\nContent-Encoding: gzip\r\nContent-Length: " + gzip.length + "\r\n\r\n");
		decoded.onConnected = () -> decoded.sendBytes(gzip);
		var tooLarge:Client = new Client(server, "POST /big HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n3e8\r\n" + __fill(1000) + "\r\n10000\r\n");
		var cutOff:Client = new Client(server, "POST /cut HTTP/1.1\r\nHost: x\r\nContent-Length: 10000\r\n\r\n" + __fill(3000));

		plain.run(() -> held.length >= 1, () -> chunked.run(() -> held.length >= 2, () -> decoded.run(() -> held.length >= 3, function():Void {
			var whileHeld:Float = server.heldRequestBodyBytes;
			for (handler in held) {
				__answer(handler);
			}
			tooLarge.run(() -> tooLarge.answered, () -> cutOff.run(() -> server.heldRequestBodyBytes >= 3000, function():Void {
				var cutWhileArriving:Float = server.heldRequestBodyBytes;
				cutOff.hangUp();
				plain.run(() -> plain.answered && chunked.answered && decoded.answered && server.heldRequestBodyBytes == 0, function():Void {
					var heldAfter:Float = server.heldRequestBodyBytes;
					try server.close() catch (_:Dynamic) {}
					Assert.equals(3000.0, whileHeld, "three answered-later bodies of 1,000 bytes, decoded, were not counted as such");
					Assert.isTrue(decoded.raw.indexOf("got 1000") >= 0, decoded.raw);
					Assert.equals(413, tooLarge.status(), tooLarge.raw);
					Assert.equals(3000.0, cutWhileArriving, "a body still arriving was not counted as it came");
					Assert.equals(0.0, heldAfter, "something was left counted");
					async.done();
				});
			}));
		})));
	}

	/** With no limit nothing waits, and what is held is still counted. **/
	public function testNoLimitCountsButNeverWaits(async:Async):Void {
		var held:Array<HTTPRequestHandler> = [];
		var server:HTTPServer = __serve(held, config -> config.maxRequestBodyMemory = 0);
		var first:Client = new Client(server, __post("/a", LIMIT));
		var second:Client = new Client(server, __post("/b", LIMIT));
		first.run(() -> held.length == 1, () -> second.run(() -> held.length == 2, function():Void {
			var whileHeld:Float = server.heldRequestBodyBytes;
			for (handler in held) {
				__answer(handler);
			}
			second.run(() -> first.answered && second.answered, function():Void {
				var heldAfter:Float = server.heldRequestBodyBytes;
				try server.close() catch (_:Dynamic) {}
				Assert.equals(2, held.length, "a body waited with no limit set");
				Assert.equals(2.0 * LIMIT, whileHeld, "what was held was not counted");
				Assert.equals(0.0, heldAfter);
				async.done();
			});
		}));
	}

	/** The limit is never below maxRequestBodySize: one body of the largest size taken always fits. **/
	public function testTheLimitNeverKeepsOutTheLargestBody(async:Async):Void {
		var held:Array<HTTPRequestHandler> = [];
		var server:HTTPServer = __serve(held, config -> config.maxRequestBodyMemory = 1024);
		var only:Client = new Client(server, __post("/a", LIMIT));
		only.run(() -> held.length == 1, function():Void {
			__answer(held[0]);
			only.run(() -> only.answered, function():Void {
				try server.close() catch (_:Dynamic) {}
				Assert.isTrue(only.raw.indexOf("got " + LIMIT) >= 0, only.raw);
				async.done();
			});
		});
	}

	private function __serve(held:Array<HTTPRequestHandler>, ?configure:HTTPServerConfig->Void):HTTPServer {
		var config:HTTPServerConfig = new HTTPServerConfig("127.0.0.1", 0);
		config.maxRequestBodySize = LIMIT;
		config.maxRequestBodyMemory = LIMIT;
		if (configure != null) {
			configure(config);
		}
		// Each request held unanswered until the case answers it, its body
		// counted meanwhile; one past the limit is answered by the server.
		config.middleware.push(function(handler:HTTPRequestHandler, _:?Dynamic->Void):Void {
			held.push(handler);
		});
		return new HTTPServer(config);
	}

	private static function __answer(handler:HTTPRequestHandler):Void {
		handler.respond(200, "text/plain", "got " + handler.requestBody.length);
	}

	private static function __post(path:String, length:Int):String {
		return "POST " + path + " HTTP/1.1\r\nHost: x\r\nContent-Length: " + length + "\r\n\r\n" + __fill(length);
	}

	private static function __fill(length:Int):String {
		var text:StringBuf = new StringBuf();
		for (i in 0...length) {
			text.addChar("a".code + i % 26);
		}
		return text.toString();
	}
}

/** One connection's client: what it sends first, more when told, and everything that came back. */
private class Client {
	public var raw(default, null):String = "";
	public var closed(default, null):Bool = false;
	public var onConnected:Null<Void->Void> = null;
	public var answered(get, never):Bool;

	private final __server:HTTPServer;
	private final __socket:Socket = new Socket();
	private final __head:String;
	private var __started:Bool = false;

	public function new(server:HTTPServer, head:String) {
		__server = server;
		__head = head;
		__socket.addEventListener(Event.CONNECT, function(_):Void {
			__socket.writeUtfBytes(__head);
			__socket.flush();
			if (onConnected != null) {
				onConnected();
			}
		});
		__socket.addEventListener(ProgressEvent.SOCKET_DATA, function(_):Void {
			while (__socket.bytesAvailable > 0) {
				raw += String.fromCharCode(__socket.readUnsignedByte());
			}
		});
		__socket.addEventListener(Event.CLOSE, _ -> closed = true);
	}

	private function get_answered():Bool {
		var text:String = StringTools.replace(raw, "HTTP/1.1 100 Continue\r\n\r\n", "");
		return HTTPTestSupport.countResponses(text) > 0;
	}

	public function status():Int {
		return HTTPTestSupport.parseResponse(raw).status;
	}

	public function send(text:String):Void {
		if (__socket.connected) {
			__socket.writeUtfBytes(text);
			__socket.flush();
		}
	}

	public function sendBytes(bytes:ByteArray):Void {
		if (__socket.connected) {
			__socket.writeBytes(bytes, 0, bytes.length);
			__socket.flush();
		}
	}

	public function hangUp():Void {
		__socket.close();
	}

	/** Connects if it has not, and pumps until `done` says so or `timeout` passes, then calls `then`, whichever it was. */
	public function run(done:Void->Bool, then:Void->Void, timeout:Float = 5.0):Void {
		function pump():Void {
			HTTPTestSupport.pumpWallUntilAsync(done, timeout, _ -> then());
		}
		if (__started) {
			pump();
			return;
		}
		__started = true;
		HTTPTestSupport.connectThen(__socket, __server, pump);
	}
}
