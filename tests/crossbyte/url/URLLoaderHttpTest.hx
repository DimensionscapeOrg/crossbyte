package crossbyte.url;

import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.HTTPStatusEvent;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ProgressEvent;
import crossbyte.http.HTTPBackend;
import crossbyte.http.HTTPBackendRegistry;
import crossbyte.http.HTTPRequestContext;
import crossbyte.http.HTTPVersion;
import haxe.io.Bytes;
import sys.net.Host;
import sys.net.Socket as SysSocket;
import sys.thread.Lock;
import sys.thread.Mutex;
import sys.thread.Thread;
import utest.Assert;
import crossbyte.test.Require;

class URLLoaderHttpTest extends utest.Test {
	public function testLoadsFixedLengthTextAndReportsPublicEvents():Void {
		var fixture = serveRequests(_ -> response(200, "OK", ["Content-Length: 5"], "hello"), 1);
		var result = loadText('http://127.0.0.1:${fixture.port}/fixed');

		fixture.waitDone();

		Assert.equals("hello", result.data);
		Assert.same([200], result.statuses);
		Assert.equals(0, result.progress[0].loaded);
		Assert.equals(5, result.progress[0].total);
		Assert.equals(5, result.progress[result.progress.length - 1].loaded);
		Assert.isNull(result.error);
		Assert.isTrue(fixture.requests[0].raw.indexOf("GET /fixed HTTP/1.1") == 0);
	}

	public function testTheResponseReachesTheLoaderWithItsHeaders():Void {
		// HTTP_RESPONSE_STATUS is dispatched, so Retry-After, ETag and Location
		// can be read.
		var fixture = serveRequests(_ -> response(200, "OK", [
			"Content-Length: 2", "ETag: \"abc\"", "Retry-After: 120", "Set-Cookie: a=1; Path=/", "Set-Cookie: b=2; Expires=Wed, 09 Jun 2100 10:18:14 GMT"
		], "ok"), 1);
		var url = 'http://127.0.0.1:${fixture.port}/resource';
		var result = loadText(url);

		fixture.waitDone();

		Assert.equals(1, result.responses.length, "HTTP_RESPONSE_STATUS was not dispatched once");
		if (result.responses.length > 0) {
			var event:HTTPStatusEvent = result.responses[0];
			Assert.equals(200, event.status);
			Assert.equals(url, event.responseURL);
			Assert.isFalse(event.redirected);
			Assert.equals("\"abc\"", __header(event, "etag"));
			Assert.equals("120", __header(event, "retry-after"));
			var cookies = event.responseHeaders.filter(h -> h.name == "set-cookie").map(h -> h.value);
			Assert.equals(2, cookies.length, "the two Set-Cookie fields were not kept apart: " + cookies);
		}
		Assert.isTrue(result.complete);
	}

	public function testARedirectedResponseNamesWhereItCameFrom():Void {
		var fixture = serveRequests(request -> request.target == "/start" ? response(302, "Found", ["Location: /final", "Content-Length: 0"], "")
			: response(200, "OK", ["Content-Length: 4", "X-Served-By: final"], "done"), 2);
		var result = loadText('http://127.0.0.1:${fixture.port}/start');

		fixture.waitDone();

		Assert.equals(1, result.responses.length, "a redirect's own response was reported as the answer");
		if (result.responses.length > 0) {
			Assert.equals(200, result.responses[0].status);
			Assert.isTrue(result.responses[0].redirected);
			Assert.equals('http://127.0.0.1:${fixture.port}/final', result.responses[0].responseURL);
			Assert.equals("final", __header(result.responses[0], "x-served-by"));
		}
	}

	public function testAnErrorResponseIsReportedBeforeTheError():Void {
		var fixture = serveRequests(_ -> response(503, "Service Unavailable", ["Content-Length: 4", "Retry-After: 30"], "busy"), 1);
		var result = loadText('http://127.0.0.1:${fixture.port}/busy');

		fixture.waitDone();

		Assert.equals("HTTP error 503", result.error);
		Assert.equals("busy", result.data);
		Assert.equals(1, result.responses.length);
		if (result.responses.length > 0) {
			Assert.equals("30", __header(result.responses[0], "retry-after"));
		}
	}

	private static function __header(event:HTTPStatusEvent, name:String):Null<String> {
		if (event.responseHeaders == null) {
			return null;
		}
		for (header in event.responseHeaders) {
			if (header.name == name) {
				return header.value;
			}
		}
		return null;
	}

	public function testTheDecodedSizeLimitIsTheRequests():Void {
		// 100 KB of one letter is a few hundred bytes of gzip. The client's
		// ceiling on what a body may decode to is set per request, not one
		// internal 64 MB for every request.
		var plain:crossbyte.io.ByteArray = new crossbyte.io.ByteArray();
		for (_ in 0...100 * 1024) {
			plain.writeByte("a".code);
		}
		plain.compress(crossbyte.utils.CompressionAlgorithm.GZIP);
		var gzip:Bytes = Bytes.alloc(plain.length);
		gzip.blit(0, plain, 0, plain.length);

		var head:String = 'HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: ${gzip.length}\r\n\r\n';
		var limited = serveBytes(head, gzip);
		var request = new URLRequest('http://127.0.0.1:${limited.port}/zeros');
		request.maxDecompressedSize = 10 * 1024;
		var refused = load(request);
		limited.waitDone();

		Assert.isFalse(refused.complete, "a body past the request's decode limit completed");
		Require.notNull(refused.error);
		Assert.isTrue(refused.error.indexOf("decode") >= 0, refused.error);

		// The default still takes it.
		var open = serveBytes(head, gzip);
		var taken = load(new URLRequest('http://127.0.0.1:${open.port}/zeros'));
		open.waitDone();
		Assert.isTrue(taken.complete, taken.error);
		Assert.equals(100 * 1024, taken.data == null ? -1 : taken.data.length);
	}

	/**
		A `deflate` response is read as zlib, which is what the name means
		(RFC 9110 8.4.1.2), and as raw DEFLATE too, which servers commonly
		send under it, so a server following the standard can be read.
	**/
	public function testADeflateResponseIsReadAsZlibOrRaw():Void {
		var text:String = "a deflate body, coded both ways";
		for (algorithm in [crossbyte.utils.CompressionAlgorithm.ZLIB, crossbyte.utils.CompressionAlgorithm.DEFLATE]) {
			var coded:crossbyte.io.ByteArray = new crossbyte.io.ByteArray();
			coded.writeUTFBytes(text);
			coded.compress(algorithm);
			var body:Bytes = Bytes.alloc(coded.length);
			body.blit(0, coded, 0, coded.length);

			var fixture = serveBytes('HTTP/1.1 200 OK
Content-Encoding: deflate
Content-Length: ${body.length}

', body);
			var result = load(new URLRequest('http://127.0.0.1:${fixture.port}/coded'));
			fixture.waitDone();

			Assert.isTrue(result.complete, algorithm + ": " + result.error);
			Assert.equals(text, result.data == null ? null : result.data.toString(), algorithm + " was not read");
		}
	}

	/** Answers one request with `head` and then `body`, byte for byte. */
	private static function serveBytes(head:String, body:Bytes):URLLoaderHttpFixture {
		var fixture = new URLLoaderHttpFixture(1);
		Thread.create(() -> {
			var server = new SysSocket();
			var peer:SysSocket = null;
			try {
				server.bind(new Host("127.0.0.1"), 0);
				server.listen(1);
				fixture.port = server.host().port;
				fixture.ready.release();
				peer = server.accept();
				peer.setTimeout(2.0);
				fixture.requests.push(readRequest(peer));
				peer.output.writeString(head);
				peer.output.writeFullBytes(body, 0, body.length);
				peer.output.flush();
			} catch (error:Dynamic) {
				fixture.error = error;
				fixture.ready.release();
			}
			closeQuietly(peer);
			closeQuietly(server);
			fixture.done.release();
		});
		if (!fixture.ready.wait(2.0)) {
			Assert.fail("Timed out waiting for HTTP fixture server");
		}
		return fixture;
	}

	public function testLoadsChunkedTextWithUnknownTotal():Void {
		var fixture = serveRequests(_ -> "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6;ext=1\r\n world\r\n0\r\n\r\n", 1);
		var result = loadText('http://127.0.0.1:${fixture.port}/chunked');

		fixture.waitDone();

		Assert.equals("hello world", result.data);
		// 0 for a length nobody declared, as on JavaScript; -1 would reach
		// ProgressEvent's UInt as 4294967295.
		Assert.equals(0, result.progress[0].total);
		Assert.equals(11, result.progress[result.progress.length - 1].loaded);
		Assert.isNull(result.error);
	}

	public function testLoadsCloseDelimitedText():Void {
		var fixture = serveRequests(_ -> "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nclose body", 1);
		var result = loadText('http://127.0.0.1:${fixture.port}/close-delimited');

		fixture.waitDone();

		Assert.equals("close body", result.data);
		Assert.isNull(result.error);
		Assert.equals(0, result.progress[0].total, "a body ended by the close has no length to report");
	}

	public function testHeadCompletesWithoutReadingResponseBody():Void {
		var fixture = serveRequests(_ -> response(200, "OK", ["Content-Length: 5"], "hello"), 1);
		var request = new URLRequest('http://127.0.0.1:${fixture.port}/head');
		request.method = URLRequestMethod.HEAD;
		var result = load(request);

		fixture.waitDone();

		Assert.equals("", result.data);
		Assert.isNull(result.error);
		Assert.equals(5, result.progress[0].total);
		Assert.isTrue(fixture.requests[0].raw.indexOf("HEAD /head HTTP/1.1") == 0);
	}

	public function testInformationalStatusIsSkippedBeforeFinalResponse():Void {
		var fixture = serveRequests(_ -> "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok", 1);
		var result = loadText('http://127.0.0.1:${fixture.port}/continue');

		fixture.waitDone();

		Assert.equals("ok", result.data);
		// The interim 100 is not a status the load ends with, and the client
		// contract says it is not reported, as HTTP_STATUS or otherwise.
		Assert.same([200], result.statuses);
		Assert.isNull(result.error);
	}

	public function testHttpErrorDispatchesIoErrorAndKeepsResponseBody():Void {
		var fixture = serveRequests(_ -> response(404, "Not Found", ["Content-Length: 7"], "missing"), 1);
		var result = loadText('http://127.0.0.1:${fixture.port}/missing');

		fixture.waitDone();

		Assert.equals("HTTP error 404", result.error);
		Assert.equals("missing", result.data);
		Assert.same([404], result.statuses);
		Assert.isFalse(result.complete);
	}

	public function testPostObjectDataIsFormEncoded():Void {
		var fixture = serveRequests(_ -> response(204, "No Content", ["Content-Length: 0"], ""), 1);
		var request = new URLRequest('http://127.0.0.1:${fixture.port}/submit');
		request.method = URLRequestMethod.POST;
		request.requestHeaders.push(new URLRequestHeader("X-Test", "yes"));
		request.data = {
			field: "a b",
			ok: false
		};
		var result = load(request);

		fixture.waitDone();

		Assert.equals("", result.data);
		Assert.isNull(result.error);
		Assert.isTrue(fixture.requests[0].raw.indexOf("POST /submit HTTP/1.1") == 0);
		Assert.equals("yes", fixture.requests[0].headers.get("x-test"));
		Assert.equals("application/x-www-form-urlencoded; charset=utf-8", fixture.requests[0].headers.get("content-type"));
		Assert.isTrue(fixture.requests[0].body.indexOf("field=a%20b") >= 0);
		Assert.isTrue(fixture.requests[0].body.indexOf("ok=false") >= 0);
	}

	/**
		Form data reaches the server over HTTP/2 as it does over HTTP/1.1: a
		GET's as its query, a POST's as a form body. The HTTP/2 backend reads
		`requestData`, so a `URLVariables` or an object does not go nowhere (a
		POST with an empty body and no Content-Type, a GET with no query), since
		setting `httpVersion` is all a request is told to change.
	**/
	public function testFormDataGoesOutOverHttp2AsOverHttp11():Void {
		var config = new crossbyte.http.HTTPServerConfig("127.0.0.1", 0);
		config.http2Enabled = true;
		config.middleware = [
			(handler, next) -> handler.respond(200, "text/plain",
				handler.method + " ?" + handler.queryString + " [" + handler.getHeader("content-type") + "] " + handler.requestText)
		];
		var server = new crossbyte.http.HTTPServer(config);
		pumpUntil(() -> server.localPort != 0);

		var answers:Array<String> = [];
		for (version in [HTTPVersion.HTTP_1_1, HTTPVersion.HTTP_2]) {
			var form = new URLVariables();
			form.set("user", "alice");
			form.set("score", "42");
			var post = new URLRequest('http://127.0.0.1:${server.localPort}/form');
			post.httpVersion = version;
			post.method = URLRequestMethod.POST;
			post.data = form;
			var posted = load(post);

			var get = new URLRequest('http://127.0.0.1:${server.localPort}/form?page=2');
			get.httpVersion = version;
			get.data = {user: "bob"};
			var got = load(get);

			// Key order is the map's, which differs by target.
			for (field in ["user=alice", "score=42"]) {
				Assert.isTrue(posted.data != null && posted.data.indexOf(field) >= 0, '$version: $field is not in the POST: ${posted.data} ${posted.error}');
			}
			Assert.isTrue(posted.data != null && StringTools.startsWith(posted.data, "POST ? [application/x-www-form-urlencoded"),
				'$version: the POST was not a form: ${posted.data}');
			Assert.equals("GET ?page=2&user=bob [null] ", got.data, '$version: the GET did not carry its fields as its query');
		}

		server.close();
		crossbyte._internal.http.h2.H2ConnectionPool.closeAll();
	}

	public function testRelativeRedirectNormalizesDotSegments():Void {
		var fixture = serveRequests(request -> {
			return switch (request.target) {
				case "/dir/start":
					response(302, "Found", ["Location: ../final?token=1", "Content-Length: 0"], "");
				case "/final?token=1":
					response(200, "OK", ["Content-Length: 4"], "done");
				default:
					response(500, "Unexpected", ["Content-Length: 0"], "");
			}
		}, 2);
		var result = loadText('http://127.0.0.1:${fixture.port}/dir/start');

		fixture.waitDone();

		Assert.equals("done", result.data);
		Assert.same([302, 200], result.statuses);
		Assert.equals("/dir/start", fixture.requests[0].target);
		Assert.equals("/final?token=1", fixture.requests[1].target);
		Assert.isNull(result.error);
	}

	public function testQueryOnlyRedirectPreservesBasePath():Void {
		var fixture = serveRequests(request -> {
			return switch (request.target) {
				case "/dir/start?old=1":
					response(302, "Found", ["Location: ?token=1", "Content-Length: 0"], "");
				case "/dir/start?token=1":
					response(200, "OK", ["Content-Length: 4"], "done");
				default:
					response(500, "Unexpected", ["Content-Length: 0"], "");
			}
		}, 2);
		var result = loadText('http://127.0.0.1:${fixture.port}/dir/start?old=1');

		fixture.waitDone();

		Assert.equals("done", result.data);
		Assert.same([302, 200], result.statuses);
		Assert.equals("/dir/start?old=1", fixture.requests[0].target);
		Assert.equals("/dir/start?token=1", fixture.requests[1].target);
		Assert.isNull(result.error);
	}

	public function testFollowRedirectsFalseCompletesWithRedirectResponse():Void {
		var fixture = serveRequests(_ -> response(302, "Found", ["Location: /final", "Content-Length: 0"], ""), 1);
		var request = new URLRequest('http://127.0.0.1:${fixture.port}/start');
		request.followRedirects = false;
		var result = load(request);

		fixture.waitDone();

		Assert.isTrue(result.complete);
		Assert.equals("", result.data);
		Assert.same([302], result.statuses);
		Assert.equals(1, fixture.requests.length);
	}

	public function testSeeOtherRedirectConvertsPostToGetAndDropsBody():Void {
		var fixture = serveRequests(request -> {
			return switch (request.target) {
				case "/submit":
					response(303, "See Other", ["Location: /final", "Content-Length: 0"], "");
				case "/final":
					response(200, "OK", ["Content-Length: 2"], "ok");
				default:
					response(500, "Unexpected", ["Content-Length: 0"], "");
			}
		}, 2);
		var request = new URLRequest('http://127.0.0.1:${fixture.port}/submit');
		request.method = URLRequestMethod.POST;
		request.data = "payload";
		var result = load(request);

		fixture.waitDone();

		Assert.equals("ok", result.data);
		Assert.same([303, 200], result.statuses);
		Assert.isTrue(fixture.requests[0].raw.indexOf("POST /submit HTTP/1.1") == 0);
		Assert.equals("payload", fixture.requests[0].body);
		Assert.isTrue(fixture.requests[1].raw.indexOf("GET /final HTTP/1.1") == 0);
		Assert.equals("", fixture.requests[1].body);
	}

	public function testTemporaryRedirectPreservesPostMethodAndBody():Void {
		var fixture = serveRequests(request -> {
			return switch (request.target) {
				case "/submit":
					response(307, "Temporary Redirect", ["Location: /final", "Content-Length: 0"], "");
				case "/final":
					response(200, "OK", ["Content-Length: 2"], "ok");
				default:
					response(500, "Unexpected", ["Content-Length: 0"], "");
			}
		}, 2);
		var request = new URLRequest('http://127.0.0.1:${fixture.port}/submit');
		request.method = URLRequestMethod.POST;
		request.data = "payload";
		var result = load(request);

		fixture.waitDone();

		Assert.equals("ok", result.data);
		Assert.same([307, 200], result.statuses);
		Assert.isTrue(fixture.requests[0].raw.indexOf("POST /submit HTTP/1.1") == 0);
		Assert.equals("payload", fixture.requests[0].body);
		Assert.isTrue(fixture.requests[1].raw.indexOf("POST /final HTTP/1.1") == 0);
		Assert.equals("payload", fixture.requests[1].body);
	}

	public function testInvalidContentLengthDispatchesIoError():Void {
		var fixture = serveRequests(_ -> "HTTP/1.1 200 OK\r\nContent-Length: nope\r\n\r\nbad", 1);
		var result = loadText('http://127.0.0.1:${fixture.port}/invalid-length');

		fixture.waitDone();

		Assert.equals("Download failed: invalid Content-Length", result.error);
		Assert.isFalse(result.complete);
	}

	public function testConflictingDuplicateContentLengthDispatchesIoError():Void {
		var fixture = serveRequests(_ -> "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Length: 3\r\n\r\nbad", 1);
		var result = loadText('http://127.0.0.1:${fixture.port}/conflicting-length');

		fixture.waitDone();

		Assert.equals("Download failed: invalid Content-Length", result.error);
		Assert.isFalse(result.complete);
	}

	public function testMatchingDuplicateContentLengthIsAccepted():Void {
		var fixture = serveRequests(_ -> "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\nok", 1);
		var result = loadText('http://127.0.0.1:${fixture.port}/matching-length');

		fixture.waitDone();

		Assert.equals("ok", result.data);
		Assert.isNull(result.error);
	}

	public function testInvalidChunkTerminatorDispatchesIoError():Void {
		var fixture = serveRequests(_ -> "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nokXX0\r\n\r\n", 1);
		var result = loadText('http://127.0.0.1:${fixture.port}/bad-chunk');

		fixture.waitDone();

		// The cause travels with the message, so a bad chunk size, a truncated
		// chunk and a missing terminator do not all reach the caller as the
		// same four words.
		var error:String = Require.notNull(result.error);
		Assert.equals(0, error.indexOf("Download failed"), error);
		Assert.isTrue(error.indexOf("Invalid chunk terminator") > 0, error);
		Assert.isFalse(result.complete);
	}

	public function testChunkedTransferIgnoresContentLength():Void {
		var fixture = serveRequests(_ -> "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: nope\r\n\r\n2\r\nok\r\n0\r\n\r\n", 1);
		var result = loadText('http://127.0.0.1:${fixture.port}/chunked-over-length');

		fixture.waitDone();

		Assert.equals("ok", result.data);
		Assert.isNull(result.error);
		Assert.equals(0, result.progress[0].total);
	}

	public function testTheNextLoadCanStartFromComplete():Void {
		// The loader is free while COMPLETE is dispatched, not freed after the
		// listeners run, so a listener starting the next load on it is not
		// refused with "URLLoader is already loading".
		var fixture = serveRequests(_ -> response(200, "OK", ["Content-Length: 2"], "ok"), 2);
		var loader = new URLLoader();
		var events:Array<String> = [];
		var loads:Int = 0;
		loader.addEventListener(Event.COMPLETE, _ -> {
			events.push("complete " + loader.data);
			if (++loads == 1) {
				var next = new URLRequest('http://127.0.0.1:${fixture.port}/second');
				next.idleTimeout = 2000;
				loader.load(next);
			}
		});
		loader.addEventListener(IOErrorEvent.IO_ERROR, (event:IOErrorEvent) -> events.push("error " + event.text));
		var first = new URLRequest('http://127.0.0.1:${fixture.port}/first');
		first.idleTimeout = 2000;
		loader.load(first);

		pumpUntil(() -> events.length >= 2);
		fixture.waitDone();
		Assert.same(["complete ok", "complete ok"], events);
	}

	/**
		A backend is handed the request's headers as `HTTPRequestContext`
		says, each `"Name: value"`, not as `URLRequestHeader.toString()` writes
		them, `"Name:value"`, where a backend splitting at ": " as told would
		find no value.
	**/
	public function testABackendIsHandedHeaderLinesAsItsContractSays():Void {
		var backend = new HeaderRecordingBackend();
		HTTPBackendRegistry.register(backend);
		var request = new URLRequest("http://127.0.0.1/lines");
		request.httpVersion = HTTPVersion.HTTP_3;
		request.requestHeaders.push(new URLRequestHeader("X-Test", "yes"));
		var result = load(request);
		HTTPBackendRegistry.unregister(backend);

		Assert.isTrue(result.complete, result.error);
		Assert.same(["X-Test: yes"], backend.lines);
	}

	#if target.threaded
	public function testLoadsReuseTheirThreadsAndStayOffTheRuntime():Void {
		// Loads share a pool of threads. A thread of its own for every load
		// would make a hundred loads a second a hundred thread starts, and on
		// the jvm each thread's selector, never closed, would leave two sockets
		// open per load. A backend of the test's own, on HTTP/3, which nothing
		// else serves, says which thread each load ran on.
		var backend = new ThreadRecordingBackend();
		HTTPBackendRegistry.register(backend);
		var loader = new URLLoader();
		var completed:Int = 0;
		var failures:Array<String> = [];
		loader.addEventListener(Event.COMPLETE, _ -> completed++);
		loader.addEventListener(IOErrorEvent.IO_ERROR, (event:IOErrorEvent) -> failures.push(event.text));
		try {
			for (i in 0...12) {
				var request = new URLRequest('http://127.0.0.1/n$i');
				request.httpVersion = HTTPVersion.HTTP_3;
				var before:Int = completed + failures.length;
				loader.load(request);
				pumpUntil(() -> completed + failures.length > before);
			}
		} catch (e:Dynamic) {
			HTTPBackendRegistry.unregister(backend);
			throw e;
		}
		HTTPBackendRegistry.unregister(backend);

		Assert.equals(12, completed, failures.join("; "));
		// And off the runtime's thread, where a blocking request (or the name
		// lookup at its start) would stop every socket and timer.
		Assert.equals(0, backend.onRuntime(), "a load ran on the runtime's thread");
		// One thread, or two when the next load is queued in the moment
		// before the thread that finished the last one is waiting again.
		var threads:Int = backend.distinctThreads();
		Assert.isTrue(threads <= 2, '12 loads, one after another, ran on $threads threads');
	}

	// Only where the loader's worker is a thread: elsewhere it runs the load
	// inside load(), so nothing can close it while it is in flight.
	public function testClosingALoadInFlightEndsItQuietly():Void {
		// A server that takes the request and holds it, answering nothing,
		// and notes how its wait for the client ended.
		var ready = new Lock();
		var finished = new Lock();
		// Strings, not Bools. On the jvm a Deque of a basic type answers
		// `pop(false)` on an empty queue with false or 0 rather than null, so
		// a Deque<Bool> here would say the request had arrived before it was
		// sent: the loader would be closed before its load began, and the
		// server would wait in accept() for a client that never came.
		var arrived = new sys.thread.Deque<String>();
		var ended:String = null;
		var port = 0;
		Thread.create(() -> {
			var server = new SysSocket();
			var peer:SysSocket = null;
			try {
				server.bind(new Host("127.0.0.1"), 0);
				server.listen(1);
				port = server.host().port;
				ready.release();
				peer = server.accept();
				// Longer than the test waits for this thread below, so only the
				// client going ends the wait in time.
				peer.setTimeout(5.0);
				readRequest(peer);
				arrived.add("arrived");
				try {
					peer.input.readByte();
					ended = "a byte arrived";
				} catch (_:haxe.io.Eof) {
					ended = "the client went";
				} catch (e:Dynamic) {
					ended = Std.string(e);
				}
			} catch (_:Dynamic) {
				ready.release();
			}
			closeQuietly(peer);
			closeQuietly(server);
			finished.release();
		});
		if (!ready.wait(2.0) || port == 0) {
			Assert.fail("the fixture server did not start");
			return;
		}

		var loader = new URLLoader();
		var events:Array<String> = [];
		loader.addEventListener(Event.COMPLETE, _ -> events.push("complete"));
		loader.addEventListener(IOErrorEvent.IO_ERROR, (event:IOErrorEvent) -> events.push("error: " + event.text));
		var request = new URLRequest('http://127.0.0.1:${port}/held');
		request.idleTimeout = 2000;
		loader.load(request);

		var inFlight = false;
		pumpUntil(() -> inFlight = inFlight || arrived.pop(false) != null);
		if (!inFlight) {
			Assert.fail("the request never reached the server");
			loader.close();
			return;
		}

		// The worker thread is blocked reading. Closing ends that read, and
		// what the thread reports next must not go through the loader's worker
		// field, which close() has just cleared: natively that would be an
		// access violation.
		loader.close();
		var settle = haxe.Timer.stamp() + 0.5;
		pumpUntil(() -> haxe.Timer.stamp() >= settle);

		Assert.same([], events);
		// And the server hears of it now, not when its own wait runs out. The
		// client's socket is not closed from the closing thread: on eval that
		// would kill the worker with an error nothing could catch, and the reset
		// it caused would kill the server's reader too; on Linux a close does
		// not wake the read, so the server would wait out the idle timeout.
		Assert.isTrue(finished.wait(2.0), "the server never saw the client go");
		Assert.equals("the client went", ended);

		// And the loader is free for the next load.
		var fixture = serveRequests(_ -> response(200, "OK", ["Content-Length: 2"], "ok"), 1);
		loader.addEventListener(Event.COMPLETE, _ -> events.push("data: " + loader.data));
		var next = new URLRequest('http://127.0.0.1:${fixture.port}/next');
		next.idleTimeout = 2000;
		loader.load(next);
		pumpUntil(() -> events.length >= 2);
		fixture.waitDone();
		Assert.same(["complete", "data: ok"], events);
	}
	#end

	/**
		A body trickled a byte at a time ends at the request's `totalTimeout`.
		Each byte resets the idle timeout, so without a total bound this one
		(five seconds of body) would run to the end of it.
	**/
	public function testATrickledBodyEndsAtTheTotalTimeout():Void {
		var fixture = serveTrickled("HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 100\r\n\r\n", StringTools.rpad("", "t", 100), 0.05);
		var request = new URLRequest('http://127.0.0.1:${fixture.port}/trickle');
		request.idleTimeout = 2000;
		request.totalTimeout = 700;
		var loader = new URLLoader();
		var events:Array<String> = [];
		loader.addEventListener(Event.COMPLETE, _ -> events.push("complete"));
		loader.addEventListener(IOErrorEvent.IO_ERROR, (event:IOErrorEvent) -> events.push("error: " + event.text));

		var started:Float = haxe.Timer.stamp();
		loader.load(request);
		pumpUntil(() -> events.length > 0, 8.0);
		var took:Float = haxe.Timer.stamp() - started;

		Assert.equals(1, events.length, "the load did not end once: " + events);
		Assert.isTrue(events.length > 0 && events[0].indexOf("did not complete within 700 ms") >= 0, "the load did not end at its deadline: " + events);
		Assert.isTrue(took >= 0.6 && took < 3.0, 'a 0.7 s deadline ended the load after $took s');

		// And nothing more is said of it, however much more its thread says
		// as it winds down: on eval under Windows the cancel ends its read
		// only when the server stops sending.
		var settle:Float = haxe.Timer.stamp() + 0.3;
		pumpUntil(() -> haxe.Timer.stamp() >= settle);
		Assert.equals(1, events.length, "the load said more after its deadline: " + events);
		fixture.done.wait(6.0);
	}

	/**
		Progress the runtime has not yet told is folded into the latest. The
		client reports it per chunk, so without folding, 5,000 chunks arriving
		while the runtime was busy would queue 5,000 messages, and 5,000 events
		would follow.
	**/
	public function testProgressNotYetToldIsFoldedIntoTheLatest():Void {
		var chunks:StringBuf = new StringBuf();
		for (_ in 0...5000) {
			chunks.add("a\r\n0123456789\r\n");
		}
		chunks.add("0\r\n\r\n");
		var fixture = serveRequests(_ -> "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n" + chunks.toString(), 1);
		var request = new URLRequest('http://127.0.0.1:${fixture.port}/chunks');
		request.idleTimeout = 5000;
		var loader = new URLLoader();
		var progress:Array<Int> = [];
		var done:Bool = false;
		loader.addEventListener(ProgressEvent.PROGRESS, (event:ProgressEvent) -> progress.push(Std.int(event.bytesLoaded)));
		loader.addEventListener(Event.COMPLETE, _ -> done = true);
		loader.addEventListener(IOErrorEvent.IO_ERROR, _ -> done = true);
		loader.load(request);

		// The runtime busy (not pumped) while the whole body arrives.
		fixture.waitDone();
		crossbyte.sys.System.sleep(0.5);
		pumpUntil(() -> done, 5.0);

		Assert.isTrue(done, "the load never ended");
		Assert.isTrue(progress.length < 50, progress.length + " progress events told for 5,000 chunks the runtime was too busy to hear");
		// The first report, at nothing loaded, is kept: where a listener
		// learns the total before any of the body.
		Assert.equals(0, progress.length > 0 ? progress[0] : -1, "the first progress told is not the body's start");
		Assert.equals(50000, progress.length > 0 ? progress[progress.length - 1] : -1, "the last progress told is not the whole body");
	}

	/** A deadline the load meets changes nothing: the load completes, once. **/
	public function testALoadWithinItsTotalTimeoutCompletes():Void {
		var fixture = serveRequests(_ -> response(200, "OK", ["Content-Length: 5"], "hello"), 1);
		var request = new URLRequest('http://127.0.0.1:${fixture.port}/quick');
		request.totalTimeout = 5000;
		var result = load(request);
		fixture.waitDone();
		Assert.isNull(result.error, result.error);
		Assert.equals("hello", result.data);
	}

	/**
		A load waiting for a thread waits its `idleTimeout` at most. With
		every thread taken by loads whose servers hold them, it would otherwise
		wait for as long as they do, and a load whose server trickles holds its
		thread for good.
	**/
	public function testALoadWaitingForAThreadEndsAtItsIdleTimeout():Void {
		var saved:Int = URLLoader.maxConcurrentLoads;
		URLLoader.maxConcurrentLoads = 1;
		var held = holdOne();
		var first = new URLLoader();
		var firstEvents:Array<String> = [];
		first.addEventListener(IOErrorEvent.IO_ERROR, (event:IOErrorEvent) -> firstEvents.push(event.text));
		first.addEventListener(Event.COMPLETE, _ -> firstEvents.push("complete"));
		var holding = new URLRequest('http://127.0.0.1:${held.port}/held');
		holding.idleTimeout = 5000;
		first.load(holding);
		pumpUntil(() -> held.requests.length > 0, 3.0);
		Assert.equals(1, held.requests.length, "the first load never reached its server");

		var second = new URLLoader();
		var events:Array<String> = [];
		second.addEventListener(IOErrorEvent.IO_ERROR, (event:IOErrorEvent) -> events.push(event.text));
		second.addEventListener(Event.COMPLETE, _ -> events.push("complete"));
		var queued = new URLRequest('http://127.0.0.1:${held.port}/queued');
		queued.idleTimeout = 500;
		var started:Float = haxe.Timer.stamp();
		second.load(queued);
		pumpUntil(() -> events.length > 0, 4.0);
		var took:Float = haxe.Timer.stamp() - started;

		first.close();
		URLLoader.maxConcurrentLoads = saved;
		held.done.wait(3.0);

		Assert.equals(1, events.length, "the queued load did not end once: " + events);
		Assert.isTrue(events.length > 0 && events[0].indexOf("did not start within 500 ms") >= 0, "the queued load did not say it waited for a thread: " + events);
		Assert.isTrue(took >= 0.4 && took < 2.5, 'a 0.5 s limit on the wait ended it after $took s');
		Assert.same([], firstEvents);
	}

	/**
		Takes one request, holds it unanswered until its client goes (five
		seconds at most), and refuses anything after it.
	**/
	private static function holdOne():URLLoaderHttpFixture {
		var fixture = new URLLoaderHttpFixture(1);
		Thread.create(() -> {
			var server = new SysSocket();
			var peer:SysSocket = null;
			try {
				server.bind(new Host("127.0.0.1"), 0);
				server.listen(4);
				fixture.port = server.host().port;
				fixture.ready.release();
				peer = server.accept();
				peer.setTimeout(5.0);
				fixture.requests.push(readRequest(peer));
				try {
					peer.input.readByte();
				} catch (_:Dynamic) {}
			} catch (error:Dynamic) {
				fixture.error = error;
				fixture.ready.release();
			}
			closeQuietly(peer);
			closeQuietly(server);
			fixture.done.release();
		});
		if (!fixture.ready.wait(2.0)) {
			Assert.fail("Timed out waiting for HTTP fixture server");
		}
		return fixture;
	}

	/**
		Takes one request and answers `prompt` at once, then `trickled` a byte
		every `gap` seconds (each byte enough to reset an idle timeout) until
		the client goes.
	**/
	private static function serveTrickled(prompt:String, trickled:String, gap:Float):URLLoaderHttpFixture {
		var fixture = new URLLoaderHttpFixture(1);
		Thread.create(() -> {
			var server = new SysSocket();
			var peer:SysSocket = null;
			try {
				server.bind(new Host("127.0.0.1"), 0);
				server.listen(1);
				fixture.port = server.host().port;
				fixture.ready.release();
				peer = server.accept();
				peer.setTimeout(6.0);
				fixture.requests.push(readRequest(peer));
				peer.output.writeString(prompt);
				peer.output.flush();
				for (i in 0...trickled.length) {
					crossbyte.sys.System.sleep(gap);
					peer.output.writeString(trickled.charAt(i));
					peer.output.flush();
				}
			} catch (_:Dynamic) {
				// The client went: what this waits for.
			}
			closeQuietly(peer);
			closeQuietly(server);
			fixture.done.release();
		});
		if (!fixture.ready.wait(2.0)) {
			Assert.fail("Timed out waiting for HTTP fixture server");
		}
		return fixture;
	}

	private static function loadText(url:String):URLLoaderHttpResult {
		return load(new URLRequest(url));
	}

	private static function load(request:URLRequest):URLLoaderHttpResult {
		request.idleTimeout = 2000;
		var loader = new URLLoader();
		var result:URLLoaderHttpResult = {
			complete: false,
			error: null,
			data: null,
			statuses: [],
			progress: [],
			responses: []
		};

		loader.addEventListener(HTTPStatusEvent.HTTP_STATUS, (event:HTTPStatusEvent) -> result.statuses.push(event.status));
		loader.addEventListener(HTTPStatusEvent.HTTP_RESPONSE_STATUS, (event:HTTPStatusEvent) -> result.responses.push(event));
		loader.addEventListener(ProgressEvent.PROGRESS, (event:ProgressEvent) -> result.progress.push({loaded: event.bytesLoaded, total: event.bytesTotal}));
		loader.addEventListener(Event.COMPLETE, (_:Event) -> {
			result.complete = true;
			result.data = Std.string(loader.data);
		});
		loader.addEventListener(IOErrorEvent.IO_ERROR, (event:IOErrorEvent) -> {
			result.error = event.text;
			result.data = loader.data == null ? null : Std.string(loader.data);
		});

		loader.load(request);
		pumpUntil(() -> result.complete || result.error != null);

		Assert.isTrue(result.complete || result.error != null);
		return result;
	}

	private static function serveRequests(responder:URLLoaderHttpFixtureRequest->String, expectedRequests:Int):URLLoaderHttpFixture {
		var fixture = new URLLoaderHttpFixture(expectedRequests);
		Thread.create(() -> {
			var server = new SysSocket();
			try {
				server.bind(new Host("127.0.0.1"), 0);
				server.listen(expectedRequests);
				fixture.port = server.host().port;
				fixture.ready.release();

				for (_ in 0...expectedRequests) {
					var peer:SysSocket = null;
					try {
						peer = server.accept();
						peer.setTimeout(2.0);
						var request = readRequest(peer);
						fixture.requests.push(request);
						peer.output.writeString(responder(request));
						peer.output.flush();
					} catch (error:Dynamic) {
						fixture.error = error;
						break;
					}
					closeQuietly(peer);
				}
			} catch (error:Dynamic) {
				fixture.error = error;
				fixture.ready.release();
			}

			closeQuietly(server);
			fixture.done.release();
		});

		if (!fixture.ready.wait(2.0)) {
			Assert.fail("Timed out waiting for HTTP fixture server");
		}
		if (fixture.error != null) {
			Assert.fail("HTTP fixture server failed to start: " + fixture.error);
		}
		return fixture;
	}

	private static function readRequest(peer:SysSocket):URLLoaderHttpFixtureRequest {
		var rawLines:Array<String> = [];
		var headers:Map<String, String> = new Map();
		var firstLine:String = peer.input.readLine();
		rawLines.push(firstLine);
		var firstParts = firstLine.split(" ");
		var target = firstParts.length > 1 ? firstParts[1] : "";
		var contentLength = 0;

		while (true) {
			var line = peer.input.readLine();
			rawLines.push(line);
			if (line == "") {
				break;
			}

			var separator = line.indexOf(":");
			if (separator > 0) {
				var key = StringTools.trim(line.substr(0, separator)).toLowerCase();
				var value = StringTools.trim(line.substr(separator + 1));
				headers.set(key, value);
				if (key == "content-length") {
					contentLength = Std.parseInt(value);
				}
			}
		}

		var body = contentLength > 0 ? peer.input.read(contentLength).toString() : "";
		return {
			raw: rawLines.join("\n") + "\n" + body,
			target: target,
			headers: headers,
			body: body
		};
	}

	private static function response(status:Int, reason:String, headers:Array<String>, body:String):String {
		return 'HTTP/1.1 ${status} ${reason}\r\n' + headers.join("\r\n") + "\r\n\r\n" + body;
	}

	private static function pumpUntil(done:Void->Bool, timeoutSeconds:Float = 2.0):Void {
		var runtime = CrossByte.current();
		var deadline = haxe.Timer.stamp() + timeoutSeconds;
		while (!done() && haxe.Timer.stamp() < deadline) {
			runtime.pump(1 / 60, 0);
			// Not Sys.sleep, which on eval now and then never returns, and which
			// would hang testClosingALoadInFlightEndsItQuietly in this loop.
			crossbyte.http.HTTPTestSupport.nap(0.001);
		}
	}

	private static function closeQuietly(socket:SysSocket):Void {
		try {
			if (socket != null) {
				socket.close();
			}
		} catch (_:Dynamic) {}
	}
}

#if target.threaded
/** Answers every HTTP/3 request at once, noting the thread each came on. */
private class ThreadRecordingBackend implements HTTPBackend {
	private final __lock:Mutex = new Mutex();
	private final __threads:Array<Thread> = [];
	private var __onRuntime:Int = 0;

	public function new() {}

	public function supports(version:HTTPVersion):Bool {
		return version == HTTPVersion.HTTP_3;
	}

	public function load(context:HTTPRequestContext):Void {
		var thread:Thread = Thread.current();
		var runtime:Null<CrossByte> = CrossByte.__currentOrNull();
		__lock.acquire();
		__threads.push(thread);
		if (runtime != null) {
			__onRuntime++;
		}
		__lock.release();

		context.onStatus(200);
		context.onHeaders(new Map());
		context.onComplete(Bytes.ofString("ok"));
	}

	public function onRuntime():Int {
		__lock.acquire();
		var count:Int = __onRuntime;
		__lock.release();
		return count;
	}

	public function distinctThreads():Int {
		__lock.acquire();
		var distinct:Array<Thread> = [];
		for (thread in __threads) {
			var seen:Bool = false;
			for (other in distinct) {
				if (other == thread) {
					seen = true;
					break;
				}
			}
			if (!seen) {
				distinct.push(thread);
			}
		}
		__lock.release();
		return distinct.length;
	}
}
#end

/** Answers every HTTP/3 request at once, keeping the header lines it was handed. */
private class HeaderRecordingBackend implements HTTPBackend {
	public var lines:Array<String> = null;

	public function new() {}

	public function supports(version:HTTPVersion):Bool {
		return version == HTTPVersion.HTTP_3;
	}

	public function load(context:HTTPRequestContext):Void {
		lines = context.headers.copy();
		context.onStatus(200);
		context.onHeaders(new Map());
		context.onComplete(Bytes.ofString("ok"));
	}
}

typedef URLLoaderHttpResult = {
	var complete:Bool;
	var error:String;
	var data:String;
	var statuses:Array<Int>;
	var progress:Array<{loaded:UInt, total:UInt}>;
	var responses:Array<HTTPStatusEvent>;
}

typedef URLLoaderHttpFixtureRequest = {
	var raw:String;
	var target:String;
	var headers:Map<String, String>;
	var body:String;
}

private class URLLoaderHttpFixture {
	public var port:Int = 0;
	public var requests:Array<URLLoaderHttpFixtureRequest> = [];
	public var error:Dynamic = null;
	public var ready:Lock = new Lock();
	public var done:Lock = new Lock();
	private var expectedRequests:Int;

	public function new(expectedRequests:Int) {
		this.expectedRequests = expectedRequests;
	}

	public function waitDone():Void {
		if (!done.wait(2.0)) {
			Assert.fail("Timed out waiting for HTTP fixture requests");
		}
		if (error != null) {
			Assert.fail("HTTP fixture request failed: " + error);
		}
		Assert.equals(expectedRequests, requests.length);
	}
}
