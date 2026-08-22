package crossbyte.http;

import crossbyte.core.CrossByte;
import crossbyte.io.ByteArray;

/**
 * Wire-level helpers shared by the HTTP server tests.
 *
 * These lived separately in every suite in this package, and the copies had
 * already drifted: five pump loops, three response parsers, two completeness
 * predicates that disagreed about whether a response missing `Content-Length`
 * was finished. A predicate fixed in one copy left the others deciding
 * completeness by pump timeout instead — which reads as a slow test rather
 * than a wrong one, so it goes unnoticed.
 *
 * What is deliberately not here is the server-and-client scaffold each suite
 * builds around these. Those differ in ways that matter — the fixtures they
 * write, the configuration they apply, whether they hold the connection open
 * — and folding them together would mean a parameter per difference.
 *
 * Not a `utest.Test`, so the suite coverage macro has nothing to register.
 */
class HTTPTestSupport {
	/**
	 * Pumps the current runtime until `done` reports true or `timeout`
	 * seconds pass. Returns whether it finished rather than timed out, so a
	 * caller can assert on that instead of inferring it.
	 *
	 * The short sleep between pumps keeps a spin from starving the peer
	 * socket's own progress on a loaded machine.
	 */
	public static function pumpUntil(done:Void->Bool, timeout:Float, step:Float = 1 / 60, sleepBetween:Float = 0.001):Bool {
		var runtime:CrossByte = CrossByte.current();
		var deadline:Float = Sys.time() + timeout;

		while (!done() && Sys.time() < deadline) {
			runtime.pump(step, 0);

			if (sleepBetween > 0) {
				Sys.sleep(sleepBetween);
			}
		}

		return done();
	}

	/**
	 * Pumps until `done` reports true, then calls `then` with whether it
	 * finished rather than timed out.
	 *
	 * This exists because `pumpUntil` above cannot work on Node, and does not
	 * fail there in a way anyone would notice. Node delivers socket I/O by
	 * returning to its event loop, and a `while` loop holding the thread never
	 * returns to it -- so nothing arrives, `done` stays false, and the loop
	 * spends its whole timeout before reporting a clean "timed out". Measured
	 * rather than assumed: a probe doing this could not even read the port off
	 * a listening server, because `listen()` resolves asynchronously there too.
	 *
	 * So on Node the pumping is spread across event loop turns. On every other
	 * target this delegates to `pumpUntil` and calls `then` inline, which keeps
	 * the native tests exactly as fast and exactly as debuggable as they were:
	 * a failing assertion still unwinds through the test body rather than
	 * arriving on some later turn with no stack.
	 */
	public static function pumpUntilAsync(done:Void->Bool, timeout:Float, then:Bool->Void, step:Float = 1 / 60):Void {
		#if nodejs
		var runtime:CrossByte = CrossByte.current();
		var deadline:Float = Sys.time() + timeout;

		function turn():Void {
			runtime.pump(step, 0);

			if (done()) {
				then(true);
				return;
			}

			if (Sys.time() >= deadline) {
				then(false);
				return;
			}

			// setTimeout rather than setImmediate: an immediate runs before
			// the loop polls for I/O, so a tight chain of them starves the
			// very sockets being waited on -- the same failure as the while
			// loop, only harder to see.
			js.Node.setTimeout(turn, 1);
		}

		turn();
		#else
		then(pumpUntil(done, timeout, step));
		#end
	}

	/**
	 * Waits for `server` to have a port, connects `client` to it, then calls
	 * `then`.
	 *
	 * The wait is not ceremony. A native `ServerSocket` has bound by the time
	 * its constructor returns, so `localPort` is readable immediately; Node has
	 * no bind separate from listen and claims the port on a later turn, so
	 * reading it straight away gives `0` and connecting to port 0 fails in a
	 * way that has nothing to do with the case being tested.
	 */
	public static function connectThen(client:crossbyte.net.Socket, server:HTTPServer, then:Void->Void):Void {
		pumpUntilAsync(() -> server.localPort != 0, 2.0, function(_):Void {
			client.connect("127.0.0.1", server.localPort);
			then();
		});
	}

	/** Pumps `count` further times, for settling work that follows a close. */
	public static function pumpMore(count:Int, step:Float = 1 / 60):Void {
		var runtime:CrossByte = CrossByte.current();

		for (i in 0...count) {
			runtime.pump(step, 0);
		}
	}

	/**
	 * `pumpMore`, spread over event loop turns where that is the only way it
	 * can mean anything.
	 */
	public static function pumpMoreAsync(count:Int, then:Void->Void, step:Float = 1 / 60):Void {
		#if nodejs
		var runtime:CrossByte = CrossByte.current();
		var remaining:Int = count;

		function turn():Void {
			runtime.pump(step, 0);
			remaining--;

			if (remaining <= 0) {
				then();
				return;
			}

			js.Node.setTimeout(turn, 1);
		}

		turn();
		#else
		pumpMore(count, step);
		then();
		#end
	}

	/**
	 * Whether a complete response begins at the start of `raw`.
	 */
	public static function isResponseComplete(raw:String, headOnly:Bool = false):Bool {
		return responseEndAt(raw, 0, headOnly) >= 0;
	}

	/**
	 * Absolute index one past the end of the response starting at `start`, or
	 * -1 while it is still incomplete.
	 *
	 * Leading 1xx interim blocks are skipped, since they carry no framing of
	 * their own; without that a response following `Expect: 100-continue` is
	 * never seen as complete and the caller waits out its whole timeout.
	 * `headOnly` ends the response at its header terminator, because a HEAD
	 * response advertises a `Content-Length` it will never send.
	 *
	 * Being offset-aware is what lets a caller walk several responses off one
	 * kept-alive connection instead of only ever inspecting the first.
	 */
	public static function responseEndAt(raw:String, start:Int, headOnly:Bool):Int {
		while (raw.indexOf("HTTP/1.1 100 ", start) == start || raw.indexOf("HTTP/1.0 100 ", start) == start) {
			var interimEnd:Int = raw.indexOf("\r\n\r\n", start);
			if (interimEnd < 0) {
				return -1;
			}
			start = interimEnd + 4;
		}

		var headerEnd:Int = raw.indexOf("\r\n\r\n", start);
		if (headerEnd < 0) {
			return -1;
		}

		var bodyStart:Int = headerEnd + 4;
		if (headOnly || statusOmitsBody(raw, start)) {
			return bodyStart;
		}

		for (line in raw.substring(start, headerEnd).split("\r\n")) {
			var lower:String = StringTools.trim(line).toLowerCase();
			if (lower.indexOf("content-length:") == 0) {
				// Parsed from the trimmed, lowercased copy rather than sliced
				// out of the original at a fixed offset: a leading space made
				// that arithmetic produce null, which then read as a
				// zero-length body and declared a response complete before any
				// of it had arrived.
				var len:Null<Int> = Std.parseInt(StringTools.trim(lower.substr(15)));
				if (len == null) {
					return -1;
				}
				return raw.length >= bodyStart + len ? bodyStart + len : -1;
			}
		}

		return -1;
	}

	/**
	 * Whether the response beginning at `start` is one RFC 7230 3.3.3 ends at
	 * the header terminator whatever the headers say.
	 *
	 * A 1xx, 204 or 304 carries no body by definition, so the server sends no
	 * `Content-Length` for one -- and a reader that waits for that header waits
	 * forever. The same rule `headOnly` above encodes, arrived at from the
	 * status line instead of from the request method.
	 */
	public static function statusOmitsBody(raw:String, start:Int = 0):Bool {
		var lineEnd:Int = raw.indexOf("\r\n", start);

		if (lineEnd < 0) {
			return false;
		}

		var parts:Array<String> = raw.substring(start, lineEnd).split(" ");

		if (parts.length < 2) {
			return false;
		}

		var code:Null<Int> = Std.parseInt(parts[1]);

		if (code == null) {
			return false;
		}

		return code == 204 || code == 304 || (code >= 100 && code < 200);
	}

	/**
	 * How many complete responses `raw` holds.
	 *
	 * Walks them with `responseEndAt` rather than counting status lines, so a
	 * body that happens to contain one is not mistaken for a response, and a
	 * trailing partial response is not counted as arrived.
	 */
	public static function countResponses(raw:String):Int {
		var count:Int = 0;
		var cursor:Int = 0;

		while (cursor < raw.length) {
			var end:Int = responseEndAt(raw, cursor, false);

			if (end < 0) {
				break;
			}

			count++;
			cursor = end;
		}

		return count;
	}

	/**
	 * Splits one response out of `raw`, skipping any 1xx interim blocks ahead
	 * of it. `bytes` supplies the body byte-exactly, for suites asserting on
	 * compressed or binary payloads.
	 */
	public static function parseResponse(raw:String, ?bytes:ByteArray):HTTPTestResponse {
		var originalRaw:String = raw;
		var parseBytes:ByteArray = bytes;

		while (raw.indexOf("HTTP/1.1 100 ") == 0 || raw.indexOf("HTTP/1.0 100 ") == 0) {
			var interimEnd:Int = raw.indexOf("\r\n\r\n");
			if (interimEnd < 0) {
				break;
			}

			var drop:Int = interimEnd + 4;
			raw = raw.substr(drop);

			if (parseBytes != null) {
				var next:ByteArray = new ByteArray();
				if (parseBytes.length > drop) {
					next.writeBytes(parseBytes, drop, parseBytes.length - drop);
				}
				parseBytes = next;
			}
		}

		var lineEnd:Int = raw.indexOf("\r\n");
		var status:Int = 0;
		if (lineEnd >= 12) {
			status = Std.parseInt(raw.substr(9, 3));
		}

		var headers:Map<String, String> = new Map();
		var body:String = "";
		var responseBody:ByteArray = new ByteArray();
		var headerEnd:Int = raw.indexOf("\r\n\r\n");

		if (headerEnd >= 0) {
			for (line in raw.substr(lineEnd + 2, headerEnd - lineEnd - 2).split("\r\n")) {
				var separator:Int = line.indexOf(":");
				if (separator > 0) {
					headers.set(StringTools.trim(line.substr(0, separator)).toLowerCase(), StringTools.trim(line.substr(separator + 1)));
				}
			}

			body = raw.substr(headerEnd + 4);

			if (parseBytes != null && parseBytes.length >= headerEnd + 4) {
				responseBody.writeBytes(parseBytes, headerEnd + 4, parseBytes.length - (headerEnd + 4));
			}
		}

		return {
			status: status,
			headers: headers,
			body: body,
			bodyBytes: responseBody,
			raw: originalRaw
		};
	}
}

typedef HTTPTestResponse = {
	var status:Int;
	var headers:Map<String, String>;
	var body:String;
	var bodyBytes:ByteArray;
	var raw:String;
}
