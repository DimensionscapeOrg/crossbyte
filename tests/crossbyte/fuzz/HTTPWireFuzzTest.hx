package crossbyte.fuzz;

import crossbyte.http.HTTPServer;
import crossbyte.http.HTTPServerConfig;
import crossbyte.http.RateLimiter;
import crossbyte.http.HTTPTestSupport;
import crossbyte.io.ByteArray;
import crossbyte.io.File;
import crossbyte.net.Socket;
import haxe.io.Bytes;
import utest.Assert;
import utest.Async;

/**
 * Sends a real server real nonsense over a real socket, then asks it for a
 * page.
 *
 * `ParserFuzzTest` fuzzes the parsers that are pure functions over bytes. The
 * two most exposed parsers in this codebase are not: an HTTP request is read
 * across reads, out of a buffer that persists between them, by a handler that
 * also owns a socket and writes replies. Reaching that through `@:privateAccess`
 * would mean assembling a handler with no server behind it and hoping the
 * fields chosen are the ones that matter -- and a fuzz case that quietly stops
 * reaching the parser is worse than none, because it still reads as coverage.
 *
 * So this drives the socket instead, which is also the way an attacker would.
 * Whatever state the handler keeps, keeps itself.
 *
 * **The assertion is the last request, not the malformed ones.** Each round is
 * entitled to any answer at all: a 400, a close, silence. What is not allowed
 * is for the server to be unable to serve a perfectly ordinary GET afterwards.
 * That one assertion catches a crash, a hung accept loop, a handler wedged
 * mid-parse, a connection never reclaimed, and a buffer left holding the last
 * peer's bytes -- none of which a per-round assertion would notice, because
 * each round is allowed to fail.
 */
@:timeout(120000)
class HTTPWireFuzzTest extends utest.Test {
	/** Malformed connections before the server is asked to prove it is well. **/
	private static inline var ROUNDS:Int = 120;

	/** Pump turns given to each round, enough for a reply or a close. **/
	private static inline var TURNS_PER_ROUND:Int = 4;

	private var __roots:Array<File> = [];
	private var __state:Int;

	/**
		Rounds the rate limiter answered instead of the parser.

		The first run of this test spent a hundred and ten of its hundred and
		twenty rounds here without saying so. `HTTPServerConfig` fits a
		`RateLimiter` by default -- ten requests a minute -- so every round
		past the tenth was refused before `__parseRequest` was reached, and the
		fuzzer was exercising the limiter. It only showed because the closing
		request came back 429 as well. Counting them is cheaper than finding
		out that way twice.
	**/
	private var __rateLimited:Int = 0;

	public function setup():Void {
		// Seeded, so a red run reproduces.
		__state = 0x0FF1CE99;
	}

	public function teardown():Void {
		for (root in __roots) {
			try {
				root.deleteDirectory(true);
			} catch (_:Dynamic) {}
		}

		__roots = [];
	}

	public function testTheServerStillServesAfterMalformedTraffic(async:Async):Void {
		var server:HTTPServer = __makeServer();

		function finish():Void {
			Assert.equals(0, __rateLimited,
				"the rate limiter answered " + __rateLimited + " of " + ROUNDS + " rounds, so the parser never saw them");

			// The whole point. After everything above, an ordinary request.
			var client:Socket = new Socket();
			var raw:String = "";
			client.addEventListener(crossbyte.events.ProgressEvent.SOCKET_DATA, function(_):Void {
				raw += client.readUTFBytes(client.bytesAvailable);
			});

			HTTPTestSupport.connectThen(client, server, function():Void {
				client.writeUTFBytes("GET /index.html HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
				client.flush();

				HTTPTestSupport.pumpUntilAsync(() -> HTTPTestSupport.isResponseComplete(raw), 5.0, function(complete:Bool):Void {
					Assert.isTrue(complete, "the server stopped answering after malformed traffic; last bytes: " + raw);
					Assert.isTrue(raw.indexOf("200") > 0, "expected a 200 after malformed traffic, got: " + raw);
					Assert.isTrue(raw.indexOf("fuzz fixture") > 0, "the body was not served after malformed traffic: " + raw);

					try client.close() catch (_:Dynamic) {}

					// Retention, which nothing above in this case can see:
					// every assertion so far is satisfied by a server that
					// kept a handler for each of those 120 peers. It still
					// answers, it still serves the body, and it grows by one
					// connection per malformed visitor until it dies.
					//
					// The drain and metrics cases do catch a break in
					// cleanupSocket itself -- measured, they go red alongside
					// this one when it is disabled. What they cannot reach is
					// retention that only adversarial traffic produces, which
					// is the shape the SCTP and WebSocket growth bugs had:
					// those passed the entire suite green.
					HTTPTestSupport.pumpMoreAsync(30, function():Void {
						var retained:Int = @:privateAccess server.__connections;

						Assert.isTrue(retained <= 1,
							"the server still held " + retained + " connections after all " + (ROUNDS + 1)
							+ " peers had closed, so it retains one per visitor");

						try server.close() catch (_:Dynamic) {}
						async.done();
					});
				});
			});
		}

		function round(index:Int):Void {
			if (index >= ROUNDS) {
				finish();
				return;
			}

			var client:Socket = new Socket();
			var reply:String = "";
			client.addEventListener(crossbyte.events.ProgressEvent.SOCKET_DATA, function(_):Void {
				try {
					reply += client.readUTFBytes(client.bytesAvailable);
				} catch (_:Dynamic) {}
			});

			HTTPTestSupport.connectThen(client, server, function():Void {
				try {
					client.writeBytes(ByteArray.fromBytes(__malformed(index)));
					client.flush();
				} catch (_:Dynamic) {
					// The server may have closed on us mid-write, which is one
					// of the answers a malformed request is entitled to.
				}

				HTTPTestSupport.pumpMoreAsync(TURNS_PER_ROUND, function():Void {
					if (reply.indexOf("429") > 0) {
						__rateLimited++;
					}

					try client.close() catch (_:Dynamic) {}
					round(index + 1);
				});
			});
		}

		round(0);
	}

	// --- the traffic ------------------------------------------------------

	/**
	 * Five shapes, chosen for the things that have actually gone wrong in HTTP
	 * servers rather than for variety.
	 */
	private function __malformed(index:Int):Bytes {
		return switch (index % 5) {
			// Bytes that are not a request at all.
			case 0: __randomBytes(__nextInt(1, 512));

			// A valid request cut somewhere, which leaves the handler holding
			// a partial header block and waiting for a read that never comes.
			case 1:
				var whole:Bytes = Bytes.ofString(__validRequest());
				whole.sub(0, __nextInt(1, whole.length));

			// A valid request with one byte changed. Most land in a header
			// name or a number, which is where a length that is believed
			// rather than checked shows itself.
			case 2:
				var mutant:Bytes = Bytes.ofString(__validRequest());
				mutant.set(__nextInt(0, mutant.length), __nextInt(0, 256));
				mutant;

			// Framing a server has to refuse rather than guess at: a chunk
			// size that is not a number, one that does not fit an Int, and
			// both framing headers at once.
			case 3: Bytes.ofString(__badFraming(__nextInt(0, 4)));

			// A header block that does not end, which is how a peer asks a
			// server to buy memory on its behalf.
			case 4:
				var out:StringBuf = new StringBuf();
				out.add("GET /index.html HTTP/1.1\r\nHost: 127.0.0.1\r\n");
				for (i in 0...__nextInt(1, 200)) {
					out.add("X-Filler-" + i + ": " + StringTools.lpad("", "a", __nextInt(1, 64)) + "\r\n");
				}
				Bytes.ofString(out.toString());

			case _: __randomBytes(16);
		}
	}

	private function __validRequest():String {
		return "GET /index.html HTTP/1.1\r\nHost: 127.0.0.1\r\nUser-Agent: crossbyte-fuzz\r\nAccept: */*\r\n\r\n";
	}

	private function __badFraming(which:Int):String {
		return switch (which) {
			case 0:
				"POST /index.html HTTP/1.1\r\nHost: 127.0.0.1\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\nhello\r\n0\r\n\r\n";
			case 1:
				"POST /index.html HTTP/1.1\r\nHost: 127.0.0.1\r\nTransfer-Encoding: chunked\r\n\r\nFFFFFFFFFF\r\nhello\r\n0\r\n\r\n";
			case 2:
				"POST /index.html HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\nhello";
			case _:
				"POST /index.html HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: -1\r\n\r\nhello";
		}
	}

	private function __makeServer():HTTPServer {
		var root:File = File.createTempDirectory();
		var indexFile:File = root.resolvePath("index.html");
		var fixture:ByteArray = new ByteArray();
		fixture.writeUTFBytes("fuzz fixture");
		indexFile.save(fixture);

		__roots.push(root);

		var config:HTTPServerConfig = new HTTPServerConfig("127.0.0.1", 0, root, null, ["index.html"]);

		// Wide enough that every round reaches the parser. The default is ten
		// a minute, which is a sensible thing for a server to ship and the
		// wrong thing to fuzz through: a refusal before `__parseRequest` tests
		// the limiter and nothing else.
		config.rateLimiter = new RateLimiter(ROUNDS * 10, 60.0);

		return new HTTPServer(config);
	}

	// --- deterministic input ---------------------------------------------

	private function __next():Int {
		__state ^= __state << 13;
		__state ^= __state >>> 17;
		__state ^= __state << 5;
		return __state;
	}

	private function __nextInt(low:Int, high:Int):Int {
		if (high <= low) {
			return low;
		}

		var value:Int = __next();
		if (value < 0) {
			value = -(value + 1);
		}

		return low + (value % (high - low));
	}

	private function __randomBytes(length:Int):Bytes {
		var out:Bytes = Bytes.alloc(length);
		for (i in 0...length) {
			out.set(i, __nextInt(0, 256));
		}

		return out;
	}
}
