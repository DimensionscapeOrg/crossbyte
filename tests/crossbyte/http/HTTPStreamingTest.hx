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
