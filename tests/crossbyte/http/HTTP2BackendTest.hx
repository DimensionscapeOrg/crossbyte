package crossbyte.http;

import crossbyte._internal.http.Http;
import crossbyte._internal.http.HttpVersion;
import crossbyte._internal.http.h2.H2ClientSession;
import crossbyte._internal.http.h2.H2Connection;
import crossbyte._internal.http.h2.H2ConnectionError;
import crossbyte._internal.http.h2.H2ConnectionPool;
import crossbyte._internal.http.h2.H2ErrorCode;
import crossbyte._internal.http.h2.H2Flags;
import crossbyte._internal.http.h2.H2Frame;
import crossbyte._internal.http.h2.H2FrameType;
import crossbyte._internal.http.h2.H2Settings;
import crossbyte._internal.http.h2.hpack.HpackDecoder;
import crossbyte._internal.http.h2.hpack.HpackEncoder;
import crossbyte._internal.http.h2.hpack.HpackHeader;
import crossbyte.sys.System;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import sys.net.Host;
import sys.net.Socket as SysSocket;
import sys.thread.Lock;
import sys.thread.Mutex;
import sys.thread.Thread;
import utest.Assert;
import crossbyte.test.Require;

/**
 * `HTTP2Backend` end to end, over a real socket against a scripted h2c server.
 *
 * The unit suite drives `H2Connection` over a byte buffer, which proves the
 * state machine but not that the pieces are wired together: that the registry
 * resolves the backend, that the preface reaches a real peer before anything
 * else, and that a response comes back out through the `HTTPRequestContext`
 * callbacks a caller actually sees.
 */
class HTTP2BackendTest extends utest.Test {
	public function teardown():Void {
		HTTPBackendRegistry.clear();
		// Each pooled session owns a reader thread and a socket. Leaving one
		// behind leaks both into every case that follows.
		H2ConnectionPool.closeAll();
	}

	public function testBackendResolvesForHttp2Only():Void {
		var backend = new HTTP2Backend();
		Assert.isTrue(backend.supports(HTTPVersion.HTTP_2));
		Assert.isFalse(backend.supports(HTTPVersion.HTTP_1_1));
		// HTTP/3 is QUIC, which shares none of this framing.
		Assert.isFalse(backend.supports(HTTPVersion.HTTP_3));
	}

	public function testGetOverH2cReturnsStatusHeadersAndBody():Void {
		var server = new H2cServer();
		server.respond([new HpackHeader(":status", "200"), new HpackHeader("content-type", "text/plain")], "hello h2c");
		server.start();

		HTTPBackendRegistry.register(new HTTP2Backend());

		var status:Int = -1;
		var headers:Map<String, String> = null;
		var body:Bytes = null;
		var error:String = null;

		var http = new Http('http://127.0.0.1:${server.port}/greet', "GET", null, null, null, null, HttpVersion.HTTP_2, 5000);
		http.onStatus = code -> status = code;
		http.onHeaders = received -> headers = received;
		http.onComplete = data -> body = data;
		http.onError = (message, ?data) -> error = message;

		http.load();
		server.waitDone();

		Assert.isNull(error);
		Assert.equals(200, status);
		Require.notNull(body);
		Assert.equals("hello h2c", body.toString());

		Require.notNull(headers);
		Assert.equals("text/plain", headers.get("content-type"));
		// :status is reported through onStatus, not left among the fields.
		Assert.isFalse(headers.exists(":status"));
	}

	public function testAnErrorStatusOverHttp2IsAnErrorWithItsBody():Void {
		// The HTTP/1.1 client reports a 4xx or 5xx through onError with the
		// body; this completed, so one status meant two outcomes by version.
		var server = new H2cServer();
		server.respond([new HpackHeader(":status", "404"), new HpackHeader("content-type", "text/plain")], "no such thing");
		server.start();
		HTTPBackendRegistry.register(new HTTP2Backend());

		var completed:Bytes = null;
		var error:String = null;
		var errorBody:Bytes = null;
		var http = new Http('http://127.0.0.1:${server.port}/missing', "GET", null, null, null, null, HttpVersion.HTTP_2, 5000);
		http.onComplete = data -> completed = data;
		http.onError = (message, ?data) -> {
			error = message;
			errorBody = data;
		};

		http.load();
		server.waitDone();

		Assert.isNull(completed, "a 404 over HTTP/2 completed");
		Assert.equals("HTTP error 404", error);
		Require.notNull(errorBody);
		Assert.equals("no such thing", errorBody.toString());
	}

	public function testAGzipResponseOverHttp2IsDecoded():Void {
		var body = new crossbyte.io.ByteArray();
		body.writeUTFBytes("hello compressed h2");
		body.compress(crossbyte.utils.CompressionAlgorithm.GZIP);
		var compressed = Bytes.alloc(body.length);
		compressed.blit(0, body, 0, body.length);

		var server = new H2cServer();
		server.respondBytes([new HpackHeader(":status", "200"), new HpackHeader("content-encoding", "gzip")], compressed);
		server.start();
		HTTPBackendRegistry.register(new HTTP2Backend());

		var completed:Bytes = null;
		var error:String = null;
		var http = new Http('http://127.0.0.1:${server.port}/zipped', "GET", null, null, null, null, HttpVersion.HTTP_2, 5000);
		http.onComplete = data -> completed = data;
		http.onError = (message, ?data) -> error = message;

		http.load();
		server.waitDone();

		Assert.isNull(error);
		Require.notNull(completed);
		Assert.equals("hello compressed h2", completed.toString());
	}

	public function testRequestCarriesLowercasePseudoHeadersAndDropsHopByHopFields():Void {
		var server = new H2cServer();
		server.respond([new HpackHeader(":status", "204")], "");
		server.start();

		HTTPBackendRegistry.register(new HTTP2Backend());

		var http = new Http('http://127.0.0.1:${server.port}/path?x=1', "GET", ["X-Custom: yes", "Connection: keep-alive", "Host: elsewhere.example"],
			null, null, null, HttpVersion.HTTP_2, 5000, "CrossByteTest");
		http.load();
		server.waitDone();

		var sent:Map<String, String> = server.requestHeaders;
		Require.notNull(sent);

		Assert.equals("GET", sent.get(":method"));
		Assert.equals("http", sent.get(":scheme"));
		// :path is path and query together.
		Assert.equals("/path?x=1", sent.get(":path"));
		Assert.equals('127.0.0.1:${server.port}', sent.get(":authority"));

		// §8.2.1: field names are lowercase on the wire, so the caller's
		// casing must not survive.
		Assert.equals("yes", sent.get("x-custom"));
		Assert.isFalse(sent.exists("X-Custom"));

		// §8.2.2: connection-specific fields are malformed in HTTP/2, and Host
		// is redundant beside :authority -- keeping either would let a peer
		// reject the request outright.
		Assert.isFalse(sent.exists("connection"));
		Assert.isFalse(sent.exists("host"));

		Assert.equals("CrossByteTest", sent.get("user-agent"));
	}

	public function testAResponseHeaderSectionPastTheLimitIsAnError():Void {
		// A server chooses how many fields it sends, and 3,000 one-byte
		// references to one set-cookie crumb decode to 117 KB by HPACK's
		// accounting. The client took them under an eight megabyte limit it
		// never advertised and joined them quadratically; at 200,000 that is
		// the 23.5 seconds the server half was shown to lose. Refused now at
		// the HTTP/1.1 client's 64 KB, and the limit is said in SETTINGS.
		var fields:Array<HpackHeader> = [new HpackHeader(":status", "200")];
		for (_ in 0...3000) {
			fields.push(new HpackHeader("set-cookie", "a=1"));
		}
		var server = new H2cServer();
		server.respond(fields, "never read");
		server.start();
		HTTPBackendRegistry.register(new HTTP2Backend());

		var completed:Null<Bytes> = null;
		var error:Null<String> = null;
		var http = new Http('http://127.0.0.1:${server.port}/crumbs', "GET", null, null, null, null, HttpVersion.HTTP_2, 5000);
		http.onComplete = data -> completed = data;
		http.onError = (message, ?data) -> error = message;
		http.load();
		server.waitDone();

		Assert.isNull(completed, "a response past the header limit completed");
		Require.notNull(error);
		Assert.isTrue(error.indexOf("exceeded") >= 0, error);
		Assert.equals(64 * 1024, server.clientSetting(0x6), "SETTINGS_MAX_HEADER_LIST_SIZE was not advertised");
	}

	#if (cpp || java || jvm)
	public function testATlsHandshakeThatNeverAnswersHasADeadline():Void {
		// A server that accepts TCP and then says nothing. The connect had no
		// deadline and the per-origin gate was held across it, so three
		// requests to it had no outcome in 15 s, one TCP connection between
		// them, and a cancel did nothing. Each is held to its own timeout now,
		// and the waiters to theirs; they share the one connection attempt.
		// On the jvm too since J2: its handshake loop retried a timeout
		// 10,000 times, and now holds to the deadline, saying so in words of
		// its own that the backend reports as the timeout it was.
		if (!crossbyte._internal.socket.FlexSocket.alpnSupported) {
			Assert.pass("this build has no ALPN, so no HTTP/2 over TLS");
			return;
		}

		var server = new SilentServer();
		HTTPBackendRegistry.register(new HTTP2Backend());

		var outcomes:Array<String> = [];
		var guard:Mutex = new Mutex();
		var done:Lock = new Lock();
		var started:Float = haxe.Timer.stamp();
		for (i in 0...3) {
			Thread.create(() -> {
				var http = new Http('https://127.0.0.1:${server.port}/silent/$i', "GET", null, null, null, null, HttpVersion.HTTP_2, 1000);
				http.onComplete = _ -> {
					guard.acquire();
					outcomes.push("completed");
					guard.release();
				};
				http.onError = (message, ?data) -> {
					guard.acquire();
					outcomes.push(message);
					guard.release();
				};
				http.load();
				done.release();
			});
		}

		var all:Bool = true;
		for (_ in 0...3) {
			if (!done.wait(10.0)) {
				all = false;
				break;
			}
		}
		var elapsed:Float = haxe.Timer.stamp() - started;
		// Frees anything still stuck, whichever way this went.
		server.close();
		if (!all) {
			for (_ in 0...3) {
				done.wait(5.0);
			}
		}

		Assert.isTrue(all, "a request to a server that never finished TLS had no outcome in 10 s");
		Assert.isTrue(elapsed < 6.0, "took " + elapsed + " s for a 1 s timeout");
		guard.acquire();
		var seen:Array<String> = outcomes.copy();
		guard.release();
		Assert.equals(3, seen.length);
		for (outcome in seen) {
			Assert.isTrue(outcome.indexOf("timed out") >= 0 || outcome.indexOf("Timed out") >= 0, outcome);
		}
		Assert.equals(1, server.accepted, "the requests each connected rather than waiting on one connect");
	}
	#end

	public function testAWaiterForAConnectLeavesAtItsOwnDeadline():Void {
		// Waiters queued on a per-origin mutex for as long as the connect in
		// front of them took, with no deadline of their own.
		var origin:String = "https://pool.example:1";
		var release:Lock = new Lock();
		var connecting:Lock = new Lock();
		var connector:Lock = new Lock();
		Thread.create(() -> {
			try {
				H2ConnectionPool.acquire(origin, () -> {
					connecting.release();
					release.wait(10.0);
					throw "the server never answered";
				}, 30);
			} catch (_:Dynamic) {}
			connector.release();
		});
		Assert.isTrue(connecting.wait(5.0));

		var started:Float = haxe.Timer.stamp();
		var failure:Null<String> = null;
		var connected:Bool = false;
		try {
			H2ConnectionPool.acquire(origin, () -> {
				connected = true;
				throw "a waiter connected on its own";
			}, 0.3);
		} catch (e:H2ConnectionError) {
			failure = e.message;
		}
		var waited:Float = haxe.Timer.stamp() - started;
		release.release();
		connector.wait(5.0);

		Require.notNull(failure);
		Assert.isTrue(failure.indexOf("Timed out waiting") >= 0, failure);
		Assert.isFalse(connected);
		Assert.isTrue(waited < 3.0, "waited " + waited + " s on a 0.3 s deadline");
	}

	public function testAWaiterForAConnectLeavesOnItsCancel():Void {
		var origin:String = "https://pool.example:2";
		var release:Lock = new Lock();
		var connecting:Lock = new Lock();
		var connector:Lock = new Lock();
		Thread.create(() -> {
			try {
				H2ConnectionPool.acquire(origin, () -> {
					connecting.release();
					release.wait(10.0);
					throw "the server never answered";
				});
			} catch (_:Dynamic) {}
			connector.release();
		});
		Assert.isTrue(connecting.wait(5.0));

		var token = new HTTPCancelToken();
		Thread.create(() -> {
			System.sleep(0.2);
			token.cancel();
		});

		var started:Float = haxe.Timer.stamp();
		var failure:Null<String> = null;
		try {
			H2ConnectionPool.acquire(origin, () -> throw "a waiter connected on its own", 0, token);
		} catch (e:H2ConnectionError) {
			failure = e.message;
		}
		var waited:Float = haxe.Timer.stamp() - started;
		release.release();
		connector.wait(5.0);

		Require.notNull(failure);
		Assert.isTrue(failure.indexOf("cancelled") >= 0, failure);
		Assert.isTrue(waited < 3.0, "a cancel took " + waited + " s to reach a waiter");
	}

	public function testWaitersShareTheConnectorsFailureUnlessItWasCancelled():Void {
		// The next waiter took the gate and made the same connect again, and
		// the one after it again: three requests, three timeouts in a row.
		var origin:String = "https://pool.example:3";
		var release:Lock = new Lock();
		var connecting:Lock = new Lock();
		var connector:Lock = new Lock();
		Thread.create(() -> {
			try {
				H2ConnectionPool.acquire(origin, () -> {
					connecting.release();
					release.wait(10.0);
					throw "refused by the server";
				});
			} catch (_:Dynamic) {}
			connector.release();
		});
		Assert.isTrue(connecting.wait(5.0));

		var connected:Bool = false;
		var failure:Dynamic = null;
		Thread.create(() -> {
			System.sleep(0.2);
			release.release();
		});
		try {
			H2ConnectionPool.acquire(origin, () -> {
				connected = true;
				throw "a waiter connected on its own";
			}, 5);
		} catch (e:Dynamic) {
			failure = e;
		}
		connector.wait(5.0);

		Assert.equals("refused by the server", Std.string(failure));
		Assert.isFalse(connected, "a waiter made the failed connect again");

		// A connector that was cancelled says nothing about the server: the
		// waiter behind it connects for itself.
		var cancelOrigin:String = "https://pool.example:4";
		var token = new HTTPCancelToken();
		connecting = new Lock();
		var ownConnect:Bool = false;
		var cancelled:Lock = new Lock();
		Thread.create(() -> {
			try {
				H2ConnectionPool.acquire(cancelOrigin, () -> {
					connecting.release();
					cancelled.wait(10.0);
					throw "cancelled under the connect";
				}, 0, token);
			} catch (_:Dynamic) {}
			connector.release();
		});
		Assert.isTrue(connecting.wait(5.0));
		Thread.create(() -> {
			System.sleep(0.2);
			token.cancel();
			cancelled.release();
		});
		try {
			H2ConnectionPool.acquire(cancelOrigin, () -> {
				ownConnect = true;
				throw "its own attempt";
			}, 5);
		} catch (_:Dynamic) {}
		connector.wait(5.0);
		Assert.isTrue(ownConnect, "a cancelled connect's waiter did not try for itself");
	}

	public function testAnIpv6AuthorityKeepsItsBrackets():Void {
		// URL takes the brackets off an IPv6 literal, and :authority put the
		// host back bare: ::1:port, which no server can split.
		var probe = new SysSocket();
		try {
			probe.bind(new Host("::1"), 0);
			probe.close();
		} catch (_:Dynamic) {
			try {
				probe.close();
			} catch (_:Dynamic) {}
			Assert.pass("no IPv6 loopback on this machine");
			return;
		}

		var server = new H2cServer();
		server.bindAddress = "::1";
		server.respond([new HpackHeader(":status", "200")], "v6");
		server.start();
		HTTPBackendRegistry.register(new HTTP2Backend());

		var body:Bytes = null;
		var http = new Http('http://[::1]:${server.port}/v6', "GET", null, null, null, null, HttpVersion.HTTP_2, 5000);
		http.onComplete = data -> body = data;
		http.onError = (message, ?data) -> Assert.fail("request failed: " + message);
		http.load();
		server.waitDone();

		Require.notNull(body);
		Assert.equals('[::1]:${server.port}', server.requestHeaders.get(":authority"));
	}

	/**
		The client supplies an `Accept-Encoding` when the caller has not, as
		`URLRequest.requestHeaders` says and as the HTTP/1.1 client and Node
		do: `identity`. Over HTTP/2 there was none, which RFC 9110 12.5.3
		reads as any coding at all -- zstd included, which nothing here
		decodes. The caller's own is the one sent.
	**/
	public function testAnAcceptEncodingIsSentUnlessTheCallerSentOne():Void {
		var server = new H2RouteServer(_ -> {status: 200, chunks: ["ok"]});
		HTTPBackendRegistry.register(new HTTP2Backend());

		var unset = new Http('http://127.0.0.1:${server.port}/plain', "GET", null, null, null, null, HttpVersion.HTTP_2, 5000);
		unset.load();
		var own = new Http('http://127.0.0.1:${server.port}/own', "GET", ["Accept-Encoding: gzip"], null, null, null, HttpVersion.HTTP_2, 5000);
		own.load();
		server.stop();

		var requests = server.requests();
		Assert.equals(2, requests.length);
		if (requests.length == 2) {
			Assert.equals("identity", requests[0].headers.get("accept-encoding"), "no Accept-Encoding was supplied");
			Assert.equals("gzip", requests[1].headers.get("accept-encoding"), "the caller's Accept-Encoding was not the one sent");
		}
	}

	public function testPostSendsABodyAndContentLength():Void {
		var server = new H2cServer();
		server.respond([new HpackHeader(":status", "201")], "created");
		server.start();

		HTTPBackendRegistry.register(new HTTP2Backend());

		var http = new Http('http://127.0.0.1:${server.port}/submit', "POST", null, null, "text/plain", "payload body", HttpVersion.HTTP_2, 5000);
		var status:Int = -1;
		http.onStatus = code -> status = code;
		http.load();
		server.waitDone();

		Assert.equals(201, status);
		Assert.equals("payload body", server.requestBody);
		Assert.equals("12", server.requestHeaders.get("content-length"));
		Assert.equals("text/plain", server.requestHeaders.get("content-type"));
	}

	public function testAuthorizationIsSentNeverIndexed():Void {
		var server = new H2cServer();
		server.respond([new HpackHeader(":status", "200")], "ok");
		server.start();

		HTTPBackendRegistry.register(new HTTP2Backend());

		var http = new Http('http://127.0.0.1:${server.port}/secure', "GET", ["Authorization: Bearer secret-token"], null, null, null,
			HttpVersion.HTTP_2, 5000);
		http.load();
		server.waitDone();

		Assert.equals("Bearer secret-token", server.requestHeaders.get("authorization"));

		// A credential in the dynamic table is recoverable from how later
		// requests compress it, so it must be absent -- while the ordinary
		// fields around it are indexed as usual. Asserting an empty table
		// would pass for the wrong reason, by also forbidding those.
		Assert.isTrue(server.decoderTableNames.length > 0);
		Assert.equals(-1, server.decoderTableNames.indexOf("authorization"));
		Assert.isTrue(server.decoderTableNames.indexOf("user-agent") >= 0);
	}

	public function testAnIdlePooledConnectionIsReaped():Void {
		var server = new H2MuxServer(1);
		server.start();

		HTTPBackendRegistry.register(new HTTP2Backend());
		var origin = 'http://127.0.0.1:${server.port}';

		Assert.equals("/once", get(server.port, "/once"));

		// Pooled, which is the saving: the next request to this host skips the
		// handshakes and starts with a warm HPACK table.
		Assert.equals(1, H2ConnectionPool.sessionCount(origin));

		// But a pool that never lets go is a leak. Each session holds a socket
		// and a parked reader thread, so a program that talks to many hosts
		// accumulates one of each per host for as long as it runs.
		var previous = H2ConnectionPool.idleTimeoutSeconds;
		H2ConnectionPool.idleTimeoutSeconds = 0;
		var reaped = H2ConnectionPool.reapIdle();
		H2ConnectionPool.idleTimeoutSeconds = previous;

		Assert.equals(1, reaped);
		Assert.equals(0, H2ConnectionPool.sessionCount(origin));
	}

	public function testReapingLeavesABusyConnectionAlone():Void {
		var server = new H2MuxServer(1);
		server.start();

		HTTPBackendRegistry.register(new HTTP2Backend());
		var origin = 'http://127.0.0.1:${server.port}';

		Assert.equals("/keep", get(server.port, "/keep"));

		// The default allowance is generous, so a connection used a moment ago
		// is nowhere near idle and must survive a sweep.
		Assert.equals(0, H2ConnectionPool.reapIdle());
		Assert.equals(1, H2ConnectionPool.sessionCount(origin));
	}

	// ------------------------------------------------------ cancellation

	public function testCancellingOneStreamLeavesTheConnectionUsable():Void {
		// The server answers nothing until two requests have arrived, so the
		// first is genuinely in flight when it is cancelled.
		var server = new H2MuxServer(2, true, true, true);
		server.start();

		HTTPBackendRegistry.register(new HTTP2Backend());

		var cancelledError:String = null;
		var survivorBody:String = null;
		var cancelledDone = new Lock();
		var survivorDone = new Lock();

		var doomed = new Http('http://127.0.0.1:${server.port}/doomed', "GET", null, null, null, null, HttpVersion.HTTP_2, 5000);
		doomed.onError = (message, ?data) -> cancelledError = message;
		doomed.onComplete = data -> cancelledError = "COMPLETED " + data.toString();

		Thread.create(() -> {
			doomed.load();
			cancelledDone.release();
		});
		Thread.create(() -> {
			try survivorBody = get(server.port, "/survivor") catch (e:Dynamic) survivorBody = "ERR " + e;
			survivorDone.release();
		});

		// Both requests are on the connection before either is answered, so
		// this cancels one that is genuinely open.
		while (!server.sawBothArrive()) {
			System.sleep(0.01);
		}
		doomed.cancelToken.cancel();
		server.releaseResponses();

		Assert.isTrue(cancelledDone.wait(10), "cancelled request never returned");
		Assert.isTrue(survivorDone.wait(10), "surviving request never returned");

		Assert.equals("Request cancelled", cancelledError);

		// The whole point of RST_STREAM over a close: the other request on the
		// same connection is untouched.
		Assert.equals("/survivor", survivorBody);
		Assert.equals(1, server.connections);

		// Which stream the cancelled request actually got, rather than stream 1.
		// The two requests are opened on two threads, so whichever opens first
		// takes id 1 and the other takes 3 -- and when the survivor won that
		// race this looked for a reset on a stream nobody had cancelled. That
		// was the intermittent failure here: the reset was sent and the fixture
		// read it, against an id the assertion was not watching.
		var doomedId:Int = server.streamIdFor("/doomed");
		Assert.isTrue(doomedId > 0, "the cancelled request never reached the server");

		// The reset reaches the server on its own schedule -- it is read in the
		// drain loop, after the responses this test already waited for -- so
		// this waits for the observation rather than assuming it has landed.
		//
		// Ten seconds, matching the two Lock.wait calls above rather than the
		// three this used to allow: the loop leaves the moment the reset is seen,
		// so the budget only matters on a machine slow enough to need it, and a
		// busy one was enough to spend three seconds and fail a working reset.
		var deadline:Float = Sys.time() + 10;
		while (!server.sawReset(doomedId) && Sys.time() < deadline) {
			System.sleep(0.01);
		}
		Assert.isTrue(server.sawReset(doomedId),
			"server never saw RST_STREAM for the cancelled stream " + doomedId);

		// And only that one: cancelling must not disturb the other request.
		var survivorId:Int = server.streamIdFor("/survivor");
		Assert.isFalse(server.sawReset(survivorId), "the surviving stream was reset too");
	}

	public function testCancellingAfterTheHeadersArriveStillCancels():Void {
		var server = new H2HeadersFirstServer();
		server.start();

		HTTPBackendRegistry.register(new HTTP2Backend());

		var outcome:String = null;
		var done = new Lock();

		var http = new Http('http://127.0.0.1:${server.port}/partial', "GET", null, null, null, null, HttpVersion.HTTP_2, 5000);
		http.onError = (message, ?data) -> outcome = message;
		http.onComplete = data -> outcome = "COMPLETED " + data.toString();

		Thread.create(() -> {
			http.load();
			done.release();
		});

		// Obtained rather than assumed: the fixture follows the response
		// headers with a PING, and the client processes frames in order, so
		// its acknowledgement means the status is already on the stream.
		Assert.isTrue(server.waitHeadersProcessed(10), "the client never processed the response headers");
		http.cancelToken.cancel();
		// Only now does the rest of the response go out.
		server.releaseBody();

		Assert.isTrue(done.wait(10), "cancelled request never returned");
		// A status alone is not a response. This completed with an empty
		// body -- or, when the body won the race to the caller, a full one --
		// for a request cancelled before its body was even sent.
		Assert.equals("Request cancelled", outcome);
		Assert.isTrue(server.waitSawReset(10), "server never saw RST_STREAM for the cancelled stream");
	}

	public function testCancellingBeforeTheRequestStartsNeverOpensAStream():Void {
		var server = new H2MuxServer(1);
		server.start();

		HTTPBackendRegistry.register(new HTTP2Backend());

		var error:String = null;
		var http = new Http('http://127.0.0.1:${server.port}/never', "GET", null, null, null, null, HttpVersion.HTTP_2, 5000);
		http.onError = (message, ?data) -> error = message;
		http.cancelToken.cancel();
		http.load();

		Assert.notNull(error);
		// Opening a stream only to reset it would still burn an id, and ids
		// never come back on a connection.
		Assert.equals(0, server.streamIds.length);
	}

	public function testARequestCancelledBeforeItStartsLeavesTheConnectionAlone():Void {
		// Refused by the session before anything was sent, which the backend
		// took for a failed connection and closed -- the connection every
		// other request to the origin was sharing.
		var server = new H2RouteServer(request -> request.path == "/slow" ? {status: 200, chunks: ["done"], gap: 0.5} : {status: 200});
		HTTPBackendRegistry.register(new HTTP2Backend());

		var first:String = null;
		var done = new Lock();
		var slow = new Http('http://127.0.0.1:${server.port}/slow', "GET", null, null, null, null, HttpVersion.HTTP_2, 5000);
		slow.onComplete = data -> first = "COMPLETED " + data.toString();
		slow.onError = (message, ?data) -> first = message;
		Thread.create(() -> {
			slow.load();
			done.release();
		});
		var until:Float = haxe.Timer.stamp() + 5;
		while (server.requests().length == 0 && haxe.Timer.stamp() < until) {
			System.sleep(0.01);
		}

		var second:String = null;
		var cancelled = new Http('http://127.0.0.1:${server.port}/never', "GET", null, null, null, null, HttpVersion.HTTP_2, 5000);
		cancelled.onComplete = data -> second = "COMPLETED " + data.toString();
		cancelled.onError = (message, ?data) -> second = message;
		cancelled.cancelToken.cancel();
		cancelled.load();

		Assert.isTrue(done.wait(10), "the request in flight never returned");
		server.stop();
		Assert.equals("Request cancelled", second);
		Assert.equals("COMPLETED done", first, "the request sharing the connection failed with it");
		Assert.equals(1, server.connections());
	}

	// ------------------------------------------------------ multiplexing

	public function testTwoRequestsReuseOneConnection():Void {
		var server = new H2MuxServer(2);
		server.start();

		HTTPBackendRegistry.register(new HTTP2Backend());
		var origin = 'http://127.0.0.1:${server.port}';

		// Answered as they arrive, so these are sequential requests. The point
		// is only that the second did not open a second connection: a fresh
		// one would mean paying the handshakes again and starting HPACK cold.
		var first = get(server.port, "/one");
		var second = get(server.port, "/two");

		Assert.equals("/one", first);
		Assert.equals("/two", second);
		Assert.equals(1, H2ConnectionPool.sessionCount(origin));

		// One accepted socket carrying both, confirmed from the server side
		// rather than inferred from the pool's own bookkeeping.
		Assert.equals(1, server.connections);
		Assert.same([1, 3], server.streamIds);
	}

	public function testConcurrentRequestsAreNotSerialized():Void {
		// The server will not answer anything until both requests have
		// arrived. A client that serialized -- one connection per request, or
		// one stream at a time -- can never reach that state, so this either
		// demonstrates multiplexing or times out.
		var server = new H2MuxServer(2, true);
		server.start();

		HTTPBackendRegistry.register(new HTTP2Backend());

		var firstBody:String = null;
		var secondBody:String = null;
		var firstDone = new Lock();
		var secondDone = new Lock();

		Thread.create(() -> {
			try firstBody = get(server.port, "/slow") catch (e:Dynamic) firstBody = "ERR " + e;
			firstDone.release();
		});
		Thread.create(() -> {
			try secondBody = get(server.port, "/quick") catch (e:Dynamic) secondBody = "ERR " + e;
			secondDone.release();
		});

		Assert.isTrue(firstDone.wait(10), "first request did not finish");
		Assert.isTrue(secondDone.wait(10), "second request did not finish");

		Assert.equals("/slow", firstBody);
		Assert.equals("/quick", secondBody);

		// Both on one connection, and the server held the first open until the
		// second had been received.
		Assert.equals(1, server.connections);
		Assert.isTrue(server.sawBothArrive());
	}

	public function testDeadConnectionIsNotHandedToTheNextRequest():Void {
		var server = new H2MuxServer(1);
		server.start();

		HTTPBackendRegistry.register(new HTTP2Backend());
		var origin = 'http://127.0.0.1:${server.port}';

		Assert.equals("/first", get(server.port, "/first"));
		Assert.equals(1, H2ConnectionPool.sessionCount(origin));

		// The fixture serves one request and hangs up. The next caller must
		// not be handed the corpse, which is what a pool that only checks
		// liveness on insert would do.
		server.hangUp();
		server.waitClosed();

		var error:String = null;
		try {
			get(server.port, "/second");
		} catch (e:Dynamic) {
			error = Std.string(e);
		}

		Assert.notNull(error);
		Assert.equals(0, H2ConnectionPool.sessionCount(origin));
	}

	// ------------------------------------------------- sweeping under load

	/**
	 * A sweep beside a stream of requests never closes the connection under
	 * one of them.
	 *
	 * It did, about once in two thousand of the concurrent case above, which
	 * failed as
	 *
	 *     line: 343, expected "/slow" but it is "ERR Connection closed before the response headers arrived"
	 *     line: 344, expected "/quick" but it is "ERR HTTP/2 request failed: java.net.ConnectException: Connection refused: connect"
	 *
	 * The pool judged a session idle from two fields read without the
	 * session's lock: how many streams were in flight, and when the last one
	 * ended. A request starting on the session writes both, bumping the count
	 * and zeroing the time. A sweep that read the count before the bump and
	 * the time after it saw nothing in flight and a session idle since the
	 * clock began -- 459,622 seconds, when it was caught -- and closed the
	 * connection a request had just opened a stream on. The first request
	 * lost its connection; the second, finding none, dialled a server that
	 * had stopped listening.
	 *
	 * The window is a few instructions wide, so this widens it the other
	 * way: one thread sweeps continuously while another sends a thousand
	 * requests, each of which opens and closes a stream. Nothing here is idle
	 * for anything like the allowance, so nothing may be reaped.
	 *
	 * The allowance is a second rather than the default ninety, because the
	 * torn read made a session "idle since the clock's origin", and natively
	 * that origin is the process's first reading: a short run has not yet
	 * left ninety seconds behind, and would not see the bug at all. So the
	 * allowance is one second and the case runs at least that long after the
	 * origin. On the jvm the origin is boot, and nothing waits.
	 */
	public function testASweepNeverClosesAConnectionUnderARequest():Void {
		var requests = 1000;
		var server = new H2MuxServer(requests);
		server.start();

		HTTPBackendRegistry.register(new HTTP2Backend());
		var previous = H2ConnectionPool.idleTimeoutSeconds;
		H2ConnectionPool.idleTimeoutSeconds = 1;
		if (haxe.Timer.stamp() < 1.5) {
			System.sleep(1.5 - haxe.Timer.stamp());
		}

		var control = new Mutex();
		var stopping = false;
		var reaped = 0;
		var swept = new Lock();
		Thread.create(() -> {
			var total = 0;
			while (true) {
				control.acquire();
				var stop = stopping;
				control.release();
				if (stop) {
					break;
				}
				total += H2ConnectionPool.reapIdle();
			}
			control.acquire();
			reaped = total;
			control.release();
			swept.release();
		});

		var failure:String = null;
		var sent = 0;
		while (sent < requests && failure == null) {
			var path = "/r" + sent;
			var body = try get(server.port, path) catch (e:Dynamic) "ERR " + Std.string(e);
			if (body != path) {
				failure = 'request $sent of $requests: $body';
			}
			sent++;
		}

		control.acquire();
		stopping = true;
		control.release();
		Assert.isTrue(swept.wait(5), "the sweeping thread did not stop");
		H2ConnectionPool.idleTimeoutSeconds = previous;

		control.acquire();
		var closed = reaped;
		control.release();
		Assert.isNull(failure, failure);
		Assert.equals(0, closed, 'the sweep closed $closed connection(s) that were in use');
	}

	/**
	 * A request the pooled connection refuses before sending goes out once
	 * more on another.
	 *
	 * The session a request is handed can refuse its stream with nothing
	 * sent: the pool retires it as idle between handing it over and the
	 * stream opening, or its peer has said GOAWAY. REFUSED_STREAM promises
	 * the request was not processed, so the backend sends it again rather
	 * than failing a request nobody ever saw. GOAWAY is the one of those a
	 * test can arrange: nothing about a session says its peer has gone away
	 * until a stream is asked of it.
	 */
	public function testARequestRefusedBeforeItIsSentGoesOutOnceMore():Void {
		var server = new H2GoAwayServer();
		server.start();

		HTTPBackendRegistry.register(new HTTP2Backend());

		Assert.equals("/first", get(server.port, "/first"));
		var second = try get(server.port, "/second") catch (e:Dynamic) "ERR " + Std.string(e);
		Assert.equals("/second", second);

		server.waitServed();
		Assert.equals(2, server.connections, "the second request did not open a connection of its own");
		Assert.same(["/first", "/second"], server.paths);
	}

	/** One request through the registered backend, returning the body. */
	private function get(port:Int, path:String):String {
		var body:String = null;
		var error:String = null;

		var http = new Http('http://127.0.0.1:$port$path', "GET", null, null, null, null, HttpVersion.HTTP_2, 5000);
		http.onComplete = data -> body = data.toString();
		http.onError = (message, ?data) -> error = message;
		http.load();

        if (error != null) {
            throw error;
        }
		return body;
	}

	public function testStreamResetIsReportedAsAnError():Void {
		var server = new H2cServer();
		server.reset(H2ErrorCodeShim.REFUSED_STREAM);
		server.start();

		HTTPBackendRegistry.register(new HTTP2Backend());

		var error:String = null;
		var completed:Bool = false;
		var http = new Http('http://127.0.0.1:${server.port}/gone', "GET", null, null, null, null, HttpVersion.HTTP_2, 5000);
		http.onError = (message, ?data) -> error = message;
		http.onComplete = _ -> completed = true;

		http.load();
		server.waitDone();

		Require.notNull(error);
		Assert.isFalse(completed);
		Assert.isTrue(error.indexOf("REFUSED_STREAM") >= 0);
	}

	public function testAResetAfterTheHeadersIsAnErrorNotATruncatedResponse():Void {
		var server = new H2TruncatedResponseServer(H2ErrorCodeShim.INTERNAL_ERROR);
		server.start();

		HTTPBackendRegistry.register(new HTTP2Backend());

		var error:String = null;
		var completed:String = null;
		var http = new Http('http://127.0.0.1:${server.port}/cut', "GET", null, null, null, null, HttpVersion.HTTP_2, 5000);
		http.onError = (message, ?data) -> error = message;
		http.onComplete = data -> completed = data.toString();

		http.load();

		// The status, the headers and part of the body had all arrived, and
		// the reset used to be reported only when the status had not: this
		// completed with the part.
		Assert.isNull(completed, "a reset response completed with " + completed);
		Assert.equals("Stream reset by peer: INTERNAL_ERROR", error);
	}

	public function testAConnectionLostMidBodyIsAnErrorNotATruncatedResponse():Void {
		var server = new H2TruncatedResponseServer();
		server.start();

		HTTPBackendRegistry.register(new HTTP2Backend());

		var error:String = null;
		var completed:String = null;
		var http = new Http('http://127.0.0.1:${server.port}/cut', "GET", null, null, null, null, HttpVersion.HTTP_2, 5000);
		http.onError = (message, ?data) -> error = message;
		http.onComplete = data -> completed = data.toString();

		http.load();

		Assert.isNull(completed, "a response cut short completed with " + completed);
		// Its own message rather than the one for no headers at all: a
		// caller deciding whether to retry wants to know the server had
		// started answering.
		Assert.equals("Connection closed before the response body completed", error);
		Assert.isTrue(server.closedCleanly(), "the fixture's close was not a clean FIN");
	}

	public function testAnAnswerBeforeTheUploadEndsCompletesTheRequest():Void {
		// RFC 9113 8.1: the server answers in full once it has seen part of
		// the body, then asks for no more with RST_STREAM(NO_ERROR). It never
		// grants more window, so the upload is waiting on one when it does.
		var server = new H2EarlyResponseServer(H2EarlyResponseServer.ANSWER);
		server.start();

		HTTPBackendRegistry.register(new HTTP2Backend());

		var started:Float = haxe.Timer.stamp();
		var outcome:String = __upload(server.port);
		var took:Float = haxe.Timer.stamp() - started;

		// This waited on the stream's window, which never reopens once the
		// stream is over, until the connection had been quiet for thirty
		// seconds -- then failed it with a FLOW_CONTROL_ERROR, and every other
		// request on it.
		Assert.equals("COMPLETED early answer", outcome);
		Assert.isTrue(took < 10, 'the answered upload took ${took}s to return');

		// The connection is still good, and it is the same one.
		Assert.equals("/second", get(server.port, "/second"));
		Assert.equals(1, server.connections());

		// Our half was released before the next request went out: the
		// server's response ended only its own.
		Assert.equals("1:CANCEL", server.resetsBeforeSecond());
		server.stop();
	}

	public function testAResetDuringTheUploadIsReportedPromptly():Void {
		var server = new H2EarlyResponseServer(H2EarlyResponseServer.RESET);
		server.start();

		HTTPBackendRegistry.register(new HTTP2Backend());

		var started:Float = haxe.Timer.stamp();
		var outcome:String = __upload(server.port);
		var took:Float = haxe.Timer.stamp() - started;

		Assert.equals("Stream reset by peer: CANCEL", outcome);
		Assert.isTrue(took < 10, 'the reset upload took ${took}s to return');

		Assert.equals("/second", get(server.port, "/second"));
		Assert.equals(1, server.connections());
		// And no RST_STREAM sent back in reply to the server's own.
		Assert.equals("", server.resetsBeforeSecond());
		server.stop();
	}

	public function testAnUploadTheServerStopsTakingTimesOut():Void {
		// The server takes the 65535 bytes it granted and no more, answers
		// nothing, and keeps the connection busy with PINGs meanwhile.
		var server = new H2EarlyResponseServer(H2EarlyResponseServer.SILENT, true);
		server.start();

		HTTPBackendRegistry.register(new HTTP2Backend());

		var started:Float = haxe.Timer.stamp();
		var outcome:String = __upload(server.port, 1500);
		var took:Float = haxe.Timer.stamp() - started;

		// The timeout started only once the body was out. While it waited on
		// the window any frame counted as progress, so this waited as long as
		// the PINGs went on, and thirty seconds after -- then failed the
		// connection, and every request on it.
		Assert.equals('Request to http://127.0.0.1:${server.port} timed out after 1.5s', outcome);
		Assert.isTrue(took < 5, 'the stalled upload took ${took}s to time out');

		// Only the upload's own stream was reset, and the connection is kept.
		Assert.equals("/second", get(server.port, "/second"));
		Assert.equals(1, server.connections());
		Assert.equals("1:CANCEL", server.resetsBeforeSecond());
		server.stop();
	}

	public function testCancellingAnUploadWaitingOnAWindowStopsIt():Void {
		var server = new H2EarlyResponseServer(H2EarlyResponseServer.SILENT);
		server.start();

		HTTPBackendRegistry.register(new HTTP2Backend());

		var outcome:String = null;
		var done = new Lock();
		var http = new Http('http://127.0.0.1:${server.port}/upload', "POST", null, null, "application/octet-stream", Bytes.alloc(100000),
			HttpVersion.HTTP_2, 20000);
		http.onComplete = data -> outcome = "COMPLETED " + data.toString();
		http.onError = (message, ?data) -> outcome = message;

		Thread.create(() -> {
			http.load();
			done.release();
		});

		// Obtained rather than assumed: the whole window has gone out, so the
		// body is waiting on one the server will not grant.
		Assert.isTrue(server.waitWindowUsed(10), "the upload never used its window");
		var cancelledAt:Float = haxe.Timer.stamp();
		http.cancelToken.cancel();

		// The cancel handler was registered only once the body was out, so
		// this cancel did nothing, and the upload waited on.
		Assert.isTrue(done.wait(10), "the cancelled upload never returned");
		var took:Float = haxe.Timer.stamp() - cancelledAt;
		Assert.equals("Request cancelled", outcome);
		Assert.isTrue(took < 5, 'the cancelled upload took ${took}s to return');

		Assert.equals("/second", get(server.port, "/second"));
		Assert.equals(1, server.connections());
		Assert.equals("1:CANCEL", server.resetsBeforeSecond());
		server.stop();
	}

	public function testAResponseThatNeverComesTimesOutOnlyItsStream():Void {
		var server = new H2EarlyResponseServer(H2EarlyResponseServer.SILENT);
		server.start();

		HTTPBackendRegistry.register(new HTTP2Backend());

		var outcome:String = null;
		var http = new Http('http://127.0.0.1:${server.port}/hang', "GET", null, null, null, null, HttpVersion.HTTP_2, 1500);
		http.onComplete = data -> outcome = "COMPLETED " + data.toString();
		http.onError = (message, ?data) -> outcome = message;
		http.load();

		// A timeout belongs to its stream, which is reset. Reported as a
		// connection error, it closed the connection, and every other request
		// on it failed along with this one.
		Assert.equals('Request to http://127.0.0.1:${server.port} timed out after 1.5s', outcome);
		Assert.equals("/second", get(server.port, "/second"));
		Assert.equals(1, server.connections());
		Assert.equals("1:CANCEL", server.resetsBeforeSecond());
		server.stop();
	}

	/** POSTs more than the default 65535-byte window can carry. */
	private function __upload(port:Int, timeout:Int = 20000):String {
		var outcome:String = null;
		var http = new Http('http://127.0.0.1:$port/upload', "POST", null, null, "application/octet-stream", Bytes.alloc(100000),
			HttpVersion.HTTP_2, timeout);
		http.onComplete = data -> outcome = "COMPLETED " + data.toString();
		http.onError = (message, ?data) -> outcome = message;
		http.load();
		return outcome;
	}

	public function testServerThatIsNotSpeakingH2FailsRatherThanHanging():Void {
		// Prior-knowledge h2c has no negotiation: RFC 9113 §3.1 removed the
		// upgrade handshake, so an HTTP/1.1 server just sees garbage. The
		// backend must surface that instead of blocking forever.
		var server = new H2cServer();
		server.replyWithHttp1();
		server.start();

		HTTPBackendRegistry.register(new HTTP2Backend());

		var error:String = null;
		var http = new Http('http://127.0.0.1:${server.port}/', "GET", null, null, null, null, HttpVersion.HTTP_2, 5000);
		http.onError = (message, ?data) -> error = message;
		http.load();
		server.waitDone();

		Assert.notNull(error);
	}

	// ------------------------------------------------------ redirects

	public function testARedirectOverHttp2IsFollowed():Void {
		// A 3xx completed here with its Location unfollowed, where the
		// HTTP/1.1 client, Node and the browser all followed it.
		var server = new H2RouteServer(request -> switch (request.path) {
			case "/dir/start": {status: 302, fields: [new HpackHeader("location", "../final?x=1")]};
			case "/final?x=1": {status: 200, chunks: ["done"]};
			default: {status: 500};
		});
		HTTPBackendRegistry.register(new HTTP2Backend());

		var statuses:Array<Int> = [];
		var outcome:String = null;
		var http = new Http('http://127.0.0.1:${server.port}/dir/start', "GET", null, null, null, null, HttpVersion.HTTP_2, 5000);
		http.onStatus = status -> statuses.push(status);
		http.onComplete = data -> outcome = "COMPLETED " + data.toString();
		http.onError = (message, ?data) -> outcome = message;
		http.load();
		server.stop();

		Assert.equals("COMPLETED done", outcome);
		// Each hop reported as it went, as over HTTP/1.1.
		Assert.same([302, 200], statuses);
		Assert.same(["/dir/start", "/final?x=1"], [for (request in server.requests()) request.path]);
		// Where the response came from, which is what URLLoader reports.
		Assert.equals('http://127.0.0.1:${server.port}/final?x=1', http.url);
		Assert.isTrue(http.redirected);
		// And the second hop rode the first one's connection.
		Assert.equals(1, server.connections());
	}

	public function testAnHttp2RedirectToAnotherOriginLeavesTheCredentialsBehind():Void {
		var elsewhere = new H2RouteServer(_ -> {status: 200, chunks: ["ok"]});
		var origin = new H2RouteServer(_ -> {status: 302, fields: [new HpackHeader("location", 'http://127.0.0.1:${elsewhere.port}/landing')]});
		HTTPBackendRegistry.register(new HTTP2Backend());

		var outcome:String = null;
		var http = new Http('http://127.0.0.1:${origin.port}/start', "GET",
			["Authorization: Bearer sk-live-secret", "Proxy-Authorization: Basic cHJveHk=", "Cookie: sid=caller-set", "X-Trace: t-1"], null, null, null,
			HttpVersion.HTTP_2, 5000);
		http.onComplete = data -> outcome = "COMPLETED " + data.toString();
		http.onError = (message, ?data) -> outcome = message;
		http.load();
		origin.stop();
		elsewhere.stop();

		Assert.equals("COMPLETED ok", outcome);
		var asked:Array<H2RouteRequest> = origin.requests();
		var landed:Array<H2RouteRequest> = elsewhere.requests();
		Assert.equals(1, asked.length);
		Assert.equals(1, landed.length, "the redirect was not followed");
		if (asked.length != 1 || landed.length != 1) {
			return;
		}
		Assert.equals("Bearer sk-live-secret", asked[0].headers.get("authorization"), "the origin itself did not get the credentials");
		Assert.isFalse(landed[0].headers.exists("authorization"), "Authorization reached another origin");
		Assert.isFalse(landed[0].headers.exists("proxy-authorization"), "Proxy-Authorization reached another origin");
		Assert.isFalse(landed[0].headers.exists("cookie"), "a caller's Cookie reached another origin");
		Assert.equals("t-1", landed[0].headers.get("x-trace"), "an ordinary header was dropped as well");
	}

	public function testAnHttp2SeeOtherTurnsAPostIntoAGet():Void {
		var server = new H2RouteServer(request -> request.path == "/submit" ? {status: 303, fields: [new HpackHeader("location", "/final")]} : {
			status: 200,
			chunks: ["ok"]
		});
		HTTPBackendRegistry.register(new HTTP2Backend());

		var outcome:String = null;
		var http = new Http('http://127.0.0.1:${server.port}/submit', "POST", null, null, "text/plain", "payload", HttpVersion.HTTP_2, 5000);
		http.onComplete = data -> outcome = "COMPLETED " + data.toString();
		http.onError = (message, ?data) -> outcome = message;
		http.load();
		server.stop();

		Assert.equals("COMPLETED ok", outcome);
		var requests:Array<H2RouteRequest> = server.requests();
		Assert.equals(2, requests.length, "the redirect was not followed");
		if (requests.length != 2) {
			return;
		}
		Assert.equals("POST", requests[0].method);
		Assert.equals("payload", requests[0].body);
		Assert.equals("GET", requests[1].method);
		Assert.equals("", requests[1].body);
		Assert.isFalse(requests[1].headers.exists("content-type"), "the dropped body's Content-Type went with the GET");
	}

	public function testAnHttp2RedirectCarriesTheCookieItSet():Void {
		// A sign-in answering 302 with a session cookie, which the page it
		// sends the client to needs to see.
		var server = new H2RouteServer(request -> request.path == "/signin" ? {
			status: 302,
			fields: [new HpackHeader("location", "/landing"), new HpackHeader("set-cookie", "session=abc123; Path=/; HttpOnly")]
		} : {status: 200, chunks: ["ok"]});
		HTTPBackendRegistry.register(new HTTP2Backend());

		var outcome:String = null;
		var http = new Http('http://127.0.0.1:${server.port}/signin', "GET", null, null, null, null, HttpVersion.HTTP_2, 5000);
		http.onComplete = data -> outcome = "COMPLETED " + data.toString();
		http.onError = (message, ?data) -> outcome = message;
		http.load();
		server.stop();

		Assert.equals("COMPLETED ok", outcome);
		var requests:Array<H2RouteRequest> = server.requests();
		Assert.equals(2, requests.length, "the redirect was not followed");
		if (requests.length != 2) {
			return;
		}
		Assert.isFalse(requests[0].headers.exists("cookie"), "a cookie was sent before anything set one");
		Assert.equals("session=abc123", requests[1].headers.get("cookie"));
	}

	public function testAnHttp2RedirectLimitIsTheHttp11One():Void {
		// Ten followed and then answered is within Http.MAX_REDIRECTS; an
		// eleventh is one too many.
		function hops(answerAt:Int):H2RouteServer {
			return new H2RouteServer(request -> {
				var hop:Int = Std.parseInt(request.path.substr(4));
				return hop == answerAt ? {status: 200, chunks: ["done"]} : {status: 302, fields: [new HpackHeader("location", '/hop${hop + 1}')]};
			});
		}
		HTTPBackendRegistry.register(new HTTP2Backend());

		var ten = hops(10);
		var outcome:String = null;
		var http = new Http('http://127.0.0.1:${ten.port}/hop0', "GET", null, null, null, null, HttpVersion.HTTP_2, 5000);
		http.onComplete = data -> outcome = "COMPLETED " + data.toString();
		http.onError = (message, ?data) -> outcome = message;
		http.load();
		ten.stop();
		Assert.equals("COMPLETED done", outcome);

		var endless = hops(-1);
		outcome = null;
		http = new Http('http://127.0.0.1:${endless.port}/hop0', "GET", null, null, null, null, HttpVersion.HTTP_2, 5000);
		http.onComplete = data -> outcome = "COMPLETED " + data.toString();
		http.onError = (message, ?data) -> outcome = message;
		http.load();
		endless.stop();
		Assert.equals("Exceeded the number of allowed redirects", outcome);
		Assert.equals(11, endless.requests().length);
	}

	public function testAnHttp2RedirectLeavingHttpIsRefused():Void {
		var server = new H2RouteServer(_ -> {status: 302, fields: [new HpackHeader("location", "ftp://127.0.0.1/file")]});
		HTTPBackendRegistry.register(new HTTP2Backend());

		var outcome:String = null;
		var http = new Http('http://127.0.0.1:${server.port}/start', "GET", null, null, null, null, HttpVersion.HTTP_2, 5000);
		http.onComplete = data -> outcome = "COMPLETED " + data.toString();
		http.onError = (message, ?data) -> outcome = message;
		http.load();
		server.stop();

		Assert.equals("Refused a redirect to ftp: only http and https are followed", outcome);
	}

	public function testAnHttp2RedirectIsHandedBackWhenNotFollowed():Void {
		var server = new H2RouteServer(_ -> {status: 302, fields: [new HpackHeader("location", "/final")]});
		HTTPBackendRegistry.register(new HTTP2Backend());

		var outcome:String = null;
		var http = new Http('http://127.0.0.1:${server.port}/start', "GET", null, null, null, null, HttpVersion.HTTP_2, 5000, "CrossByte", false);
		http.onStatus = status -> outcome = "status " + status;
		http.onError = (message, ?data) -> outcome = message;
		http.load();
		server.stop();

		Assert.equals("status 302", outcome);
		Assert.equals(1, server.requests().length);
		Assert.isFalse(http.redirected);
	}

	// ------------------------------------------------------ idle timeout

	public function testAnHttp2ResponseStillArrivingOutlivesTheTimeout():Void {
		// A 600 ms idle timeout, and a body in five pieces a quarter second
		// apart: well over a second in all, never quiet for 600 ms. The
		// timeout was a deadline on the whole response over HTTP/2, so this
		// was cut off where the HTTP/1.1 client let it finish.
		var server = new H2RouteServer(_ -> {status: 200, chunks: ["a", "b", "c", "d", "e"], gap: 0.25});
		HTTPBackendRegistry.register(new HTTP2Backend());

		var outcome:String = null;
		var http = new Http('http://127.0.0.1:${server.port}/slow', "GET", null, null, null, null, HttpVersion.HTTP_2, 600);
		http.onComplete = data -> outcome = "COMPLETED " + data.toString();
		http.onError = (message, ?data) -> outcome = message;
		http.load();
		server.stop();

		Assert.equals("COMPLETED abcde", outcome);
	}

	/**
		A timeout of `0` is no limit, as `URLRequest.idleTimeout` says and as
		it is on JavaScript: a stream waits for its answer however long it
		takes. The session took `0` as a wait of none and failed the stream
		at once, so the backend could not pass it on and waited 30 seconds
		instead -- one setting, two meanings, depending on the target.
	**/
	public function testAStreamWithNoIdleLimitWaitsForItsAnswer():Void {
		var server = new H2RouteServer(_ -> {status: 200, chunks: ["late"], gap: 0.4});
		var socket = new crossbyte._internal.socket.FlexSocket(false);
		socket.connect("127.0.0.1", server.port);
		var session = new crossbyte._internal.http.h2.H2ClientSession('http://127.0.0.1:${server.port}', socket,
			new H2Connection(socket.input, socket.output, new H2Settings()));
		var direct:String;
		try {
			var stream = session.execute("GET", "http", '127.0.0.1:${server.port}', "/late", [], null, 0);
			direct = stream.endOfStream ? "ended " + stream.takeBody().toString() : "not ended";
		} catch (e:Dynamic) {
			direct = "failed: " + Std.string(e);
		}
		session.close();

		// And through the backend, which passes the request's 0 on now.
		HTTPBackendRegistry.register(new HTTP2Backend());
		var outcome:String = null;
		var http = new Http('http://127.0.0.1:${server.port}/late', "GET", null, null, null, null, HttpVersion.HTTP_2, 0);
		http.onComplete = data -> outcome = "COMPLETED " + data.toString();
		http.onError = (message, ?data) -> outcome = message;
		http.load();
		server.stop();

		Assert.equals("ended late", direct, "a stream with no idle limit did not wait for its answer");
		Assert.equals("COMPLETED late", outcome);
	}

	public function testAnHttp2ResponseThatStopsTimesOutFromItsLastFrame():Void {
		// Two pieces, then nothing: the timeout runs from the last of them.
		var server = new H2RouteServer(_ -> {status: 200, chunks: ["a", "b"], gap: 0.3, hold: true});
		HTTPBackendRegistry.register(new HTTP2Backend());

		var outcome:String = null;
		var http = new Http('http://127.0.0.1:${server.port}/stalls', "GET", null, null, null, null, HttpVersion.HTTP_2, 500);
		http.onComplete = data -> outcome = "COMPLETED " + data.toString();
		http.onError = (message, ?data) -> outcome = message;
		var started:Float = haxe.Timer.stamp();
		http.load();
		var took:Float = haxe.Timer.stamp() - started;
		server.stop();

		Assert.equals('Request to http://127.0.0.1:${server.port} timed out after 0.5s', outcome);
		// The last piece came at 0.6 s, so no sooner than 1.1 s: a deadline
		// counted from the start ended it at half a second.
		Assert.isTrue(took >= 1.0, 'timed out after ${took}s, before the stream had been idle 0.5s');
		Assert.isTrue(took < 5.0, 'a stalled stream took ${took}s to time out');
	}

	// ------------------------------------------------------ a hostile server

	public function testAResponseBodyPastTheLimitIsAnError():Void {
		// The HTTP/1.1 client holds a body to Http.MAX_BODY_SIZE; over HTTP/2
		// nothing held it, and the stream's window was opened again as every
		// half of it arrived, so a server sending without end grew the body
		// for as long as it liked. 4 MB here against a 256 KB limit.
		var saved:Int = Http.MAX_BODY_SIZE;
		Http.MAX_BODY_SIZE = 256 * 1024;
		var server = new H2ScriptServer(peer -> {
			peer.open();
			var id:Int = peer.readRequest();
			peer.headers(id, [new HpackHeader(":status", "200")], 0);
			// Within the windows the client gives, as a server sending an
			// endless body by the rules does: the client opened them again
			// as each half was used.
			var sent:Int = peer.sendBody(id, 4 * 1024 * 1024);
			peer.server.note(sent < 0 ? "reset after " + (-sent) : "no reset, sent " + sent);
			peer.drain();
		});
		HTTPBackendRegistry.register(new HTTP2Backend());

		var completed:Null<Bytes> = null;
		var error:Null<String> = null;
		try {
			var http = new Http('http://127.0.0.1:${server.port}/endless', "GET", null, null, null, null, HttpVersion.HTTP_2, 10000);
			http.onComplete = data -> completed = data;
			http.onError = (message, ?data) -> error = message;
			http.load();
		} catch (e:Dynamic) {
			error = "threw " + Std.string(e);
		}
		Http.MAX_BODY_SIZE = saved;
		// What the server saw, before the pool hangs up: a close with its
		// frames unread would be a reset, which throws them away.
		var outcome:String = server.waitNote(10);
		H2ConnectionPool.closeAll();
		server.waitDone(10);

		Assert.isNull(completed, completed == null ? "" : 'a ${completed.length}-byte body past the 256 KB limit completed');
		Require.notNull(error);
		Assert.equals("Response body exceeded 262144 bytes", error);
		// The stream was reset, so the server stopped within a window of the
		// limit, and the connection was left to the requests after it.
		Require.notNull(outcome, "the server never finished");
		Assert.isTrue(StringTools.startsWith(outcome, "reset after "), outcome);
		var sentBeforeReset:Null<Int> = Std.parseInt(outcome.substr("reset after ".length));
		Assert.isTrue(sentBeforeReset != null && sentBeforeReset < 512 * 1024, outcome);
	}

	public function testAPingFloodTheServerNeverReadsTheAnswersToEndsAtTheTimeout():Void {
		// PING after PING, and the acknowledgements never read. The client
		// answered each from its reader with the connection's lock held, so
		// once the socket's buffers filled, the reader waited in that write
		// for good, holding the lock -- and the request, which needs the lock
		// to look at its stream, never reached its 1.5 s timeout.
		var threads:Int = H2ClientSession.liveThreads();
		var server = new H2ScriptServer(peer -> {
			peer.open();
			peer.readRequest();
			var ping = Bytes.ofHex("0102030405060708");
			var sent:Int = 0;
			try {
				while (sent < 4000000 && !peer.server.hungUp) {
					peer.write(H2FrameType.PING, 0, 0, ping);
					sent++;
				}
			} catch (_:Dynamic) {}
			peer.server.note("pinged " + sent);
		});
		HTTPBackendRegistry.register(new HTTP2Backend());

		var outcome:Null<String> = null;
		var took:Float = __loadWithin('http://127.0.0.1:${server.port}/flood', null, 1500, 10, value -> outcome = value);
		// Its threads are let go by the client alone: the server still has
		// not read a byte.
		H2ConnectionPool.closeAll();
		var settled:Bool = __threadsSettle(threads, 5);
		server.hangUp();
		server.waitDone(10);

		Require.notNull(outcome, "the request never ended");
		Assert.isFalse(StringTools.startsWith(outcome, "COMPLETED"), outcome);
		Assert.isTrue(took < 6, 'a 1.5 s request took ${took}s to end');
		Assert.isTrue(settled, 'the connection\'s threads were still running: ${H2ClientSession.liveThreads()} against $threads before');
	}

	public function testAnUploadAServerStopsReadingEndsAtTheTimeout():Void {
		// Every window opened as wide as it goes, and then nothing read: the
		// body went out in a write that waited on the socket for good, with
		// the connection's lock held, so the request's 1.5 s timeout -- the
		// longest its body may be kept from going out -- never came.
		var threads:Int = H2ClientSession.liveThreads();
		var server = __stopsReading();
		HTTPBackendRegistry.register(new HTTP2Backend());

		var outcome:Null<String> = null;
		var took:Float = __loadWithin('http://127.0.0.1:${server.port}/upload', Bytes.alloc(64 * 1024 * 1024), 1500, 10, value -> outcome = value);
		// The connection was given up with the request: its writer, held in
		// a write the server is not taking, is ended without the server's
		// help.
		var settled:Bool = __threadsSettle(threads, 5);
		server.hangUp();
		server.waitDone(10);

		Require.notNull(outcome, "the upload never ended");
		Assert.equals('Request to http://127.0.0.1:${server.port} timed out after 1.5s', outcome);
		Assert.isTrue(took < 6, 'a 1.5 s upload took ${took}s to end');
		Assert.isTrue(settled, 'the connection\'s threads were still running: ${H2ClientSession.liveThreads()} against $threads before');
	}

	public function testCancellingAnUploadAServerStopsReadingReturnsAtOnce():Void {
		// No timeout, so only a cancel ends it. The cancel needed the
		// connection's lock, which the upload held in its write: the
		// cancelling thread -- a runtime's, for URLLoader.close() -- waited
		// with it.
		var threads:Int = H2ClientSession.liveThreads();
		var server = __stopsReading();
		HTTPBackendRegistry.register(new HTTP2Backend());

		var outcome:Null<String> = null;
		var done = new Lock();
		var http = new Http('http://127.0.0.1:${server.port}/upload', "POST", null, null, "application/octet-stream", Bytes.alloc(64 * 1024 * 1024),
			HttpVersion.HTTP_2, 0);
		http.onComplete = data -> outcome = "COMPLETED";
		http.onError = (message, ?data) -> outcome = message;
		Thread.create(() -> {
			http.load();
			done.release();
		});

		// Obtained rather than assumed: the request is out, and a second on
		// lets the body fill what the socket holds.
		Assert.notNull(server.waitNote(10), "the request never arrived");
		System.sleep(1.0);
		var cancelled = new Lock();
		var cancelStarted:Float = haxe.Timer.stamp();
		Thread.create(() -> {
			http.cancelToken.cancel();
			cancelled.release();
		});
		var cancelReturned:Bool = cancelled.wait(5);
		var cancelTook:Float = haxe.Timer.stamp() - cancelStarted;
		var ended:Bool = done.wait(5);
		var took:Float = haxe.Timer.stamp() - cancelStarted;
		// And closing the connection, its writer still held, ends it.
		var closeStarted:Float = haxe.Timer.stamp();
		H2ConnectionPool.closeAll();
		var closeTook:Float = haxe.Timer.stamp() - closeStarted;
		var settled:Bool = __threadsSettle(threads, 5);
		server.hangUp();
		done.wait(10);
		server.waitDone(10);

		Assert.isTrue(cancelReturned, "cancel() did not return");
		Assert.isTrue(cancelTook < 1, 'cancel() took ${cancelTook}s to return');
		Assert.isTrue(ended, "the cancelled upload never ended");
		Assert.equals("Request cancelled", outcome);
		Assert.isTrue(took < 2, 'the cancelled upload took ${took}s to end');
		Assert.isTrue(closeTook < 1, 'closing the connection took ${closeTook}s');
		Assert.isTrue(settled, 'the connection\'s threads were still running: ${H2ClientSession.liveThreads()} against $threads before');
	}

	/** Waits up to `seconds` for the HTTP/2 client's threads to be no more than `count`. */
	private static function __threadsSettle(count:Int, seconds:Float):Bool {
		var until:Float = haxe.Timer.stamp() + seconds;
		while (H2ClientSession.liveThreads() > count) {
			if (haxe.Timer.stamp() >= until) {
				return false;
			}
			System.sleep(0.02);
		}
		return true;
	}

	public function testARequestWhoseHeadIsNotTakenEndsAtItsTimeout():Void {
		// A request with no body writes its own head when nothing else is
		// being written, and the session's writer watches that write. Here
		// the write is held -- as a peer that has stopped reading holds it --
		// and has to end at the request's 1 s timeout.
		var server = new H2RouteServer(_ -> {status: 200, chunks: ["ok"]});
		var held = __holdingSession(server.port);
		var outcome:Null<String> = null;
		var took:Float = __executeWithin(held.session, '127.0.0.1:${server.port}', 1.0, null, held.socket, 10, value -> outcome = value);
		var released:Bool = held.socket.released;
		held.session.close();
		server.stop();

		Require.notNull(outcome, "the request never ended");
		Assert.equals('Request to http://127.0.0.1:${server.port} timed out after 1s', outcome);
		Assert.isTrue(took < 4, 'a 1 s request whose head was held took ${took}s to end');
		Assert.isTrue(released, "the held write was never ended");
		Assert.isTrue(held.session.dead, "a connection that took nothing for the whole timeout was kept");
	}

	public function testCancellingARequestWhoseHeadIsNotTakenReturnsAtOnce():Void {
		// No timeout: the cancel is what ends it, and the write it is held
		// in has the close's grace, a second, from the cancel.
		var server = new H2RouteServer(_ -> {status: 200, chunks: ["ok"]});
		var held = __holdingSession(server.port);
		var token = new HTTPCancelToken();
		var outcome:Null<String> = null;
		var cancelTook:Float = -1;
		var took:Float = __executeWithin(held.session, '127.0.0.1:${server.port}', 0, token, held.socket, 10, value -> outcome = value, () -> {
			var started:Float = haxe.Timer.stamp();
			token.cancel();
			cancelTook = haxe.Timer.stamp() - started;
		});
		held.session.close();
		server.stop();

		Require.notNull(outcome, "the cancelled request never ended");
		Assert.equals("Request was cancelled", outcome);
		Assert.isTrue(cancelTook >= 0 && cancelTook < 0.5, 'cancel() took ${cancelTook}s to return');
		Assert.isTrue(took < 4, 'the cancelled request took ${took}s to end');
		Assert.isTrue(held.socket.released, "the held write was never ended");
	}

	/** A session over a `HoldingSocket` to `port`, its first request answered. */
	private static function __holdingSession(port:Int):{session:H2ClientSession, socket:HoldingSocket} {
		var socket = new HoldingSocket();
		socket.connect(new Host("127.0.0.1"), port);
		var session = new H2ClientSession('http://127.0.0.1:$port', socket, new H2Connection(socket.input, socket.output, new H2Settings()));
		// Answered, so the preface and everything else queued has gone.
		var warm = session.execute("GET", "http", '127.0.0.1:$port', "/warm", [], null, 5);
		Assert.isTrue(warm.endOfStream, "the first request was not answered");
		return {session: session, socket: socket};
	}

	/**
		Executes a GET on `session` on a thread of its own with its next
		write held, calling `whileHeld` once the write is being held, and
		waits `seconds` at most. Answers how long it took; `report` is given
		what it threw or returned, if it ended.
	**/
	private static function __executeWithin(session:H2ClientSession, authority:String, timeout:Float, token:Null<HTTPCancelToken>, socket:HoldingSocket,
			seconds:Float, report:String->Void, ?whileHeld:Void->Void):Float {
		var outcome:Null<String> = null;
		var done = new Lock();
		socket.hold();
		var started:Float = haxe.Timer.stamp();
		Thread.create(() -> {
			try {
				var stream = session.execute("GET", "http", authority, "/held", [], null, timeout, token);
				outcome = "returned " + (stream.endOfStream ? "the response" : "an unfinished stream");
			} catch (e:crossbyte.errors.Error) {
				outcome = e.message;
			} catch (e:Dynamic) {
				outcome = Std.string(e);
			}
			done.release();
		});
		if (whileHeld != null) {
			Assert.isTrue(socket.waitHeld(5), "the request's head was never written");
			whileHeld();
		}
		var ended:Bool = done.wait(seconds);
		var took:Float = haxe.Timer.stamp() - started;
		if (ended) {
			report(outcome);
		}
		return took;
	}

	/** A server that opens every window as wide as it goes, takes a request's head and then reads nothing more. */
	private static function __stopsReading():H2ScriptServer {
		return new H2ScriptServer(peer -> {
			// SETTINGS_INITIAL_WINDOW_SIZE 2^31 - 1, and the connection's
			// window opened to match.
			peer.open(Bytes.ofHex("00047fffffff"));
			peer.write(H2FrameType.WINDOW_UPDATE, 0, 0, Bytes.ofHex("7fff0000"));
			peer.server.note("request " + peer.readRequest());
			peer.hold(30);
		});
	}

	/**
		Loads `url` on a thread of its own -- a POST of `body` when given --
		waiting `seconds` at most for it, and answers how long it took.
		`report` is given the outcome, or nothing if there was none in time.
	**/
	private static function __loadWithin(url:String, body:Null<Bytes>, timeout:Int, seconds:Float, report:String->Void):Float {
		var outcome:Null<String> = null;
		var done = new Lock();
		var http = new Http(url, body != null ? "POST" : "GET", null, null, body != null ? "application/octet-stream" : null, body, HttpVersion.HTTP_2,
			timeout);
		http.onComplete = data -> outcome = "COMPLETED " + data.length;
		http.onError = (message, ?data) -> outcome = message;
		var started:Float = haxe.Timer.stamp();
		Thread.create(() -> {
			http.load();
			done.release();
		});
		var ended:Bool = done.wait(seconds);
		var took:Float = haxe.Timer.stamp() - started;
		if (ended) {
			report(outcome);
		}
		return took;
	}
}

/**
	A plain socket whose next write, once `hold()` is called, waits until the
	socket is shut down or closed -- a peer that has stopped reading, met as
	that write goes out -- and then fails, as such a write does once ended.
**/
private class HoldingSocket extends SysSocket {
	/** Set once a held write has been let go by a shutdown or a close. */
	public var released(get, never):Bool;

	private final __lock:Mutex = new Mutex();
	private final __let:Lock = new Lock();
	private var __armed:Bool = false;
	private var __holding:Bool = false;
	private var __released:Bool = false;
	private var __output:Null<haxe.io.Output> = null;

	public function new() {
		super();
	}

	override public function connect(host:Host, port:Int):Void {
		super.connect(host, port);
		__output = output;
		output = new HoldingOutput(output, this);
	}

	/** Holds the next write. */
	public function hold():Void {
		__lock.acquire();
		__armed = true;
		__lock.release();
	}

	/** Waits up to `seconds` for a write to be held. */
	public function waitHeld(seconds:Float):Bool {
		var until:Float = haxe.Timer.stamp() + seconds;
		while (haxe.Timer.stamp() < until) {
			__lock.acquire();
			var holding:Bool = __holding;
			__lock.release();
			if (holding) {
				return true;
			}
			System.sleep(0.01);
		}
		return false;
	}

	/** Called by the output before each write: false once a held write was let go. */
	public function beforeWrite():Bool {
		__lock.acquire();
		var hold:Bool = __armed;
		__armed = false;
		if (hold) {
			__holding = true;
		}
		__lock.release();
		if (!hold) {
			return true;
		}
		__let.wait();
		return false;
	}

	override public function shutdown(read:Bool, write:Bool):Void {
		__letGo();
		try super.shutdown(read, write) catch (_:Dynamic) {}
	}

	override public function close():Void {
		__letGo();
		// Its own output back first: natively the close casts the output to
		// the socket's own class and clears a field of it.
		if (__output != null) {
			output = __output;
		}
		super.close();
	}

	private function __letGo():Void {
		__lock.acquire();
		var holding:Bool = __holding && !__released;
		if (holding) {
			__released = true;
		}
		__lock.release();
		if (holding) {
			__let.release();
		}
	}

	private function get_released():Bool {
		__lock.acquire();
		var value:Bool = __released;
		__lock.release();
		return value;
	}
}

/** `HoldingSocket`'s output. */
private class HoldingOutput extends haxe.io.Output {
	private final __inner:haxe.io.Output;
	private final __socket:HoldingSocket;

	public function new(inner:haxe.io.Output, socket:HoldingSocket) {
		__inner = inner;
		__socket = socket;
	}

	override public function writeByte(c:Int):Void {
		if (!__socket.beforeWrite()) {
			throw haxe.io.Error.Custom("the write was ended under it");
		}
		__inner.writeByte(c);
	}

	override public function writeBytes(buffer:Bytes, position:Int, length:Int):Int {
		if (!__socket.beforeWrite()) {
			throw haxe.io.Error.Custom("the write was ended under it");
		}
		return __inner.writeBytes(buffer, position, length);
	}

	override public function flush():Void {
		__inner.flush();
	}
}

/** A frame as `H2ScriptPeer` read it. */
private typedef H2ScriptFrame = {
	var type:Int;
	var flags:Int;
	var id:Int;
	var payload:Bytes;
}

/**
 * Plays a server written as a script against one connection: what a hostile
 * server does, step by step, where the fixtures above each play one shape.
 * The script runs on a thread of its own once the client connects; whatever
 * it throws ends it, and the connection is closed after.
 */
private class H2ScriptServer {
	public var port(default, null):Int = 0;

	private final __listener:SysSocket = new SysSocket();
	private final __done:Lock = new Lock();
	private final __noted:Lock = new Lock();
	private final __lock:Mutex = new Mutex();
	private var __notes:Array<String> = [];
	private var __taken:Int = 0;

	public function new(script:H2ScriptPeer->Void) {
		__listener.bind(new Host("127.0.0.1"), 0);
		__listener.listen(1);
		port = __listener.host().port;
		Thread.create(() -> {
			var peer:SysSocket = null;
			try {
				peer = __listener.accept();
				peer.setTimeout(20.0);
				script(new H2ScriptPeer(peer, this));
			} catch (e:Dynamic) {
				note("ended: " + Std.string(e));
			}
			try if (peer != null) peer.close() catch (_:Dynamic) {}
			try __listener.close() catch (_:Dynamic) {}
			__done.release();
		});
	}

	/** Records something the script saw, for the test to look at. */
	public function note(text:String):Void {
		__lock.acquire();
		__notes.push(text);
		__lock.release();
		__noted.release();
	}

	/** The next note not yet taken, waiting up to `seconds` for it; null if none came. */
	public function waitNote(seconds:Float):Null<String> {
		if (!__noted.wait(seconds)) {
			return null;
		}
		__lock.acquire();
		var text:String = __notes[__taken++];
		__lock.release();
		return text;
	}

	public function notes():Array<String> {
		__lock.acquire();
		var copy:Array<String> = __notes.copy();
		__lock.release();
		return copy;
	}

	/** Waits for the script to end, which it does once the client hangs up. */
	public function waitDone(seconds:Float):Bool {
		return __done.wait(seconds);
	}

	/**
		Hangs up on the client now, whatever the script is doing -- a write
		the client is not reading included -- and ends a `hold`: the end of
		a case that, failing, would leave both ends waiting on each other.
	**/
	public function hangUp():Void {
		__lock.acquire();
		hungUp = true;
		var peer:Null<SysSocket> = peerSocket;
		__lock.release();
		if (peer != null) {
			try peer.shutdown(true, true) catch (_:Dynamic) {}
			try peer.close() catch (_:Dynamic) {}
		}
	}

	/** Set by `hangUp`. */
	public var hungUp(default, null):Bool = false;

	/** The connection the script was given, once there is one. */
	public var peerSocket:Null<SysSocket> = null;
}

/** The server's end of an `H2ScriptServer` connection. */
private class H2ScriptPeer {
	public final socket:SysSocket;
	public final server:H2ScriptServer;
	public final encoder:HpackEncoder = new HpackEncoder(H2Settings.DEFAULT_HEADER_TABLE_SIZE);
	public final decoder:HpackDecoder = new HpackDecoder(H2Settings.DEFAULT_HEADER_TABLE_SIZE);

	public function new(socket:SysSocket, server:H2ScriptServer) {
		this.socket = socket;
		this.server = server;
		server.peerSocket = socket;
	}

	/** Reads the client's preface, and answers with SETTINGS carrying `settings`. */
	public function open(?settings:Bytes):Void {
		var preface = Bytes.alloc(H2Connection.PREFACE.length);
		socket.input.readFullBytes(preface, 0, preface.length);
		write(H2FrameType.SETTINGS, 0, 0, settings != null ? settings : Bytes.alloc(0));
	}

	public function read():H2ScriptFrame {
		var header = Bytes.alloc(H2Frame.HEADER_SIZE);
		socket.input.readFullBytes(header, 0, H2Frame.HEADER_SIZE);
		var length:Int = H2Frame.lengthOf(header);
		var payload = Bytes.alloc(length);
		if (length > 0) {
			socket.input.readFullBytes(payload, 0, length);
		}
		return {
			type: header.get(3),
			flags: header.get(4),
			id: ((header.get(5) & 0x7f) << 24) | (header.get(6) << 16) | (header.get(7) << 8) | header.get(8),
			payload: payload
		};
	}

	/** Reads until a request's HEADERS, and answers its stream id. */
	public function readRequest():Int {
		while (true) {
			var frame = read();
			if (frame.type == (H2FrameType.HEADERS : Int)) {
				decoder.decode(frame.payload);
				return frame.id;
			}
		}
	}

	/** Reads until the client resets `id` or hangs up; true for the reset. */
	public function readUntilReset(id:Int):Bool {
		try {
			while (true) {
				var frame = read();
				if (frame.type == (H2FrameType.RST_STREAM : Int) && frame.id == id) {
					return true;
				}
			}
		} catch (_:Dynamic) {}
		return false;
	}

	/**
		Sends `length` bytes of body on `id` in 16 KB frames, each within the
		windows the client has opened, then ends the stream. Answers what it
		sent, or that negated if the client reset the stream first.
	**/
	public function sendBody(id:Int, length:Int):Int {
		var streamWindow:Int = H2Settings.DEFAULT_INITIAL_WINDOW_SIZE;
		var connectionWindow:Int = H2Settings.DEFAULT_INITIAL_WINDOW_SIZE;
		var chunk = Bytes.alloc(16384);
		var sent:Int = 0;
		while (sent < length) {
			while (streamWindow < chunk.length || connectionWindow < chunk.length) {
				var frame = read();
				if (frame.type == (H2FrameType.RST_STREAM : Int) && frame.id == id) {
					return -sent;
				}
				if (frame.type == (H2FrameType.WINDOW_UPDATE : Int)) {
					var increment:Int = ((frame.payload.get(0) & 0x7f) << 24) | (frame.payload.get(1) << 16) | (frame.payload.get(2) << 8)
						| frame.payload.get(3);
					if (frame.id == 0) {
						connectionWindow += increment;
					} else if (frame.id == id) {
						streamWindow += increment;
					}
				}
			}
			write(H2FrameType.DATA, 0, id, chunk);
			sent += chunk.length;
			streamWindow -= chunk.length;
			connectionWindow -= chunk.length;
		}
		write(H2FrameType.DATA, H2Flags.END_STREAM, id, Bytes.alloc(0));
		return sent;
	}

	/**
		Keeps the connection, reading nothing, until the test hangs up or
		`seconds` pass: a server that has stopped reading.
	**/
	public function hold(seconds:Float):Void {
		var until:Float = haxe.Timer.stamp() + seconds;
		while (!server.hungUp && haxe.Timer.stamp() < until) {
			System.sleep(0.05);
		}
	}

	/** Reads and drops everything until the client hangs up. */
	public function drain():Void {
		try {
			var scratch = Bytes.alloc(4096);
			while (socket.input.readBytes(scratch, 0, scratch.length) > 0) {}
		} catch (_:Dynamic) {}
	}

	public function headers(id:Int, fields:Array<HpackHeader>, flags:Int):Void {
		write(H2FrameType.HEADERS, H2Flags.END_HEADERS | flags, id, encoder.encode(fields));
	}

	public function write(type:H2FrameType, flags:Int, id:Int, payload:Bytes):Void {
		var out = new BytesBuffer();
		H2Frame.writeHeader(out, payload.length, type, flags, id);
		if (payload.length > 0) {
			out.addBytes(payload, 0, payload.length);
		}
		var bytes = out.getBytes();
		socket.output.writeFullBytes(bytes, 0, bytes.length);
		socket.output.flush();
	}
}

/** Error codes the test names without importing the whole enum surface. */
private class H2ErrorCodeShim {
	public static inline var INTERNAL_ERROR:Int = 0x2;
	public static inline var REFUSED_STREAM:Int = 0x7;
}

/**
 * Holds up an upload: reads `/upload` and grants no window, so the client can
 * send only the default 65535 bytes. Once those have arrived the client is
 * waiting on a WINDOW_UPDATE that never comes, and the fixture then:
 *
 * - `ANSWER`: answers in full and resets with NO_ERROR (RFC 9113 8.1);
 * - `RESET`: resets with CANCEL;
 * - `SILENT`: does nothing, and with `ping` sends a PING every 50 ms for six
 *   seconds, so the connection is busy while the upload is stuck.
 *
 * `/hang` is never answered. Any other path is answered at once with its own
 * path as the body.
 *
 * Accepts in a loop, so a client that gives up on the connection and dials
 * another is counted rather than left in the backlog. Records each
 * RST_STREAM the client sends, as `id:CODE`.
 */
private class H2EarlyResponseServer {
	public static inline var ANSWER:Int = 0;
	public static inline var RESET:Int = 1;
	public static inline var SILENT:Int = 2;

	public var port:Int = 0;

	private var __mode:Int;
	private var __ping:Bool;
	private var __ready:Lock = new Lock();
	private var __windowUsed:Lock = new Lock();
	private var __lock:Mutex = new Mutex();
	// Frames go out from the connection's thread and, with `ping`, from the
	// pinger's; a frame written half by each is garbage to the client.
	private var __writeLock:Mutex = new Mutex();
	private var __listener:SysSocket = null;
	private var __connections:Int = 0;
	private var __resets:Array<String> = [];
	private var __resetsBeforeSecond:String = null;

	public function new(mode:Int, ping:Bool = false) {
		__mode = mode;
		__ping = ping;
	}

	public function start():Void {
		Thread.create(() -> {
			var listener = new SysSocket();
			try {
				listener.bind(new Host("127.0.0.1"), 0);
				listener.listen(4);
				__listener = listener;
				port = listener.host().port;
				__ready.release();

				while (true) {
					var peer:SysSocket = listener.accept();
					__lock.acquire();
					__connections++;
					__lock.release();
					Thread.create(() -> {
						try {
							peer.setTimeout(10.0);
							__serve(peer);
						} catch (_:Dynamic) {}
						try peer.close() catch (_:Dynamic) {}
					});
				}
			} catch (_:Dynamic) {
				__ready.release();
			}
			try listener.close() catch (_:Dynamic) {}
		});

		if (!__ready.wait(5.0)) {
			Assert.fail("Timed out starting the early-response fixture");
		}
	}

	/** Stops accepting. Connections end when the client closes them. */
	public function stop():Void {
		try if (__listener != null) __listener.close() catch (_:Dynamic) {}
	}

	/** Waits until the upload has used all the window it was given. */
	public function waitWindowUsed(seconds:Float):Bool {
		return __windowUsed.wait(seconds);
	}

	public function connections():Int {
		__lock.acquire();
		var count:Int = __connections;
		__lock.release();
		return count;
	}

	/** The resets the client had sent when the second request arrived. */
	public function resetsBeforeSecond():String {
		__lock.acquire();
		var seen:String = __resetsBeforeSecond;
		__lock.release();
		return seen;
	}

	private function __serve(peer:SysSocket):Void {
		var preface = Bytes.alloc(H2Connection.PREFACE.length);
		peer.input.readFullBytes(preface, 0, preface.length);

		__writeFrame(peer, H2FrameType.SETTINGS, 0, 0, Bytes.alloc(0));

		var decoder = new HpackDecoder(H2Settings.DEFAULT_HEADER_TABLE_SIZE);
		var encoder = new HpackEncoder(H2Settings.DEFAULT_HEADER_TABLE_SIZE);
		var uploadId:Int = -1;
		var uploaded:Int = 0;
		var answered:Bool = false;

		while (true) {
			var header = Bytes.alloc(H2Frame.HEADER_SIZE);
			peer.input.readFullBytes(header, 0, H2Frame.HEADER_SIZE);

			var length = H2Frame.lengthOf(header);
			var payload = Bytes.alloc(length);
			if (length > 0) {
				peer.input.readFullBytes(payload, 0, length);
			}

			var type:Int = header.get(3);
			var id:Int = ((header.get(5) & 0x7f) << 24) | (header.get(6) << 16) | (header.get(7) << 8) | header.get(8);

			if (type == (H2FrameType.RST_STREAM : Int)) {
				var code:H2ErrorCode = payload.get(3);
				__lock.acquire();
				__resets.push('$id:${code.toString()}');
				__lock.release();
			}

			if (type == (H2FrameType.HEADERS : Int)) {
				var path = "/";
				for (field in decoder.decode(payload)) {
					if (field.name == ":path") {
						path = field.value;
					}
				}

				if (path == "/upload") {
					uploadId = id;
				} else if (path != "/hang") {
					__lock.acquire();
					__resetsBeforeSecond = __resets.join(",");
					__lock.release();
					__writeFrame(peer, H2FrameType.HEADERS, H2Flags.END_HEADERS, id, encoder.encode([new HpackHeader(":status", "200")]));
					__writeFrame(peer, H2FrameType.DATA, H2Flags.END_STREAM, id, Bytes.ofString(path));
				}
			}

			if (type == (H2FrameType.DATA : Int) && id == uploadId) {
				uploaded += length;
				// All the window there is: the client cannot send another byte
				// of the body, so it is waiting now.
				if (uploaded >= H2Settings.DEFAULT_INITIAL_WINDOW_SIZE && !answered) {
					answered = true;
					__windowUsed.release();

					if (__mode == ANSWER || __mode == RESET) {
						var reset = Bytes.alloc(4);
						if (__mode == RESET) {
							reset.set(3, (H2ErrorCode.CANCEL : Int));
						} else {
							__writeFrame(peer, H2FrameType.HEADERS, H2Flags.END_HEADERS, id, encoder.encode([new HpackHeader(":status", "200")]));
							__writeFrame(peer, H2FrameType.DATA, H2Flags.END_STREAM, id, Bytes.ofString("early answer"));
							reset.set(3, (H2ErrorCode.NO_ERROR : Int));
						}
						__writeFrame(peer, H2FrameType.RST_STREAM, 0, id, reset);
					} else if (__ping) {
						Thread.create(() -> {
							for (_ in 0...120) {
								System.sleep(0.05);
								try {
									__writeFrame(peer, H2FrameType.PING, 0, 0, Bytes.ofHex("0102030405060708"));
								} catch (_:Dynamic) {
									return;
								}
							}
						});
					}
				}
			}
		}
	}

	private function __writeFrame(peer:SysSocket, type:H2FrameType, flags:Int, streamId:Int, payload:Bytes):Void {
		var out = new BytesBuffer();
		H2Frame.writeHeader(out, payload.length, type, flags, streamId);
		if (payload.length > 0) {
			out.addBytes(payload, 0, payload.length);
		}
		var bytes = out.getBytes();
		__writeLock.acquire();
		try {
			peer.output.writeBytes(bytes, 0, bytes.length);
			peer.output.flush();
		} catch (e:Dynamic) {
			__writeLock.release();
			throw e;
		}
		__writeLock.release();
	}
}

/**
 * Starts a response and does not finish it: the headers and part of the
 * body, then either a RST_STREAM with `resetCode` or, with none, a close.
 *
 * The close has to be a FIN. Closing with the client's frames still unread
 * makes it a RST, which can discard the response before the client reads it
 * and turn the case into "no headers" -- so the fixture follows the partial
 * body with a PING and closes only once the acknowledgement is read. By
 * then it has drained everything the client sends unprompted, and the
 * client has processed the headers and body ahead of the PING.
 */
private class H2TruncatedResponseServer {
	public var port:Int = 0;

	private var __resetCode:Int;
	private var __ready:Lock = new Lock();
	private var __closedCleanly:Bool = false;
	private var __lock:Mutex = new Mutex();

	public function new(resetCode:Int = -1) {
		__resetCode = resetCode;
	}

	public function start():Void {
		Thread.create(() -> {
			var listener = new SysSocket();
			var peer:SysSocket = null;
			try {
				listener.bind(new Host("127.0.0.1"), 0);
				listener.listen(1);
				port = listener.host().port;
				__ready.release();

				peer = listener.accept();
				peer.setTimeout(10.0);
				__serve(peer);
			} catch (_:Dynamic) {
				__ready.release();
			}

			try if (peer != null) peer.close() catch (_:Dynamic) {}
			try listener.close() catch (_:Dynamic) {}
		});

		if (!__ready.wait(5.0)) {
			Assert.fail("Timed out starting the truncated-response fixture");
		}
	}

	/** Whether the fixture drained the client before hanging up on it. */
	public function closedCleanly():Bool {
		__lock.acquire();
		var clean:Bool = __closedCleanly;
		__lock.release();
		return clean;
	}

	private function __serve(peer:SysSocket):Void {
		var preface = Bytes.alloc(H2Connection.PREFACE.length);
		peer.input.readFullBytes(preface, 0, preface.length);

		__writeFrame(peer, H2FrameType.SETTINGS, 0, 0, Bytes.alloc(0));

		var streamId:Int = -1;
		while (streamId < 0) {
			var frame = __readFrame(peer);
			if (frame.type == (H2FrameType.HEADERS : Int)) {
				streamId = frame.id;
			}
		}

		var encoder = new HpackEncoder(H2Settings.DEFAULT_HEADER_TABLE_SIZE);
		__writeFrame(peer, H2FrameType.HEADERS, H2Flags.END_HEADERS, streamId, encoder.encode([new HpackHeader(":status", "200")]));
		__writeFrame(peer, H2FrameType.DATA, 0, streamId, Bytes.ofString("the first half"));

		if (__resetCode >= 0) {
			var payload = Bytes.alloc(4);
			payload.set(3, __resetCode);
			__writeFrame(peer, H2FrameType.RST_STREAM, 0, streamId, payload);

			// Held open until the client hangs up: the connection outlives a
			// reset stream, and closing it here would be a second failure.
			while (true) {
				__readFrame(peer);
			}
		}

		__writeFrame(peer, H2FrameType.PING, 0, 0, Bytes.ofHex("0102030405060708"));
		while (true) {
			var frame = __readFrame(peer);
			if (frame.type == (H2FrameType.PING : Int) && (frame.flags & H2Flags.ACK) != 0) {
				break;
			}
		}

		__lock.acquire();
		__closedCleanly = true;
		__lock.release();
		peer.close();
	}

	private function __readFrame(peer:SysSocket):{type:Int, flags:Int, id:Int} {
		var header = Bytes.alloc(H2Frame.HEADER_SIZE);
		peer.input.readFullBytes(header, 0, H2Frame.HEADER_SIZE);

		var length = H2Frame.lengthOf(header);
		if (length > 0) {
			peer.input.readFullBytes(Bytes.alloc(length), 0, length);
		}

		return {
			type: header.get(3),
			flags: header.get(4),
			id: ((header.get(5) & 0x7f) << 24) | (header.get(6) << 16) | (header.get(7) << 8) | header.get(8)
		};
	}

	private function __writeFrame(peer:SysSocket, type:H2FrameType, flags:Int, streamId:Int, payload:Bytes):Void {
		var out = new BytesBuffer();
		H2Frame.writeHeader(out, payload.length, type, flags, streamId);
		if (payload.length > 0) {
			out.addBytes(payload, 0, payload.length);
		}
		var bytes = out.getBytes();
		peer.output.writeBytes(bytes, 0, bytes.length);
		peer.output.flush();
	}
}

/**
 * A scripted h2c server on a background thread.
 *
 * Reads the client preface and frames, then plays back a canned response. It
 * decodes the request header block for real, so the assertions above are
 * against what actually went over the socket rather than what the client
 * believes it sent.
 */
/**
 * Accepts every connection and never says a word on any of them, until
 * closed: a server stalled after TCP, as far as a client can tell.
 */
private class SilentServer {
	public var port(default, null):Int = 0;
	public var accepted(get, never):Int;

	private final __listener:SysSocket = new SysSocket();
	private final __held:Array<SysSocket> = [];
	private final __lock:Mutex = new Mutex();
	private final __stopped:Lock = new Lock();
	private var __accepted:Int = 0;
	private var __closing:Bool = false;

	public function new() {
		__listener.bind(new Host("127.0.0.1"), 0);
		__listener.listen(8);
		port = __listener.host().port;
		Thread.create(__accept);
	}

	private function get_accepted():Int {
		__lock.acquire();
		var count:Int = __accepted;
		__lock.release();
		return count;
	}

	/** Closes the listener and everything it accepted, which ends any wait on them. */
	public function close():Void {
		__lock.acquire();
		__closing = true;
		__lock.release();
		__stopped.wait(2.0);
		__lock.acquire();
		var held:Array<SysSocket> = __held.copy();
		__lock.release();
		for (socket in held) {
			try {
				socket.close();
			} catch (_:Dynamic) {}
		}
		try {
			__listener.close();
		} catch (_:Dynamic) {}
	}

	private function __accept():Void {
		while (true) {
			__lock.acquire();
			var closing:Bool = __closing;
			__lock.release();
			if (closing) {
				break;
			}
			try {
				if (SysSocket.select([__listener], null, null, 0.05).read.length == 0) {
					continue;
				}
				var peer:SysSocket = __listener.accept();
				__lock.acquire();
				__held.push(peer);
				__accepted++;
				__lock.release();
			} catch (_:Dynamic) {
				break;
			}
		}
		__stopped.release();
	}
}

private class H2cServer {
	public var port:Int = 0;
	public var error:Dynamic = null;

	/** Where the fixture listens; set before `start`. */
	public var bindAddress:String = "127.0.0.1";

	/** The payload of the client's SETTINGS, once it has arrived. */
	public var clientSettings:Null<Bytes> = null;

	/** The value the client's SETTINGS gave `id`, or -1 when it gave none. */
	public function clientSetting(id:Int):Int {
		var payload:Null<Bytes> = clientSettings;
		if (payload == null) {
			return -1;
		}
		var found:Int = -1;
		var offset:Int = 0;
		while (offset + 6 <= payload.length) {
			if (((payload.get(offset) << 8) | payload.get(offset + 1)) == id) {
				found = (payload.get(offset + 2) << 24) | (payload.get(offset + 3) << 16) | (payload.get(offset + 4) << 8) | payload.get(offset + 5);
			}
			offset += 6;
		}
		return found;
	}
	public var requestHeaders:Map<String, String> = new Map();
	public var requestBody:String = "";
	public var decoderTableNames:Array<String> = [];

	private var __ready:Lock = new Lock();
	private var __done:Lock = new Lock();
	private var __responseHeaders:Array<HpackHeader> = null;
	private var __responseBody:String = "";
	private var __resetCode:Int = -1;
	private var __http1:Bool = false;

	public function new() {}

	public function respond(headers:Array<HpackHeader>, body:String):Void {
		__responseHeaders = headers;
		__responseBody = body;
	}

	/** As `respond`, with a body that is not text. */
	public function respondBytes(headers:Array<HpackHeader>, body:Bytes):Void {
		__responseHeaders = headers;
		__responseBytes = body;
	}

	private var __responseBytes:Bytes = null;

	public function reset(code:Int):Void {
		__resetCode = code;
	}

	public function replyWithHttp1():Void {
		__http1 = true;
	}

	public function start():Void {
		Thread.create(() -> {
			var listener = new SysSocket();
			var peer:SysSocket = null;
			try {
				listener.bind(new Host(bindAddress), 0);
				listener.listen(1);
				port = listener.host().port;
				__ready.release();

				peer = listener.accept();
				// Shorter than the __done wait below on purpose: a drain that
				// blocks has to unblock and let the thread finish before the
				// test gives up on it, or a slow target reports a hung fixture
				// for what is really just an unread socket.
				peer.setTimeout(2.0);
				__serve(peer);
			} catch (e:Dynamic) {
				error = e;
				__ready.release();
			}

			try {
				if (peer != null) {
					peer.close();
				}
			} catch (_:Dynamic) {}
			try {
				listener.close();
			} catch (_:Dynamic) {}

			__done.release();
		});

		if (!__ready.wait(5.0)) {
			Assert.fail("Timed out starting the h2c fixture server");
		}
		if (error != null) {
			Assert.fail("h2c fixture server failed to start: " + error);
		}
	}

	public function waitDone():Void {
		// The client pools its connection now, so it never hangs up on its
		// own and this fixture's read loop would wait out its socket timeout.
		// Releasing the pool is what ends the conversation -- which is also
		// the honest shape of the change: a connection outliving one request
		// is the feature.
		H2ConnectionPool.closeAll();

		if (!__done.wait(5.0)) {
			Assert.fail("Timed out waiting for the h2c fixture server");
		}
		if (error != null) {
			Assert.fail("h2c fixture server failed: " + error);
		}
	}

	private function __serve(peer:SysSocket):Void {
		// §3.4: the client sends this before any frame.
		var preface = Bytes.alloc(H2Connection.PREFACE.length);
		peer.input.readFullBytes(preface, 0, preface.length);
		if (preface.toString() != H2Connection.PREFACE) {
			error = "Client did not send the connection preface";
			return;
		}

		if (__http1) {
			// Read what the client has already sent -- its SETTINGS and its
			// HEADERS -- before replying. Closing with those still unread makes
			// the close a RST, and a RST discards the peer's receive buffer, so
			// the client loses the very bytes it is meant to choke on and fails
			// with a socket error instead. Draining afterwards does not help:
			// the reset then lands on this thread, where eval surfaces it as a
			// native error no catch block sees.
			__skipFrame(peer);
			__skipFrame(peer);

			peer.output.writeString("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n");
			peer.output.flush();
			return;
		}

		__writeFrame(peer, H2FrameType.SETTINGS, 0, 0, Bytes.alloc(0));

		var decoder = new HpackDecoder(H2Settings.DEFAULT_HEADER_TABLE_SIZE);
		var encoder = new HpackEncoder(H2Settings.DEFAULT_HEADER_TABLE_SIZE);
		var streamId:Int = 0;
		var sawHeaders:Bool = false;
		var bodyIn = new BytesBuffer();
		var bodyLength:Int = 0;

		while (true) {
			var header = Bytes.alloc(H2Frame.HEADER_SIZE);
			peer.input.readFullBytes(header, 0, H2Frame.HEADER_SIZE);

			var length:Int = H2Frame.lengthOf(header);
			var payload = Bytes.alloc(length);
			if (length > 0) {
				peer.input.readFullBytes(payload, 0, length);
			}

			var type:Int = header.get(3);
			var flags:Int = header.get(4);
			var id:Int = ((header.get(5) & 0x7f) << 24) | (header.get(6) << 16) | (header.get(7) << 8) | header.get(8);

			if (type == (H2FrameType.HEADERS : Int)) {
				streamId = id;
				sawHeaders = true;
				for (field in decoder.decode(payload)) {
					requestHeaders.set(field.name, field.value);
				}
				decoderTableNames = [];
				for (slot in 0...decoder.tableLength) {
					decoderTableNames.push(decoder.dynamicEntry(slot).name);
				}
				if ((flags & H2Flags.END_STREAM) != 0) {
					break;
				}
			} else if (type == (H2FrameType.DATA : Int)) {
				bodyIn.addBytes(payload, 0, payload.length);
				bodyLength += payload.length;
				if ((flags & H2Flags.END_STREAM) != 0) {
					break;
				}
			} else if (type == (H2FrameType.SETTINGS : Int) && (flags & H2Flags.ACK) == 0) {
				clientSettings = payload;
			}
			// SETTINGS ACK and WINDOW_UPDATE are read and ignored.
		}

		if (bodyLength > 0) {
			requestBody = bodyIn.getBytes().toString();
		}

		if (!sawHeaders) {
			error = "Client sent no HEADERS frame";
			return;
		}

		if (__resetCode >= 0) {
			var reset = Bytes.alloc(4);
			reset.set(3, __resetCode);
			__writeFrame(peer, H2FrameType.RST_STREAM, 0, streamId, reset);
			__drain(peer);
			return;
		}

		var block:Bytes = encoder.encode(__responseHeaders);
		var payload:Bytes = __responseBytes != null ? __responseBytes : Bytes.ofString(__responseBody);
		var hasBody:Bool = payload.length > 0;
		__writeFrame(peer, H2FrameType.HEADERS, H2Flags.END_HEADERS | (hasBody ? 0 : H2Flags.END_STREAM), streamId, block);

		if (hasBody) {
			__writeFrame(peer, H2FrameType.DATA, H2Flags.END_STREAM, streamId, payload);
		}

		__drain(peer);
	}

	/** Reads one frame and discards it, header and payload. */
	private function __skipFrame(peer:SysSocket):Void {
		var header = Bytes.alloc(H2Frame.HEADER_SIZE);
		peer.input.readFullBytes(header, 0, H2Frame.HEADER_SIZE);

		var length:Int = H2Frame.lengthOf(header);
		if (length > 0) {
			peer.input.readFullBytes(Bytes.alloc(length), 0, length);
		}
	}

	/**
	 * Reads until the client hangs up, before closing.
	 *
	 * The client's SETTINGS ACK arrives after we have already stopped reading,
	 * so it is still sitting in the receive buffer at this point. Closing a
	 * socket with unread data makes Windows send RST rather than FIN, and the
	 * client then sees the connection reset instead of the response it was
	 * midway through parsing.
	 */
	private function __drain(peer:SysSocket):Void {
		try {
			var scratch = Bytes.alloc(256);
			while (peer.input.readBytes(scratch, 0, scratch.length) > 0) {}
		} catch (_:Dynamic) {}
	}

	private function __writeFrame(peer:SysSocket, type:H2FrameType, flags:Int, streamId:Int, payload:Bytes):Void {
		var out = new BytesBuffer();
		H2Frame.writeHeader(out, payload.length, type, flags, streamId);
		if (payload.length > 0) {
			out.addBytes(payload, 0, payload.length);
		}
		var bytes:Bytes = out.getBytes();
		peer.output.writeBytes(bytes, 0, bytes.length);
		peer.output.flush();
	}
}

/**
 * A server that keeps one connection and serves several streams on it.
 *
 * `holdUntilAll` is what makes concurrency observable: with it set, nothing is
 * answered until every expected request has arrived, so a client that issues
 * them one at a time deadlocks instead of quietly passing.
 */
private class H2MuxServer {
	public var port:Int = 0;
	public var error:Dynamic = null;
	public var connections:Int = 0;
	public var streamIds:Array<Int> = [];
	// Also written by the connection thread and spun on by the test's, so it
	// goes through the same lock. A bool cannot tear, but nothing obliges one
	// thread to ever observe the other's write, and a spin loop with no
	// barrier is exactly where that shows up as a hang rather than a failure.
	private var __sawBothBeforeResponding:Bool = false;
	// Written by the connection thread, read by the test's. Both go through
	// `__resetLock` and `sawReset`: an unguarded `push` here against an
	// `indexOf` there is not just a torn read, it is a push that may reallocate
	// the array while the other thread walks it. The visible symptom was
	// milder and more confusing -- the reset arrived and was recorded, and the
	// polling thread spun out its whole ten-second deadline without ever seeing
	// it, reporting a reset the client had definitely sent as one the server
	// never got.
	private var __resetStreamIds:Array<Int> = [];

	// Which stream carried which request. Stream ids are assigned in the order
	// the client opens them, and a test that opens two requests on two threads
	// does not decide that order -- so a case asking "was the cancelled stream
	// reset?" has to look the id up by path rather than assume it.
	private var __streamPaths:Map<String, Int> = new Map();

	private var __resetLock:Mutex = new Mutex();

	private var __ready:Lock = new Lock();
	private var __closed:Lock = new Lock();
	private var __peer:SysSocket = null;
	private var __gate:Lock = new Lock();
	private var __gated:Bool = false;
	private var __listener:SysSocket = null;
	private var __expected:Int;
	private var __holdUntilAll:Bool;
	private var __keepOpen:Bool;

	public function new(expected:Int, holdUntilAll:Bool = false, keepOpen:Bool = true, gated:Bool = false) {
		__gated = gated;
		__expected = expected;
		__holdUntilAll = holdUntilAll;
		__keepOpen = keepOpen;
	}

	public function start():Void {
		Thread.create(() -> {
			var listener = new SysSocket();
			var peer:SysSocket = null;
			try {
				__listener = listener;
				listener.bind(new Host("127.0.0.1"), 0);
				listener.listen(4);
				port = listener.host().port;
				__ready.release();

				peer = listener.accept();
				__peer = peer;
				connections++;
				peer.setTimeout(10.0);
				__serve(peer);
			} catch (e:Dynamic) {
				error = e;
				__ready.release();
			}

			try if (peer != null) peer.close() catch (_:Dynamic) {}
			try listener.close() catch (_:Dynamic) {}
			__closed.release();
		});

		if (!__ready.wait(5.0)) {
			Assert.fail("Timed out starting the multiplexing fixture");
		}
	}

	public function waitClosed():Void {
		__closed.wait(5.0);
	}

	/**
	 * Drops the connection and stops listening.
	 *
	 * Called only once the fixture is draining, so the client's SETTINGS ACK
	 * has already been consumed and this is a clean FIN. Closing with that
	 * still unread would be a RST, which discards the response the client has
	 * not finished parsing -- and turns a test about pool liveness into a
	 * coin flip about timing.
	 */
	public function hangUp():Void {
		try if (__peer != null) __peer.close() catch (_:Dynamic) {}
		try if (__listener != null) __listener.close() catch (_:Dynamic) {}
	}

	private function __serve(peer:SysSocket):Void {
		var preface = Bytes.alloc(H2Connection.PREFACE.length);
		peer.input.readFullBytes(preface, 0, preface.length);

		__writeFrame(peer, H2FrameType.SETTINGS, 0, 0, Bytes.alloc(0));

		var decoder = new HpackDecoder(H2Settings.DEFAULT_HEADER_TABLE_SIZE);
		var encoder = new HpackEncoder(H2Settings.DEFAULT_HEADER_TABLE_SIZE);
		var pending:Array<{id:Int, path:String}> = [];

		while (pending.length < __expected) {
			var header = Bytes.alloc(H2Frame.HEADER_SIZE);
			peer.input.readFullBytes(header, 0, H2Frame.HEADER_SIZE);

			var length = H2Frame.lengthOf(header);
			var payload = Bytes.alloc(length);
			if (length > 0) {
				peer.input.readFullBytes(payload, 0, length);
			}

			var type = header.get(3);
			var id = ((header.get(5) & 0x7f) << 24) | (header.get(6) << 16) | (header.get(7) << 8) | header.get(8);

			if (type == (H2FrameType.RST_STREAM : Int)) {
				__recordReset(id);
			}

			if (type == (H2FrameType.HEADERS : Int)) {
				var path = "/";
				for (field in decoder.decode(payload)) {
					if (field.name == ":path") {
						path = field.value;
					}
				}
				streamIds.push(id);
				__resetLock.acquire();
				__streamPaths.set(path, id);
				__resetLock.release();
				pending.push({id: id, path: path});

				if (!__holdUntilAll) {
					__respond(peer, encoder, id, path);
				}
			}
		}

		if (__holdUntilAll) {
			__resetLock.acquire();
			__sawBothBeforeResponding = true;
			__resetLock.release();

			// Held here until the test says go. Without it the flag above and
			// the responses below are the same instant, so a test trying to
			// cancel an in-flight request always loses the race and the case
			// passes for the wrong reason.
			if (__gated) {
				__gate.wait(10.0);
			}
			// Answered newest first, so a client that assumed responses come
			// back in request order would fail here too.
			var index = pending.length - 1;
			while (index >= 0) {
				__respond(peer, encoder, pending[index].id, pending[index].path);
				index--;
			}
		}

		if (__keepOpen) {
			// Held open until the client hangs up. A pooled client keeps the
			// connection by design, so closing here would close with its
			// SETTINGS ACK still unread -- and a close on unread data is a RST
			// that discards the responses the client has not yet parsed.
			//
			// Read as frames rather than as bytes so a RST_STREAM arriving
			// after the responses is still recorded: cancellation is only
			// observable from this side as that frame.
			try {
				while (true) {
					var header = Bytes.alloc(H2Frame.HEADER_SIZE);
					peer.input.readFullBytes(header, 0, H2Frame.HEADER_SIZE);

					var length = H2Frame.lengthOf(header);
					if (length > 0) {
						peer.input.readFullBytes(Bytes.alloc(length), 0, length);
					}

					if (header.get(3) == (H2FrameType.RST_STREAM : Int)) {
						__recordReset(((header.get(5) & 0x7f) << 24) | (header.get(6) << 16) | (header.get(7) << 8) | header.get(8));
					}
				}
			} catch (_:Dynamic) {}
		}
	}

	/** Whether both requests reached the server before either was answered. **/
	public function sawBothArrive():Bool {
		__resetLock.acquire();
		var seen:Bool = __sawBothBeforeResponding;
		__resetLock.release();
		return seen;
	}

	/** Records a reset seen on the connection thread. **/
	private function __recordReset(id:Int):Void {
		__resetLock.acquire();
		__resetStreamIds.push(id);
		__resetLock.release();
	}

	/**
		The id of the stream that carried `path`, or -1 if it has not arrived.

		Safe to ask from another thread.
	**/
	public function streamIdFor(path:String):Int {
		__resetLock.acquire();
		var id:Int = __streamPaths.exists(path) ? __streamPaths.get(path) : -1;
		__resetLock.release();
		return id;
	}

	/** Whether the peer reset this stream. Safe to ask from another thread. **/
	public function sawReset(id:Int):Bool {
		__resetLock.acquire();
		var seen:Bool = __resetStreamIds.indexOf(id) >= 0;
		__resetLock.release();
		return seen;
	}

	/** Lets a gated fixture send its responses. */
	public function releaseResponses():Void {
		__gate.release();
	}

	private function __respond(peer:SysSocket, encoder:HpackEncoder, streamId:Int, path:String):Void {
		var block = encoder.encode([new HpackHeader(":status", "200")]);
		__writeFrame(peer, H2FrameType.HEADERS, H2Flags.END_HEADERS, streamId, block);
		__writeFrame(peer, H2FrameType.DATA, H2Flags.END_STREAM, streamId, Bytes.ofString(path));
	}

	private function __writeFrame(peer:SysSocket, type:H2FrameType, flags:Int, streamId:Int, payload:Bytes):Void {
		var out = new BytesBuffer();
		H2Frame.writeHeader(out, payload.length, type, flags, streamId);
		if (payload.length > 0) {
			out.addBytes(payload, 0, payload.length);
		}
		var bytes = out.getBytes();
		peer.output.writeBytes(bytes, 0, bytes.length);
		peer.output.flush();
	}
}

/**
 * Answers one request in two halves: the headers, then -- only once the test
 * says so -- the body. Between them it waits until the client has processed
 * the headers, which it learns from the acknowledgement of a PING sent right
 * behind them.
 */
private class H2HeadersFirstServer {
	public var port:Int = 0;

	private var __ready:Lock = new Lock();
	private var __headersProcessed:Lock = new Lock();
	private var __gate:Lock = new Lock();
	private var __reset:Lock = new Lock();

	public function new() {}

	public function start():Void {
		Thread.create(() -> {
			var listener = new SysSocket();
			var peer:SysSocket = null;
			try {
				listener.bind(new Host("127.0.0.1"), 0);
				listener.listen(1);
				port = listener.host().port;
				__ready.release();

				peer = listener.accept();
				peer.setTimeout(10.0);
				__serve(peer);
			} catch (_:Dynamic) {
				__ready.release();
			}

			try if (peer != null) peer.close() catch (_:Dynamic) {}
			try listener.close() catch (_:Dynamic) {}
		});

		if (!__ready.wait(5.0)) {
			Assert.fail("Timed out starting the headers-first fixture");
		}
	}

	public function waitHeadersProcessed(seconds:Float):Bool {
		return __headersProcessed.wait(seconds);
	}

	public function releaseBody():Void {
		__gate.release();
	}

	public function waitSawReset(seconds:Float):Bool {
		return __reset.wait(seconds);
	}

	private function __serve(peer:SysSocket):Void {
		var preface = Bytes.alloc(H2Connection.PREFACE.length);
		peer.input.readFullBytes(preface, 0, preface.length);

		__writeFrame(peer, H2FrameType.SETTINGS, 0, 0, Bytes.alloc(0));

		var streamId:Int = -1;
		while (streamId < 0) {
			var frame = __readFrame(peer);
			if (frame.type == (H2FrameType.HEADERS : Int)) {
				streamId = frame.id;
			}
		}

		var encoder = new HpackEncoder(H2Settings.DEFAULT_HEADER_TABLE_SIZE);
		__writeFrame(peer, H2FrameType.HEADERS, H2Flags.END_HEADERS, streamId, encoder.encode([new HpackHeader(":status", "200")]));
		__writeFrame(peer, H2FrameType.PING, 0, 0, Bytes.ofHex("0102030405060708"));

		while (true) {
			var frame = __readFrame(peer);
			if (frame.type == (H2FrameType.PING : Int) && (frame.flags & H2Flags.ACK) != 0) {
				break;
			}
		}
		__headersProcessed.release();

		__gate.wait(10.0);
		__writeFrame(peer, H2FrameType.DATA, H2Flags.END_STREAM, streamId, Bytes.ofString("sent after the cancel"));

		// Read until the client hangs up, so the reset is seen whenever it
		// lands relative to the body.
		while (true) {
			var frame = __readFrame(peer);
			if (frame.type == (H2FrameType.RST_STREAM : Int) && frame.id == streamId) {
				__reset.release();
			}
		}
	}

	private function __readFrame(peer:SysSocket):{type:Int, flags:Int, id:Int} {
		var header = Bytes.alloc(H2Frame.HEADER_SIZE);
		peer.input.readFullBytes(header, 0, H2Frame.HEADER_SIZE);

		var length = H2Frame.lengthOf(header);
		if (length > 0) {
			peer.input.readFullBytes(Bytes.alloc(length), 0, length);
		}

		return {
			type: header.get(3),
			flags: header.get(4),
			id: ((header.get(5) & 0x7f) << 24) | (header.get(6) << 16) | (header.get(7) << 8) | header.get(8)
		};
	}

	private function __writeFrame(peer:SysSocket, type:H2FrameType, flags:Int, streamId:Int, payload:Bytes):Void {
		var out = new BytesBuffer();
		H2Frame.writeHeader(out, payload.length, type, flags, streamId);
		if (payload.length > 0) {
			out.addBytes(payload, 0, payload.length);
		}
		var bytes = out.getBytes();
		peer.output.writeBytes(bytes, 0, bytes.length);
		peer.output.flush();
	}
}

/**
 * Two connections, one after the other. The first request is answered after
 * a GOAWAY that lets it finish, so the connection it came on takes no more;
 * the second has to arrive on a connection of its own.
 */
private class H2GoAwayServer {
	public var port:Int = 0;
	public var connections:Int = 0;
	public var paths:Array<String> = [];

	private var __ready:Lock = new Lock();
	private var __served:Lock = new Lock();
	private var __done:Mutex = new Mutex();

	public function new() {}

	public function start():Void {
		Thread.create(() -> {
			var listener = new SysSocket();
			var first:SysSocket = null;
			var second:SysSocket = null;
			try {
				listener.bind(new Host("127.0.0.1"), 0);
				listener.listen(4);
				port = listener.host().port;
				__ready.release();

				first = listener.accept();
				first.setTimeout(10.0);
				__done.acquire();
				connections++;
				__done.release();
				var path = __serveOne(first, true);
				__done.acquire();
				paths.push(path);
				__done.release();

				second = listener.accept();
				second.setTimeout(10.0);
				__done.acquire();
				connections++;
				__done.release();
				path = __serveOne(second, false);
				__done.acquire();
				paths.push(path);
				__done.release();
			} catch (e:Dynamic) {
				__ready.release();
			}
			__served.release();

			// Held open until the client hangs up, as a pooled client keeps a
			// connection by design.
			try {
				if (second != null) {
					while (true) {
						second.input.readByte();
					}
				}
			} catch (_:Dynamic) {}
			try if (first != null) first.close() catch (_:Dynamic) {}
			try if (second != null) second.close() catch (_:Dynamic) {}
			try listener.close() catch (_:Dynamic) {}
		});

		if (!__ready.wait(5.0)) {
			Assert.fail("Timed out starting the GOAWAY fixture");
		}
	}

	public function waitServed():Void {
		__served.wait(10.0);
	}

	private function __serveOne(peer:SysSocket, goAwayFirst:Bool):String {
		var preface = Bytes.alloc(H2Connection.PREFACE.length);
		peer.input.readFullBytes(preface, 0, preface.length);
		__writeFrame(peer, H2FrameType.SETTINGS, 0, 0, Bytes.alloc(0));

		var decoder = new HpackDecoder(H2Settings.DEFAULT_HEADER_TABLE_SIZE);
		while (true) {
			var header = Bytes.alloc(H2Frame.HEADER_SIZE);
			peer.input.readFullBytes(header, 0, H2Frame.HEADER_SIZE);
			var length = H2Frame.lengthOf(header);
			var payload = Bytes.alloc(length);
			if (length > 0) {
				peer.input.readFullBytes(payload, 0, length);
			}
			if (header.get(3) != (H2FrameType.HEADERS : Int)) {
				continue;
			}

			var id = ((header.get(5) & 0x7f) << 24) | (header.get(6) << 16) | (header.get(7) << 8) | header.get(8);
			var path = "/";
			for (field in decoder.decode(payload)) {
				if (field.name == ":path") {
					path = field.value;
				}
			}

			if (goAwayFirst) {
				// Before the answer, so the client has read it by the time the
				// request it lets finish comes back.
				var goAway = Bytes.alloc(8);
				goAway.set(0, (id >>> 24) & 0x7f);
				goAway.set(1, (id >>> 16) & 0xff);
				goAway.set(2, (id >>> 8) & 0xff);
				goAway.set(3, id & 0xff);
				__writeFrame(peer, H2FrameType.GOAWAY, 0, 0, goAway);
			}

			var block = new HpackEncoder(H2Settings.DEFAULT_HEADER_TABLE_SIZE).encode([new HpackHeader(":status", "200")]);
			__writeFrame(peer, H2FrameType.HEADERS, H2Flags.END_HEADERS, id, block);
			__writeFrame(peer, H2FrameType.DATA, H2Flags.END_STREAM, id, Bytes.ofString(path));
			return path;
		}
	}

	private function __writeFrame(peer:SysSocket, type:H2FrameType, flags:Int, streamId:Int, payload:Bytes):Void {
		var out = new BytesBuffer();
		H2Frame.writeHeader(out, payload.length, type, flags, streamId);
		if (payload.length > 0) {
			out.addBytes(payload, 0, payload.length);
		}
		var bytes = out.getBytes();
		peer.output.writeBytes(bytes, 0, bytes.length);
		peer.output.flush();
	}
}

/** A request as `H2RouteServer` received it. */
private typedef H2RouteRequest = {
	var method:String;
	var path:String;
	var headers:Map<String, String>;
	var body:String;
}

/**
 * How `H2RouteServer` answers a request: its status and fields, then its body
 * in `chunks`, waiting `gap` seconds before each. With `hold` the stream is
 * left open after the last chunk rather than ended.
 */
private typedef H2RouteAnswer = {
	var status:Int;
	@:optional var fields:Array<HpackHeader>;
	@:optional var chunks:Array<String>;
	@:optional var gap:Float;
	@:optional var hold:Bool;
}

/**
 * Answers requests by what `route` makes of them, on every connection it is
 * given and for as long as each is kept: what a redirect chain needs, where a
 * hop to the same origin rides the connection the last one came on and a hop
 * to another origin dials another server.
 *
 * Accepts until `stop()`, thirty seconds at most, polling so no thread is left
 * in accept() on a target where closing a listener does not wake it.
 */
private class H2RouteServer {
	public var port(default, null):Int = 0;

	private final __route:H2RouteRequest->H2RouteAnswer;
	private final __listener:SysSocket = new SysSocket();
	private final __lock:Mutex = new Mutex();
	private final __requests:Array<H2RouteRequest> = [];
	private var __connections:Int = 0;
	private var __stopped:Bool = false;

	public function new(route:H2RouteRequest->H2RouteAnswer) {
		__route = route;
		__listener.bind(new Host("127.0.0.1"), 0);
		__listener.listen(4);
		port = __listener.host().port;
		Thread.create(__accept);
	}

	/** The requests answered so far, in the order they arrived. */
	public function requests():Array<H2RouteRequest> {
		__lock.acquire();
		var copy:Array<H2RouteRequest> = __requests.copy();
		__lock.release();
		return copy;
	}

	public function connections():Int {
		__lock.acquire();
		var count:Int = __connections;
		__lock.release();
		return count;
	}

	public function stop():Void {
		__lock.acquire();
		__stopped = true;
		__lock.release();
	}

	private function __isStopped():Bool {
		__lock.acquire();
		var stopped:Bool = __stopped;
		__lock.release();
		return stopped;
	}

	private function __accept():Void {
		var until:Float = haxe.Timer.stamp() + 30;
		while (!__isStopped() && haxe.Timer.stamp() < until) {
			var ready:Bool = try SysSocket.select([__listener], null, null, 0.05).read.length > 0 catch (_:Dynamic) false;
			if (!ready) {
				continue;
			}
			var peer:SysSocket = try __listener.accept() catch (_:Dynamic) null;
			if (peer != null) {
				__lock.acquire();
				__connections++;
				__lock.release();
				__spawn(peer);
			}
		}
		try __listener.close() catch (_:Dynamic) {}
	}

	private function __spawn(peer:SysSocket):Void {
		Thread.create(() -> __serve(peer));
	}

	private function __serve(peer:SysSocket):Void {
		try {
			peer.setBlocking(true);
			// Until the client hangs up, which a pooled client does only when
			// its pool lets go of the connection.
			peer.setTimeout(10.0);
			var preface = Bytes.alloc(H2Connection.PREFACE.length);
			peer.input.readFullBytes(preface, 0, preface.length);
			__writeFrame(peer, H2FrameType.SETTINGS, 0, 0, Bytes.alloc(0));

			var decoder = new HpackDecoder(H2Settings.DEFAULT_HEADER_TABLE_SIZE);
			var encoder = new HpackEncoder(H2Settings.DEFAULT_HEADER_TABLE_SIZE);
			var open:Map<Int, H2RouteRequest> = new Map();

			while (true) {
				var header = Bytes.alloc(H2Frame.HEADER_SIZE);
				peer.input.readFullBytes(header, 0, H2Frame.HEADER_SIZE);
				var length:Int = H2Frame.lengthOf(header);
				var payload = Bytes.alloc(length);
				if (length > 0) {
					peer.input.readFullBytes(payload, 0, length);
				}
				var type:Int = header.get(3);
				var flags:Int = header.get(4);
				var id:Int = ((header.get(5) & 0x7f) << 24) | (header.get(6) << 16) | (header.get(7) << 8) | header.get(8);

				var request:H2RouteRequest = null;
				if (type == (H2FrameType.HEADERS : Int)) {
					request = {method: "GET", path: "/", headers: new Map(), body: ""};
					for (field in decoder.decode(payload)) {
						switch (field.name) {
							case ":method":
								request.method = field.value;
							case ":path":
								request.path = field.value;
							default:
								request.headers.set(field.name, field.value);
						}
					}
					open.set(id, request);
				} else if (type == (H2FrameType.DATA : Int) && open.exists(id)) {
					request = open.get(id);
					request.body += payload.toString();
				}

				if (request == null || (flags & H2Flags.END_STREAM) == 0) {
					continue;
				}
				open.remove(id);
				__lock.acquire();
				__requests.push(request);
				__lock.release();
				__answer(peer, encoder, id, __route(request));
			}
		} catch (_:Dynamic) {}
		try peer.close() catch (_:Dynamic) {}
	}

	private function __answer(peer:SysSocket, encoder:HpackEncoder, id:Int, answer:H2RouteAnswer):Void {
		var fields:Array<HpackHeader> = [new HpackHeader(":status", Std.string(answer.status))];
		if (answer.fields != null) {
			for (field in answer.fields) {
				fields.push(field);
			}
		}
		var chunks:Array<String> = answer.chunks != null ? answer.chunks : [];
		var ends:Bool = answer.hold != true;
		__writeFrame(peer, H2FrameType.HEADERS, H2Flags.END_HEADERS | (chunks.length == 0 && ends ? H2Flags.END_STREAM : 0), id, encoder.encode(fields));
		for (i in 0...chunks.length) {
			if (answer.gap != null && answer.gap > 0) {
				System.sleep(answer.gap);
			}
			var last:Bool = i == chunks.length - 1;
			__writeFrame(peer, H2FrameType.DATA, last && ends ? H2Flags.END_STREAM : 0, id, Bytes.ofString(chunks[i]));
		}
	}

	private function __writeFrame(peer:SysSocket, type:H2FrameType, flags:Int, streamId:Int, payload:Bytes):Void {
		var out = new BytesBuffer();
		H2Frame.writeHeader(out, payload.length, type, flags, streamId);
		if (payload.length > 0) {
			out.addBytes(payload, 0, payload.length);
		}
		var bytes = out.getBytes();
		peer.output.writeBytes(bytes, 0, bytes.length);
		peer.output.flush();
	}
}
