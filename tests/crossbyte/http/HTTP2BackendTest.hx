package crossbyte.http;

import crossbyte._internal.http.Http;
import crossbyte._internal.http.HttpVersion;
import crossbyte._internal.http.h2.H2Connection;
import crossbyte._internal.http.h2.H2ConnectionPool;
import crossbyte._internal.http.h2.H2ErrorCode;
import crossbyte._internal.http.h2.H2Flags;
import crossbyte._internal.http.h2.H2Frame;
import crossbyte._internal.http.h2.H2FrameType;
import crossbyte._internal.http.h2.H2Settings;
import crossbyte._internal.http.h2.hpack.HpackDecoder;
import crossbyte._internal.http.h2.hpack.HpackEncoder;
import crossbyte._internal.http.h2.hpack.HpackHeader;
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
			Sys.sleep(0.01);
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
			Sys.sleep(0.01);
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
			Sys.sleep(1.5 - haxe.Timer.stamp());
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
								Sys.sleep(0.05);
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
private class H2cServer {
	public var port:Int = 0;
	public var error:Dynamic = null;
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
				listener.bind(new Host("127.0.0.1"), 0);
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
			}
			// SETTINGS, SETTINGS ACK and WINDOW_UPDATE are read and ignored.
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
		var hasBody:Bool = __responseBody.length > 0;
		__writeFrame(peer, H2FrameType.HEADERS, H2Flags.END_HEADERS | (hasBody ? 0 : H2Flags.END_STREAM), streamId, block);

		if (hasBody) {
			__writeFrame(peer, H2FrameType.DATA, H2Flags.END_STREAM, streamId, Bytes.ofString(__responseBody));
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
