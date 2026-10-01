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
			// 400: a path climbing above the root is malformed, and refused
			// before middleware, as over HTTP/1.1.
			Assert.equals(400, status);
			async.done();
		});
	}

	public function testSilentCleartextConnectionsAreCountedAndTimed(async:Async):Void {
		// While the server waits to learn a cleartext connection's protocol it
		// counted nothing and timed nothing: with maxConnections at 2 and
		// requestTimeout at half a second, six silent sockets were all taken
		// and all still open two seconds later.
		var config = new HTTPServerConfig("127.0.0.1", 0);
		config.http2Enabled = true;
		config.maxConnections = 2;
		config.requestTimeout = 0.5;
		var server = new HTTPServer(config);

		var clients:Array<Socket> = [];
		var closed:Array<Bool> = [];
		var peak:Int = 0;

		HTTPTestSupport.pumpUntilAsync(() -> server.localPort != 0, 2.0, function(_):Void {
			for (i in 0...6) {
				var client = new Socket();
				var index = i;
				closed.push(false);
				client.addEventListener(Event.CLOSE, _ -> closed[index] = true);
				client.connect("127.0.0.1", server.localPort);
				clients.push(client);
			}

			var started:Float = haxe.Timer.stamp();
			HTTPTestSupport.pumpUntilAsync(function():Bool {
				if (server.activeConnections > peak) {
					peak = server.activeConnections;
				}
				return haxe.Timer.stamp() - started > 2.0 || Lambda.foreach(closed, c -> c);
			}, 4.0, function(_):Void {
				var open:Int = Lambda.count(closed, c -> !c);
				for (client in clients) {
					try client.close() catch (_:Dynamic) {}
				}
				try server.close() catch (_:Dynamic) {}

				Assert.isTrue(peak <= 2, 'the server held $peak silent connections under a limit of 2');
				Assert.isTrue(peak > 0, "the silent connections were never counted");
				Assert.equals(0, open, '$open silent connections outlived a 0.5s requestTimeout');
				async.done();
			});
		});
	}

	public function testDrainSendsGoAwayFirstAndLetsStreamsFinish(async:Async):Void {
		// A GOAWAY came only at the drain's deadline, so clients kept opening
		// streams on a connection about to close. Now it comes at once: a
		// stream opened after it is refused, the one in flight finishes, and
		// the drain ends with it rather than at the deadline.
		// Answered by the test rather than by a timer: the harness pumps the
		// runtime's clock faster than the wall clock, so a timed answer can land
		// before the drain it is meant to straddle.
		var working:HTTPRequestHandler = null;
		var session = new H2Session(config -> {
			config.middleware = [
				(handler, next) -> {
					if (handler.requestPath == "/work") {
						working = handler;
						return;
					}
					next();
				}
			];
		});

		session.start(() -> {
			session.request(1, "GET", "/work", true);
			session.until(() -> working != null || session.ended, () -> {
				var started:Float = haxe.Timer.stamp();
				var drained:Bool = false;
				session.server.drain(5.0, () -> drained = true);

				session.until(() -> session.goAwayAt >= 0 || session.ended, () -> {
					var goAwayAfter:Float = session.goAwayAt - started;
					session.request(3, "GET", "/index.html", true);

					session.until(() -> session.finished(3) || session.dropped, () -> {
						if (working != null) {
							working.respond(200, "text/plain", "done");
						}
					});

					session.until(() -> drained && session.finished(1) && session.finished(3), () -> {
						var took:Float = haxe.Timer.stamp() - started;
						session.close();

						Assert.isTrue(session.goAwayAt >= 0 && goAwayAfter < 0.25, 'no GOAWAY at the start of the drain (${goAwayAfter}s)');
						Assert.equals(200, session.status(1), "the stream in flight did not finish");
						Assert.equals("done", session.body(1));
						Assert.equals(7, session.resetCode(3), "a stream opened after the GOAWAY was not refused");
						Assert.isTrue(drained && took < 3.0, 'the drain took ${took}s, waiting on its deadline');
						async.done();
					}, 8.0);
				});
			});
		});
	}

	public function testTheRateLimiterCountsHttp2Requests(async:Async):Void {
		// Only the HTTP/1.1 parser asked the limiter, so six requests over
		// HTTP/2 were all answered where HTTP/1.1 refused the fourth.
		var session = new H2Session(config -> config.rateLimiter = new crossbyte.net.RateLimiter(3, 60));

		session.start(() -> {
			var streams:Array<Int> = [1, 3, 5, 7, 9, 11];
			for (id in streams) {
				session.request(id, "GET", "/index.html", true);
			}
			session.until(() -> Lambda.foreach(streams, id -> session.finished(id)) || session.ended, () -> {
				session.close();
				Assert.same([200, 200, 200, 429, 429, 429], [for (id in streams) session.status(id)]);
				// Three a minute is one every twenty seconds: when to come back.
				Assert.equals("20", session.header(7, "retry-after"));
				async.done();
			});
		});
	}

	public function testAnHttp2BodyPastTheLimitIsRefused(async:Async):Void {
		// DATA was appended with no limit while window kept being granted: a
		// 3 MB upload reached a route HTTP/1.1 would have refused. Now it is
		// answered 413, the stream is reset without error to stop the upload,
		// and the connection carries on.
		var reached:Bool = false;
		var session = new H2Session(config -> {
			config.middleware = [
				(handler, next) -> {
					if (handler.method == "POST") {
						reached = true;
					}
					next();
				}
			];
		});

		session.start(() -> {
			session.request(1, "POST", "/upload", false);
			session.upload(1, Bytes.alloc(2 * 1024 * 1024), sent -> {
				session.until(() -> session.finished(1) || session.ended, () -> {
					Assert.equals(413, session.status(1), "an oversized HTTP/2 body was not refused");
					Assert.isFalse(reached, "an oversized HTTP/2 body reached middleware");
					Assert.isTrue(sent < 2 * 1024 * 1024, "the whole oversized body was taken");

					session.request(3, "GET", "/index.html", true);
					session.until(() -> session.finished(3) || session.ended, () -> {
						session.close();
						Assert.equals(200, session.status(3), "the connection did not survive the refusal");
						async.done();
					});
				});
			});
		});
	}

	public function testHttp2ResponsesAreCounted(async:Async):Void {
		var metrics = new crossbyte.metrics.Metrics();
		var session = new H2Session(config -> config.metrics = metrics);

		session.start(() -> {
			session.request(1, "GET", "/index.html", true);
			session.request(3, "GET", "/missing.html", true);
			session.until(() -> (session.finished(1) && session.finished(3)) || session.ended, () -> {
				session.close();
				Assert.equals(1.0, metrics.counter("http_requests_total", ["status" => "2xx"]).value(), "an HTTP/2 200 was not counted");
				Assert.equals(1.0, metrics.counter("http_requests_total", ["status" => "4xx"]).value(), "an HTTP/2 404 was not counted");
				async.done();
			});
		});
	}

	public function testAnHttp2BodyIsDecodedBeforeMiddleware(async:Async):Void {
		var body = new ByteArray();
		body.writeUTFBytes("hello over h2");
		body.compress(crossbyte.utils.CompressionAlgorithm.GZIP);
		var compressed = Bytes.alloc(body.length);
		compressed.blit(0, body, 0, body.length);

		var session = new H2Session(config -> {
			config.middleware = [(handler, next) -> handler.respond(200, "text/plain", "received " + handler.requestText)];
		});

		session.start(() -> {
			session.request(1, "POST", "/upload", false, [new HpackHeader("content-encoding", "gzip")]);
			session.dataBytes(1, compressed, true);
			session.until(() -> session.finished(1) || session.ended, () -> {
				session.close();
				Assert.equals(200, session.status(1));
				Assert.equals("received hello over h2", session.body(1));
				async.done();
			});
		});
	}

	public function testSplitCookiesJoinWithSemicolons(async:Async):Void {
		// Browsers send each cookie as its own field over HTTP/2 (§8.2.3), and
		// joining them with a comma made getCookie("sid") "abc123, theme=dark".
		var session = new H2Session(config -> {
			config.middleware = [
				(handler, next) -> handler.respond(200, "text/plain", handler.getCookie("sid") + "|" + handler.getCookie("theme"))
			];
		});

		session.start(() -> {
			session.request(1, "GET", "/me", true, [new HpackHeader("cookie", "sid=abc123"), new HpackHeader("cookie", "theme=dark")]);
			session.until(() -> session.finished(1) || session.ended, () -> {
				session.close();
				Assert.equals("abc123|dark", session.body(1));
				async.done();
			});
		});
	}

	public function testCredentialsInAResponseAreNeverIndexed(async:Async):Void {
		// Every response field went into the HPACK dynamic table, session
		// tokens in Set-Cookie included. RFC 7541 7.1.3: a credential in the
		// table can be recovered from the compressed sizes of later responses
		// an attacker can influence, and a table full of one-off tokens evicts
		// what was worth keeping. The client already sent its own this way.
		var session = new H2Session(config -> {
			config.middleware = [
				(handler, next) -> handler.respond(401, "text/plain", "sign in", [
					new crossbyte.url.URLRequestHeader("Set-Cookie", "session=s3cr3t-token; HttpOnly"),
					new crossbyte.url.URLRequestHeader("WWW-Authenticate", "Bearer realm=\"api\""),
					new crossbyte.url.URLRequestHeader("X-Plain", "indexable")
				])
			];
		});

		session.start(() -> {
			session.request(1, "GET", "/account", true);
			session.until(() -> session.finished(1) || session.ended, () -> {
				session.close();
				Assert.equals(401, session.status(1));
				Assert.equals("session=s3cr3t-token; HttpOnly", session.header(1, "set-cookie"));
				Assert.isTrue(session.neverIndexed(1, "set-cookie"), "set-cookie was not sent never-indexed");
				Assert.isTrue(session.neverIndexed(1, "www-authenticate"), "www-authenticate was not sent never-indexed");
				Assert.isFalse(session.tableHolds("set-cookie"), "a session token was entered into the HPACK table");
				Assert.isFalse(session.tableHolds("www-authenticate"));
				// Everything else is still worth indexing.
				Assert.isFalse(session.neverIndexed(1, "x-plain"));
				async.done();
			});
		});
	}

	public function testAHeaderSectionPastTheLimitIsAnswered431(async:Async):Void {
		// 3,000 one-byte references to a single cookie crumb: about three
		// kilobytes on the wire, 117 KB by HPACK's accounting. It was taken
		// whole, under an eight megabyte limit nobody advertised, and the
		// crumbs joined one by one -- at 200,000 of them that held the
		// runtime's thread for 23.5 seconds. HTTP/1.1 answers the same section
		// 431 at 64 KB, and so does HTTP/2 now, on that stream alone.
		var session = new H2Session(config -> {
			config.middleware = [(handler, next) -> handler.respond(200, "text/plain", "cookie=" + (handler.getCookie("a") != null))];
		});

		var crumbs:Array<HpackHeader> = [];
		for (i in 0...3000) {
			crumbs.push(new HpackHeader("cookie", "a=1"));
		}

		session.start(() -> {
			session.request(1, "GET", "/big", true, crumbs);
			session.until(() -> session.finished(1) || session.ended, () -> {
				session.request(3, "GET", "/next", true, [new HpackHeader("cookie", "a=2")]);
				session.until(() -> session.finished(3) || session.ended, () -> {
					session.close();
					Assert.equals(431, session.status(1));
					Assert.equals(200, session.status(3), "the connection did not carry on past the refusal");
					Assert.equals("cookie=true", session.body(3));
					async.done();
				});
			});
		});
	}

	public function testAGuardSeesTheSettledPathOverHttp2(async:Async):Void {
		// The path settles the same way on both protocols, so a guard written
		// once holds on both.
		exchange(async, "GET", "/./private//report.txt", null, config -> {
			config.middleware = [
				(handler, next) -> {
					if (StringTools.startsWith(handler.requestPath, "/private/")) {
						handler.respond(401, "text/plain", "guarded " + handler.requestPath);
						return;
					}
					next();
				}
			];
		}, function(status, headers, body) {
			Assert.equals(401, status);
			Assert.equals("guarded /private/report.txt", body.toString());
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

	#if (java || jvm)
	// Only the jvm can make a file past 2 GB here without writing one: it
	// asks for a sparse file, which takes no disk on NTFS, ext4 or APFS.
	public function testAFileTooLargeToStateIsRefusedOverBothProtocols(async:Async):Void {
		// File.size throws past 2 GB, since an Int cannot state the length.
		// The handler did not catch it: HTTP/1.1 answered 500 only through its
		// catch-all, and HTTP/2 reset the stream.
		var made:Bool = false;
		var session = new H2Session(config -> made = __makeSparseFile(config.rootDirectory.resolvePath("huge.bin").nativePath, 3221225473.0));
		if (!made) {
			session.close();
			Assert.warn("no room for a 3 GB file if this filesystem cannot make it sparse; not run");
			async.done();
			return;
		}

		session.start(function():Void {
			session.request(1, "GET", "/huge.bin", true);
			session.until(() -> session.finished(1) || session.resetCode(1) >= 0 || session.ended, function():Void {
				Assert.equals(-1, session.resetCode(1), "the stream was reset instead of answered");
				Assert.equals(500, session.status(1));

				HTTPTestSupport.exchangeEach(session.server, ["GET /huge.bin HTTP/1.1\r\nHost: localhost\r\n\r\n"], function(responses):Void {
					session.close();
					Assert.equals(500, responses[0].status);
					async.done();
				});
			});
		});
	}

	/**
	 * Makes `path` a sparse file `length` bytes long, or answers false where
	 * there would not be room for it should the filesystem ignore the request.
	 */
	private static function __makeSparseFile(path:String, length:Float):Bool {
		var directory = new java.io.File(path).getParentFile();
		var room:Float = haxe.Int64.toInt(directory.getUsableSpace() / 1048576) / 1024.0;
		if (room < 16) {
			return false;
		}

		var createNew:java.nio.file.OpenOption = cast java.nio.file.StandardOpenOption.CREATE_NEW;
		var write:java.nio.file.OpenOption = cast java.nio.file.StandardOpenOption.WRITE;
		var sparse:java.nio.file.OpenOption = cast java.nio.file.StandardOpenOption.SPARSE;
		var channel = java.nio.file.Files.newByteChannel(new java.io.File(path).toPath(), createNew, write, sparse);
		channel.position(haxe.Int64.fromFloat(length - 1));
		channel.write(java.nio.ByteBuffer.allocate(1));
		channel.close();
		return true;
	}
	#end

	public function testAThrowServingTheFirstHttp11RequestIsA500(async:Async):Void {
		// A cleartext HTTP/2 listener reads the first bytes to tell the
		// versions apart, and the handler it passed them to parsed them outside
		// the catch every later read goes through: what serving that request
		// threw went up through the socket's dispatch into the runtime's pump.
		var root = File.createTempDirectory();
		var config = new HTTPServerConfig("127.0.0.1", 0, root);
		config.http2Enabled = true;
		config.rateLimiter = new ThrowingRateLimiter();
		var server = new HTTPServer(config);

		HTTPTestSupport.exchangeEach(server, ["GET / HTTP/1.1\r\nHost: localhost\r\n\r\n"], function(responses):Void {
			try server.close() catch (_:Dynamic) {}
			try root.deleteDirectory(true) catch (_:Dynamic) {}
			Assert.equals(500, responses[0].status);
			async.done();
		});
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

	public function testAStalledHttp2RequestIsAnswered408AfterRequestTimeout(async:Async):Void {
		// Headers promising a body that never comes. It is requestTimeout's to
		// end, as it is for an HTTP/1.1 request that stops arriving: answered
		// 408, on its own stream. The connection carries everything else, so
		// it is not the connection that goes.
		var session = new H2Session(config -> {
			config.requestTimeout = 1;
			config.keepAliveTimeout = 10;
		});

		session.start(() -> {
			session.request(1, "POST", "/upload", false);
			var opened:Float = haxe.Timer.stamp();
			session.until(() -> session.finished(1) || session.ended, () -> {
				var took:Float = session.finishedAt(1) - opened;
				session.request(3, "GET", "/index.html", true);
				session.until(() -> session.finished(3) || session.ended, () -> {
					session.close();
					Assert.equals(408, session.status(1), "a stalled HTTP/2 request was not answered 408");
					Assert.isTrue(took >= 1 - SLACK, 'answered after ${took}s, inside its 1s requestTimeout');
					Assert.equals(200, session.status(3), "the connection went with the stalled request");
					async.done();
				});
			}, 5.0);
		});
	}

	public function testAnHttp2BodyTrickledInIsHeldToRequestTimeout(async:Async):Void {
		// One byte of body every 0.4 s, under a requestTimeout of one second.
		// Every frame read refreshed the connection's clock, so the request
		// was still open at 3.6 s and answered 200, where HTTP/1.1 answered
		// 408 at 1.05 s. The deadline is the stream's own now, set when its
		// headers arrive, and nothing it sends moves it.
		var reached:Bool = false;
		var session = new H2Session(config -> {
			config.requestTimeout = 1;
			config.keepAliveTimeout = 10;
			config.middleware = [
				(handler, next) -> {
					if (handler.method == "POST") {
						reached = true;
					}
					handler.respond(200, "text/plain", "received " + handler.requestBody.length);
				}
			];
		});

		session.start(() -> {
			session.request(1, "POST", "/upload", false);
			var opened:Float = haxe.Timer.stamp();

			function drip():Void {
				if (session.finished(1) || session.ended || haxe.Timer.stamp() - opened > 4.0) {
					var took:Float = session.finishedAt(1) - opened;
					session.request(3, "GET", "/index.html", true);
					session.until(() -> session.finished(3) || session.ended, () -> {
						session.close();
						Assert.equals(408, session.status(1), "a trickled body was not held to requestTimeout");
						Assert.isTrue(took >= 1 - SLACK && took < 2.5, 'answered after ${took}s under a 1s requestTimeout');
						Assert.isFalse(reached, "a request that missed its deadline reached middleware");
						Assert.equals(200, session.status(3), "the connection went with the late request");
						async.done();
					});
					return;
				}
				session.trickle(1, "x");
				session.pause(0.4, drip);
			}
			drip();
		});
	}

	public function testPingsDoNotKeepAnIdleHttp2ConnectionOpen(async:Async):Void {
		// Any frame counted as activity, so a peer sending nothing but PING
		// held a connection past keepAliveTimeout for as long as it liked.
		var session = new H2Session(config -> {
			config.keepAliveTimeout = 1;
			config.requestTimeout = 10;
		});

		session.start(() -> {
			session.request(1, "GET", "/index.html", true);
			session.until(() -> session.finished(1) || session.ended, () -> {
				var idleFrom:Float = session.finishedAt(1);

				function keepPinging():Void {
					if (session.ended || haxe.Timer.stamp() - idleFrom > 4.0) {
						var after:Float = (session.goAwayAt >= 0 ? session.goAwayAt : session.droppedAt) - idleFrom;
						session.close();
						Assert.equals(200, session.status(1));
						Assert.isTrue(session.ended, "PINGs held an idle HTTP/2 connection open past keepAliveTimeout");
						Assert.isTrue(after >= 1 - SLACK && after < 2.5, 'closed ${after}s after its last request, under a 1s keepAliveTimeout');
						async.done();
						return;
					}
					session.ping();
					session.pause(0.4, keepPinging);
				}
				keepPinging();
			});
		});
	}

	public function testKeepAliveMaxRequestsEndsAnHttp2Connection(async:Async):Void {
		// HTTP/2 took no notice of keepAliveMaxRequests, so a connection served
		// requests for as long as its client kept it. Now the stream that
		// reaches the limit is the last one taken: a GOAWAY names it, a stream
		// opened past it is refused, and the connection closes once it ends.
		var session = new H2Session(config -> config.keepAliveMaxRequests = 2);

		session.start(() -> {
			// One write: a stream read after the connection has closed is not
			// refused, it is never seen.
			session.requestAll([1, 3, 5], "GET", "/index.html");
			session.until(() -> session.dropped, () -> {
				session.close();
				Assert.equals(200, session.status(1));
				Assert.equals(200, session.status(3));
				Assert.equals(7, session.resetCode(5), "a stream past the limit was not refused");
				Assert.equals(3, session.goAwayLastStream, "the GOAWAY did not name the last stream taken");
				Assert.equals(H2ErrorCode.NO_ERROR, session.goAwayCode);
				Assert.isTrue(session.dropped, "the connection outlived its last request");
				async.done();
			});
		});
	}

	public function testKeepAliveOffEndsAnHttp2ConnectionAfterOneRequest(async:Async):Void {
		var session = new H2Session(config -> config.keepAlive = false);

		session.start(() -> {
			session.requestAll([1, 3], "GET", "/index.html");
			session.until(() -> session.dropped, () -> {
				session.close();
				Assert.equals(200, session.status(1));
				Assert.equals(7, session.resetCode(3), "a second stream was taken with keepAlive off");
				Assert.equals(1, session.goAwayLastStream);
				Assert.isTrue(session.dropped, "the connection outlived its one request");
				async.done();
			});
		});
	}

	public function testAnHttp2ContentLengthPastTheLimitIsRefusedAtItsHeaders(async:Async):Void {
		// The limit was held per DATA frame only, so a request that declared
		// a body far past it was invited to send the first megabyte of it.
		var reached:Bool = false;
		var session = new H2Session(config -> {
			config.maxRequestBodySize = 10;
			config.middleware = [
				(handler, next) -> {
					if (handler.method == "POST") {
						reached = true;
					}
					next();
				}
			];
		});

		session.start(() -> {
			session.request(1, "POST", "/upload", false, [new HpackHeader("content-length", "1000")]);
			session.until(() -> session.finished(1) || session.ended, () -> {
				session.request(3, "GET", "/index.html", true);
				session.until(() -> session.finished(3) || session.ended, () -> {
					session.close();
					Assert.equals(413, session.status(1), "a declared body past the limit was not refused before it was sent");
					Assert.equals(0, session.resetCode(1), "the upload was not told to stop");
					Assert.isFalse(reached);
					Assert.equals(200, session.status(3));
					async.done();
				});
			});
		});
	}

	public function testOnExpectContinueIsAskedOfAnHttp2Request(async:Async):Void {
		// Only the HTTP/1.1 parser asked it. An HTTP/2 request reached the
		// hook's job -- refusing before the body is sent -- only once the whole
		// body had arrived, and never asked it at all.
		var asked:Int = 0;
		var session = new H2Session(config -> {
			config.onExpectContinue = handler -> {
				asked++;
				handler.respond(401, "text/plain", "sign in first");
				return false;
			};
			config.middleware = [(handler, next) -> handler.respond(200, "text/plain", "uploaded")];
		});

		session.start(() -> {
			session.request(1, "POST", "/upload", false, [new HpackHeader("expect", "100-continue"), new HpackHeader("content-length", "4")]);
			session.until(() -> session.finished(1) || session.ended, () -> {
				session.request(3, "GET", "/index.html", true);
				session.until(() -> session.finished(3) || session.ended, () -> {
					session.close();
					Assert.equals(1, asked, "onExpectContinue was not asked");
					Assert.equals(401, session.status(1));
					Assert.equals("sign in first", session.body(1));
					Assert.equals(0, session.resetCode(1), "the body was not refused");
					Assert.equals(200, session.status(3));
					async.done();
				});
			});
		});
	}

	public function testAnHttp2RequestLetThroughIsToldToContinue(async:Async):Void {
		var session = new H2Session(config -> {
			config.onExpectContinue = handler -> handler.getHeader("authorization") == "Bearer ok";
			config.middleware = [(handler, next) -> handler.respond(200, "text/plain", "uploaded " + handler.requestText)];
		});

		session.start(() -> {
			session.request(1, "POST", "/upload", false, [
				new HpackHeader("expect", "100-continue"),
				new HpackHeader("authorization", "Bearer ok"),
				new HpackHeader("content-length", "4")
			]);
			session.until(() -> session.statuses(1).length > 0 || session.ended, () -> {
				session.data(1, "body");
				session.until(() -> session.finished(1) || session.ended, () -> {
					session.close();
					Assert.same([100, 200], session.statuses(1), "expected a 100 and then the answer");
					Assert.equals("uploaded body", session.body(1));
					async.done();
				});
			});
		});
	}

	public function testAnHttp2RequestIsTimedFromItsHeaders(async:Async):Void {
		// The handler was made once the body had arrived, and the duration was
		// measured from there, so an upload that took a second was recorded as
		// taking none. HTTP/1.1 measures from the request's first byte.
		var metrics = new crossbyte.metrics.Metrics();
		var session = new H2Session(config -> {
			config.metrics = metrics;
			config.middleware = [(handler, next) -> handler.respond(200, "text/plain", "ok")];
		});

		session.start(() -> {
			session.request(1, "POST", "/upload", false);
			session.pause(0.5, () -> {
				session.data(1, "late");
				session.until(() -> session.finished(1) || session.ended, () -> {
					session.close();
					var seconds = metrics.histogram("http_request_seconds");
					Assert.equals(200, session.status(1));
					Assert.equals(1.0, seconds.count(), "the request was not timed");
					Assert.isTrue(seconds.sum() >= 0.5 - SLACK, 'recorded ${seconds.sum()}s for a request that took half a second to arrive');
					async.done();
				});
			});
		});
	}

	public function testAnHttp2MethodIsReadAsAnHttp11OneIs(async:Async):Void {
		// The HTTP/1.1 parser upper-cases the method, as `method` says, and
		// HTTP/2 took it as it came: "get" was refused 405 there and served
		// over HTTP/1.1.
		var seen:String = null;
		var session = new H2Session(config -> {
			config.middleware = [
				(handler, next) -> {
					seen = handler.method;
					next();
				}
			];
		});

		session.start(() -> {
			session.request(1, "get", "/index.html", true);
			session.until(() -> session.finished(1) || session.ended, () -> {
				session.close();
				Assert.equals("GET", seen);
				Assert.equals(200, session.status(1));
				async.done();
			});
		});
	}

	public function testAnHttp2ProducerThatOutrunsItsClientHearsClose(async:Async):Void {
		// At the output cap the stream is reset, which under HTTP/1.1 is the
		// connection closing and so Event.CLOSE. Under HTTP/2 the connection
		// stays, and the producer was never told: one writing on a timer kept
		// writing into a stream that refused everything, for good.
		var heardClose:Bool = false;
		var accepted:Null<Bool> = null;
		var session = new H2Session(config -> {
			config.maxOutputBufferSize = 16 * 1024;
			config.middleware = [
				(handler, next) -> {
					if (handler.requestPath != "/flood") {
						next();
						return;
					}
					handler.addEventListener(crossbyte.events.Event.CLOSE, _ -> heardClose = true);
					var body = handler.beginResponse(200, "application/octet-stream");
					var big = new ByteArray();
					big.length = 128 * 1024;
					accepted = body.write(big);
				}
			];
		});

		session.start(() -> {
			session.request(1, "GET", "/flood", true);
			session.until(() -> heardClose || session.finished(1) || session.ended, () -> {
				session.request(3, "GET", "/index.html", true);
				session.until(() -> session.finished(3) || session.ended, () -> {
					session.close();
					Assert.isFalse(accepted);
					Assert.isTrue(heardClose, "the producer was not told its response was ended");
					Assert.equals(2, session.resetCode(1), "the stream was not reset");
					Assert.equals(200, session.status(3));
					async.done();
				});
			});
		});
	}

	public function testAFileThatShrinksMidStreamEndsOnlyItsOwnStream(async:Async):Void {
		// The file pump gave up on a file that came up short by closing the
		// socket, which under HTTP/2 is the connection every other stream is
		// on: one file changing under a download took down every request.
		// A megabyte, so that most of it is still on disk, unread, when it is
		// cut: the pump reads ahead only as far as its watermark.
		var size:Int = 1024 * 1024;
		var path:String = null;
		var session = new H2Session(config -> {
			var big = new ByteArray();
			for (i in 0...size) {
				big.writeByte(i & 0xFF);
			}
			var file = config.rootDirectory.resolvePath("big.bin");
			file.save(big);
			path = file.nativePath;
		});

		session.start(() -> {
			session.request(1, "GET", "/big.bin", true);
			// The first window's worth arrives, and the rest waits on the
			// client, the pump paused at its watermark with the file open.
			session.until(() -> session.received(1) >= 65535 || session.ended, () -> {
				__truncate(path, 1024);
				Assert.equals(1024, sys.FileSystem.stat(path).size, "the file could not be cut, so this case shows nothing");
				session.windowUpdate(0, 1 << 20);
				session.windowUpdate(1, 1 << 20);
				session.until(() -> session.finished(1) || session.ended, () -> {
					var endedWithIt:Bool = session.ended;
					session.request(3, "GET", "/index.html", true);
					session.until(() -> session.finished(3) || session.ended, () -> {
						session.close();
						Assert.isFalse(endedWithIt, "the connection went with the stream whose file shrank");
						Assert.equals(2, session.resetCode(1), "the stream was not reset");
						Assert.isTrue(session.received(1) < size, "a file that shrank was sent whole");
						Assert.equals(200, session.status(3));
						async.done();
					});
				});
			});
		});
	}

	public function testAnHttp2DownloadResetByItsClientLetsGoOfItsFile(async:Async):Void {
		// The file pump resumes on its stream's writable callback, which a
		// reset drops, and only the socket closing stopped it: a client
		// resetting a large download left its file open, and its pump parked,
		// for as long as the connection lived.
		var held:HTTPRequestHandler = null;
		var session = new H2Session(config -> {
			__bigFile(config, 1024 * 1024);
			config.middleware = [
				(handler, next) -> {
					if (handler.requestPath == "/big.bin") {
						held = handler;
					}
					next();
				}
			];
		});

		session.start(() -> {
			session.request(1, "GET", "/big.bin", true);
			session.until(() -> session.received(1) >= 65535 || session.ended, () -> {
				var pumping:Bool = held != null && @:privateAccess held.__streaming;
				session.reset(1);
				session.until(() -> (held != null && !@:privateAccess held.__streaming) || session.ended, () -> {
					session.request(3, "GET", "/index.html", true);
					session.until(() -> session.finished(3) || session.ended, () -> {
						session.close();
						Assert.isTrue(pumping, "the download was not being pumped, so this shows nothing");
						Assert.isFalse(@:privateAccess held.__streaming, "a reset download kept its file open");
						Assert.equals(200, session.status(3));
						async.done();
					});
				}, 2.0);
			});
		});
	}

	public function testAStalledHttp2DownloadIsEndedAtTheStallDeadline(async:Async):Void {
		// The stall deadline -- 30 s without the client taking a byte -- was
		// checked by the HTTP/1.1 sweep alone, so an HTTP/2 client that never
		// opened its window held a file, and a pump, per stream, for good.
		var held:HTTPRequestHandler = null;
		var session = new H2Session(config -> {
			__bigFile(config, 1024 * 1024);
			config.middleware = [
				(handler, next) -> {
					if (handler.requestPath == "/big.bin") {
						held = handler;
					}
					next();
				}
			];
		});

		session.start(() -> {
			session.request(1, "GET", "/big.bin", true);
			session.until(() -> session.received(1) >= 65535 || session.ended, () -> {
				// The sweep, as it would run once the deadline has passed.
				@:privateAccess session.server.__sweep(haxe.Timer.stamp() + 31);
				session.until(() -> session.finished(1) || session.ended, () -> {
					session.request(3, "GET", "/index.html", true);
					session.until(() -> session.finished(3) || session.ended, () -> {
						session.close();
						Assert.isFalse(held == null || @:privateAccess held.__streaming, "a stalled download was not ended");
						Assert.equals(2, session.resetCode(1), "the stalled stream was not reset");
						Assert.equals(200, session.status(3), "the connection went with the stalled stream");
						async.done();
					});
				});
			});
		});
	}

	public function testAStalledHttp2DownloadIsEndedWithBothTimeoutsOff(async:Async):Void {
		// requestTimeout and keepAliveTimeout at 0 set no deadline for what
		// they bound, and the stall deadline is not theirs: a download whose
		// client stops taking it is still ended. It was checked from the walk
		// those two arm, so with both off nothing looked at it, and the file
		// stayed open for as long as the connection did. The deadline is held
		// in the past while this waits, as 30 s without a byte taken would
		// leave it: what is under test is whether the running server looks.
		var held:HTTPRequestHandler = null;
		var session = new H2Session(config -> {
			config.requestTimeout = 0;
			config.keepAliveTimeout = 0;
			__bigFile(config, 1024 * 1024);
			config.middleware = [
				(handler, next) -> {
					if (handler.requestPath == "/big.bin") {
						held = handler;
					}
					next();
				}
			];
		});

		session.start(() -> {
			session.request(1, "GET", "/big.bin", true);
			session.until(() -> session.received(1) >= 65535 || session.ended, () -> {
				var pumping:Bool = held != null && @:privateAccess held.__streaming;
				session.until(() -> {
					if (held != null && @:privateAccess held.__streaming) {
						@:privateAccess held.__streamStallDeadline = haxe.Timer.stamp() - 1;
					}
					return session.finished(1) || session.ended;
				}, () -> {
					session.request(3, "GET", "/index.html", true);
					session.until(() -> session.finished(3) || session.ended, () -> {
						// A few sweeps' worth, for it to find nothing left to do.
						session.pause(0.75, () -> {
							var stillSweeping:Bool = @:privateAccess session.server.__sweepArmed;
							session.close();
							Assert.isTrue(pumping, "the download was not being pumped, so this shows nothing");
							Assert.isFalse(@:privateAccess held.__streaming, "a stalled download outlived its deadline with both timeouts off");
							Assert.equals(2, session.resetCode(1), "the stalled stream was not reset");
							Assert.equals(200, session.status(3), "the connection went with the stalled stream");
							Assert.isFalse(stillSweeping, "the sweep kept running with both timeouts off and nothing being sent");
							async.done();
						});
					});
				}, 3.0);
			});
		});
	}

	public function testALongPollOutlivesTheRequestTimeout(async:Async):Void {
		// Every open stream counted as a request still arriving, so a long
		// poll answered after requestTimeout found its connection closed with
		// a GOAWAY, and every other stream on it gone too. A request that has
		// arrived is the application's to answer, as over HTTP/1.1.
		// Answered by the test rather than by a timer: the harness runs the
		// runtime's clock faster than the wall clock the timeout is kept on.
		var held:HTTPRequestHandler = null;
		var session = new H2Session(config -> {
			config.requestTimeout = 0.5;
			config.middleware = [
				(handler, next) -> {
					if (handler.requestPath == "/poll") {
						held = handler;
						return;
					}
					next();
				}
			];
		});

		session.start(() -> {
			session.request(1, "GET", "/poll", true);
			session.until(() -> held != null || session.ended, () -> {
				// Three times the request timeout, with the answer still owed.
				session.pause(1.5, () -> {
					var endedWhileWaiting:Bool = session.ended;
					if (held != null) {
						held.respond(200, "text/plain", "late");
					}
					session.until(() -> session.finished(1) || session.ended, () -> {
						session.close();
						Assert.isFalse(endedWhileWaiting, "the connection was closed under a request being answered");
						Assert.equals(200, session.status(1));
						Assert.equals("late", session.body(1));
						async.done();
					});
				});
			});
		});
	}

	public function testAnHttp2ResponseIsWrittenAsItGoes(async:Async):Void {
		// The body goes out as DATA while the stream stays open; only
		// endResponse ends it.
		var held:HTTPResponseStream = null;
		var session = new H2Session(config -> {
			config.middleware = [
				(handler, next) -> {
					held = handler.beginResponse(200, "text/event-stream");
					held.writeText("one ");
				}
			];
		});

		session.start(() -> {
			session.request(1, "GET", "/events", true);
			session.until(() -> session.body(1) == "one " || session.ended, () -> {
				var openAfterFirst:Bool = !session.finished(1);
				held.writeText("two");
				held.end();
				session.until(() -> session.finished(1) || session.ended, () -> {
					session.close();
					Assert.equals(200, session.status(1));
					Assert.isTrue(openAfterFirst, "the stream ended with the first write");
					Assert.equals("one two", session.body(1));
					Assert.isNull(session.header(1, "content-length"));
					async.done();
				});
			});
		});
	}

	public function testAnHttp2ProducerHearsItsStreamReset(async:Async):Void {
		// A client that cancels one stream leaves the connection up, so the
		// connection closing is not how a producer on that stream would ever
		// find out. It hears Event.CLOSE, and can write no more.
		var held:HTTPRequestHandler = null;
		var events:HTTPResponseStream = null;
		var heardClose:Bool = false;
		var session = new H2Session(config -> {
			config.middleware = [
				(handler, next) -> {
					if (handler.requestPath == "/events") {
						held = handler;
						handler.addEventListener(crossbyte.events.Event.CLOSE, _ -> heardClose = true);
						events = handler.beginResponse(200, "text/event-stream");
						events.writeText("first");
						return;
					}
					next();
				}
			];
		});

		session.start(() -> {
			session.request(1, "GET", "/events", true);
			session.until(() -> session.body(1) == "first" || session.ended, () -> {
				session.reset(1);
				session.until(() -> heardClose || session.ended, () -> {
					var accepted:Bool = events.writeText("after");
					var connected:Bool = held.connected || events.connected;
					// The connection carries on for everything else.
					session.request(3, "GET", "/index.html", true);
					session.until(() -> session.finished(3) || session.ended, () -> {
						session.close();
						Assert.isTrue(heardClose, "the producer was not told its stream was reset");
						Assert.isFalse(accepted);
						Assert.isFalse(connected);
						Assert.equals(200, session.status(3));
						async.done();
					});
				});
			});
		});
	}

	public function testAProducerHearsTheServerResetItsStream(async:Async):Void {
		// A stream the server resets is as over as one the client resets, but
		// only the client's reset reached the producer: one the server reset
		// for the client's protocol error -- DATA on a stream the client had
		// ended, STREAM_CLOSED -- heard nothing until it next wrote, and one
		// waiting on an event to write never did.
		var closes:Int = 0;
		var events:HTTPResponseStream = null;
		var session = new H2Session(config -> {
			config.middleware = [
				(handler, next) -> {
					if (handler.requestPath == "/events") {
						handler.addEventListener(crossbyte.events.Event.CLOSE, _ -> closes++);
						events = handler.beginResponse(200, "text/event-stream");
						events.writeText("first");
						return;
					}
					next();
				}
			];
		});

		session.start(() -> {
			session.request(1, "GET", "/events", true);
			session.until(() -> session.body(1) == "first" || session.ended, () -> {
				session.trickle(1, "after the end");
				session.until(() -> closes > 0 || session.ended, () -> {
					var heardBeforeWriting:Int = closes;
					var accepted:Bool = events.writeText("after");
					// The connection carries on for everything else.
					session.request(3, "GET", "/index.html", true);
					session.until(() -> session.finished(3) || session.ended, () -> {
						session.close();
						// The connection closing as well, which must not tell it again.
						HTTPTestSupport.pumpMoreAsync(5, () -> {
							Assert.equals(5, session.resetCode(1), "the server did not reset the stream, so this shows nothing");
							Assert.equals(1, heardBeforeWriting, "the producer was not told its stream was reset");
							Assert.isFalse(accepted);
							Assert.equals(1, closes, "CLOSE was dispatched " + closes + " times");
							Assert.equals(200, session.status(3));
							async.done();
						});
					});
				}, 2.0);
			});
		});
	}

	public function testAStreamTheServerResetsLetsGoOfItsFile(async:Async):Void {
		// A download parked on the client's window, whose stream the server
		// then resets for a WINDOW_UPDATE of nothing (PROTOCOL_ERROR). The
		// reset drops the stream's writable callback, which is all the pump
		// was waiting on, so it held the file until the stall deadline -- and,
		// with both timeouts off, for as long as the connection lived.
		var held:HTTPRequestHandler = null;
		var closes:Int = 0;
		var session = new H2Session(config -> {
			__bigFile(config, 1024 * 1024);
			config.middleware = [
				(handler, next) -> {
					if (handler.requestPath == "/big.bin") {
						held = handler;
						handler.addEventListener(crossbyte.events.Event.CLOSE, _ -> closes++);
					}
					next();
				}
			];
		});

		session.start(() -> {
			session.request(1, "GET", "/big.bin", true);
			session.until(() -> session.received(1) >= 65535 || session.ended, () -> {
				var pumping:Bool = held != null && @:privateAccess held.__streaming;
				session.windowUpdate(1, 0);
				session.until(() -> (held != null && !@:privateAccess held.__streaming) || session.ended, () -> {
					var stillPumping:Bool = held != null && @:privateAccess held.__streaming;
					session.request(3, "GET", "/index.html", true);
					session.until(() -> session.finished(3) || session.ended, () -> {
						session.close();
						HTTPTestSupport.pumpMoreAsync(5, () -> {
							Assert.isTrue(pumping, "the download was not being pumped, so this shows nothing");
							Assert.equals(1, session.resetCode(1), "the server did not reset the stream, so this shows nothing");
							Assert.isFalse(stillPumping, "a download whose stream the server reset kept its file open");
							Assert.equals(1, closes, "CLOSE was dispatched " + closes + " times");
							Assert.equals(200, session.status(3));
							async.done();
						});
					});
				}, 2.0);
			});
		});
	}

	public function testAThrowServingAnHttp2RequestIsAnswered500(async:Async):Void {
		// What a request's serving throws outside any middleware -- here the
		// rate limiter's key -- is answered 500 over HTTP/1.1. Over HTTP/2 the
		// stream was reset INTERNAL_ERROR instead, so the client got no status
		// at all for a request the server could still answer.
		var session = new H2Session(config -> {
			config.rateLimitKey = handler -> {
				if (handler.requestPath == "/broken") {
					throw "the key broke";
				}
				return null;
			};
		});

		session.start(() -> {
			session.request(1, "GET", "/broken", true);
			session.until(() -> session.finished(1) || session.ended, () -> {
				session.request(3, "GET", "/index.html", true);
				session.until(() -> session.finished(3) || session.ended, () -> {
					session.close();
					Assert.equals(-1, session.resetCode(1), "the stream was reset rather than answered");
					Assert.equals(500, session.status(1));
					Assert.equals(200, session.status(3), "the connection did not carry on");
					async.done();
				});
			});
		});
	}

	public function testAThrowServingAnHttp2RequestAfterItsBodyIsAnswered500(async:Async):Void {
		// The same for a request weighed at its headers and carried on when
		// its body arrives: there it was reset too. The throw is a status
		// listener's, on the response the request was first given.
		var thrown:Bool = false;
		var session = new H2Session(config -> {
			config.onExpectContinue = handler -> {
				handler.addEventListener(crossbyte.events.HTTPStatusEvent.HTTP_RESPONSE_STATUS, _ -> {
					if (!thrown) {
						thrown = true;
						throw "the listener broke";
					}
				});
				return true;
			};
		});

		session.start(() -> {
			session.request(1, "POST", "/upload", false, [new HpackHeader("expect", "100-continue")]);
			session.until(() -> session.statuses(1).length > 0 || session.ended, () -> {
				session.data(1, "the body");
				session.until(() -> session.finished(1) || session.ended, () -> {
					session.close();
					Assert.isTrue(thrown, "the listener never threw, so this shows nothing");
					Assert.equals(-1, session.resetCode(1), "the stream was reset rather than answered");
					Assert.equals("100,500", session.statuses(1).join(","));
					async.done();
				});
			});
		});
	}

	public function testAnHttp2ResponseCutShortIsResetNotAnsweredAgain():Void {
		// A write that throws after a response's head has gone out leaves no
		// status to say so with: a 500 now would go in behind the head. From a
		// middleware, the 500's text went out as the 200's body, ended as
		// though whole; from the files, outside any middleware, the stream
		// was reset, which is what both do now.
		for (routed in [true, false]) {
			var frames:Array<H2Frame> = __servedThroughABreakingWrite(routed);
			var types:Array<String> = [for (frame in frames) frame.type.toString()];
			var label:String = routed ? "from a middleware" : "from the files";
			Assert.equals("HEADERS,RST_STREAM", types.join(","), label + ": stream 1 got " + types.join(","));
			var reset:Null<H2Frame> = frames.length > 0 ? frames[frames.length - 1] : null;
			if (reset != null && reset.type == H2FrameType.RST_STREAM) {
				Assert.equals(2, reset.payload.get(3), label + ": the stream was reset with " + reset.payload.get(3));
			}
		}
	}

	/**
		The frames written for stream 1 of one GET for `/index.html` through an
		`H2ConnectionHandler`, on a socket that throws when the response's
		first DATA is written: answered by a middleware, or, with none, by the
		files.
	**/
	private static function __servedThroughABreakingWrite(routed:Bool):Array<H2Frame> {
		var root = File.createTempDirectory();
		var fixture = new ByteArray();
		fixture.writeUTFBytes("Hello over h2");
		root.resolvePath("index.html").save(fixture);

		var config = new HTTPServerConfig("127.0.0.1", 0, root, null, ["index.html"]);
		config.http2Enabled = true;
		if (routed) {
			config.middleware.push((handler, next) -> handler.respond(200, "text/plain", "routed"));
		}
		var socket = new BreakingDataSocket(1);
		var connection = new crossbyte._internal.http.H2ConnectionHandler(socket, config);

		var out = new BytesBuffer();
		out.addString(H2Connection.PREFACE);
		writeFrame(out, H2FrameType.SETTINGS, 0, 0, Bytes.alloc(0));
		var block = new HpackEncoder(4096).encode([
			new HpackHeader(":method", "GET"),
			new HpackHeader(":scheme", "http"),
			new HpackHeader(":authority", "127.0.0.1"),
			new HpackHeader(":path", "/index.html")
		]);
		writeFrame(out, H2FrameType.HEADERS, H2Flags.END_HEADERS | H2Flags.END_STREAM, 1, block);
		socket.arrive(out.getBytes());
		connection.close();
		try root.deleteDirectory(true) catch (_:Dynamic) {}

		var written = socket.writtenSoFar();
		var frames:Array<H2Frame> = [];
		var position = 0;
		while (position + H2Frame.HEADER_SIZE <= written.length) {
			var frame = H2Frame.read(written, position);
			position += H2Frame.HEADER_SIZE + H2Frame.lengthOf(written, position);
			if (frame.streamId == 1) {
				frames.push(frame);
			}
		}
		return frames;
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

	/** Writes `size` patterned bytes to big.bin under the configuration's root, and answers its path. */
	private static function __bigFile(config:HTTPServerConfig, size:Int):String {
		var bytes:Bytes = Bytes.alloc(size);
		for (i in 0...size) {
			bytes.set(i, i & 0xFF);
		}
		var file = config.rootDirectory.resolvePath("big.bin");
		file.save(ByteArray.fromBytes(bytes));
		return file.nativePath;
	}

	/**
	 * Cuts the file at `path` to `length` bytes, where another handle has it
	 * open for reading. `sys.io.File.saveBytes` does that on every target but
	 * the jvm: there, with a reader open on the file, it overwrites the start
	 * and leaves the length, throwing nothing. With none open it truncates.
	 */
	private static function __truncate(path:String, length:Int):Void {
		#if (jvm || java)
		var file = new java.io.RandomAccessFile(path, "rw");
		file.setLength(haxe.Int64.ofInt(length));
		file.close();
		#else
		sys.io.File.saveBytes(path, Bytes.alloc(length));
		#end
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

	/**
		What one read asks for goes out in one write. Every frame was flushed
		on its own -- the SETTINGS, its acknowledgement, and each response's
		HEADERS and DATA -- a system call apiece, so an HTTP/2 request cost
		two where HTTP/1.1 costs one: 47,800 a second over cleartext, where
		Node's own http2 answered 111,000.
	**/
	public function testWhatOneReadAsksForGoesOutInOneWrite():Void {
		var config = new HTTPServerConfig("127.0.0.1", 0);
		config.http2Enabled = true;
		config.middleware.push((handler, next) -> handler.respond(200, "text/plain", "ok " + handler.requestPath));
		var socket = new FlushCountingSocket();
		var connection = new crossbyte._internal.http.H2ConnectionHandler(socket, config);

		var out = new BytesBuffer();
		out.addString(H2Connection.PREFACE);
		writeFrame(out, H2FrameType.SETTINGS, 0, 0, Bytes.alloc(0));
		var encoder = new HpackEncoder(4096);
		for (stream in [1, 3]) {
			var block = encoder.encode([
				new HpackHeader(":method", "GET"),
				new HpackHeader(":scheme", "http"),
				new HpackHeader(":authority", "127.0.0.1"),
				new HpackHeader(":path", "/" + stream)
			]);
			writeFrame(out, H2FrameType.HEADERS, H2Flags.END_HEADERS | H2Flags.END_STREAM, stream, block);
		}
		socket.arrive(out.getBytes());

		Assert.equals(1, socket.flushes, "one read was answered in " + socket.flushes + " writes");

		var written = socket.writtenSoFar();
		var answered:Array<Int> = [];
		var position = 0;
		while (position + H2Frame.HEADER_SIZE <= written.length) {
			var frame = H2Frame.read(written, position);
			position += H2Frame.HEADER_SIZE + H2Frame.lengthOf(written, position);
			if (frame.type == H2FrameType.HEADERS) {
				answered.push(frame.streamId);
			}
		}
		Assert.equals("1,3", answered.join(","), "the responses written");
		connection.close();
	}
}

/**
	A connected socket with nothing behind it: what is written is kept, flushes
	are counted, and what `arrive` is given is read as if it came off the wire.
**/
private class FlushCountingSocket extends Socket {
	public var flushes:Int = 0;

	private var __written:BytesBuffer = new BytesBuffer();
	private var __arriving:Null<Bytes> = null;

	public function new() {
		super();
	}

	/** Everything written so far, the record kept going: getBytes() spends a BytesBuffer. **/
	public function writtenSoFar():Bytes {
		var bytes = __written.getBytes();
		__written = new BytesBuffer();
		__written.addBytes(bytes, 0, bytes.length);
		return bytes;
	}

	public function arrive(bytes:Bytes):Void {
		__arriving = bytes;
		dispatchEvent(new ProgressEvent(ProgressEvent.SOCKET_DATA, bytes.length, 0));
	}

	override private function get_connected():Bool {
		return true;
	}

	// The peer the rate limiter and the access log ask for; there is no
	// descriptor here to ask.
	override private function get_remoteAddress():String {
		return "127.0.0.1";
	}

	override private function get_remotePort():Int {
		return 50000;
	}

	override public function readBytes(bytes:ByteArray, offset:Int = 0, length:Int = 0):Void {
		if (__arriving != null) {
			bytes.position = offset;
			bytes.writeBytes(__arriving, 0, __arriving.length);
			__arriving = null;
		}
	}

	override public function writeBytes(bytes:ByteArray, offset:Int = 0, length:Int = 0):Void {
		var count:Int = length == 0 ? bytes.length - offset : length;
		for (i in 0...count) {
			__written.addByte(bytes[offset + i]);
		}
	}

	override public function flush():Void {
		flushes++;
	}

	override public function close():Void {}
}

/**
	A `FlushCountingSocket` whose write of the first DATA frame on one stream
	throws, as a socket refusing a write mid-response does: one past its
	output cap under `OutputOverflowPolicy.THROW`, say. Each frame is one
	write here, so the frame's type and stream are the first bytes given.
**/
private class BreakingDataSocket extends FlushCountingSocket {
	private final __streamId:Int;
	private var __broken:Bool = false;

	public function new(streamId:Int) {
		super();
		__streamId = streamId;
	}

	override public function writeBytes(bytes:ByteArray, offset:Int = 0, length:Int = 0):Void {
		var count:Int = length == 0 ? bytes.length - offset : length;
		if (!__broken && count >= H2Frame.HEADER_SIZE && bytes[offset + 3] == (H2FrameType.DATA : Int)) {
			var streamId:Int = ((bytes[offset + 5] & 0x7F) << 24) | (bytes[offset + 6] << 16) | (bytes[offset + 7] << 8) | bytes[offset + 8];
			if (streamId == __streamId) {
				__broken = true;
				throw new crossbyte.errors.IOError("the write broke");
			}
		}
		super.writeBytes(bytes, offset, length);
	}
}

/** A limiter that throws: something the parse path calls outside any middleware. */
private class ThrowingRateLimiter extends crossbyte.net.RateLimiter {
	override public function isRateLimited(key:String):Bool {
		throw "the limiter broke";
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

	/** The last stream that GOAWAY said the server would process, or -1. */
	public var goAwayLastStream(default, null):Int = -1;

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
	// Every :status each stream was sent, interim ones included, in order.
	private final __statuses:Map<Int, Array<Int>> = new Map();
	private final __bodies:Map<Int, Bytes> = new Map();
	private final __finished:Map<Int, Bool> = new Map();
	private final __finishedAt:Map<Int, Float> = new Map();
	private final __headers:Map<Int, Map<String, String>> = new Map();
	private final __resets:Map<Int, Int> = new Map();
	// Names each stream's response sent never-indexed (RFC 7541 6.2.3).
	private final __neverIndexed:Map<Int, Array<String>> = new Map();

	// What the server lets this side send, for uploads that keep to flow
	// control. Both start at the RFC 9113 default.
	private var __connectionWindow:Int = 65535;
	private final __streamWindows:Map<Int, Int> = new Map();

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

	/**
	 * Opens each of `streamIds` with a bodiless request for `path`, in one
	 * write, so the server reads them together however its reads fall.
	 */
	public function requestAll(streamIds:Array<Int>, method:String, path:String):Void {
		var out = new BytesBuffer();
		for (streamId in streamIds) {
			__streamWindows.set(streamId, 65535);
			var block:Bytes = __encoder.encode([
				new HpackHeader(":method", method),
				new HpackHeader(":scheme", "http"),
				new HpackHeader(":authority", "127.0.0.1"),
				new HpackHeader(":path", path)
			]);
			__writeFrame(out, H2FrameType.HEADERS, H2Flags.END_HEADERS | H2Flags.END_STREAM, streamId, block);
		}
		__send(out);
	}

	/** Opens `streamId` with a request, left open for a body unless `endStream`. */
	public function request(streamId:Int, method:String, path:String, endStream:Bool, ?extra:Array<HpackHeader>):Void {
		var fields:Array<HpackHeader> = [
			new HpackHeader(":method", method),
			new HpackHeader(":scheme", "http"),
			new HpackHeader(":authority", "127.0.0.1"),
			new HpackHeader(":path", path)
		];
		if (extra != null) {
			for (field in extra) {
				fields.push(field);
			}
		}

		__streamWindows.set(streamId, 65535);
		var out = new BytesBuffer();
		__writeFrame(out, H2FrameType.HEADERS, H2Flags.END_HEADERS | (endStream ? H2Flags.END_STREAM : 0), streamId, __encoder.encode(fields));
		__send(out);
	}

	/** Sends `body` on `streamId` in frames no larger than the default maximum. */
	public function dataBytes(streamId:Int, body:Bytes, endStream:Bool):Void {
		var out = new BytesBuffer();
		var offset:Int = 0;
		do {
			var size:Int = body.length - offset > 16384 ? 16384 : body.length - offset;
			var last:Bool = offset + size >= body.length;
			__writeFrame(out, H2FrameType.DATA, (endStream && last) ? H2Flags.END_STREAM : 0, streamId, body.sub(offset, size));
			offset += size;
		} while (offset < body.length);
		__send(out);
	}

	/**
	 * Sends `body` on `streamId` only as fast as the server's windows allow,
	 * pumping between frames, and continues once it is all sent or the
	 * stream has been answered or reset. Continues with the bytes sent.
	 */
	public function upload(streamId:Int, body:Bytes, then:Int->Void, timeout:Float = 10.0):Void {
		var sent:Int = 0;
		function pushWhatFits():Bool {
			while (sent < body.length && !finished(streamId) && !ended) {
				var window:Int = __streamWindows.get(streamId);
				var allowed:Int = window < __connectionWindow ? window : __connectionWindow;
				if (allowed <= 0) {
					return false;
				}
				var size:Int = body.length - sent;
				if (size > 16384) {
					size = 16384;
				}
				if (size > allowed) {
					size = allowed;
				}
				var last:Bool = sent + size >= body.length;
				var out = new BytesBuffer();
				__writeFrame(out, H2FrameType.DATA, last ? H2Flags.END_STREAM : 0, streamId, body.sub(sent, size));
				__send(out);
				sent += size;
				__connectionWindow -= size;
				__streamWindows.set(streamId, window - size);
			}
			return true;
		}

		until(() -> pushWhatFits() && (sent >= body.length || finished(streamId) || ended), () -> then(sent), timeout);
	}

	/** The response header `name` on `streamId`, or null. */
	public function header(streamId:Int, name:String):Null<String> {
		var fields:Null<Map<String, String>> = __headers.get(streamId);
		return fields == null ? null : fields.get(name);
	}

	/** Whether the response on `streamId` sent `name` as a never-indexed literal. */
	public function neverIndexed(streamId:Int, name:String):Bool {
		var hidden:Null<Array<String>> = __neverIndexed.get(streamId);
		return hidden != null && hidden.indexOf(name) >= 0;
	}

	/** Whether this side's HPACK table holds an entry named `name`: what the server indexed. */
	public function tableHolds(name:String):Bool {
		for (slot in 0...__decoder.tableLength) {
			if (__decoder.dynamicEntry(slot).name == name) {
				return true;
			}
		}
		return false;
	}

	/** The error code of an RST_STREAM the server sent for `streamId`, or -1. */
	public function resetCode(streamId:Int):Int {
		return __resets.exists(streamId) ? __resets.get(streamId) : -1;
	}

	/** Resets `streamId` from this side, CANCEL by default: a client giving up. */
	public function reset(streamId:Int, code:Int = 8):Void {
		var payload:Bytes = Bytes.alloc(4);
		payload.set(0, (code >> 24) & 0xFF);
		payload.set(1, (code >> 16) & 0xFF);
		payload.set(2, (code >> 8) & 0xFF);
		payload.set(3, code & 0xFF);
		var out = new BytesBuffer();
		__writeFrame(out, H2FrameType.RST_STREAM, 0, streamId, payload);
		__send(out);
	}

	/** Sends the rest of a request's body and ends its stream. */
	public function data(streamId:Int, text:String):Void {
		var out = new BytesBuffer();
		__writeFrame(out, H2FrameType.DATA, H2Flags.END_STREAM, streamId, Bytes.ofString(text));
		__send(out);
	}

	/** Sends `text` on `streamId` and leaves the stream open for more. */
	public function trickle(streamId:Int, text:String):Void {
		var out = new BytesBuffer();
		__writeFrame(out, H2FrameType.DATA, 0, streamId, Bytes.ofString(text));
		__send(out);
	}

	/** Grants the server `increment` more bytes on `streamId`, or on the connection for 0. */
	public function windowUpdate(streamId:Int, increment:Int):Void {
		var payload:Bytes = Bytes.alloc(4);
		payload.set(0, (increment >> 24) & 0x7F);
		payload.set(1, (increment >> 16) & 0xFF);
		payload.set(2, (increment >> 8) & 0xFF);
		payload.set(3, increment & 0xFF);
		var out = new BytesBuffer();
		__writeFrame(out, H2FrameType.WINDOW_UPDATE, 0, streamId, payload);
		__send(out);
	}

	/** Bytes of body the server has sent on `streamId` so far. */
	public function received(streamId:Int):Int {
		return __bodies.exists(streamId) ? __bodies.get(streamId).length : 0;
	}

	/** Sends a PING, which asks the server only for its acknowledgement. */
	public function ping():Void {
		var out = new BytesBuffer();
		__writeFrame(out, H2FrameType.PING, 0, 0, Bytes.alloc(8));
		__send(out);
	}

	/** Every `:status` the server sent on `streamId`, interim ones first. */
	public function statuses(streamId:Int):Array<Int> {
		return __statuses.exists(streamId) ? __statuses.get(streamId).copy() : [];
	}

	/** When `streamId` was answered in full or reset, or -1. */
	public function finishedAt(streamId:Int):Float {
		return __finishedAt.exists(streamId) ? __finishedAt.get(streamId) : -1;
	}

	/**
	 * Pumps until `done` holds or `timeout` seconds pass, then continues. On
	 * the wall's clock, for the reason `pause` gives: several cases here wait
	 * for the server to enforce a deadline.
	 */
	public function until(done:Void->Bool, then:Void->Void, timeout:Float = 5.0):Void {
		HTTPTestSupport.pumpWallUntilAsync(done, timeout, _ -> then());
	}

	/**
	 * Pumps for `seconds` without sending anything. Cut short if the server
	 * ends the connection, since then there is nothing left to wait for.
	 *
	 * Each pump advances the runtime by the wall time it took. At the default
	 * step of a sixtieth the runtime's clock ran about fifteen times faster
	 * than the wall clock this waits on wherever a millisecond's sleep takes
	 * one -- Linux, not Windows -- and utest's timeout runs on the runtime's
	 * clock: the 1.5 s pause of the long poll case came to some 24 s of it,
	 * and the case timed out on CI with its answer on the way. A step of a
	 * millisecond, which mended that, ran it as much slower on Windows, where
	 * the sleep takes a timer tick, so the server's sweep came seconds late to
	 * a deadline a case was waiting on.
	 */
	public function pause(seconds:Float, then:Void->Void):Void {
		var resumeAt:Float = haxe.Timer.stamp() + seconds;
		HTTPTestSupport.pumpWallUntilAsync(() -> ended || haxe.Timer.stamp() >= resumeAt, seconds + 5.0, _ -> then());
	}

	/** The server this session talks to. */
	public var server(get, never):HTTPServer;

	private inline function get_server():HTTPServer {
		return __server;
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
			var fields:Map<String, String> = new Map();
			var hidden:Array<String> = [];
			for (field in __decoder.decode(frame.payload)) {
				if (field.name == ":status") {
					var code:Int = Std.parseInt(field.value);
					__status.set(frame.streamId, code);
					if (!__statuses.exists(frame.streamId)) {
						__statuses.set(frame.streamId, []);
					}
					__statuses.get(frame.streamId).push(code);
				} else {
					fields.set(field.name, field.value);
				}
				if (field.sensitive) {
					hidden.push(field.name);
				}
			}
			__headers.set(frame.streamId, fields);
			__neverIndexed.set(frame.streamId, hidden);
		} else if (frame.type == H2FrameType.DATA) {
			__append(frame.streamId, frame.payload);
		} else if (frame.type == H2FrameType.WINDOW_UPDATE) {
			var payload:Bytes = frame.payload;
			var increment:Int = ((payload.get(0) & 0x7f) << 24) | (payload.get(1) << 16) | (payload.get(2) << 8) | payload.get(3);
			if (frame.streamId == 0) {
				__connectionWindow += increment;
			} else if (__streamWindows.exists(frame.streamId)) {
				__streamWindows.set(frame.streamId, __streamWindows.get(frame.streamId) + increment);
			}
		} else if (frame.type == H2FrameType.RST_STREAM) {
			// Refused rather than answered, which is also the end of it.
			var payload:Bytes = frame.payload;
			__resets.set(frame.streamId, (payload.get(0) << 24) | (payload.get(1) << 16) | (payload.get(2) << 8) | payload.get(3));
			__finish(frame.streamId);
		} else if (frame.type == H2FrameType.GOAWAY && goAwayAt < 0) {
			goAwayAt = haxe.Timer.stamp();
			var payload:Bytes = frame.payload;
			goAwayLastStream = ((payload.get(0) & 0x7f) << 24) | (payload.get(1) << 16) | (payload.get(2) << 8) | payload.get(3);
			goAwayCode = (payload.get(4) << 24) | (payload.get(5) << 16) | (payload.get(6) << 8) | payload.get(7);
		}

		if ((frame.type == H2FrameType.HEADERS || frame.type == H2FrameType.DATA) && frame.has(H2Flags.END_STREAM)) {
			__finish(frame.streamId);
		}
	}

	private function __finish(streamId:Int):Void {
		if (!__finished.exists(streamId)) {
			__finished.set(streamId, true);
			__finishedAt.set(streamId, haxe.Timer.stamp());
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
