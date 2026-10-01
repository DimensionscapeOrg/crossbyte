package crossbyte.http;

import crossbyte.core.CrossByte;
import crossbyte.io.ByteArray;
import crossbyte.sys.System;

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
		var deadline:Float = haxe.Timer.stamp() + timeout;

		while (!done() && haxe.Timer.stamp() < deadline) {
			runtime.pump(step, 0);

			if (sleepBetween > 0) {
				nap(sleepBetween);
			}
		}

		return done();
	}

	/**
		Waits about `seconds`, for a pump loop to give the other side a turn.

		Through `System.sleep`, not `Sys.sleep`: on the interpreter under
		Windows a sleep of a millisecond or two can be left a negative
		remainder, which OCaml hands to `Sleep()` as about 49 days. That was
		the interpreter's intermittent hang in
		`URLLoaderHttpTest.testClosingALoadInFlightEndsItQuietly`, which
		stalled in its pump loop's sleep with every other thread idle.
	**/
	public static inline function nap(seconds:Float):Void {
		System.sleep(seconds);
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
		var deadline:Float = haxe.Timer.stamp() + timeout;

		function turn():Void {
			runtime.pump(step, 0);

			if (done()) {
				then(true);
				return;
			}

			if (haxe.Timer.stamp() >= deadline) {
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
	 * `pumpUntilAsync`, each pump advancing the runtime by the wall time since
	 * the one before, so the runtime's clock keeps to the wall's on every
	 * system.
	 *
	 * A fixed step cannot: what a millisecond's sleep takes differs, a
	 * millisecond on Linux and up to a timer tick of 15.6 ms on Windows, so a
	 * step of a millisecond ran the runtime's clock fifteen times slower than
	 * the wall there and a sixtieth fifteen times faster on Linux. The server's
	 * sweep runs on that clock and its deadlines on the wall's, so a case
	 * waiting for a deadline to be enforced saw the sweep come seconds late on
	 * one system, and spent utest's timeout, which also runs on that clock,
	 * fifteen times over on the other.
	 */
	public static function pumpWallUntilAsync(done:Void->Bool, timeout:Float, then:Bool->Void):Void {
		var runtime:CrossByte = CrossByte.current();
		var last:Float = haxe.Timer.stamp();
		var deadline:Float = last + timeout;

		#if nodejs
		function turn():Void {
			var now:Float = haxe.Timer.stamp();
			runtime.pump(now - last, 0);
			last = now;

			if (done()) {
				then(true);
				return;
			}

			if (now >= deadline) {
				then(false);
				return;
			}

			js.Node.setTimeout(turn, 1);
		}

		turn();
		#else
		while (!done() && haxe.Timer.stamp() < deadline) {
			var now:Float = haxe.Timer.stamp();
			runtime.pump(now - last, 0);
			last = now;
			nap(0.001);
		}

		then(done());
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

	/**
	 * Sends each of `requests` on a connection of its own, one after another,
	 * and hands back what each connection received, in order.
	 *
	 * A connection is read until its response is complete, or with
	 * `untilClosed` until the server closes it -- which is how a case shows a
	 * second response never followed the first. One that answers nothing
	 * before `timeout` comes back with status 0 rather than failing here, so
	 * the case decides what that means.
	 *
	 * Each byte becomes one character of `raw` and `body`, as `__sendRequest`
	 * in the handler suite does, so a binary body survives the trip.
	 */
	public static function exchangeEach(server:HTTPServer, requests:Array<String>, done:Array<HTTPTestResponse>->Void, untilClosed:Bool = false,
			timeout:Float = 3.0):Void {
		var responses:Array<HTTPTestResponse> = [];

		function next(index:Int):Void {
			if (index >= requests.length) {
				done(responses);
				return;
			}

			var request:String = requests[index];
			var client:crossbyte.net.Socket = new crossbyte.net.Socket();
			var raw:String = "";
			var bytes:ByteArray = new ByteArray();
			var closed:Bool = false;

			client.addEventListener(crossbyte.events.Event.CONNECT, function(_):Void {
				client.writeUTFBytes(request);
				client.flush();
			});
			client.addEventListener(crossbyte.events.ProgressEvent.SOCKET_DATA, function(_):Void {
				if (client.bytesAvailable > 0) {
					var chunk:ByteArray = new ByteArray();
					client.readBytes(chunk, 0, client.bytesAvailable);
					bytes.writeBytes(chunk, 0, chunk.length);
					for (i in 0...chunk.length) {
						raw += String.fromCharCode(chunk[i]);
					}
				}
			});
			client.addEventListener(crossbyte.events.Event.CLOSE, function(_):Void {
				closed = true;
			});

			var headOnly:Bool = StringTools.startsWith(request, "HEAD ");
			connectThen(client, server, function():Void {
				pumpUntilAsync(() -> closed || (!untilClosed && isResponseComplete(raw, headOnly)), timeout, function(_):Void {
					try {
						client.close();
					} catch (_:Dynamic) {}
					responses.push(parseResponse(raw, bytes));
					next(index + 1);
				});
			});
		}

		next(0);
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
