package crossbyte.http;

import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.ProgressEvent;
import crossbyte.io.ByteArray;
import crossbyte.io.File;
import crossbyte.net.Socket;
import utest.Assert;

@:access(crossbyte.http.HTTPServer)
@:access(crossbyte.http.HTTPRequestHandler)
class HTTPStreamingTest extends utest.Test {
	// Several times the streaming watermark, with a deliberately unaligned
	// tail so the final slice is a partial one — an off-by-slice bug at the
	// end of the transfer cannot hide behind a size that divides evenly.
	private static inline var LARGE_SIZE:Int = 2 * 1024 * 1024 + 137;

	public function testLargeFileStreamsWithBoundedBuffer():Void {
		var result = __serveFixture(LARGE_SIZE, "GET /large.bin HTTP/1.1\r\nHost: localhost\r\n\r\n");

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
	}

	public function testRangeRequestStreamsPartialContent():Void {
		// A span crossing the 128 KB, 192 KB and 256 KB slice boundaries, so
		// the ranged pump must stitch several reads at a nonzero file offset.
		var start:Int = 100000;
		var end:Int = 300000;
		var expected:Int = end - start + 1;
		var result = __serveFixture(LARGE_SIZE, 'GET /large.bin HTTP/1.1\r\nHost: localhost\r\nRange: bytes=${start}-${end}\r\n\r\n');

		Assert.equals(206, result.status);
		Assert.equals('bytes ${start}-${end}/${LARGE_SIZE}', result.headers.get("content-range"));
		Assert.equals(Std.string(expected), result.headers.get("content-length"));
		Assert.equals(expected, result.body.length);
		Assert.equals(__patternAt(start), result.body[0]);
		Assert.equals(__patternAt(end), result.body[expected - 1]);
		Assert.equals(0, __countPatternMismatches(result.body, 0, expected, start));
		Assert.isTrue(result.peak > 0);
	}

	public function testSmallFileKeepsBufferedPath():Void {
		var size:Int = 32 * 1024;
		var result = __serveFixture(size, "GET /large.bin HTTP/1.1\r\nHost: localhost\r\n\r\n");

		Assert.equals(200, result.status);
		Assert.equals(size, result.body.length);
		Assert.equals(0, __countPatternMismatches(result.body, 0, size, 0));
		// An untouched peak proves the file went out through the buffered
		// branch: the pump is the only writer of this field.
		Assert.equals(0, result.peak);
	}

	public function testHeadOnLargeFileSendsNoBody():Void {
		var result = __serveFixture(LARGE_SIZE, "HEAD /large.bin HTTP/1.1\r\nHost: localhost\r\n\r\n");

		Assert.equals(200, result.status);
		Assert.equals(Std.string(LARGE_SIZE), result.headers.get("content-length"));
		Assert.equals(0, result.body.length);
		Assert.equals(0, result.peak);
	}

	/**
	 * Serves one request against a temp-rooted server whose only file is
	 * `large.bin` filled with the deterministic pattern, and returns the
	 * parsed response together with the handler's observed peak buffering.
	 */
	private function __serveFixture(fileSize:Int, requestText:String):StreamedResult {
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
		var result:StreamedResult = null;
		var requestFailed:Dynamic = null;

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

		try {
			client.connect("127.0.0.1", server.localPort);
			__pumpUntil(() -> closeSeen || __responseComplete(received), 15.0);

			// Let the transfer finish tearing itself down before anything is
			// torn down around it. A stream still holding its FileStream
			// when the fixture deletes the directory turns a pump bug into a
			// file-locking error somewhere unrelated, and it is also the
			// assertion that the pump releases what it holds at all.
			__pumpUntil(() -> handler == null || handler.__streamSource == null, 5.0);
			Assert.isTrue(handler == null || handler.__streamSource == null);

			result = __parseResponse(received, handler != null ? handler.__streamPeakBuffered : -1);
			try {
				client.close();
			} catch (_:Dynamic) {}
		} catch (error:Dynamic) {
			requestFailed = error;
		}

		try {
			server.close();
		} catch (_:Dynamic) {}
		try {
			root.deleteDirectory(true);
		} catch (_:Dynamic) {}

		if (requestFailed != null) {
			throw requestFailed;
		}

		Assert.notNull(result);
		return result;
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

	private static function __responseComplete(bytes:ByteArray):Bool {
		var headerEnd:Int = __headerEnd(bytes);
		if (headerEnd < 0) {
			return false;
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

	private function __pumpUntil(done:Void->Bool, timeout:Float):Void {
		var runtime = CrossByte.current();
		var deadline = Sys.time() + timeout;
		while (!done() && Sys.time() < deadline) {
			runtime.pump(1 / 60, 0);
			Sys.sleep(0.001);
		}
	}
}

typedef StreamedResult = {
	var status:Int;
	var headers:Map<String, String>;
	var body:ByteArray;
	var peak:Int;
}
