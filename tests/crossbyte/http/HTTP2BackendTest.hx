package crossbyte.http;

import crossbyte._internal.http.Http;
import crossbyte._internal.http.HttpVersion;
import crossbyte._internal.http.h2.H2Connection;
import crossbyte._internal.http.h2.H2ConnectionPool;
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
		while (!server.sawBothBeforeResponding) {
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

		// The reset reaches the server on its own schedule -- it is read in the
		// drain loop, after the responses this test already waited for -- so
		// this waits for the observation rather than assuming it has landed.
		//
		// Ten seconds, matching the two Lock.wait calls above rather than the
		// three this used to allow: the loop leaves the moment the reset is seen,
		// so the budget only matters on a machine slow enough to need it, and a
		// busy one was enough to spend three seconds and fail a working reset.
		var deadline:Float = Sys.time() + 10;
		while (server.resetStreamIds.indexOf(1) < 0 && Sys.time() < deadline) {
			Sys.sleep(0.01);
		}
		Assert.isTrue(server.resetStreamIds.indexOf(1) >= 0, "server never saw RST_STREAM for the cancelled stream");
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
		Assert.isTrue(server.sawBothBeforeResponding);
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
	public static inline var REFUSED_STREAM:Int = 0x7;
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

			peer.output.writeString("HTTP/1.1 400 Bad Request
Content-Length: 0

");
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
	public var sawBothBeforeResponding:Bool = false;
	public var resetStreamIds:Array<Int> = [];

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
				resetStreamIds.push(id);
			}

			if (type == (H2FrameType.HEADERS : Int)) {
				var path = "/";
				for (field in decoder.decode(payload)) {
					if (field.name == ":path") {
						path = field.value;
					}
				}
				streamIds.push(id);
				pending.push({id: id, path: path});

				if (!__holdUntilAll) {
					__respond(peer, encoder, id, path);
				}
			}
		}

		if (__holdUntilAll) {
			sawBothBeforeResponding = true;

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
						resetStreamIds.push(((header.get(5) & 0x7f) << 24) | (header.get(6) << 16) | (header.get(7) << 8) | header.get(8));
					}
				}
			} catch (_:Dynamic) {}
		}
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
