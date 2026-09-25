package crossbyte.http;

import crossbyte._internal.http.h2.H2Connection;
import crossbyte._internal.http.h2.H2ErrorCode;
import crossbyte._internal.http.h2.H2Flags;
import crossbyte._internal.http.h2.H2Frame;
import crossbyte._internal.http.h2.H2FrameType;
import crossbyte._internal.http.h2.hpack.HpackDecoder;
import crossbyte._internal.http.h2.hpack.HpackEncoder;
import crossbyte._internal.http.h2.hpack.HpackHeader;
import crossbyte.events.Event;
import crossbyte.events.ProgressEvent;
import crossbyte.io.ByteArray;
import crossbyte.io.File;
import crossbyte.net.Socket;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import utest.Assert;
import utest.Async;

/**
 * `HTTPServer` serving HTTP/2 through the ordinary request pipeline.
 *
 * The point of these is the seam rather than the protocol: `H2ServerTest`
 * already covers framing against a canned handler, so what is being checked
 * here is that a request arriving as frames reaches the same static-file
 * routing, middleware and CORS an HTTP/1.1 request would, and that the
 * response comes back out as frames. Anything less and the writer split would
 * be structure without payoff.
 */
@:timeout(20000)
class HTTPServerH2Test extends utest.Test {
	public function testStaticFileIsServedOverHttp2(async:Async):Void {
		exchange(async, "GET", "/index.html", null, null, function(status, headers, body) {
			Assert.equals(200, status);
			Assert.equals("Hello over h2", body.toString());
			// The same content type the HTTP/1.1 path derives, so routing and
			// negotiation ran rather than being bypassed.
			Assert.isTrue(headers.get("content-type").indexOf("text/html") >= 0);
			// Written by the shared response assembly, not by either writer.
			Assert.equals("nosniff", headers.get("x-content-type-options"));
			Assert.equals("CrossByte", headers.get("server"));
			async.done();
		});
	}

	public function testMissingFileStillProducesA404(async:Async):Void {
		exchange(async, "GET", "/nope.html", null, null, function(status, headers, body) {
			Assert.equals(404, status);
			async.done();
		});
	}

	public function testConnectionHeadersAreNotSentOnAnHttp2Response(async:Async):Void {
		exchange(async, "GET", "/index.html", null, null, function(status, headers, body) {
			// The HTTP/1.1 writer always emits Connection. §8.2.2 makes it
			// malformed here, so the h2 writer has to drop it -- and a client
			// is entitled to reject the whole response if it does not.
			Assert.isFalse(headers.exists("connection"));
			Assert.isFalse(headers.exists("keep-alive"));
			Assert.isFalse(headers.exists("transfer-encoding"));
			async.done();
		});
	}

	public function testResponseFieldNamesAreLowercase(async:Async):Void {
		exchange(async, "GET", "/index.html", null, null, function(status, headers, body) {
			// §8.2.1. The pipeline produces "Content-Type" and "Server"; the
			// writer is what has to normalise them.
			for (name in headers.keys()) {
				if (name.toLowerCase() != name) {
					Assert.fail('response field "$name" is not lowercase');
					async.done();
					return;
				}
			}
			Assert.pass();
			async.done();
		});
	}

	public function testPathTraversalIsContainedOnTheHttp2Path(async:Async):Void {
		// The containment lives in the HTTP/1.1 parser, so an HTTP/2 request
		// reaching dispatch without it would escape the document root on one
		// protocol and not the other. That is exactly what happened while this
		// was being wired: the injection path set the file path straight from
		// the request target, and the dispatch fallback serves that as-is.
		exchange(async, "GET", "/../../../../../../etc/passwd", null, null, function(status, headers, body) {
			Assert.equals(403, status);
			async.done();
		});
	}

	public function testMiddlewareRunsForAnHttp2Request(async:Async):Void {
		exchange(async, "GET", "/index.html", null, config -> {
			config.middleware = [
				(handler, next) -> {
					handler.respond(203, "text/plain", "from middleware");
				}
			];
		}, function(status, headers, body) {
			// Middleware lives above the framing split, so it must see an
			// HTTP/2 request exactly as it sees an HTTP/1.1 one.
			Assert.equals(203, status);
			Assert.equals("from middleware", body.toString());
			async.done();
		});
	}

	public function testCorsHeadersSurviveTheHttp2Writer(async:Async):Void {
		exchange(async, "GET", "/index.html", null, config -> config.corsEnabled = true, function(status, headers, body) {
			Assert.equals(200, status);
			Assert.equals("*", headers.get("access-control-allow-origin"));
			Assert.equals("Origin", headers.get("vary"));
			async.done();
		});
	}

	public function testLargeFileSurvivesTheFlowControlWindow(async:Async):Void {
		// Larger than both the 65535-byte default window and the 256 KB
		// streaming threshold, so this goes out through the file pump *and*
		// has to stop and wait for WINDOW_UPDATEs on the way. Writing past the
		// window is not a slow transfer -- 6.9.1 makes it a FLOW_CONTROL_ERROR
		// a real client answers by killing the connection.
		var size = 300000;
		exchange(async, "GET", "/big.bin", null, null, function(status, headers, body) {
			Assert.equals(200, status);
			Assert.equals(size, body.length);

			// Compared byte for byte, not just by length: a transfer that
			// resumes at the wrong offset can lose one slice and repeat
			// another and still arrive the right size.
			for (i in 0...size) {
				if (body.get(i) != (i % 251)) {
					Assert.fail('byte $i is ${body.get(i)}, expected ${i % 251}');
					async.done();
					return;
				}
			}

			Assert.pass();
			async.done();
		}, size);
	}

	public function testHttp11IsStillServedOnAnHttp2Listener(async:Async):Void {
		// The listener offers both. A cleartext port cannot negotiate -- RFC
		// 9113 3.1 retired the h2c upgrade -- so this is decided by looking at
		// the first bytes, and an HTTP/1.1 request must come out the other
		// side unharmed rather than being met with frames it cannot read.
		var root = File.createTempDirectory();
		var indexFile = root.resolvePath("index.html");
		var fixture = new ByteArray();
		fixture.writeUTFBytes("Hello over h2");
		indexFile.save(fixture);

		var config = new HTTPServerConfig("127.0.0.1", 0, root, null, ["index.html"]);
		config.http2Enabled = true;

		var server = new HTTPServer(config);
		var client = new Socket();
		var response = "";
		var done = false;

		client.addEventListener(Event.CONNECT, _ -> {
			client.writeUTFBytes("GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n");
			client.flush();
		});
		client.addEventListener(ProgressEvent.SOCKET_DATA, _ -> {
			if (client.bytesAvailable == 0) {
				return;
			}
			var chunk = new ByteArray();
			client.readBytes(chunk, 0, client.bytesAvailable);
			for (i in 0...chunk.length) {
				response += String.fromCharCode(chunk[i]);
			}
			if (response.indexOf("Hello over h2") >= 0) {
				done = true;
			}
		});

		HTTPTestSupport.connectThen(client, server, function():Void {
			HTTPTestSupport.pumpUntilAsync(() -> done, 5.0, function(_):Void {
				try client.close() catch (_:Dynamic) {}
				try server.close() catch (_:Dynamic) {}
				try root.deleteDirectory(true) catch (_:Dynamic) {}

				Assert.isTrue(response.indexOf("HTTP/1.1 200") == 0, "expected an HTTP/1.1 response, got: " + response.substr(0, 40));
				Assert.isTrue(response.indexOf("Hello over h2") >= 0);
				async.done();
			});
		});
	}

	// --------------------------------------------------- connection lifetime
	//
	// The sweep that closes quiet HTTP/2 connections measured the quiet as
	// Sys.time() minus a haxe.Timer.stamp(). Those are one clock on hl, neko
	// and jvm and two different ones on cpp and Node, where every connection
	// read as idle since 1970 and was closed at the first sweep -- a quarter
	// second in, with a request in flight or without. Every exchange above is
	// over before that sweep runs, so none of them could see it; each case here
	// outlasts it. Each also sets the allowance it is not about so that judging
	// by that one instead fails too: short where the connection must survive,
	// long where it must be closed.

	// Long enough to span several sweeps, which run every quarter second, and
	// well short of the allowance the surviving cases are judged by.
	private static inline var PAUSE:Float = 1.0;

	// The server's clock is Sys.time() on eval, hl and neko, which Windows
	// advances in steps of up to about 16 ms, so a close can read a little
	// early.
	private static inline var SLACK:Float = 0.1;

	public function testAnHttp2ConnectionIsNotReapedBetweenRequests(async:Async):Void {
		var session = new H2Session(config -> {
			config.keepAliveTimeout = 10;
			config.requestTimeout = 0.5;
		});

		session.start(() -> {
			session.request(1, "GET", "/index.html", true);
			session.until(() -> session.finished(1) || session.ended, () -> {
				session.pause(PAUSE, () -> {
					// Sent only on a connection that is still there, so a reaped
					// one fails on what happened to it rather than on a write.
					if (!session.ended) {
						session.request(3, "GET", "/index.html", true);
					}
					session.until(() -> session.finished(3) || session.ended, () -> {
						session.close();
						Assert.isFalse(session.ended, 'the server ended the connection after ${session.silence()}s of silence, under a 10s keepAliveTimeout');
						Assert.equals(200, session.status(3));
						Assert.equals("Hello over h2", session.body(3));
						async.done();
					});
				});
			});
		});
	}

	public function testAnHttp2RequestIsNotReapedWhileItsBodyIsArriving(async:Async):Void {
		// A slow upload: the headers now, the body after the pause, so a stream
		// is open throughout and requestTimeout is the allowance that applies.
		var session = new H2Session(config -> {
			config.requestTimeout = 10;
			config.keepAliveTimeout = 0.5;
			config.middleware = [(handler, next) -> handler.respond(200, "text/plain", "received " + handler.requestText)];
		});

		session.start(() -> {
			session.request(1, "POST", "/upload", false);
			session.pause(PAUSE, () -> {
				if (!session.ended) {
					session.data(1, "the rest");
				}
				session.until(() -> session.finished(1) || session.ended, () -> {
					session.close();
					Assert.isFalse(session.ended, 'the server ended the connection after ${session.silence()}s of silence, under a 10s requestTimeout');
					Assert.equals(200, session.status(1));
					Assert.equals("received the rest", session.body(1));
					async.done();
				});
			});
		});
	}

	public function testAnIdleHttp2ConnectionIsReapedAfterKeepAliveTimeout(async:Async):Void {
		// The other half: whatever fixes the clock must leave the sweep able to
		// close a connection that really has gone quiet, and no sooner.
		var session = new H2Session(config -> {
			config.keepAliveTimeout = 1;
			config.requestTimeout = 10;
		});

		session.start(() -> {
			session.request(1, "GET", "/index.html", true);
			session.until(() -> session.finished(1) || session.ended, () -> {
				// Silent from here. Waiting on the socket going, which is the
				// effect; the GOAWAY ahead of it is the courtesy.
				session.until(() -> session.dropped, () -> {
					session.close();
					Assert.equals(200, session.status(1));
					Assert.isTrue(session.dropped, "an idle HTTP/2 connection was never closed");
					Assert.isTrue(session.goAwayCode == H2ErrorCode.NO_ERROR, 'expected a GOAWAY with NO_ERROR before the close, got ${session.goAwayCode}');
					Assert.isTrue(session.silence() >= 1 - SLACK, 'closed after ${session.silence()}s of silence, inside its 1s keepAliveTimeout');
					async.done();
				}, 5.0);
			});
		});
	}

	public function testAStalledHttp2RequestIsReapedAfterRequestTimeout(async:Async):Void {
		// Headers promising a body that never comes. The stream stays open, so
		// this is requestTimeout's to close, as it is for an HTTP/1.1 request
		// that stops arriving.
		var session = new H2Session(config -> {
			config.requestTimeout = 1;
			config.keepAliveTimeout = 10;
		});

		session.start(() -> {
			session.request(1, "POST", "/upload", false);
			session.until(() -> session.dropped, () -> {
				session.close();
				Assert.isTrue(session.dropped, "a stalled HTTP/2 request was never closed");
				Assert.isTrue(session.silence() >= 1 - SLACK, 'closed after ${session.silence()}s of silence, inside its 1s requestTimeout');
				async.done();
			}, 5.0);
		});
	}

	// ---------------------------------------------------------------- driver

	/**
	 * Runs one request against a real `HTTPServer` over a real socket.
	 *
	 * The client side is hand-built rather than `H2Connection`, because that
	 * one blocks on reads and this has to run on the same runtime loop as the
	 * server it is talking to.
	 */
	private function exchange(async:Async, method:String, path:String, body:Null<String>, configure:Null<HTTPServerConfig->Void>,
			done:(Int, Map<String, String>, Bytes) -> Void, largeFileSize:Int = 0):Void {
		var root = File.createTempDirectory();
		var indexFile = root.resolvePath("index.html");
		var fixture = new ByteArray();
		fixture.writeUTFBytes("Hello over h2");
		indexFile.save(fixture);

		if (largeFileSize > 0) {
			var big = new ByteArray();
			for (i in 0...largeFileSize) {
				big.writeByte(i % 251);
			}
			root.resolvePath("big.bin").save(big);
		}

		var config = new HTTPServerConfig("127.0.0.1", 0, root, null, ["index.html"]);
		config.http2Enabled = true;
		if (configure != null) {
			configure(config);
		}

		var server = new HTTPServer(config);
		var client = new Socket();
		var inbound = new BytesBuffer();
		var inboundLength = 0;
		var parsedUpTo = 0;
		var finished = false;
		var pendingCredit = 0;

		var decoder = new HpackDecoder(4096);
		var status = -1;
		var headers = new Map<String, String>();
		var payload = new BytesBuffer();
		var payloadLength = 0;

		// One teardown shared by the success path and the timeout path.
		// The document root is a temp directory of our own making, and a
		// driver that leaks one per request leaks thousands over a week of
		// runs.
		var shutdown = function():Void {
			try {
				client.close();
			} catch (_:Dynamic) {}
			try {
				server.close();
			} catch (_:Dynamic) {}
			try {
				root.deleteDirectory(true);
			} catch (_:Dynamic) {}
		};

		client.addEventListener(Event.CONNECT, _ -> {
			var out = new BytesBuffer();
			out.addString(H2Connection.PREFACE);
			writeFrame(out, H2FrameType.SETTINGS, 0, 0, Bytes.alloc(0));

			var encoder = new HpackEncoder(4096);
			var block = encoder.encode([
				new HpackHeader(":method", method),
				new HpackHeader(":scheme", "http"),
				new HpackHeader(":authority", "127.0.0.1"),
				new HpackHeader(":path", path)
			]);

			var hasBody = body != null && body.length > 0;
			writeFrame(out, H2FrameType.HEADERS, H2Flags.END_HEADERS | (hasBody ? 0 : H2Flags.END_STREAM), 1, block);
			if (hasBody) {
				writeFrame(out, H2FrameType.DATA, H2Flags.END_STREAM, 1, Bytes.ofString(body));
			}

			var bytes = out.getBytes();
			var wrapper = new ByteArray();
			wrapper.writeBytes(bytes, 0, bytes.length);
			client.writeBytes(wrapper, 0, wrapper.length);
			client.flush();
		});

		client.addEventListener(ProgressEvent.SOCKET_DATA, _ -> {
			if (finished || client.bytesAvailable == 0) {
				return;
			}

			var chunk = new ByteArray();
			client.readBytes(chunk, 0, client.bytesAvailable);
			for (i in 0...chunk.length) {
				inbound.addByte(chunk[i]);
			}
			inboundLength += chunk.length;

			// Kept whole and re-read from a running offset. Re-parsing from
			// the top each time counts every earlier frame again, which a
			// single-frame response hides completely and a transfer spread
			// over many reads does not.
			var all = inbound.getBytes();
			inbound = new BytesBuffer();
			inbound.addBytes(all, 0, all.length);

			var position = parsedUpTo;
			while (position + H2Frame.HEADER_SIZE <= all.length) {
				var length = H2Frame.lengthOf(all, position);
				if (position + H2Frame.HEADER_SIZE + length > all.length) {
					break;
				}

				var frame = H2Frame.read(all, position);
				position += H2Frame.HEADER_SIZE + length;
				parsedUpTo = position;

				if (frame.type == H2FrameType.HEADERS && frame.streamId == 1) {
					for (field in decoder.decode(frame.payload)) {
						if (field.name == ":status") {
							status = Std.parseInt(field.value);
						} else {
							headers.set(field.name, field.value);
						}
					}
				} else if (frame.type == H2FrameType.DATA && frame.streamId == 1) {
					payload.addBytes(frame.payload, 0, frame.payload.length);
					payloadLength += frame.payload.length;

					// The client half of flow control, and only where a body
					// actually needs it: without this a transfer past the
					// opening window stops and never resumes -- correctly,
					// which is what makes it the thing under test.
					if (largeFileSize > 0 && frame.payload.length > 0) {
						pendingCredit += frame.payload.length;
					}
				}

				if (frame.streamId == 1 && frame.has(H2Flags.END_STREAM)) {
					finished = true;
					var received:Bytes = payloadLength > 0 ? payload.getBytes() : Bytes.alloc(0);
					shutdown();
					done(status, headers, received);
					return;
				}
			}

		});

		HTTPTestSupport.connectThen(client, server, function():Void {
			// Credit goes out from the pump, not from the socket's own data
			// dispatch: writing to a socket while it is delivering a read
			// throws, and swallowing that only turns a visible failure into a
			// transfer that stalls for no stated reason.
			HTTPTestSupport.pumpUntilAsync(function():Bool {
				if (pendingCredit > 0 && !finished && client.connected) {
					var credit = pendingCredit;
					pendingCredit = 0;
					sendWindowUpdate(client, 0, credit);
					sendWindowUpdate(client, 1, credit);
				}
				return finished;
			}, 10.0, function(reached:Bool):Void {
				if (!reached && !finished) {
					finished = true;
					shutdown();
					Assert.fail("Timed out waiting for the HTTP/2 response");
					async.done();
				}
			});
		});
	}

	private static function sendWindowUpdate(client:Socket, streamId:Int, increment:Int):Void {
		if (!client.connected) {
			return;
		}

		var payload = Bytes.alloc(4);
		payload.set(0, (increment >> 24) & 0xff);
		payload.set(1, (increment >> 16) & 0xff);
		payload.set(2, (increment >> 8) & 0xff);
		payload.set(3, increment & 0xff);

		var out = new BytesBuffer();
		writeFrame(out, H2FrameType.WINDOW_UPDATE, 0, streamId, payload);

		var bytes = out.getBytes();
		var wrapper = new ByteArray();
		wrapper.writeBytes(bytes, 0, bytes.length);

		// The peer can finish and close between the connected check above and
		// this write; returning credit to a connection that no longer needs it
		// is not a failure of what is under test.
		try {
			client.writeBytes(wrapper, 0, wrapper.length);
			client.flush();
		} catch (_:Dynamic) {}
	}

	private static function writeFrame(out:BytesBuffer, type:H2FrameType, flags:Int, streamId:Int, payload:Bytes):Void {
		H2Frame.writeHeader(out, payload.length, type, flags, streamId);
		if (payload.length > 0) {
			out.addBytes(payload, 0, payload.length);
		}
	}
}

/**
 * One HTTP/2 connection to a real `HTTPServer`, kept open across steps.
 *
 * `exchange` answers one request and tears everything down, which suits what a
 * response contains and says nothing about how long a connection lives. This
 * holds the connection, sends each frame when told to, and records what comes
 * back -- including the server ending the connection, and how long after this
 * side last spoke.
 *
 * Every write is made between pumps, never from the socket's data dispatch, for
 * the reason `exchange` gives.
 */
private class H2Session {
	/** `haxe.Timer.stamp()` when this side last wrote a frame. */
	public var lastSentAt(default, null):Float = -1;

	/** When a GOAWAY arrived, or -1. */
	public var goAwayAt(default, null):Float = -1;

	/** The error code that GOAWAY carried, or -1. */
	public var goAwayCode(default, null):Int = -1;

	/**
	 * When the far end closed the socket, or -1. Never set by `close()`: the
	 * socket dispatches `Event.CLOSE` for a local close too, and counting that
	 * would report every session as reaped.
	 */
	public var droppedAt(default, null):Float = -1;

	/** Whether the server closed the socket. */
	public var dropped(get, never):Bool;

	/** Whether the server has ended the connection, by GOAWAY or by closing. */
	public var ended(get, never):Bool;

	private final __root:File;
	private final __server:HTTPServer;
	private final __client:Socket;

	// One of each for the life of the connection. HPACK is connection state: a
	// block skipped, or encoded against a fresh table, leaves the two ends
	// disagreeing about every block after it.
	private final __encoder:HpackEncoder = new HpackEncoder(4096);
	private final __decoder:HpackDecoder = new HpackDecoder(4096);

	private var __inbound:BytesBuffer = new BytesBuffer();
	private var __parsedUpTo:Int = 0;
	private var __settingsArrived:Bool = false;
	private var __closing:Bool = false;
	private final __status:Map<Int, Int> = new Map();
	private final __bodies:Map<Int, Bytes> = new Map();
	private final __finished:Map<Int, Bool> = new Map();

	public function new(configure:HTTPServerConfig->Void) {
		__root = File.createTempDirectory();
		var fixture = new ByteArray();
		fixture.writeUTFBytes("Hello over h2");
		__root.resolvePath("index.html").save(fixture);

		var config = new HTTPServerConfig("127.0.0.1", 0, __root, null, ["index.html"]);
		config.http2Enabled = true;
		configure(config);

		__server = new HTTPServer(config);
		__client = new Socket();

		__client.addEventListener(Event.CONNECT, _ -> {
			var out = new BytesBuffer();
			out.addString(H2Connection.PREFACE);
			__writeFrame(out, H2FrameType.SETTINGS, 0, 0, Bytes.alloc(0));
			__send(out);
		});
		__client.addEventListener(ProgressEvent.SOCKET_DATA, __onData);
		__client.addEventListener(Event.CLOSE, _ -> {
			if (!__closing && droppedAt < 0) {
				droppedAt = haxe.Timer.stamp();
			}
		});
	}

	/** Connects, and continues once the server's SETTINGS shows it is speaking HTTP/2. */
	public function start(then:Void->Void):Void {
		HTTPTestSupport.connectThen(__client, __server, function():Void {
			until(() -> __settingsArrived || ended, function():Void {
				if (!__settingsArrived) {
					Assert.fail("the server never sent its SETTINGS, so this is not an HTTP/2 connection");
				}
				then();
			});
		});
	}

	/** Opens `streamId` with a request, left open for a body unless `endStream`. */
	public function request(streamId:Int, method:String, path:String, endStream:Bool):Void {
		var block:Bytes = __encoder.encode([
			new HpackHeader(":method", method),
			new HpackHeader(":scheme", "http"),
			new HpackHeader(":authority", "127.0.0.1"),
			new HpackHeader(":path", path)
		]);

		var out = new BytesBuffer();
		__writeFrame(out, H2FrameType.HEADERS, H2Flags.END_HEADERS | (endStream ? H2Flags.END_STREAM : 0), streamId, block);
		__send(out);
	}

	/** Sends the rest of a request's body and ends its stream. */
	public function data(streamId:Int, text:String):Void {
		var out = new BytesBuffer();
		__writeFrame(out, H2FrameType.DATA, H2Flags.END_STREAM, streamId, Bytes.ofString(text));
		__send(out);
	}

	/** Pumps until `done` holds or `timeout` seconds pass, then continues. */
	public function until(done:Void->Bool, then:Void->Void, timeout:Float = 5.0):Void {
		HTTPTestSupport.pumpUntilAsync(done, timeout, _ -> then());
	}

	/**
	 * Pumps for `seconds` without sending anything. Cut short if the server
	 * ends the connection, since then there is nothing left to wait for.
	 */
	public function pause(seconds:Float, then:Void->Void):Void {
		var resumeAt:Float = haxe.Timer.stamp() + seconds;
		until(() -> ended || haxe.Timer.stamp() >= resumeAt, then, seconds + 5.0);
	}

	/** Whether `streamId` has been answered in full, or refused. */
	public function finished(streamId:Int):Bool {
		return __finished.exists(streamId);
	}

	public function status(streamId:Int):Int {
		return __status.exists(streamId) ? __status.get(streamId) : -1;
	}

	public function body(streamId:Int):String {
		return __bodies.exists(streamId) ? __bodies.get(streamId).toString() : "";
	}

	/**
	 * Seconds from this side's last frame to the server ending the connection,
	 * to the millisecond, or -1 if it has not.
	 */
	public function silence():Float {
		var endedAt:Float = goAwayAt >= 0 && (droppedAt < 0 || goAwayAt < droppedAt) ? goAwayAt : droppedAt;
		return endedAt < 0 ? -1 : Math.round((endedAt - lastSentAt) * 1000) / 1000;
	}

	/** Closes both ends and removes the document root. */
	public function close():Void {
		__closing = true;
		try {
			__client.close();
		} catch (_:Dynamic) {}
		try {
			__server.close();
		} catch (_:Dynamic) {}
		try {
			__root.deleteDirectory(true);
		} catch (_:Dynamic) {}
	}

	private function get_dropped():Bool {
		return droppedAt >= 0;
	}

	private function get_ended():Bool {
		return goAwayAt >= 0 || droppedAt >= 0;
	}

	private function __send(out:BytesBuffer):Void {
		var bytes:Bytes = out.getBytes();
		var wrapper = new ByteArray();
		wrapper.writeBytes(bytes, 0, bytes.length);

		// A write refused because the server has already hung up is the
		// connection ending, noticed by the side that had not heard yet.
		try {
			__client.writeBytes(wrapper, 0, wrapper.length);
			__client.flush();
		} catch (_:Dynamic) {
			if (droppedAt < 0) {
				droppedAt = haxe.Timer.stamp();
			}
		}
		lastSentAt = haxe.Timer.stamp();
	}

	private function __onData(_:ProgressEvent):Void {
		if (__client.bytesAvailable == 0) {
			return;
		}

		var chunk = new ByteArray();
		__client.readBytes(chunk, 0, __client.bytesAvailable);
		for (i in 0...chunk.length) {
			__inbound.addByte(chunk[i]);
		}

		// Kept whole and read on from a running offset, as `exchange` does.
		var all:Bytes = __inbound.getBytes();
		__inbound = new BytesBuffer();
		__inbound.addBytes(all, 0, all.length);

		while (__parsedUpTo + H2Frame.HEADER_SIZE <= all.length) {
			var length:Int = H2Frame.lengthOf(all, __parsedUpTo);
			if (__parsedUpTo + H2Frame.HEADER_SIZE + length > all.length) {
				break;
			}

			var frame:H2Frame = H2Frame.read(all, __parsedUpTo);
			__parsedUpTo += H2Frame.HEADER_SIZE + length;
			__onFrame(frame);
		}
	}

	private function __onFrame(frame:H2Frame):Void {
		if (frame.type == H2FrameType.SETTINGS) {
			if (!frame.has(H2Flags.ACK)) {
				__settingsArrived = true;
			}
		} else if (frame.type == H2FrameType.HEADERS) {
			// Every block is decoded, whichever stream it belongs to; see the
			// decoder above.
			for (field in __decoder.decode(frame.payload)) {
				if (field.name == ":status") {
					__status.set(frame.streamId, Std.parseInt(field.value));
				}
			}
		} else if (frame.type == H2FrameType.DATA) {
			__append(frame.streamId, frame.payload);
		} else if (frame.type == H2FrameType.RST_STREAM) {
			// Refused rather than answered, which is also the end of it.
			__finished.set(frame.streamId, true);
		} else if (frame.type == H2FrameType.GOAWAY && goAwayAt < 0) {
			goAwayAt = haxe.Timer.stamp();
			var payload:Bytes = frame.payload;
			goAwayCode = (payload.get(4) << 24) | (payload.get(5) << 16) | (payload.get(6) << 8) | payload.get(7);
		}

		if ((frame.type == H2FrameType.HEADERS || frame.type == H2FrameType.DATA) && frame.has(H2Flags.END_STREAM)) {
			__finished.set(frame.streamId, true);
		}
	}

	private function __append(streamId:Int, payload:Bytes):Void {
		var before:Null<Bytes> = __bodies.get(streamId);
		if (before == null) {
			__bodies.set(streamId, payload);
			return;
		}

		var joined:Bytes = Bytes.alloc(before.length + payload.length);
		joined.blit(0, before, 0, before.length);
		joined.blit(before.length, payload, 0, payload.length);
		__bodies.set(streamId, joined);
	}

	private static function __writeFrame(out:BytesBuffer, type:H2FrameType, flags:Int, streamId:Int, payload:Bytes):Void {
		H2Frame.writeHeader(out, payload.length, type, flags, streamId);
		if (payload.length > 0) {
			out.addBytes(payload, 0, payload.length);
		}
	}
}
