package stress;

import crossbyte.core.CrossByte;
import crossbyte.http.HTTPServer;
import crossbyte.http.HTTPServerConfig;
import crossbyte.http.RateLimiter;
import crossbyte.io.ByteArray;
import crossbyte.io.File;
import sys.thread.Mutex;
import sys.thread.Thread;

/**
 * Many real clients against one server, over connections they keep open.
 *
 * Every other measurement of the HTTP and socket work was taken one
 * connection at a time, which cannot see the thing most likely to be wrong:
 * the read buffer is now shared per thread, poll owns the frame budget,
 * connections survive their responses, and a sweep walks every live handler
 * four times a second. Each of those is sound alone. This is whether they are
 * sound together, with a few hundred connections doing it at once.
 *
 * Clients are plain blocking `sys.net.Socket`s on their own threads, which
 * makes them stand in for arbitrary HTTP clients rather than for CrossByte
 * talking to itself. Putting them on the server's own runtime would make
 * client and server take turns through one loop, which is not concurrency at
 * all; giving each a CrossByte runtime of its own would be genuine, and is
 * what MultiRuntimeSocketStress does. This case deliberately keeps the client
 * side dumb so that anything it catches belongs to the server.
 *
 * Invariants, which hold regardless of how fast the machine is:
 *
 * - every request is answered, with the body it asked for and nothing else
 *   spliced into it
 * - no connection is closed while requests are still outstanding on it
 * - the server's connection count returns to zero once the clients are gone
 *
 * Throughput and latency are reported rather than asserted. A CI runner's
 * speed is not a property of this code, and a test that fails when a machine
 * is busy teaches people to ignore it.
 */
class HttpConcurrentLoadStress implements StressCase {
	private static inline final CLIENTS:Int = 64;
	private static inline final REQUESTS_PER_CLIENT:Int = 25;
	private static inline final BODY:String = "load-test-fixture-body";
	private static inline final TIMEOUT:Float = 60.0;

	private var lock:Mutex;
	private var completed:Int = 0;
	private var wrongStatus:Int = 0;
	private var wrongBody:Int = 0;
	private var prematureClose:Int = 0;
	private var errors:Array<String> = [];
	private var latencyTotal:Float = 0.0;
	private var latencyWorst:Float = 0.0;

	public function new() {
		lock = new Mutex();
	}

	public function run():StressResult {
		var root:File = File.createTempDirectory();
		var fixture:ByteArray = new ByteArray();
		fixture.writeUTFBytes(BODY);
		root.resolvePath("index.html").save(fixture);

		// Every client here comes from 127.0.0.1, so the default limiter — ten
		// requests a minute per address — sees one very busy client and starts
		// answering 429 after the tenth. That is the limiter working, and it is
		// what the first run of this case measured. Real load arrives from many
		// addresses; a loopback test cannot, so it is raised out of the way to
		// leave the server itself as the thing under test.
		var config = new HTTPServerConfig("127.0.0.1", 0, root, null, ["index.html"], null, null, null, null,
			new RateLimiter(1000000, 1.0));
		var server = new HTTPServer(config);
		var port:Int = server.localPort;

		var started:Float = Sys.time();

		for (i in 0...CLIENTS) {
			Thread.create(function() {
				__client(port);
			});
		}

		var runtime:CrossByte = CrossByte.current();
		var deadline:Float = Sys.time() + TIMEOUT;
		var expected:Int = CLIENTS * REQUESTS_PER_CLIENT;

		while (Sys.time() < deadline) {
			runtime.pump(1 / 120, 0);

			lock.acquire();
			var done:Bool = completed + wrongStatus + wrongBody + prematureClose + errors.length >= expected;
			lock.release();

			if (done) {
				break;
			}
		}

		var elapsed:Float = Sys.time() - started;

		// The clients are gone; let the server observe their closes and settle
		// its accounting before it is asked what it still holds.
		var settleUntil:Float = Sys.time() + 3.0;
		while (Sys.time() < settleUntil && server.activeConnections > 0) {
			runtime.pump(1 / 120, 0);
		}

		var leftOpen:Int = server.activeConnections;

		try {
			server.close();
		} catch (_:Dynamic) {}
		try {
			root.deleteDirectory(true);
		} catch (_:Dynamic) {}

		lock.acquire();
		var ok:Int = completed;
		var badStatus:Int = wrongStatus;
		var badBody:Int = wrongBody;
		var earlyClose:Int = prematureClose;
		var failed:Array<String> = errors.copy();
		var meanLatency:Float = ok > 0 ? (latencyTotal / ok) : 0.0;
		var worstLatency:Float = latencyWorst;
		lock.release();

		var passed:Bool = ok == expected && badStatus == 0 && badBody == 0 && earlyClose == 0 && failed.length == 0 && leftOpen == 0;

		var details:Array<String> = [
			'clients: $CLIENTS, requests each: $REQUESTS_PER_CLIENT (expected $expected)',
			'answered correctly: $ok',
			'wrong status: $badStatus, wrong body: $badBody, closed early: $earlyClose',
			'client errors: ' + failed.length + (failed.length > 0 ? " -> " + failed[0] : ""),
			'connections still held after clients exited: $leftOpen',
			'wall time: ' + Math.round(elapsed * 1000) + 'ms, throughput: ' + Math.round(ok / elapsed) + ' req/sec',
			'latency mean: ' + Math.round(meanLatency * 1000) + 'ms, worst: ' + Math.round(worstLatency * 1000) + 'ms'
		];

		return {
			name: "HttpConcurrentLoadStress",
			passed: passed,
			details: details
		};
	}

	/**
	 * One client: connect once, then issue every request down that same
	 * connection, which is what makes this exercise keep-alive rather than a
	 * sequence of unrelated conversations.
	 */
	private function __client(port:Int):Void {
		var socket:sys.net.Socket = null;

		try {
			socket = new sys.net.Socket();
			socket.connect(new sys.net.Host("127.0.0.1"), port);

			var pending:String = "";

			for (i in 0...REQUESTS_PER_CLIENT) {
				var sentAt:Float = Sys.time();
				socket.output.writeString("GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n");
				socket.output.flush();

				var body:String = null;

				while (body == null) {
					var end:Int = __responseEnd(pending);

					if (end >= 0) {
						body = __bodyOf(pending.substr(0, end));
						pending = pending.substr(end);
						break;
					}

					// Blocking read: this thread has nothing else to do, and a
					// spin here would steal the core the server is running on.
					var chunk:String = socket.input.readString(1);
					pending += chunk;
				}

				var took:Float = Sys.time() - sentAt;

				lock.acquire();
				if (body == BODY) {
					completed++;
					latencyTotal += took;
					if (took > latencyWorst) {
						latencyWorst = took;
					}
				} else {
					wrongBody++;
				}
				lock.release();
			}

			socket.close();
		} catch (e:haxe.io.Eof) {
			// The peer closed while this client still had requests to make,
			// which under keep-alive is the failure rather than the normal end.
			lock.acquire();
			prematureClose++;
			lock.release();
			__closeQuietly(socket);
		} catch (e:Dynamic) {
			lock.acquire();
			errors.push(Std.string(e));
			lock.release();
			__closeQuietly(socket);
		}
	}

	private function __closeQuietly(socket:sys.net.Socket):Void {
		if (socket != null) {
			try {
				socket.close();
			} catch (_:Dynamic) {}
		}
	}

	/** Index one past the end of the first complete response in `raw`, or -1. */
	private function __responseEnd(raw:String):Int {
		var headerEnd:Int = raw.indexOf("\r\n\r\n");

		if (headerEnd < 0) {
			return -1;
		}

		var bodyStart:Int = headerEnd + 4;

		for (line in raw.substr(0, headerEnd).split("\r\n")) {
			var lower:String = StringTools.trim(line).toLowerCase();

			if (lower.indexOf("content-length:") == 0) {
				var length:Null<Int> = Std.parseInt(StringTools.trim(lower.substr(15)));

				if (length == null) {
					return -1;
				}

				return raw.length >= bodyStart + length ? bodyStart + length : -1;
			}
		}

		return -1;
	}

	private function __bodyOf(response:String):String {
		var headerEnd:Int = response.indexOf("\r\n\r\n");

		if (response.indexOf("HTTP/1.1 200") != 0) {
			lock.acquire();
			wrongStatus++;
			lock.release();
		}

		return headerEnd >= 0 ? response.substr(headerEnd + 4) : "";
	}
}
