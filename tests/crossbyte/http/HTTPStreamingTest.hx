package crossbyte.http;

import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.ProgressEvent;
import crossbyte.io.ByteArray;
import crossbyte.io.File;
import crossbyte.net.Socket;
import utest.Assert;
import utest.Async;

@:access(crossbyte.http.HTTPServer)
@:access(crossbyte.http.HTTPRequestHandler)
@:timeout(60000)
class HTTPStreamingTest extends utest.Test {
	// Several times the streaming watermark, with a deliberately unaligned
	// tail so the final slice is a partial one — an off-by-slice bug at the
	// end of the transfer cannot hide behind a size that divides evenly.
	private static inline var LARGE_SIZE:Int = 2 * 1024 * 1024 + 137;

	// What the held-response cases below send: HELD_PIECES pipelined answers
	// of HELD_PIECE bytes each, written whole -- see __serveHeld -- under an
	// output cap raised past their total.
	private static inline var HELD_PIECE:Int = 512 * 1024;
	private static inline var HELD_PIECES:Int = 128;
	private static inline var HELD_CAP:Int = 96 * 1024 * 1024;

	// What the last __serveHeld saw while it waited, for a precondition that
	// fails: whether the server answered at all, and what it held.
	private static var __heldSaw:String = "";

	public function testLargeFileStreamsWithBoundedBuffer(async:Async):Void {
		__serveFixture(async, LARGE_SIZE, "GET /large.bin HTTP/1.1\r\nHost: localhost\r\n\r\n", function(result):Void {
			Assert.equals(200, result.status);
			Assert.equals(Std.string(LARGE_SIZE), result.headers.get("content-length"));
			Assert.equals(LARGE_SIZE, result.body.length);

			// Byte-exactness at the seams a slice pump can get wrong: the very
			// first and last bytes, and both sides of a slice boundary.
			Assert.equals(__patternAt(0), result.body[0]);
			Assert.equals(__patternAt(LARGE_SIZE - 1), result.body[LARGE_SIZE - 1]);
			for (offset in [1, 65535, 65536, 65537, 131071, 262144, 1048576, LARGE_SIZE - 2]) {
				Assert.equals(__patternAt(offset), result.body[offset]);
			}
			Assert.equals(0, __countPatternMismatches(result.body, 0, LARGE_SIZE, 0));

			// The claim streaming exists to make: memory held per transfer is
			// bounded by watermark plus one slice, never the file. A regression
			// back to whole-file buffering passes every assertion above and only
			// this one catches it.
			Assert.isTrue(result.peak > 0);
			Assert.isTrue(result.peak <= HTTPRequestHandler.STREAM_WATERMARK + HTTPRequestHandler.STREAM_SLICE);
			async.done();
		});
	}

	public function testRangeRequestStreamsPartialContent(async:Async):Void {
		// A span crossing the 128 KB, 192 KB and 256 KB slice boundaries, so
		// the ranged pump must stitch several reads at a nonzero file offset.
		var start:Int = 100000;
		var end:Int = 300000;
		var expected:Int = end - start + 1;
		__serveFixture(async, LARGE_SIZE, 'GET /large.bin HTTP/1.1\r\nHost: localhost\r\nRange: bytes=${start}-${end}\r\n\r\n', function(result):Void {
			Assert.equals(206, result.status);
			Assert.equals('bytes ${start}-${end}/${LARGE_SIZE}', result.headers.get("content-range"));
			Assert.equals(Std.string(expected), result.headers.get("content-length"));
			Assert.equals(expected, result.body.length);
			Assert.equals(__patternAt(start), result.body[0]);
			Assert.equals(__patternAt(end), result.body[expected - 1]);
			Assert.equals(0, __countPatternMismatches(result.body, 0, expected, start));
			Assert.isTrue(result.peak > 0);
			async.done();
		});
	}

	public function testSmallFileKeepsBufferedPath(async:Async):Void {
		var size:Int = 32 * 1024;
		__serveFixture(async, size, "GET /large.bin HTTP/1.1\r\nHost: localhost\r\n\r\n", function(result):Void {
			Assert.equals(200, result.status);
			Assert.equals(size, result.body.length);
			Assert.equals(0, __countPatternMismatches(result.body, 0, size, 0));
			// An untouched peak proves the file went out through the buffered
			// branch: the pump is the only writer of this field.
			Assert.equals(0, result.peak);
			async.done();
		});
	}

	public function testHeadOnLargeFileSendsNoBody(async:Async):Void {
		__serveFixture(async, LARGE_SIZE, "HEAD /large.bin HTTP/1.1\r\nHost: localhost\r\n\r\n", function(result):Void {
			Assert.equals(200, result.status);
			Assert.equals(Std.string(LARGE_SIZE), result.headers.get("content-length"));
			Assert.equals(0, result.body.length);
			Assert.equals(0, result.peak);
			async.done();
		});
	}

	public function testStreamedResponseKeepsTheConnectionUsable(async:Async):Void {
		// A streamed response used to force its connection closed, because
		// the head is written long before the body finishes and settling at
		// head time would either cut the body or let the next request's
		// response interleave into it. Settling moved to the pump instead, so
		// the body's own Content-Length frames it exactly as it does for a
		// buffered response and the connection survives.
		//
		// Both bodies are checked byte-for-byte: a second response that began
		// before the first had drained would corrupt the tail of the first,
		// and a length assertion alone would not see it.
		var root:File = File.createTempDirectory();
		var size:Int = 512 * 1024;
		root.resolvePath("large.bin").save(__makePattern(size));

		var config = new HTTPServerConfig("127.0.0.1", 0, root, null, ["index.html"]);
		var server = new HTTPServer(config);
		var client = new Socket();
		var received = new ByteArray();
		var closeSeen = false;
		var failure:Dynamic = null;

		client.addEventListener(ProgressEvent.SOCKET_DATA, _ -> {
			if (client.bytesAvailable > 0) {
				client.readBytes(received, received.length);
			}
		});
		client.addEventListener(Event.CLOSE, _ -> closeSeen = true);

		var request:String = "GET /large.bin HTTP/1.1\r\nHost: localhost\r\n\r\n";
		client.addEventListener(Event.CONNECT, _ -> {
			client.writeUTFBytes(request);
			client.flush();
		});

		function finish():Void {
			try client.close() catch (_:Dynamic) {}
			try server.close() catch (_:Dynamic) {}
			try root.deleteDirectory(true) catch (_:Dynamic) {}

			if (failure != null) {
				Assert.fail(Std.string(failure));
			}

			async.done();
		}

		try {
			HTTPTestSupport.connectThen(client, server, function():Void {
				var firstEnd:Int = -1;

				HTTPTestSupport.pumpUntilAsync(function() {
					firstEnd = HTTPTestSupport.responseEndAt(__asText(received), 0, false);
					return closeSeen || firstEnd >= 0;
				}, 20.0, function(_):Void {
					Assert.isTrue(firstEnd >= 0);
					Assert.isFalse(closeSeen);

					var head = HTTPTestSupport.parseResponse(__asText(received));
					Assert.equals(200, head.status);
					Assert.equals("keep-alive", head.headers.get("connection"));

					// The whole first body, verified against the pattern.
					var bodyStart:Int = firstEnd - size;
					Assert.equals(0, __countPatternMismatches(received, bodyStart, size, 0));

					// The second request goes out only now, which is the point:
					// it has to reach a connection the first streamed response
					// left usable.
					client.writeUTFBytes(request);
					client.flush();

					var secondEnd:Int = -1;

					HTTPTestSupport.pumpUntilAsync(function() {
						secondEnd = HTTPTestSupport.responseEndAt(__asText(received), firstEnd, false);
						return closeSeen || secondEnd >= 0;
					}, 20.0, function(_):Void {
						Assert.isTrue(secondEnd >= 0);
						Assert.equals(0, __countPatternMismatches(received, secondEnd - size, size, 0));
						finish();
					});
				});
			});
		} catch (error:Dynamic) {
			failure = error;
			finish();
		}
	}

	public function testABodyPastTheOutputBufferIsSentWhole(async:Async):Void {
		// A body larger than maxOutputBufferSize was written whole: what the
		// peer had not taken by the first flush stayed buffered, the socket
		// closed at the cap, and the client got the full Content-Length and a
		// fraction of the body -- a 200, logged and counted as one. The size
		// and the default cap are the audit's: 65,346 bytes of 12 MB arrived.
		var size:Int = 12 * 1024 * 1024 + 7;
		var text:StringBuf = new StringBuf();
		for (i in 0...size) {
			text.addChar(__textAt(i));
		}
		var body:String = text.toString();

		var handler:HTTPRequestHandler = null;
		var config = new HTTPServerConfig("127.0.0.1", 0);
		config.middleware.push(function(h:HTTPRequestHandler, next:?Dynamic->Void):Void {
			handler = h;
			h.respond(200, "text/plain", body);
		});
		var server = new HTTPServer(config);
		var client = new Socket();
		var received = new ByteArray();
		var closeSeen = false;
		client.addEventListener(Event.CONNECT, _ -> {
			client.writeUTFBytes("GET /big HTTP/1.1\r\nHost: localhost\r\n\r\n");
			client.flush();
		});
		client.addEventListener(ProgressEvent.SOCKET_DATA, _ -> {
			if (client.bytesAvailable > 0) {
				client.readBytes(received, received.length);
			}
		});
		client.addEventListener(Event.CLOSE, _ -> closeSeen = true);

		HTTPTestSupport.connectThen(client, server, function():Void {
			HTTPTestSupport.pumpUntilAsync(() -> closeSeen || __responseComplete(received, false), 15.0, function(_):Void {
				var result = __parseResponse(received, handler != null ? handler.__streamPeakBuffered : -1);
				// Read before closing: a local close dispatches CLOSE too.
				var closedByServer:Bool = closeSeen;
				try client.close() catch (_:Dynamic) {}
				try server.close() catch (_:Dynamic) {}

				Assert.equals(200, result.status);
				Assert.equals(Std.string(size), result.headers.get("content-length"));
				Assert.equals(size, result.body.length, "the body was cut off");
				var mismatches:Int = 0;
				for (i in 0...result.body.length) {
					if (result.body[i] != __textAt(i)) {
						mismatches++;
					}
				}
				Assert.equals(0, mismatches);
				// Fed in bursts, as a file is, not written whole.
				Assert.isTrue(result.peak > 0 && result.peak <= HTTPRequestHandler.STREAM_WATERMARK + HTTPRequestHandler.STREAM_SLICE, "peak buffered " + result.peak);
				Assert.equals("keep-alive", result.headers.get("connection"));
				Assert.isFalse(closedByServer, "a kept-alive response closed the connection");
				async.done();
			});
		});
	}

	#if (cpp || neko || hl || jvm)
	public function testAStalledDownloadIsEndedWithBothTimeoutsOff(async:Async):Void {
		// requestTimeout and keepAliveTimeout at 0 set no deadline for what
		// they bound, and the stall deadline is not theirs: a download whose
		// client stops reading is still ended. Its check was reached through
		// the connection's receive deadline, from the sweep those two arm, so
		// with both off nothing looked at it, and the file and the connection
		// were held for good.
		//
		// The client is a plain socket the runtime never reads, so the
		// transfer stalls as one to a client that stopped reading does: the
		// system's buffers fill and the pump parks with the rest of the file
		// unsent. The deadline is then held in the past, as 30 s without
		// progress would leave it: what is under test is whether the running
		// server looks. (Not on Node, which has no such socket.)
		var root:File = File.createTempDirectory();
		var body = new ByteArray();
		body.length = 16 * 1024 * 1024;
		root.resolvePath("large.bin").save(body);

		var handler:HTTPRequestHandler = null;
		var capture = function(h:HTTPRequestHandler, next:?Dynamic->Void):Void {
			handler = h;
			next();
		};
		var config = new HTTPServerConfig("127.0.0.1", 0, root, null, ["index.html"], null, null, null, [capture]);
		config.requestTimeout = 0;
		config.keepAliveTimeout = 0;
		var server = new HTTPServer(config);

		var client = new sys.net.Socket();
		client.connect(new sys.net.Host("127.0.0.1"), server.localPort);
		client.output.writeString("GET /large.bin HTTP/1.1\r\nHost: localhost\r\n\r\n");
		client.output.flush();

		function finish(parked:Bool):Void {
			var streaming:Bool = handler != null && handler.__streaming;
			var open:Int = server.activeConnections;
			try client.close() catch (_:Dynamic) {}
			try server.close() catch (_:Dynamic) {}
			try root.deleteDirectory(true) catch (_:Dynamic) {}
			Assert.isTrue(parked, "the download never stalled, so this shows nothing");
			Assert.isFalse(streaming, "a stalled download outlived its deadline with both timeouts off");
			Assert.equals(0, open, "the server kept the stalled connection");
			async.done();
		}

		// Parked: pumping, with nothing more of the file sent for fifty
		// passes in a row.
		var remaining:Int = -1;
		var still:Int = 0;
		HTTPTestSupport.pumpWallUntilAsync(function():Bool {
			if (handler == null || !handler.__streaming) {
				return false;
			}
			if (handler.__streamRemaining == remaining) {
				still++;
			} else {
				still = 0;
				remaining = handler.__streamRemaining;
			}
			return still >= 50;
		}, 10.0, function(parked:Bool):Void {
			if (!parked) {
				finish(false);
				return;
			}
			HTTPTestSupport.pumpWallUntilAsync(function():Bool {
				if (handler.__streaming) {
					handler.__streamStallDeadline = haxe.Timer.stamp() - 1;
				}
				return !handler.__streaming && server.activeConnections == 0;
			}, 3.0, _ -> finish(true));
		});
	}
	public function testABufferedResponseItsClientTakesNoneOfIsGivenUp(async:Async):Void {
		// A response written whole -- respond() with a body under the output
		// cap -- whose client stopped reading waited in the socket's buffer
		// for as long as the connection lasted: once written it was the idle
		// deadline's to end, and with keepAliveTimeout at 0 there is none. It
		// is given up at the stall deadline, as a file the client takes
		// nothing of is: the connection closed, and its bytes let go.
		__serveHeld(config -> {
			config.requestTimeout = 0;
			config.keepAliveTimeout = 0;
		}, "", function(server:HTTPServer, client:sys.net.Socket, parked:Bool):Void {
			if (parked) {
				// The sweep, once now, seeing where the parked responses stand
				// -- Linux's buffers go on taking a little after they are
				// written, which moves the deadline on, as progress should --
				// and then as it would run once the deadline has passed.
				server.__sweep(haxe.Timer.stamp());
				server.__sweep(haxe.Timer.stamp() + 31);
			}
			HTTPTestSupport.pumpWallUntilAsync(() -> server.activeConnections == 0, parked ? 3.0 : 0.0, function(_):Void {
				var open:Int = server.activeConnections;
				try client.close() catch (_:Dynamic) {}
				try server.close() catch (_:Dynamic) {}
				Assert.isTrue(parked, "the responses never stalled, so this shows nothing" + __heldSaw);
				Assert.equals(0, open, "responses their client took none of were held with both timeouts off");
				async.done();
			});
		});
	}

	public function testAResponseStillGoingOutIsNotReapedAsIdle(async:Async):Void {
		// The idle deadline was counted from when a response was written, not
		// from when its client had it: responses more than the system takes at
		// once, to a client slower to read them than keepAliveTimeout, were
		// cut off at that deadline as though the connection sat idle -- the
		// client got Content-Lengths promised and part of the bodies. A
		// connection is idle from when what it sent has gone.
		__serveHeld(config -> config.keepAliveTimeout = 0.5, "", function(server:HTTPServer, client:sys.net.Socket, parked:Bool):Void {
			// Twice the idle allowance, reading nothing.
			var resumeAt:Float = haxe.Timer.stamp() + 1.0;
			HTTPTestSupport.pumpWallUntilAsync(() -> haxe.Timer.stamp() >= resumeAt, 3.0, function(_):Void {
				__readRaw(client, false, function(whole:Int, closed:Bool):Void {
					try client.close() catch (_:Dynamic) {}
					try server.close() catch (_:Dynamic) {}
					Assert.isTrue(parked, "the responses never waited on their client, so this shows nothing" + __heldSaw);
					Assert.equals(HELD_PIECES, whole, "the responses were cut off");
					async.done();
				});
			});
		});
	}

	public function testAResponseThatClosesItsConnectionIsSentWhole(async:Async):Void {
		// A response with Connection: close -- the client asked for it here,
		// on the last of its requests -- closed its connection as soon as it
		// was written, and closing throws away whatever the system had not
		// taken yet: the responses still waiting reached the client cut off.
		// It closes once all of them have gone.
		__serveHeld(_ -> {}, "Connection: close\r\n", function(server:HTTPServer, client:sys.net.Socket, parked:Bool):Void {
			__readRaw(client, true, function(whole:Int, closed:Bool):Void {
				try client.close() catch (_:Dynamic) {}
				try server.close() catch (_:Dynamic) {}
				Assert.isTrue(parked, "the responses never waited on their client, so this shows nothing" + __heldSaw);
				Assert.equals(HELD_PIECES, whole, "the responses were cut off by the close");
				Assert.isTrue(closed, "the connection was not closed after the response");
				async.done();
			});
		});
	}

	public function testAConnectionDrainClosesIsSentWhole(async:Async):Void {
		// drain() closed a kept-alive connection between requests at once,
		// with nothing in flight -- except the responses still going out to a
		// client reading them slowly, cut off by the close. It closes once
		// they have gone.
		__serveHeld(_ -> {}, "", function(server:HTTPServer, client:sys.net.Socket, parked:Bool):Void {
			var drained:Bool = false;
			server.drain(10.0, () -> drained = true);
			__readRaw(client, true, function(whole:Int, closed:Bool):Void {
				HTTPTestSupport.pumpWallUntilAsync(() -> drained, 3.0, function(_):Void {
					try client.close() catch (_:Dynamic) {}
					try server.close() catch (_:Dynamic) {}
					Assert.isTrue(parked, "the responses never waited on their client, so this shows nothing" + __heldSaw);
					Assert.equals(HELD_PIECES, whole, "the responses were cut off by the drain");
					Assert.isTrue(closed, "the drain did not close the connection");
					Assert.isTrue(drained, "the drain did not finish once the responses had gone");
					async.done();
				});
			});
		});
	}

	/**
		Serves `HELD_PIECES` pipelined requests, each answered with a body of
		`HELD_PIECE` bytes written whole, to a plain socket the runtime does
		not read, which reads nothing. `lastFields` goes on the last request.
		Continues once the server's socket is parked -- bytes waiting it
		cannot send, the same count for fifty passes -- or after ten seconds
		without, saying which.

		Many answers, not one large one: Windows takes a single send whole,
		however large, while what it holds is under its limit, so on neko and
		native there it took 24 MB in one send and held none of it back, where
		Linux's buffers stop at about 10 MB and the jvm's writes at its own.
		Sends of this size it stops taking, as it stops taking a file pumped
		out in bursts.

		And more of them than the system will take: late in a full suite,
		Windows' loopback buffers had grown to take all 24 MB of the 48
		answers this sent, so nothing was held (5,751 samples of 0 bytes,
		2026-10-03) where alone it holds 21.5 MB at once. 64 MB now.
	**/
	private static function __serveHeld(configure:HTTPServerConfig->Void, lastFields:String,
			then:(HTTPServer, sys.net.Socket, Bool) -> Void):Void {
		var body = new ByteArray();
		body.length = HELD_PIECE;
		var handler:HTTPRequestHandler = null;
		var config = new HTTPServerConfig("127.0.0.1", 0);
		config.maxOutputBufferSize = HELD_CAP;
		configure(config);
		config.middleware.push(function(h:HTTPRequestHandler, next:?Dynamic->Void):Void {
			handler = h;
			h.respondBytes(200, "application/octet-stream", body);
		});
		var server = new HTTPServer(config);

		var client = new sys.net.Socket();
		client.connect(new sys.net.Host("127.0.0.1"), server.localPort);
		var requests = new StringBuf();
		for (i in 0...HELD_PIECES) {
			requests.add("GET /piece HTTP/1.1\r\nHost: localhost\r\n" + (i == HELD_PIECES - 1 ? lastFields : "") + "\r\n");
		}
		client.output.writeString(requests.toString());
		client.output.flush();

		var pending:Int = -1;
		var still:Int = 0;
		var samples:Int = 0;
		var started:Float = haxe.Timer.stamp();
		var handled:Float = -1;
		HTTPTestSupport.pumpWallUntilAsync(function():Bool {
			if (handler == null) {
				return false;
			}
			if (handled < 0) {
				handled = haxe.Timer.stamp() - started;
			}
			samples++;
			var now:Int = handler.__origin.outputBufferLength;
			if (now > 0 && now == pending) {
				still++;
			} else {
				still = 0;
				pending = now;
			}
			return still >= 50;
		}, 10.0, function(parked:Bool):Void {
			__heldSaw = " (first request handled after " + (handled < 0 ? "never" : Std.string(Math.round(handled * 1000)) + " ms")
				+ "; " + samples + " samples, last held " + pending + " bytes, " + still + " unchanged)";
			then(server, client, parked);
		});
	}

	/**
		Reads `client`, pumping between reads, until `HELD_PIECES` responses
		of `HELD_PIECE` bytes have all come -- and with `untilClosed`, until
		the server has closed the connection too -- then continues with how
		many came whole and whether the server closed it.
	**/
	private static function __readRaw(client:sys.net.Socket, untilClosed:Bool, then:(Int, Bool) -> Void):Void {
		var received = new ByteArray();
		var closed:Bool = false;
		var chunk = haxe.io.Bytes.alloc(64 * 1024);
		// Where the next response starts, and how many have come whole.
		var at:Int = 0;
		var whole:Int = 0;
		function count():Void {
			while (true) {
				var head:Int = -1;
				var i:Int = at;
				while (i + 3 < received.length) {
					if (received[i] == 13 && received[i + 1] == 10 && received[i + 2] == 13 && received[i + 3] == 10) {
						head = i;
						break;
					}
					i++;
				}
				if (head < 0 || received.length - (head + 4) < HELD_PIECE) {
					return;
				}
				whole++;
				at = head + 4 + HELD_PIECE;
			}
		}
		HTTPTestSupport.pumpWallUntilAsync(function():Bool {
			var grew:Bool = false;
			while (!closed && sys.net.Socket.select([client], null, null, 0).read.length > 0) {
				var read:Int = 0;
				try {
					read = client.input.readBytes(chunk, 0, chunk.length);
				} catch (_:haxe.io.Eof) {
					closed = true;
				} catch (_:Dynamic) {
					closed = true;
				}
				if (read > 0) {
					received.writeBytes(ByteArray.fromBytes(chunk), 0, read);
					grew = true;
				}
			}
			if (grew) {
				count();
			}
			return closed || (!untilClosed && whole >= HELD_PIECES);
		}, 15.0, _ -> then(whole, closed));
	}

	#end

	/** Printable, with a long period: a misplaced slice cannot alias back. */
	private static inline function __textAt(i:Int):Int {
		return 0x30 + ((i ^ (i >> 8) ^ (i >> 16)) & 0x3F);
	}

	/**
	 * The received bytes as text, for the framing helpers. Only the header
	 * blocks are read out of it; body assertions stay on the ByteArray.
	 */
	private static function __asText(bytes:ByteArray):String {
		var out = new StringBuf();
		for (i in 0...bytes.length) {
			out.addChar(bytes[i]);
		}
		return out.toString();
	}

	/**
	 * Serves one request against a temp-rooted server whose only file is
	 * `large.bin` filled with the deterministic pattern, and hands the
	 * parsed response together with the handler's observed peak buffering.
	 */
	private function __serveFixture(async:Async, fileSize:Int, requestText:String, done:StreamedResult->Void):Void {
		// A HEAD response carries the entity headers of the GET it mirrors,
		// content-length included, but no body at all. Without this the
		// completion predicate below waits for a body that is never coming
		// and the test finishes only if the server happens to close first.
		var headOnly:Bool = StringTools.startsWith(requestText, "HEAD ");
		var root:File = File.createTempDirectory();
		var fixtureFile:File = root.resolvePath("large.bin");
		fixtureFile.save(__makePattern(fileSize));

		var handler:HTTPRequestHandler = null;
		// Captured from a middleware rather than sampled out of the server's
		// active map: the map entry disappears the moment the socket closes,
		// so a sampling loop races the very teardown these tests assert on.
		var capture = function(h:HTTPRequestHandler, next:?Dynamic->Void):Void {
			handler = h;
			next();
		};

		var config = new HTTPServerConfig("127.0.0.1", 0, root, null, ["index.html"], null, null, null, [capture]);
		var server = new HTTPServer(config);
		var client = new Socket();
		var received = new ByteArray();
		var closeSeen = false;
		client.addEventListener(Event.CONNECT, _ -> {
			client.writeUTFBytes(requestText);
			client.flush();
		});
		client.addEventListener(ProgressEvent.SOCKET_DATA, _ -> {
			// Bytes only, no per-byte string building: a two-megabyte body
			// appended character by character turns the harness quadratic
			// and the test into a timeout.
			if (client.bytesAvailable > 0) {
				client.readBytes(received, received.length);
			}
		});
		client.addEventListener(Event.CLOSE, _ -> closeSeen = true);

		function finish(failure:Dynamic):Void {
			var result:StreamedResult = failure == null ? __parseResponse(received, handler != null ? handler.__streamPeakBuffered : -1) : null;

			try {
				client.close();
			} catch (_:Dynamic) {}
			try {
				server.close();
			} catch (_:Dynamic) {}
			try {
				root.deleteDirectory(true);
			} catch (_:Dynamic) {}

			if (failure != null) {
				Assert.fail("the request failed: " + Std.string(failure));
				async.done();
				return;
			}

			Assert.notNull(result);
			done(result);
		}

		try {
			HTTPTestSupport.connectThen(client, server, function():Void {
				HTTPTestSupport.pumpUntilAsync(() -> closeSeen || __responseComplete(received, headOnly), 15.0, function(_):Void {
					// Let the transfer finish tearing itself down before anything
					// is torn down around it. A stream still holding its
					// FileStream when the fixture deletes the directory turns a
					// pump bug into a file-locking error somewhere unrelated, and
					// it is also the assertion that the pump releases what it
					// holds at all.
					HTTPTestSupport.pumpUntilAsync(() -> handler == null || handler.__streamSource == null, 5.0, function(_):Void {
						Assert.isTrue(handler == null || handler.__streamSource == null);
						finish(null);
					});
				});
			});
		} catch (error:Dynamic) {
			finish(error);
		}
	}

	/**
	 * Position-dependent with a long period, so a slice that is duplicated,
	 * dropped or reordered cannot alias back to the right value: bytes
	 * 64 KB apart differ because bit 16 feeds the XOR.
	 */
	private static inline function __patternAt(i:Int):Int {
		return (i ^ (i >> 8) ^ (i >> 16)) & 0xFF;
	}

	private static function __makePattern(size:Int):ByteArray {
		var bytes = new ByteArray(size);
		for (i in 0...size) {
			bytes.writeByte(__patternAt(i));
		}
		return bytes;
	}

	private static function __countPatternMismatches(body:ByteArray, bodyOffset:Int, length:Int, patternOffset:Int):Int {
		var mismatches:Int = 0;
		for (i in 0...length) {
			if (body[bodyOffset + i] != __patternAt(patternOffset + i)) {
				mismatches++;
			}
		}
		return mismatches;
	}

	private static function __headerEnd(bytes:ByteArray):Int {
		// The response head is far smaller than this; scanning a bounded
		// prefix keeps the completion predicate cheap enough to run every
		// pump iteration.
		var limit:Int = bytes.length < 8192 ? bytes.length : 8192;
		if (limit < 4) {
			return -1;
		}
		for (i in 0...limit - 3) {
			if (bytes[i] == 13 && bytes[i + 1] == 10 && bytes[i + 2] == 13 && bytes[i + 3] == 10) {
				return i;
			}
		}
		return -1;
	}

	private static function __headerText(bytes:ByteArray, headerEnd:Int):String {
		var text = new StringBuf();
		for (i in 0...headerEnd) {
			text.addChar(bytes[i]);
		}
		return text.toString();
	}

	private static function __responseComplete(bytes:ByteArray, headOnly:Bool):Bool {
		var headerEnd:Int = __headerEnd(bytes);
		if (headerEnd < 0) {
			return false;
		}

		if (headOnly) {
			return true;
		}

		var head:String = __headerText(bytes, headerEnd);
		for (line in head.split("\r\n")) {
			var lower:String = StringTools.trim(line).toLowerCase();
			if (lower.indexOf("content-length:") == 0) {
				var len:Null<Int> = Std.parseInt(StringTools.trim(lower.substr(15)));
				if (len == null) {
					return false;
				}
				return bytes.length >= headerEnd + 4 + len;
			}
		}
		return false;
	}

	private static function __parseResponse(bytes:ByteArray, peak:Int):StreamedResult {
		var status:Int = 0;
		var headers:Map<String, String> = new Map();
		var body = new ByteArray();

		var headerEnd:Int = __headerEnd(bytes);
		if (headerEnd >= 0) {
			var head:String = __headerText(bytes, headerEnd);
			var lines = head.split("\r\n");
			if (lines[0].length >= 12) {
				status = Std.parseInt(lines[0].substr(9, 3));
			}
			for (i in 1...lines.length) {
				var separator:Int = lines[i].indexOf(":");
				if (separator > 0) {
					headers.set(StringTools.trim(lines[i].substr(0, separator)).toLowerCase(), StringTools.trim(lines[i].substr(separator + 1)));
				}
			}

			var bodyStart:Int = headerEnd + 4;
			if (bytes.length > bodyStart) {
				body.writeBytes(bytes, bodyStart, bytes.length - bodyStart);
			}
		}

		return {status: status, headers: headers, body: body, peak: peak};
	}

}

typedef StreamedResult = {
	var status:Int;
	var headers:Map<String, String>;
	var body:ByteArray;
	var peak:Int;
}
