package crossbyte._internal.http;

import crossbyte.http.HTTPBackend;
import crossbyte.http.HTTPBackendRegistry;
import crossbyte.http.HTTPCancelToken;
import crossbyte.http.HTTPRequestContext;
import crossbyte.io.ByteArray;
import crossbyte.utils.CompressionAlgorithm;
import crossbyte.url.URL;
import crossbyte.sys.System;
import haxe.io.Bytes;
import haxe.exceptions.NotImplementedException;
import sys.net.Host;
import sys.net.Socket as SysSocket;
import sys.thread.Lock;
import sys.thread.Mutex;
import sys.thread.Thread;
import utest.Assert;
import crossbyte.test.Require;

@:access(crossbyte._internal.http.Http)
class HttpTest extends utest.Test {
	// ------------------------------------------------------ cancel token

	public function testCancelTokenRunsHandlersOnceAndOnlyOnce():Void {
		var token = new HTTPCancelToken();
		var runs:Int = 0;
		token.onCancel(() -> runs++);

		Assert.isFalse(token.cancelled);
		token.cancel();
		Assert.isTrue(token.cancelled);
		Assert.equals(1, runs);

		// Idempotent: a consumer that cancels twice, or two consumers sharing
		// one token, must not double-release whatever the handler frees.
		token.cancel();
		Assert.equals(1, runs);
	}

	public function testHandlerRegisteredAfterCancellationRunsImmediately():Void {
		var token = new HTTPCancelToken();
		token.cancel();

		// The race this closes: a request cancelled in the instant between a
		// backend accepting it and registering its handler would otherwise run
		// to completion with nothing left to stop it.
		var ran:Bool = false;
		token.onCancel(() -> ran = true);
		Assert.isTrue(ran);
	}

	public function testEveryHandlerRunsEvenWhenOneThrows():Void {
		var token = new HTTPCancelToken();
		var second:Bool = false;

		token.onCancel(() -> throw "handler exploded");
		token.onCancel(() -> second = true);
		token.cancel();

		// Each handler releases a different resource; one failing must not
		// strand the rest.
		Assert.isTrue(second);
	}

	public function testRemovedHandlerDoesNotRun():Void {
		var token = new HTTPCancelToken();
		var ran:Bool = false;
		var handler = () -> ran = true;

		token.onCancel(handler);
		token.removeHandler(handler);
		token.cancel();

		Assert.isFalse(ran);
	}

	/**
		A bound method handed back is the handler it was registered as. On
		eval and the jvm each mention of `object.method` is a new closure, so
		comparing by identity never found it: the handler stayed, and ran at
		a later cancel for a request that had long finished.
	**/
	public function testARemovedBoundMethodDoesNotRun():Void {
		var token = new HTTPCancelToken();
		var owner = new CancelCounter();

		token.onCancel(owner.stop);
		token.removeHandler(owner.stop);
		token.cancel();

		Assert.equals(0, owner.stops);
	}

	public function testValidateHttpVersionOnlyAllowsImplementedVersions():Void {
		Assert.isTrue(Http.validateHttpVersion(HttpVersion.HTTP_1));
		Assert.isTrue(Http.validateHttpVersion(HttpVersion.HTTP_1_1));
		Assert.isFalse(Http.validateHttpVersion(HttpVersion.HTTP_2));
		Assert.isFalse(Http.validateHttpVersion(HttpVersion.HTTP_3));
	}

	public function testVersionWithNoBackendAnywhereIsRejected():Void {
		HTTPBackendRegistry.clear();

		// HTTP/3 is QUIC and nothing here implements it, so it still fails at
		// construction. HTTP/2 no longer does, see the next case.
		Assert.raises(() -> new Http("http://example.com/", "GET", null, null, null, null, HttpVersion.HTTP_3), NotImplementedException);

		HTTPBackendRegistry.clear();
	}

	public function testHttp2RefusesLoudlyWhereItCannotWork():Void {
		HTTPBackendRegistry.clear();

		var error:String = null;
		var completed:Bool = false;

		// example.com is never contacted: on a target that cannot support
		// HTTP/2 the backend refuses before opening a socket, and on one that
		// can this asserts nothing about the refusal at all.
		var http = new Http("http://example.com/", "GET", null, null, null, null, HttpVersion.HTTP_2, 1000);
		http.onError = (message, ?data) -> error = message;
		http.onComplete = _ -> completed = true;

		#if eval
		http.load();

		// The failure mode this exists to prevent: eval raises socket errors
		// as native exceptions no catch can see, so a pooled connection would
		// look healthy right up until a peer reset killed its reader thread or
		// the process. Refused at the door instead, saying so.
		Require.notNull(error);
		Assert.isFalse(completed);
		Assert.isTrue(error.indexOf("not supported on this target") >= 0, "the message should say why: " + error);
		#else
		// Everywhere else the capability is simply claimed, and the rest of
		// this suite exercises it for real.
		Assert.isTrue(crossbyte.http.HTTP2Backend.isSupported);
		#end

		HTTPBackendRegistry.clear();
	}

	public function testHttp2WorksWithoutRegisteringAnything():Void {
		HTTPBackendRegistry.clear();

		// The bundled backend registers itself on demand. Requiring a caller
		// to register a class that ships in this library was a chore, not a
		// choice, and the error it produced read as "unsupported".
		var http = new Http("http://example.com/", "GET", null, null, null, null, HttpVersion.HTTP_2);
		Assert.notNull(http);
		Assert.isTrue(HTTPBackendRegistry.isRegistered(HttpVersion.HTTP_2));

		HTTPBackendRegistry.clear();
	}

	public function testAutoRegistrationCanBeTurnedOff():Void {
		HTTPBackendRegistry.clear();
		HTTPBackendRegistry.autoRegisterBundled = false;

		// The escape hatch for a program that wants only backends it chose.
		Assert.raises(() -> new Http("http://example.com/", "GET", null, null, null, null, HttpVersion.HTTP_2), NotImplementedException);

		HTTPBackendRegistry.autoRegisterBundled = true;
		HTTPBackendRegistry.clear();
	}

	public function testRegisteredBackendAllowsHttp2ConstructionAndLoad():Void {
		HTTPBackendRegistry.clear();
		var backend = new FakeHTTP2Backend();
		HTTPBackendRegistry.register(backend);
		var statusCodes:Array<Int> = [];
		var progress:Array<{loaded:Int, total:Int}> = [];
		var completed:Bytes = null;
		var error:String = null;

		var http = new Http("https://example.com/resource", "POST", ["X-Test: yes"], {page: 1}, "text/plain", "body", HttpVersion.HTTP_2, 5000,
			"TestAgent", false);
		http.onStatus = code -> statusCodes.push(code);
		http.onProgress = (loaded:Int, total:Int) -> progress.push({loaded: loaded, total: total});
		http.onComplete = data -> completed = data;
		http.onError = (message:String, ?data:Bytes) -> error = message;

		http.load();

		Assert.isNull(error);
		Require.notNull(completed);
		Assert.equals("ok", completed.toString());
		Assert.same([200], statusCodes);
		Assert.equals(2, progress[progress.length - 1].loaded);
		Assert.equals(2, progress[progress.length - 1].total);
		Assert.notNull(backend.lastContext);
		Assert.equals("https://example.com/resource", backend.lastContext.url);
		Assert.equals("POST", backend.lastContext.method);
		Assert.equals(HttpVersion.HTTP_2, backend.lastContext.version);
		Assert.equals("X-Test: yes", backend.lastContext.headers[0]);
		Assert.equals("text/plain", backend.lastContext.contentType);
		Assert.equals("body", backend.lastContext.data);
		Assert.equals(5000, backend.lastContext.timeout);
		Assert.equals("TestAgent", backend.lastContext.userAgent);
		Assert.isFalse(backend.lastContext.followRedirects);
		Assert.notNull(backend.lastContext.onHeaders);

		HTTPBackendRegistry.clear();
	}

	public function testRegisteredBackendReportsResponseHeaders():Void {
		HTTPBackendRegistry.clear();
		HTTPBackendRegistry.register(new FakeHTTP2Backend());

		var reported:Array<Map<String, String>> = [];
		var http = new Http("https://example.com/resource", "GET", null, null, null, null, HttpVersion.HTTP_2);
		http.onHeaders = headers -> reported.push(headers);
		http.load();

		// Without this a backend could parse a response and have no way to
		// hand any of it back but the body.
		Assert.equals(1, reported.length);
		Assert.equals("text/plain", reported[0].get("content-type"));
		Assert.equals("2", reported[0].get("content-length"));

		HTTPBackendRegistry.clear();
	}

	public function testMostRecentlyRegisteredBackendWins():Void {
		HTTPBackendRegistry.clear();
		var first = new FakeHTTP2Backend("first");
		var second = new FakeHTTP2Backend("second");

		HTTPBackendRegistry.register(first);
		HTTPBackendRegistry.register(second);

		var http = new Http("https://example.com/", "GET", null, null, null, null, HttpVersion.HTTP_2);
		var completed:Bytes = null;
		http.onComplete = data -> completed = data;

		http.load();

		Require.notNull(completed);
		Assert.equals("second", completed.toString());
		Assert.isNull(first.lastContext);
		Assert.notNull(second.lastContext);

		HTTPBackendRegistry.clear();
	}

	public function testUnregisteringACustomBackendFallsBackToTheBundledOne():Void {
		HTTPBackendRegistry.clear();
		var backend = new FakeHTTP2Backend();

		HTTPBackendRegistry.register(backend);
		Assert.isTrue(HTTPBackendRegistry.isRegistered(HttpVersion.HTTP_2));
		// Registered last, so it wins over anything registered on demand.
		Assert.equals(backend, HTTPBackendRegistry.resolve(HttpVersion.HTTP_2));

		Assert.isTrue(HTTPBackendRegistry.unregister(backend));

		// Support does not disappear with it: HTTP/2 is a capability of the
		// library, and removing one implementation of it leaves the bundled
		// one. Removing the *last* backend used to mean losing the protocol.
		Assert.isTrue(HTTPBackendRegistry.isRegistered(HttpVersion.HTTP_2));
		Assert.isFalse(backend == HTTPBackendRegistry.resolve(HttpVersion.HTTP_2));

		HTTPBackendRegistry.clear();
	}

	public function testConcurrentFirstRequestsAllFindTheBundledBackend():Void {
		// The bundled backend's flag was set under the lock and the backend
		// added only after the lock was let go: a thread arriving in between
		// found the flag set and no backend, and its request failed with "HTTP/2
		// has no registered HTTPBackend". Concurrent first HTTP/2 requests
		// failed 5 of 6 that way on the jvm, and the http2 sample 3 of 3.
		var workers:Int = 8;
		var rounds:Int = 150;
		var misses:Int = 0;
		var count:Mutex = new Mutex();
		var go:Array<Lock> = [for (_ in 0...workers) new Lock()];
		var done:Lock = new Lock();

		for (w in 0...workers) {
			var mine:Lock = go[w];
			Thread.create(() -> {
				for (_ in 0...rounds) {
					mine.wait();
					if (HTTPBackendRegistry.resolve(HttpVersion.HTTP_2) == null) {
						count.acquire();
						misses++;
						count.release();
					}
					done.release();
				}
			});
		}

		var finished:Bool = true;
		for (_ in 0...rounds) {
			HTTPBackendRegistry.clear();
			for (lock in go) {
				lock.release();
			}
			for (_ in 0...workers) {
				if (!done.wait(10.0)) {
					finished = false;
				}
			}
			if (!finished) {
				break;
			}
		}

		Assert.isTrue(finished, "a worker never came back");
		Assert.equals(0, misses, misses + " of " + (workers * rounds) + " first lookups found no HTTP/2 backend");
		HTTPBackendRegistry.clear();
	}

	public function testLoadReportsResponseHeadersAndJoinsRepeatedFields():Void {
		var fixture = serveOnce("HTTP/1.1 200 OK\r\n"
			+ "Content-Length: 2\r\n"
			+ "X-Multi: a\r\n"
			+ "X-Multi: b\r\n"
			+ "Set-Cookie: one=1\r\n"
			+ "Set-Cookie: two=2\r\n"
			+ "\r\nhi");
		var reported:Array<Map<String, String>> = [];

		var http = new Http('http://127.0.0.1:${fixture.port}/headers');
		http.onHeaders = headers -> reported.push(headers);
		http.load();
		fixture.waitDone();

		Assert.equals(1, reported.length);
		var headers = reported[0];

		// Lowercased on the way in, so a caller never has to guess the casing
		// a server chose.
		Assert.equals("2", headers.get("content-length"));

		// Repeated ordinary fields join with ", "...
		Assert.equals("a, b", headers.get("x-multi"));

		// ...but set-cookie joins with a newline: its values contain commas of
		// their own, so a comma join could not be undone.
		// Built from a char code rather than written as a literal newline in
		// the source: a literal one carries the file's line ending, so the
		// expected value silently becomes CRLF on a CRLF checkout.
		Assert.equals("one=1" + String.fromCharCode(10) + "two=2", headers.get("set-cookie"));
	}

	public function testAResponseHeaderSectionPastTheLimitIsRefused():Void {
		// The client read header lines for as long as the server sent them;
		// the server holds a request's block to 64 KB, and a response is
		// held to the same now. About 70 KB of lines here: a little past the
		// limit, and small enough to sit in the socket's buffers whole, so the
		// fixture's write finishes whatever the client does next.
		var fill:StringBuf = new StringBuf();
		for (i in 0...1400) {
			fill.add("X-Fill-" + i + ": 0123456789012345678901234567890123456789\r\n");
		}
		__expectRefusal("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n" + fill.toString() + "\r\nok", "exceeded");
	}

	public function testAHeaderLineThatNeverEndsIsRefused():Void {
		// One line, read into memory for as long as it went on. A line with no
		// colon was then ignored, so the response completed as though nothing
		// had happened.
		__expectRefusal("HTTP/1.1 200 OK\r\n" + __repeat("a".code, 70 * 1024) + "\r\nContent-Length: 2\r\n\r\nok", "exceeded");
	}

	public function testEndlessInterimResponsesAreRefused():Void {
		// Each 1xx block was thrown away and the next read, for as long as they
		// came, and while they kept coming the idle timeout never fired.
		var interim:StringBuf = new StringBuf();
		for (_ in 0...3000) {
			interim.add("HTTP/1.1 100 Continue\r\n\r\n");
		}
		__expectRefusal(interim.toString() + "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok", "exceeded");
	}

	public function testAChunkLineThatNeverEndsIsRefused():Void {
		// A chunk extension is ignored, so one that went on for ever was read
		// into memory and then dropped, and the body completed.
		__expectRefusal("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5;" + __repeat("e".code, 8 * 1024) + "\r\nhello\r\n0\r\n\r\n", "limit");
	}

	public function testEndlessTrailersAreRefused():Void {
		var trailers:StringBuf = new StringBuf();
		for (i in 0...1400) {
			trailers.add("X-Trailer-" + i + ": 012345678901234567890123456789012345678\r\n");
		}
		__expectRefusal("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nok\r\n0\r\n" + trailers.toString() + "\r\n", "limit");
	}

	/** Serves `response` and expects the load to fail with a message holding `expected`. */
	private static function __expectRefusal(response:String, expected:String):Void {
		var fixture = serveOnce(response);
		var http = new Http('http://127.0.0.1:${fixture.port}/bounded');
		var completed:Null<Bytes> = null;
		var failure:Null<String> = null;
		http.onComplete = data -> completed = data;
		http.onError = (message, ?data) -> failure = message;
		http.load();
		fixture.waitDone();

		Assert.isNull(completed, "the response was taken whole");
		Require.notNull(failure);
		Assert.isTrue(failure.indexOf(expected) >= 0, failure);
	}

	/** `count` copies of one ASCII character, in linear time. */
	private static function __repeat(code:Int, count:Int):String {
		var bytes:Bytes = Bytes.alloc(count);
		bytes.fill(0, count, code);
		return bytes.toString();
	}

	public function testLoadReportsOnlyTheFinalHeaderBlockAfterAnInformationalResponse():Void {
		var fixture = serveOnce("HTTP/1.1 100 Continue\r\n\r\n" + "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nX-Final: yes\r\n\r\nhi");
		var reported:Array<Map<String, String>> = [];
		var completed:Bytes = null;

		var http = new Http('http://127.0.0.1:${fixture.port}/continue');
		http.onHeaders = headers -> reported.push(headers);
		http.onComplete = data -> completed = data;
		http.load();
		fixture.waitDone();

		// A 1xx block is discarded and re-read, so the caller sees one header
		// block rather than an interim one it would have to know to ignore.
		Assert.equals(1, reported.length);
		Assert.equals("yes", reported[0].get("x-final"));
		Require.notNull(completed);
		Assert.equals("hi", completed.toString());
	}

	public function testResolveLocationHandlesAbsoluteAndRootRelativeUrls():Void {
		var base = new URL("http://example.com/dir/page");

		Assert.equals("https://other.example/path?q=1", Http.__resolveLocation(base, "https://other.example/path?q=1"));
		Assert.equals("http://example.com/root?x=1", Http.__resolveLocation(base, "/root?x=1"));
	}

	public function testResolveLocationKeepsNonDefaultPortAndRelativeDirectory():Void {
		var base = new URL("http://example.com:8080/dir/page");

		Assert.equals("http://example.com:8080/dir/next", Http.__resolveLocation(base, "next"));
		Assert.equals("http://example.com:8080/dir/sub/next?x=1", Http.__resolveLocation(base, "sub/next?x=1"));
	}

	public function testResolveLocationBracketsAnIpv6HostAndKeepsASchemesOtherPort():Void {
		// The host went in bare, so a relative redirect from [::1]:8080 named
		// http://::1:8080/..., which is not a URL, and the redirect failed.
		var v6 = new URL("http://[::1]:8080/dir/page");
		Assert.equals("http://[::1]:8080/dir/next", Http.__resolveLocation(v6, "next"));
		Assert.equals("http://[::1]:8080/root", Http.__resolveLocation(v6, "/root"));
		Assert.equals("https://[2001:db8::1]/x", Http.__resolveLocation(new URL("https://[2001:db8::1]/a"), "/x"));

		// The port was dropped for 80 and 443 whatever the scheme, so a
		// redirect from http://host:443/ went to port 80.
		Assert.equals("http://example.com:443/b", Http.__resolveLocation(new URL("http://example.com:443/a"), "b"));
		Assert.equals("https://example.com:80/b", Http.__resolveLocation(new URL("https://example.com:80/a"), "b"));
	}

	public function testTheHostHeaderBracketsAnIpv6Literal():Void {
		// URL takes the brackets off, and the client put the host back as it
		// was: Host: ::1:port, which no server can split.
		if (!__ipv6Loopback()) {
			Assert.pass("no IPv6 loopback on this machine");
			return;
		}

		var fixture = serveOnce("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok", "::1");
		var http = new Http('http://[::1]:${fixture.port}/v6');
		var completed:Null<Bytes> = null;
		http.onComplete = data -> completed = data;
		http.onError = (message, ?data) -> Assert.fail("request failed: " + message);
		http.load();
		fixture.waitDone();

		Require.notNull(completed);
		Assert.isTrue(fixture.request.indexOf('Host: [::1]:${fixture.port}') >= 0, fixture.request);
	}

	/** Whether a socket can listen on the IPv6 loopback here. */
	private static function __ipv6Loopback():Bool {
		var probe = new SysSocket();
		try {
			probe.bind(new Host("::1"), 0);
			probe.close();
			return true;
		} catch (_:Dynamic) {
			closeQuietly(probe);
			return false;
		}
	}

	public function testBuildQueryEncodesScalarsArraysAndNestedObjects():Void {
		var http = new Http("http://example.com/");
		var query = http.__buildQuery({
			search: "hello world",
			page: 2,
			active: true,
			tags: ["one", "two"],
			filter: {
				kind: "exact",
				limit: 3
			},
			empty: null
		});
		var parts = query.split("&");

		Assert.isTrue(parts.indexOf("search=hello%20world") >= 0);
		Assert.isTrue(parts.indexOf("page=2") >= 0);
		Assert.isTrue(parts.indexOf("active=true") >= 0);
		Assert.isTrue(parts.indexOf("tags%5B%5D=one") >= 0);
		Assert.isTrue(parts.indexOf("tags%5B%5D=two") >= 0);
		Assert.isTrue(parts.indexOf("filter%5Bkind%5D=exact") >= 0);
		Assert.isTrue(parts.indexOf("filter%5Blimit%5D=3") >= 0);
		Assert.equals(-1, parts.indexOf("empty=null"));
	}

	public function testLoadReadsFixedLengthBodyAndSendsDefaultHeaders():Void {
		var fixture = serveOnce("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello");
		var http = new Http('http://127.0.0.1:${fixture.port}/fixed?existing=1');
		var statusCodes:Array<Int> = [];
		var progress:Array<{loaded:Int, total:Int}> = [];
		var completed:Bytes = null;
		var error:String = null;

		http.onStatus = code -> statusCodes.push(code);
		http.onProgress = (loaded:Int, total:Int) -> progress.push({loaded: loaded, total: total});
		http.onComplete = data -> completed = data;
		http.onError = (message:String, ?data:Bytes) -> error = message;

		http.load();
		fixture.waitDone();

		Assert.isNull(error);
		Require.notNull(completed);
		Assert.equals("hello", completed.toString());
		Assert.same([200], statusCodes);
		Assert.equals(0, progress[0].loaded);
		Assert.equals(5, progress[0].total);
		Assert.equals(5, progress[progress.length - 1].loaded);
		Assert.equals(5, progress[progress.length - 1].total);
		Assert.isTrue(fixture.request.indexOf("GET /fixed?existing=1 HTTP/1.1") == 0);
		Assert.isTrue(fixture.request.indexOf("Host: 127.0.0.1:" + fixture.port) >= 0);
		// Kept for the next request, except on eval, which keeps none.
		Assert.isTrue(fixture.request.indexOf(#if eval "Connection: close" #else "Connection: keep-alive" #end) >= 0);
		Assert.isTrue(fixture.request.indexOf("Accept-Encoding: identity") >= 0);
	}

	public function testLoadReadsChunkedBody():Void {
		var fixture = serveOnce("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6;ext=1\r\n world\r\n0\r\n\r\n");
		var http = new Http('http://127.0.0.1:${fixture.port}/chunked');
		var completed:Bytes = null;
		var progress:Array<{loaded:Int, total:Int}> = [];

		http.onProgress = (loaded:Int, total:Int) -> progress.push({loaded: loaded, total: total});
		http.onComplete = data -> completed = data;

		http.load();
		fixture.waitDone();

		Require.notNull(completed);
		Assert.equals("hello world", completed.toString());
		Assert.equals(-1, progress[0].total);
		Assert.equals(11, progress[progress.length - 1].loaded);
		Assert.equals(-1, progress[progress.length - 1].total);
	}

	public function testChunkSizeWithTrailingGarbageIsRejected():Void {
		// Std.parseInt stops at the first character it cannot use, so this
		// size line used to read as 5 and the body came back as "hello",
		// this client agreeing with nobody about where the chunk ended.
		var fixture = serveOnce("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5 junk\r\nhello\r\n0\r\n\r\n");
		var http = new Http('http://127.0.0.1:${fixture.port}/garbage');
		var completed:Bytes = null;
		var failure:String = null;

		http.onComplete = data -> completed = data;
		http.onError = (message, ?data) -> failure = message;

		http.load();
		fixture.waitDone();

		Assert.isNull(completed);
		Require.notNull(failure, "a malformed chunk size was accepted");
		Assert.isTrue(failure.indexOf("chunk size") >= 0, failure);
	}

	public function testChunkSizeTooLargeForAnIntIsRejected():Void {
		// Eight hex digits is more than Int holds, and Std.parseInt says so
		// four different ways: -1 on eval and cpp, a thrown
		// NumberFormatException on jvm, and 4294967295 on node, neither
		// null nor negative, so node walked straight past the guard.
		var fixture = serveOnce("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nFFFFFFFF\r\n");
		var http = new Http('http://127.0.0.1:${fixture.port}/huge');
		var completed:Bytes = null;
		var failure:String = null;

		http.onComplete = data -> completed = data;
		http.onError = (message, ?data) -> failure = message;

		http.load();
		fixture.waitDone();

		Assert.isNull(completed);
		Require.notNull(failure, "an unrepresentable chunk size was accepted");
	}

	public function testContentLengthPastAnIntIsNotALength():Void {
		// The client reads the field the way the server does. Std.parseInt
		// took 4294967296 as 0 on Linux and macOS native, an empty body,
		// reported as a complete download, as 2147483647 on Windows, and
		// threw on the jvm.
		var http = new Http("http://127.0.0.1/");
		Assert.isNull(http.__parseContentLength("4294967296"));
		Assert.isNull(http.__parseContentLength("4294967301"));
		Assert.isNull(http.__parseContentLength("2147483648"));
		Assert.isNull(http.__parseContentLength("+5"));
		Assert.isNull(http.__parseContentLength("5, 6"));
		Assert.equals(5, http.__parseContentLength("5, 5"));
		Assert.equals(2147483647, http.__parseContentLength("2147483647"));
	}

	public function testAStatusLineCarriesExactlyThreeDigits():Void {
		// Was (\d+) through Std.parseInt: "HTTP/1.1 4294967496 OK" read as
		// 200 on Linux native.
		Assert.equals(200, Http.__parseStatusLine("HTTP/1.1 200 OK"));
		Assert.equals(200, Http.__parseStatusLine("HTTP/1.1 200"));
		Assert.equals(404, Http.__parseStatusLine("HTTP/1.0 404 Not Found"));
		Assert.equals(503, Http.__parseStatusLine("HTTP/1.1  503\tBusy"));
		Assert.equals(-1, Http.__parseStatusLine("HTTP/1.1 4294967496 OK"));
		Assert.equals(-1, Http.__parseStatusLine("HTTP/1.1 2000 OK"));
		Assert.equals(-1, Http.__parseStatusLine("HTTP/1.1 20 OK"));
		Assert.equals(-1, Http.__parseStatusLine("HTTP/1.1 099 OK"));
		Assert.equals(-1, Http.__parseStatusLine("HTTP/1.1 +20 OK"));
		Assert.equals(-1, Http.__parseStatusLine("HTTP/1.1 200OK"));
		Assert.equals(-1, Http.__parseStatusLine("HTTP/1.1"));
		Assert.equals(-1, Http.__parseStatusLine("HTTP/1 200 OK"));
		Assert.equals(-1, Http.__parseStatusLine("HTTX/1.1 200 OK"));
		Assert.equals(-1, Http.__parseStatusLine("ICY 200 OK"));
	}

	public function testAResponseDeclaringMoreThanAnIntIsAnError():Void {
		var fixture = serveOnce("HTTP/1.1 200 OK\r\nContent-Length: 4294967301\r\n\r\nhello");
		var http = new Http('http://127.0.0.1:${fixture.port}/huge');
		var completed:Bytes = null;
		var failure:String = null;

		http.onComplete = data -> completed = data;
		http.onError = (message, ?data) -> failure = message;

		http.load();
		fixture.waitDone();

		Assert.isNull(completed, "a response with an impossible length completed");
		Require.notNull(failure, "an impossible Content-Length was accepted");
		Assert.isTrue(failure.indexOf("Content-Length") >= 0, failure);
	}

	public function testChunkedThatIsNotTheFinalCodingIsNotChunkDecoded():Void {
		// RFC 9112 6.1: chunked frames the body only when it is the last
		// coding applied. With something after it the body is not chunk
		// framed at all, and the length comes from the connection closing.
		// Reading it as chunks took the body's first line for a chunk size.
		var fixture = serveOnce("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked, gzip\r\n\r\nnot chunk framed");
		var http = new Http('http://127.0.0.1:${fixture.port}/notfinal');
		var completed:Bytes = null;
		var failure:String = null;

		http.onComplete = data -> completed = data;
		http.onError = (message, ?data) -> failure = message;

		http.load();
		fixture.waitDone();

		Assert.isNull(failure);
		Require.notNull(completed);
		Assert.equals("not chunk framed", completed.toString());
	}

	public function testAGzipBombIsAbandonedRatherThanDecoded():Void {
		// A megabyte of zeros is about a kilobyte on the wire, so
		// Content-Length and the chunked ceiling both see a small response.
		// Neither of them describes what it becomes.
		var previous:Int = Http.MAX_DECOMPRESSED_BODY_SIZE;
		Http.MAX_DECOMPRESSED_BODY_SIZE = 64 * 1024;

		try {
			var encoded = new ByteArray();
			encoded.length = 1024 * 1024;
			encoded.compress(CompressionAlgorithm.GZIP);

			var fixture = serveOnceWithBody("HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: " + encoded.length + "\r\n\r\n", encoded);
			var http = new Http('http://127.0.0.1:${fixture.port}/bomb');
			var completed:Bytes = null;
			var failure:String = null;

			http.onComplete = data -> completed = data;
			http.onError = (message, ?data) -> failure = message;

			http.load();
			fixture.waitDone();

			Assert.isNull(completed);
			var error:String = Require.notNull(failure, "a gzip bomb decoded to the end");
			Assert.isTrue(error.indexOf("Failed to decode response body") == 0, error);
		} catch (e:Dynamic) {
			Assert.fail("bomb test failed: " + Std.string(e));
		}

		Http.MAX_DECOMPRESSED_BODY_SIZE = previous;
	}

	public function testABrotliBombIsAbandonedRatherThanDecoded():Void {
		// The same shape as the gzip case, against the coding the modern web
		// actually sends. Brotli decodes through a ported codec that returns
		// everything at once, so the ceiling had to go down into the function
		// every decoded byte passes through rather than measuring the result.
		var previous:Int = Http.MAX_DECOMPRESSED_BODY_SIZE;
		Http.MAX_DECOMPRESSED_BODY_SIZE = 16 * 1024;

		try {
			var encoded = new ByteArray();
			encoded.length = 128 * 1024;
			encoded.compress(CompressionAlgorithm.BROTLI);

			var fixture = serveOnceWithBody("HTTP/1.1 200 OK\r\nContent-Encoding: br\r\nContent-Length: " + encoded.length + "\r\n\r\n", encoded);
			var http = new Http('http://127.0.0.1:${fixture.port}/brbomb');
			var completed:Bytes = null;
			var failure:String = null;

			http.onComplete = data -> completed = data;
			http.onError = (message, ?data) -> failure = message;

			http.load();
			fixture.waitDone();

			Assert.isNull(completed);
			var error:String = Require.notNull(failure, "a brotli bomb decoded to the end");
			Assert.isTrue(error.indexOf("Failed to decode response body") == 0, error);
		} catch (e:Dynamic) {
			Assert.fail("brotli bomb test failed: " + Std.string(e));
		}

		Http.MAX_DECOMPRESSED_BODY_SIZE = previous;
	}

	public function testStackedContentCodingsAreRefused():Void {
		// Codings multiply, so three of them is three ratios on top of each
		// other. Refused before anything is decoded, which is why the body
		// below does not have to be genuinely triple-encoded.
		var fixture = serveOnce("HTTP/1.1 200 OK\r\nContent-Encoding: gzip, gzip, gzip\r\nContent-Length: 4\r\n\r\nxxxx");
		var http = new Http('http://127.0.0.1:${fixture.port}/stacked');
		var completed:Bytes = null;
		var failure:String = null;

		http.onComplete = data -> completed = data;
		http.onError = (message, ?data) -> failure = message;

		http.load();
		fixture.waitDone();

		Assert.isNull(completed);
		var error:String = Require.notNull(failure, "three stacked codings were accepted");
		Assert.isTrue(error.indexOf("content codings") > 0, error);
	}

	public function testLoadDecodesGzipContentEncoding():Void {
		var encoded = new ByteArray();
		encoded.writeUTFBytes("hello from gzip");
		encoded.compress(CompressionAlgorithm.GZIP);

		var fixture = serveOnceWithBody("HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: " + encoded.length + "\r\n\r\n", encoded);
		var completed:Bytes = null;

		var http = new Http('http://127.0.0.1:${fixture.port}/encoded');
		http.onComplete = data -> completed = data;

		http.load();
		fixture.waitDone();

		Require.notNull(completed);
		Assert.equals("hello from gzip", completed.toString());
	}

	public function testLoadDecodesLz4ContentEncoding():Void {
		var encoded = new ByteArray();
		encoded.writeUTFBytes("hello from lz4");
		encoded.compress(CompressionAlgorithm.LZ4);

		var fixture = serveOnceWithBody("HTTP/1.1 200 OK\r\nContent-Encoding: lz4\r\nContent-Length: " + encoded.length + "\r\n\r\n", encoded);
		var completed:Bytes = null;

		var http = new Http('http://127.0.0.1:${fixture.port}/encoded');
		http.onComplete = data -> completed = data;

		http.load();
		fixture.waitDone();

		Require.notNull(completed);
		Assert.equals("hello from lz4", completed.toString());
	}

	public function testLoadDecodesBrotliContentEncoding():Void {
		var encoded = new ByteArray();
		encoded.writeUTFBytes("hello from brotli");
		encoded.compress(CompressionAlgorithm.BROTLI);

		var fixture = serveOnceWithBody("HTTP/1.1 200 OK\r\nContent-Encoding: br\r\nContent-Length: " + encoded.length + "\r\n\r\n", encoded);
		var completed:Bytes = null;

		var http = new Http('http://127.0.0.1:${fixture.port}/encoded');
		http.onComplete = data -> completed = data;

		http.load();
		fixture.waitDone();

		Require.notNull(completed);
		Assert.equals("hello from brotli", completed.toString());
	}

	public function testLoadRejectsUnsupportedContentEncoding():Void {
		var fixture = serveOnce("HTTP/1.1 200 OK\r\nContent-Encoding: zstd\r\nContent-Length: 5\r\n\r\nhello");
		var http = new Http('http://127.0.0.1:${fixture.port}/encoded');
		var message:String = null;
		var errorData:Bytes = null;

		http.onError = function(error:String, ?data:Bytes):Void {
			message = error;
			errorData = data;
		};

		http.load();
		fixture.waitDone();

		Assert.equals("Unsupported content encoding: zstd", message);
		Require.notNull(errorData);
		Assert.equals("hello", errorData.toString());
	}

	public function testHttpErrorBodyIsDecodedBeforeOnError():Void {
		var encoded = new ByteArray();
		encoded.writeUTFBytes("compressed missing");
		encoded.compress(CompressionAlgorithm.GZIP);

		var fixture = serveOnceWithBody("HTTP/1.1 404 Not Found\r\nContent-Encoding: gzip\r\nContent-Length: " + encoded.length + "\r\n\r\n", encoded);
		var message:String = null;
		var errorData:Bytes = null;

		var http = new Http('http://127.0.0.1:${fixture.port}/missing');
		http.onError = function(msg:String, ?data:Bytes):Void {
			message = msg;
			errorData = data;
		};

		http.load();
		fixture.waitDone();

		Assert.equals("HTTP error 404", message);
		Require.notNull(errorData);
		Assert.equals("compressed missing", errorData.toString());
	}

	public function testLoadReportsHttpErrorsWithResponseData():Void {
		var fixture = serveOnce("HTTP/1.1 404 Not Found\r\nContent-Length: 7\r\n\r\nmissing");
		var http = new Http('http://127.0.0.1:${fixture.port}/missing');
		var completeCalled = false;
		var errorMessage:String = null;
		var errorData:Bytes = null;

		http.onComplete = _ -> completeCalled = true;
		http.onError = (message:String, ?data:Bytes) -> {
			errorMessage = message;
			errorData = data;
		}

		http.load();
		fixture.waitDone();

		Assert.isFalse(completeCalled);
		Assert.equals("HTTP error 404", errorMessage);
		Require.notNull(errorData);
		Assert.equals("missing", errorData.toString());
	}

	public function testLoadSerializesPostFormData():Void {
		var fixture = serveOnce("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n");
		var http = new Http('http://127.0.0.1:${fixture.port}/submit', "POST", ["X-Test: yes"], {
			field: "a b",
			ok: false
		});
		var completed:Bytes = null;
		var error:String = null;

		http.onComplete = data -> completed = data;
		http.onError = (message:String, ?data:Bytes) -> error = message;

		http.load();
		fixture.waitDone();

		Assert.isNull(error);
		Require.notNull(completed);
		Assert.equals(0, completed.length);
		Assert.isTrue(fixture.request.indexOf("POST /submit HTTP/1.1") == 0);
		Assert.isTrue(fixture.request.indexOf("X-Test: yes") >= 0);
		Assert.isTrue(fixture.request.indexOf("Content-Type: application/x-www-form-urlencoded; charset=utf-8") >= 0);
		Assert.isTrue(fixture.request.indexOf("content-length: ") >= 0);
		Assert.isTrue(fixture.request.indexOf("field=a%20b") >= 0);
		Assert.isTrue(fixture.request.indexOf("ok=false") >= 0);
	}

	private static function serveOnce(response:String, address:String = "127.0.0.1"):OneShotHttpServer {
		var fixture = new OneShotHttpServer();
		Thread.create(() -> {
			var server = new SysSocket();
			var peer:SysSocket = null;
			try {
				server.bind(new Host(address), 0);
				server.listen(1);
				fixture.port = server.host().port;
				fixture.ready.release();

				peer = server.accept();
				peer.setTimeout(2.0);
				fixture.request = readRequest(peer);
				peer.output.writeString(response);
				peer.output.flush();
			} catch (e:Dynamic) {
				fixture.error = e;
				fixture.ready.release();
			}

			closeQuietly(peer);
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

	public function testASessionCookieSurvivesARedirect():Void {
		// The case this exists for. `followRedirects` is on by default, so a
		// sign-in that answers 302 with a session cookie used to lose it: the
		// cookie was read off the wire and dropped with the rest of the
		// response headers when the next hop reset them, and the page you
		// landed on saw an anonymous request.
		var fixture = serveTwice("HTTP/1.1 302 Found\r\nLocation: /landing\r\nSet-Cookie: session=abc123; Path=/; HttpOnly\r\nContent-Length: 0\r\n\r\n",
			"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok");

		var http = new Http('http://127.0.0.1:${fixture.port}/signin');
		http.onError = (message, ?data) -> Assert.fail("request failed: " + message);
		http.load();
		fixture.waitDone();

		Assert.equals(2, fixture.requests.length, "the redirect was not followed");
		Assert.isTrue(fixture.requests[0].toLowerCase().indexOf("cookie:") < 0, "a cookie was sent before anything set one");
		Assert.isTrue(fixture.requests[1].indexOf("Cookie: session=abc123") >= 0,
			"the session cookie did not survive the redirect:\n" + fixture.requests[1]);
	}

	public function testManageCookiesOffSendsNothingBack():Void {
		var fixture = serveTwice("HTTP/1.1 302 Found\r\nLocation: /landing\r\nSet-Cookie: session=abc123\r\nContent-Length: 0\r\n\r\n",
			"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok");

		var http = new Http('http://127.0.0.1:${fixture.port}/signin', "GET", null, null, null, null, HttpVersion.HTTP_1_1, 10000, "CrossByte", true,
			false);
		http.onError = (message, ?data) -> Assert.fail("request failed: " + message);
		http.load();
		fixture.waitDone();

		Assert.equals(2, fixture.requests.length, "the redirect was not followed");
		Assert.isTrue(fixture.requests[1].toLowerCase().indexOf("cookie:") < 0,
			"a cookie went out with manageCookies off:\n" + fixture.requests[1]);
	}

	public function testCredentialsDoNotFollowARedirectToAnotherOrigin():Void {
		// A 302 to another origin used to be followed with every header the
		// caller wrote: the auditor's server received Authorization: Bearer
		// sk-live-secret. The next origin gets the request without them.
		var elsewhere = serveOnce("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok");
		var origin = serveOnce('HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:${elsewhere.port}/landing\r\nContent-Length: 0\r\n\r\n');

		var http = new Http('http://127.0.0.1:${origin.port}/start', "GET",
			["Authorization: Bearer sk-live-secret", "Proxy-Authorization: Basic cHJveHk=", "Cookie: sid=caller-set", "X-Trace: t-1"]);
		var completed:Bytes = null;
		http.onComplete = data -> completed = data;
		http.onError = (message, ?data) -> Assert.fail("request failed: " + message);
		http.load();
		origin.waitDone();
		elsewhere.waitDone();

		Require.notNull(completed, "the redirect was not followed");
		Assert.isTrue(origin.request.indexOf("sk-live-secret") >= 0, "the origin itself did not get the credentials");
		Assert.isTrue(elsewhere.request.indexOf("sk-live-secret") < 0, "Authorization reached another origin:\n" + elsewhere.request);
		Assert.isTrue(elsewhere.request.indexOf("cHJveHk=") < 0, "Proxy-Authorization reached another origin");
		Assert.isTrue(elsewhere.request.indexOf("sid=caller-set") < 0, "a caller's Cookie reached another origin");
		Assert.isTrue(elsewhere.request.indexOf("X-Trace: t-1") >= 0, "an ordinary header was dropped as well:\n" + elsewhere.request);
	}

	public function testCredentialsFollowARedirectWithinTheOrigin():Void {
		var fixture = serveTwice("HTTP/1.1 302 Found\r\nLocation: /landing\r\nContent-Length: 0\r\n\r\n", "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok");

		var http = new Http('http://127.0.0.1:${fixture.port}/start', "GET", ["Authorization: Bearer same-origin"]);
		http.onError = (message, ?data) -> Assert.fail("request failed: " + message);
		http.load();
		fixture.waitDone();

		Assert.equals(2, fixture.requests.length, "the redirect was not followed");
		Assert.isTrue(fixture.requests[1].indexOf("Bearer same-origin") >= 0, "credentials were dropped within one origin");
	}

	public function testRedirectsOnlyGoWhereTheyAreAllowedTo():Void {
		// https to http gives the rest of the exchange away in the clear, so it
		// takes the caller's say-so; and only http and https are followed.
		Assert.notNull(Http.__redirectRefusal(new URL("https://example.com/"), new URL("http://example.com/"), false));
		Assert.isNull(Http.__redirectRefusal(new URL("https://example.com/"), new URL("http://example.com/"), true));
		Assert.isNull(Http.__redirectRefusal(new URL("http://example.com/"), new URL("https://example.com/"), false));
		Assert.isNull(Http.__redirectRefusal(new URL("https://example.com/"), new URL("https://other.example/"), false));
		Assert.notNull(Http.__redirectRefusal(new URL("http://example.com/"), new URL("ftp://example.com/"), true));

		Assert.equals("https://example.com:443", Http.__originOf(new URL("https://EXAMPLE.com/a")));
		Assert.isTrue(Http.__originOf(new URL("http://example.com/")) != Http.__originOf(new URL("http://example.com:8080/")));
		Assert.isTrue(Http.__originOf(new URL("http://example.com/")) != Http.__originOf(new URL("https://example.com/")));
	}

	public function testAHeadStaysAHeadThroughARedirect():Void {
		// A 301, 302 or 303 turns the request into a GET, as browsers do. A
		// HEAD was turned into one too, and downloaded the body it had asked
		// not to be sent.
		var fixture = serveTwice("HTTP/1.1 302 Found\r\nLocation: /final\r\nContent-Length: 0\r\n\r\n",
			"HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n");
		var http = new Http('http://127.0.0.1:${fixture.port}/start', "HEAD");
		var failure:String = null;
		http.onError = (message, ?data) -> failure = message;
		http.load();
		fixture.waitDone();

		Assert.isNull(failure, failure);
		Assert.equals(2, fixture.requests.length, "the redirect was not followed");
		if (fixture.requests.length == 2) {
			Assert.equals(0, fixture.requests[1].indexOf("HEAD /final HTTP/1.1"), fixture.requests[1]);
		}
	}

	public function testTenRedirectsEndingInAResponseSucceed():Void {
		// MAX_REDIRECTS is ten; ten followed and then answered is within it.
		// The old check read the count alone and reported this as too many.
		var responses:Array<String> = [for (i in 0...10) 'HTTP/1.1 302 Found\r\nLocation: /hop${i + 1}\r\nContent-Length: 0\r\n\r\n'];
		responses.push("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\ndone");
		var fixture = serveMany(responses);

		var http = new Http('http://127.0.0.1:${fixture.port}/hop0');
		var completed:Bytes = null;
		var failure:String = null;
		http.onComplete = data -> completed = data;
		http.onError = (message, ?data) -> failure = message;
		http.load();
		fixture.waitDone();

		Assert.isNull(failure, "ten redirects were reported as too many: " + failure);
		Require.notNull(completed);
		Assert.equals("done", completed.toString());
	}

	public function testElevenRedirectsAreTooMany():Void {
		var responses:Array<String> = [for (i in 0...11) 'HTTP/1.1 302 Found\r\nLocation: /hop${i + 1}\r\nContent-Length: 0\r\n\r\n'];
		var fixture = serveMany(responses);

		var http = new Http('http://127.0.0.1:${fixture.port}/hop0');
		var failure:String = null;
		http.onComplete = data -> Assert.fail("an eleventh redirect was followed to completion");
		http.onError = (message, ?data) -> failure = message;
		http.load();
		fixture.waitDone();

		Require.notNull(failure);
		Assert.isTrue(failure.indexOf("redirects") >= 0, failure);
	}

	public function testURLVariablesAreSentAsAForm():Void {
		// A URLVariables is a StringMap at run time, and Reflect.fields read
		// the map's own fields: a POST of one went out with an empty body.
		var posted = serveOnce("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok");
		var post = new Http('http://127.0.0.1:${posted.port}/form', "POST", null, new crossbyte.url.URLVariables("name=Ada%20L&tag=a&tag=b"));
		post.onError = (message, ?data) -> Assert.fail("request failed: " + message);
		post.load();
		posted.waitDone();

		var body:String = posted.request.substr(posted.request.indexOf("\n\n") + 2);
		var form:Array<String> = body.split("&");
		form.sort(Reflect.compare);
		Assert.same(["name=Ada%20L", "tag=a", "tag=b"], form);
		Assert.isTrue(posted.request.indexOf("application/x-www-form-urlencoded") >= 0, posted.request);

		var queried = serveOnce("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok");
		var get = new Http('http://127.0.0.1:${queried.port}/form', "GET", null, new crossbyte.url.URLVariables("q=x%20y"));
		get.onError = (message, ?data) -> Assert.fail("request failed: " + message);
		get.load();
		queried.waitDone();

		Assert.isTrue(StringTools.startsWith(queried.request, "GET /form?q=x%20y HTTP/1.1"), queried.request);
	}

	public function testACallerHeaderCannotAddALine():Void {
		// Written as given, a CR or LF in a caller's value ended the header and
		// began one of the caller's choosing.
		var fixture = serveOnce("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok");
		var http = new Http('http://127.0.0.1:${fixture.port}/', "GET", ["X-Forwarded: a\r\nInjected: yes", "Bad\r\nName: v"]);
		http.onError = (message, ?data) -> Assert.fail("request failed: " + message);
		http.load();
		fixture.waitDone();

		for (line in fixture.request.split("\n")) {
			Assert.isFalse(StringTools.startsWith(line, "Injected:"), "a caller's value added a header line:\n" + fixture.request);
			Assert.isFalse(StringTools.startsWith(line, "Name:"), "a caller's name added a header line:\n" + fixture.request);
		}
		Assert.isTrue(fixture.request.indexOf("X-Forwarded: aInjected: yes") >= 0, fixture.request);
	}

	public function testAUrlCannotAddAHeaderLine():Void {
		// The request target and Host went out as the URL spelled them, and a
		// URL kept its CR and LF: this sent "X-Injected: evil" as a header of
		// its own, and a longer one could smuggle a second request.
		var fixture = serveWithin(["HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"], 0.5);
		var failed:Bool = false;
		try {
			var http = new Http('http://127.0.0.1:${fixture.port}/a' + String.fromCharCode(13) + String.fromCharCode(10) + "X-Injected: evil");
			http.onError = (message, ?data) -> failed = true;
			http.load();
		} catch (_:Dynamic) {
			failed = true;
		}
		fixture.waitDone();

		Assert.isTrue(failed, "a URL carrying CR LF was requested");
		Assert.equals(0, fixture.requests.length, "the request reached the server: " + fixture.requests.join(" | "));
	}

	public function testTheRequestTargetCarriesNoSpaceOrRawNonAscii():Void {
		// A space ended the target early, "GET /a b HTTP/1.1" is three words
		// and a version of "b" to a server, and a path past ASCII went out as
		// raw bytes. Both are percent-encoded, as a browser sends them.
		var fixture = serveOnce("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok");
		// The e-acute as its UTF-8 bytes read back as text: one character
		// where strings are Unicode, and those two bytes on neko, whose
		// strings are bytes, where String.fromCharCode(0xE9) is one byte,
		// Latin-1, and no URL a user types.
		var eAcute:String = Bytes.ofHex("c3a9").toString();
		var http = new Http('http://127.0.0.1:${fixture.port}/a b/caf' + eAcute + "?q=c d&r=%41");
		http.onError = (message, ?data) -> Assert.fail("request failed: " + message);
		http.load();
		fixture.waitDone();

		var line:String = fixture.request.split("\n")[0];
		Assert.equals("GET /a%20b/caf%C3%A9?q=c%20d&r=%41 HTTP/1.1", StringTools.trim(line));
	}

	public function testAMethodThatIsNotATokenIsRefused():Void {
		// URLRequest.method is any string, and it was written first on the
		// request line as given: a "method" carrying a line break and a
		// request of its own smuggled that request onto the connection.
		var fixture = serveWithin(["HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"], 0.5);
		var failure:Null<String> = null;
		var method:String = "GET / HTTP/1.1" + String.fromCharCode(13) + String.fromCharCode(10) + "Host: x" + String.fromCharCode(13)
			+ String.fromCharCode(10) + String.fromCharCode(13) + String.fromCharCode(10) + "DELETE";
		var http = new Http('http://127.0.0.1:${fixture.port}/', method);
		http.onError = (message, ?data) -> failure = message;
		http.onComplete = data -> Assert.fail("a request with a smuggled method completed");
		http.load();
		fixture.waitDone();

		Require.notNull(failure);
		Assert.isTrue(failure.indexOf("method") >= 0, failure);
		Assert.equals(0, fixture.requests.length, "the request reached the server: " + fixture.requests.join(" | "));

		// And a method that is a token, however unusual, still goes.
		var custom = serveOnce("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok");
		var http = new Http('http://127.0.0.1:${custom.port}/', "PROPFIND");
		http.onError = (message, ?data) -> Assert.fail("request failed: " + message);
		http.load();
		custom.waitDone();
		Assert.isTrue(StringTools.startsWith(custom.request, "PROPFIND / HTTP/1.1"), custom.request);
	}

	public function testUserAgentAndContentTypeCannotAddALine():Void {
		// Both were written into their header lines as given.
		var fixture = serveOnce("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok");
		var crlf:String = String.fromCharCode(13) + String.fromCharCode(10);
		var http = new Http('http://127.0.0.1:${fixture.port}/', "POST", null, null, "text/plain" + crlf + "Injected-Type: yes", "body", HttpVersion.HTTP_1_1,
			10000, "Agent" + crlf + "Injected-Agent: yes");
		http.onError = (message, ?data) -> Assert.fail("request failed: " + message);
		http.load();
		fixture.waitDone();

		for (line in fixture.request.split("\n")) {
			Assert.isFalse(StringTools.startsWith(line, "Injected-Agent:"), "the user agent added a header line:\n" + fixture.request);
			Assert.isFalse(StringTools.startsWith(line, "Injected-Type:"), "the content type added a header line:\n" + fixture.request);
		}
	}

	public function testADeclaredLengthPastTheCapIsRefusedBeforeReading():Void {
		// The body was allocated whole from the header, before a byte arrived:
		// one response declaring 2000000000 bytes cost two gigabytes.
		var saved:Int = Http.MAX_BODY_SIZE;
		Http.MAX_BODY_SIZE = 1024;
		try {
			var fixture = serveOnce("HTTP/1.1 200 OK\r\nContent-Length: 5000\r\n\r\n" + StringTools.rpad("", "x", 5000));
			var http = new Http('http://127.0.0.1:${fixture.port}/big');
			var completed:Bytes = null;
			var failure:String = null;
			http.onComplete = data -> completed = data;
			http.onError = (message, ?data) -> failure = message;
			http.load();
			fixture.waitDone();

			Assert.isNull(completed, "a body past the cap was delivered");
			Require.notNull(failure);
			Assert.isTrue(failure.indexOf("declared") >= 0, failure);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}
		Http.MAX_BODY_SIZE = saved;
	}

	public function testACloseDelimitedBodyPastTheCapIsRefused():Void {
		var saved:Int = Http.MAX_BODY_SIZE;
		Http.MAX_BODY_SIZE = 1024;
		try {
			var fixture = serveOnce("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n" + StringTools.rpad("", "x", 5000));
			var http = new Http('http://127.0.0.1:${fixture.port}/endless');
			var completed:Bytes = null;
			var failure:String = null;
			http.onComplete = data -> completed = data;
			http.onError = (message, ?data) -> failure = message;
			http.load();
			fixture.waitDone();

			Assert.isNull(completed, "a close-delimited body past the cap was delivered");
			Require.notNull(failure);
			Assert.isTrue(failure.indexOf("exceeded") >= 0, failure);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}
		Http.MAX_BODY_SIZE = saved;
	}

	#if !eval
	// Not on eval, where a peer reset is a native Unix_error that no Haxe catch
	// can see: it ends the process, before or after this fix alike.
	public function testAResetInACloseDelimitedBodyIsAnError():Void {
		// Only the connection closing ends such a body, so every read error
		// used to be taken for that ending, and a reset partway through was
		// reported complete with half a body.
		var fixture = new OneShotHttpServer();
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
				// Time for the request to arrive, and none of it read: closing
				// with it unread makes the close below a reset rather than an
				// ending. Reading even a byte lets a buffered input take the
				// rest, and the close becomes an ordinary one.
				System.sleep(0.2);
				peer.output.writeString("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\npartial");
				peer.output.flush();
				System.sleep(0.3);
				#if (java || jvm)
				// The JDK closes gracefully even over unread data; a zero linger
				// is how a Java socket is made to reset.
				var channel:java.nio.channels.SocketChannel = cast @:privateAccess peer.channel;
				channel.socket().setSoLinger(true, 0);
				#end
			} catch (e:Dynamic) {
				fixture.error = e;
				fixture.ready.release();
			}

			closeQuietly(peer);
			closeQuietly(server);
			fixture.done.release();
		});
		if (!fixture.ready.wait(2.0)) {
			Assert.fail("Timed out waiting for HTTP fixture server");
			return;
		}

		var http = new Http('http://127.0.0.1:${fixture.port}/cut');
		var completed:Bytes = null;
		var failure:String = null;
		http.onComplete = data -> completed = data;
		http.onError = (message, ?data) -> failure = message;
		http.load();
		fixture.waitDone();

		Assert.isNull(completed, "a body cut off by a reset was reported complete: " + (completed == null ? "" : completed.toString()));
		Assert.notNull(failure);
	}
	#end

	#if (cpp || java || jvm)
	/**
		A TLS handshake the server never answers fails at the request's
		timeout, and says that is what happened. Natively the failure's
		reason was "Blocked", the read the handshake waited on had timed
		out, and on the jvm it came wrapped, as `Custom(Timeout: ...)`.
	**/
	public function testAnUnansweredHandshakeSaysItTimedOut():Void {
		var listener = new SysSocket();
		listener.bind(new Host("127.0.0.1"), 0);
		listener.listen(1);
		var port:Int = listener.host().port;
		var finished = new Lock();
		var gone = new Lock();
		Thread.create(() -> {
			var peer:SysSocket = null;
			try {
				peer = listener.accept();
			} catch (_:Dynamic) {}
			// Held and silent until the request has given up.
			finished.wait(15.0);
			closeQuietly(peer);
			closeQuietly(listener);
			gone.release();
		});

		var failure:Null<String> = null;
		var http = new Http('https://127.0.0.1:$port/silent', "GET", null, null, null, null, HttpVersion.HTTP_1_1, 1000);
		http.onComplete = _ -> failure = "completed";
		http.onError = (message, ?_) -> failure = message;
		var started:Float = haxe.Timer.stamp();
		http.load();
		var took:Float = haxe.Timer.stamp() - started;
		finished.release();
		gone.wait(5.0);

		Require.notNull(failure);
		Assert.isTrue(StringTools.startsWith(failure, "Connection Failed: "), failure);
		Assert.isTrue(failure.indexOf("did not answer within 1") >= 0, failure);
		Assert.isTrue(took < 5.0, 'took $took s for a 1 s timeout');
	}
	#end

	#if !eval
	// Not on eval, where a read that times out raises a native Unix_error no
	// Haxe catch can see, and so ends the process. On the jvm since
	// sys.net.Socket.setTimeout reaches a blocking read there.
	public function testTheIdleTimeoutIsInMilliseconds():Void {
		// The socket was handed the milliseconds as seconds, so this waited
		// until the server gave up, three seconds on, rather than 300 ms.
		var fixture = holdRequest(false);
		var http = new Http('http://127.0.0.1:${fixture.port}/slow', "GET", null, null, null, null, HttpVersion.HTTP_1_1, 300);
		var completed:Bool = false;
		var failure:String = null;
		http.onComplete = _ -> completed = true;
		http.onError = (message, ?data) -> failure = message;
		var started:Float = haxe.Timer.stamp();
		http.load();
		var took:Float = haxe.Timer.stamp() - started;
		fixture.waitDone();

		Assert.isFalse(completed);
		Require.notNull(failure);
		Assert.isTrue(took < 2.0, 'a 300 ms idle timeout took ${took} s');
	}
	#end

	public function testAServerClosingWithoutAnAnswerIsAnError():Void {
		// On eval the end of the stream read as endless NUL bytes, so the
		// status line never ended and load() never returned.
		var fixture = holdRequest(true);
		var http = new Http('http://127.0.0.1:${fixture.port}/gone');
		var completed:Bool = false;
		var failure:String = null;
		http.onComplete = _ -> completed = true;
		http.onError = (message, ?data) -> failure = message;
		http.load();
		fixture.waitDone();

		Assert.isFalse(completed);
		Require.notNull(failure);
	}

	public function testAChunkedBodyEndingBeforeItsSizeLineIsAnError():Void {
		// The size line read the end of the stream the same way on eval.
		var fixture = serveOnce("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n");
		var http = new Http('http://127.0.0.1:${fixture.port}/cut');
		var completed:Bool = false;
		var failure:String = null;
		http.onComplete = _ -> completed = true;
		http.onError = (message, ?data) -> failure = message;
		http.load();
		fixture.waitDone();

		Assert.isFalse(completed);
		Require.notNull(failure);
	}

	// ------------------------------------------------------ cancelling a load

	public function testACancelBeforeTheSocketIsMadeSendsNothing():Void {
		// Cancelled after load() looked at its token and before the socket
		// existed. The cancel found no socket to close and was lost: the
		// request went out regardless, and its thread then waited out the
		// idle timeout for an answer nobody wanted.
		var fixture = serveWithin(["HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"], 0.5);
		var http = new CancelledOnTheWay('http://127.0.0.1:${fixture.port}/late', 0);
		var completed:Bool = false;
		var failure:String = null;
		http.onComplete = _ -> completed = true;
		http.onError = (message, ?data) -> failure = message;
		http.load();
		fixture.waitDone();

		Assert.isFalse(completed, "a cancelled request completed");
		Assert.equals("Request cancelled", failure);
		Assert.equals(0, fixture.requests.length, "a cancelled request went out anyway");
	}

	public function testACancelBetweenRedirectsSendsNoMore():Void {
		// The same window between two hops: the first hop's socket is closed
		// and the next one's not yet made.
		var fixture = serveWithin([
			"HTTP/1.1 302 Found\r\nLocation: /next\r\nContent-Length: 0\r\n\r\n",
			"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
		], 0.5);
		var http = new CancelledOnTheWay('http://127.0.0.1:${fixture.port}/first', 1);
		var completed:Bool = false;
		var failure:String = null;
		http.onComplete = _ -> completed = true;
		http.onError = (message, ?data) -> failure = message;
		http.load();
		fixture.waitDone();

		Assert.isFalse(completed, "a cancelled request completed");
		Assert.equals("Request cancelled", failure);
		Assert.equals(1, fixture.requests.length, "the redirect was followed after the cancel");
	}

	public function testACancelledCloseDelimitedBodyIsNotComplete():Void {
		// Such a body ends when the stream does, and a cancel ends the stream
		// the same way the server closing does: what had arrived was delivered
		// as the whole response.
		var fixture = holdAfter("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\npartial");
		var http = new Http('http://127.0.0.1:${fixture.port}/partial');
		var completed:Bytes = null;
		var failure:String = null;
		http.onProgress = (loaded, total) -> {
			if (loaded > 0) {
				http.cancelToken.cancel();
			}
		};
		http.onComplete = data -> completed = data;
		http.onError = (message, ?data) -> failure = message;
		http.load();
		fixture.waitDone();

		Assert.isNull(completed, "a body cut short by a cancel was delivered as complete");
		Assert.equals("Request cancelled", failure);
	}

	public function testACancelFromAnotherThreadReachesAReadAtOnce():Void {
		// The cancel shuts the socket down rather than closing it, which wakes
		// a waiting read on every target and tells the server at once.
		var fixture = holdRequest(false);
		var http = new Http('http://127.0.0.1:${fixture.port}/held', "GET", null, null, null, null, HttpVersion.HTTP_1_1, 5000);
		var failure:String = null;
		http.onError = (message, ?data) -> failure = message;
		var token = http.cancelToken;
		Thread.create(() -> {
			// Once the server has the request: the read is waiting by then.
			if (fixture.requested.wait(2.0)) {
				token.cancel();
			}
		});
		var started:Float = haxe.Timer.stamp();
		http.load();
		var took:Float = haxe.Timer.stamp() - started;
		fixture.waitDone();

		Assert.equals("Request cancelled", failure);
		Assert.isTrue(took < 2.0, 'the cancelled read went on for ${took} s');
		Assert.equals("the client went", fixture.ended);
	}

	#if !eval
	// Kept connections are not used on eval, where a reset is uncatchable.
	public function testAConnectionIsKeptForTheNextRequest():Void {
		// Every request asked for Connection: close, so each was a new
		// connection, and over https a new handshake.
		HttpConnectionPool.clear();
		var server = new KeptAliveServer((connection, request) -> "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok");
		for (i in 0...3) {
			Assert.equals("ok", __get('http://127.0.0.1:${server.port}/n$i'));
		}
		HttpConnectionPool.clear();
		server.close();

		Assert.equals(1, server.connections, "each request opened a connection of its own");
		Assert.equals(3, server.requestCount());
		Assert.isTrue(server.request(0).indexOf("Connection: keep-alive") >= 0);
	}

	public function testAKeptConnectionTheServerClosedIsReplaced():Void {
		// The server reads the second request on the connection and closes it
		// unanswered, as one timing out an idle connection does while the
		// request is on its way. The request goes again, on a new one.
		HttpConnectionPool.clear();
		var server = new KeptAliveServer((connection, request) -> request == 0 ? "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok" : null);
		Assert.equals("ok", __get('http://127.0.0.1:${server.port}/first'));
		Assert.equals("ok", __get('http://127.0.0.1:${server.port}/second'));
		HttpConnectionPool.clear();
		server.close();

		Assert.equals(2, server.connections);
	}

	public function testAPostIsNotSentOnAKeptConnection():Void {
		// Whether a server acted on a request its connection died under cannot
		// be known, so only a request that may be sent twice uses one.
		HttpConnectionPool.clear();
		var server = new KeptAliveServer((connection, request) -> "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok");
		Assert.equals("ok", __get('http://127.0.0.1:${server.port}/read'));
		Assert.equals("ok", __get('http://127.0.0.1:${server.port}/write', "POST", "body"));
		HttpConnectionPool.clear();
		server.close();

		Assert.equals(2, server.connections);
	}

	public function testAResponseThatClosesIsNotKept():Void {
		HttpConnectionPool.clear();
		var server = new KeptAliveServer((connection, request) -> "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 2\r\n\r\nok");
		Assert.equals("ok", __get('http://127.0.0.1:${server.port}/a'));
		Assert.equals("ok", __get('http://127.0.0.1:${server.port}/b'));
		HttpConnectionPool.clear();
		server.close();

		Assert.equals(2, server.connections);
	}

	private static function __get(url:String, method:String = "GET", ?data:String):Null<String> {
		var http = new Http(url, method, null, null, null, data);
		var result:Null<String> = null;
		http.onComplete = bytes -> result = bytes.toString();
		http.onError = (message, ?body) -> result = "error: " + message;
		http.load();
		return result;
	}
	#end

	/**
	 * Takes one request and answers nothing: closes at once, or holds the
	 * connection until the client goes, three seconds at most.
	 */
	private static function holdRequest(closeAtOnce:Bool):OneShotHttpServer {
		var fixture = new OneShotHttpServer();
		Thread.create(() -> {
			var server = new SysSocket();
			var peer:SysSocket = null;
			try {
				server.bind(new Host("127.0.0.1"), 0);
				server.listen(1);
				fixture.port = server.host().port;
				fixture.ready.release();

				peer = server.accept();
				peer.setTimeout(3.0);
				fixture.request = readRequest(peer);
				fixture.requested.release();
				if (!closeAtOnce) {
					fixture.ended = __awaitClientGoing(peer);
				}
			} catch (e:Dynamic) {
				fixture.error = e;
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
	 * Takes one request, answers it with `response`, and holds the connection
	 * until the client goes, three seconds at most.
	 */
	private static function holdAfter(response:String):OneShotHttpServer {
		var fixture = new OneShotHttpServer();
		Thread.create(() -> {
			var server = new SysSocket();
			var peer:SysSocket = null;
			try {
				server.bind(new Host("127.0.0.1"), 0);
				server.listen(1);
				fixture.port = server.host().port;
				fixture.ready.release();

				peer = server.accept();
				peer.setTimeout(3.0);
				fixture.request = readRequest(peer);
				fixture.requested.release();
				peer.output.writeString(response);
				peer.output.flush();
				fixture.ended = __awaitClientGoing(peer);
			} catch (e:Dynamic) {
				fixture.error = e;
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

	/** How a wait for the client to hang up ended. */
	private static function __awaitClientGoing(peer:SysSocket):String {
		try {
			peer.input.readBytes(Bytes.alloc(1), 0, 1);
			return "a byte arrived";
		} catch (_:haxe.io.Eof) {
			return "the client went";
		} catch (e:Dynamic) {
			return Std.string(e);
		}
	}

	/**
	 * Answers each connection with the next of `responses`, waiting no more
	 * than `window` seconds for each to arrive, and stops at the first that
	 * does not. So a request that should never be sent can be seen not to be,
	 * with no thread left waiting in accept() for it.
	 */
	private static function serveWithin(responses:Array<String>, window:Float):TwoShotHttpServer {
		var fixture = new TwoShotHttpServer();
		Thread.create(() -> {
			var server = new SysSocket();
			var peer:SysSocket = null;
			try {
				server.bind(new Host("127.0.0.1"), 0);
				server.listen(responses.length);
				fixture.port = server.host().port;
				fixture.ready.release();

				for (response in responses) {
					if (SysSocket.select([server], null, null, window).read.length == 0) {
						break;
					}
					peer = server.accept();
					peer.setBlocking(true);
					peer.setTimeout(2.0);
					fixture.requests.push(readRequest(peer));
					peer.output.writeString(response);
					peer.output.flush();
					closeQuietly(peer);
					peer = null;
				}
			} catch (e:Dynamic) {
				fixture.error = e;
				fixture.ready.release();
			}

			closeQuietly(peer);
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

	private static function serveMany(responses:Array<String>):TwoShotHttpServer {
		var fixture = new TwoShotHttpServer();
		Thread.create(() -> {
			var server = new SysSocket();
			var peer:SysSocket = null;
			try {
				server.bind(new Host("127.0.0.1"), 0);
				server.listen(responses.length);
				fixture.port = server.host().port;
				fixture.ready.release();

				for (response in responses) {
					peer = server.accept();
					peer.setTimeout(2.0);
					fixture.requests.push(readRequest(peer));
					peer.output.writeString(response);
					peer.output.flush();
					closeQuietly(peer);
					peer = null;
				}
			} catch (e:Dynamic) {
				fixture.error = e;
				fixture.ready.release();
			}

			closeQuietly(peer);
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

	private static function serveTwice(first:String, second:String):TwoShotHttpServer {
		var fixture = new TwoShotHttpServer();
		Thread.create(() -> {
			var server = new SysSocket();
			var peer:SysSocket = null;
			try {
				server.bind(new Host("127.0.0.1"), 0);
				server.listen(2);
				fixture.port = server.host().port;
				fixture.ready.release();

				for (i in 0...2) {
					peer = server.accept();
					peer.setTimeout(2.0);
					// Http closes between hops, so each request arrives on its
					// own connection and the second accept is what catches the
					// redirected one.
					fixture.requests.push(readRequest(peer));
					peer.output.writeString(i == 0 ? first : second);
					peer.output.flush();
					closeQuietly(peer);
					peer = null;
				}
			} catch (e:Dynamic) {
				fixture.error = e;
				fixture.ready.release();
			}

			closeQuietly(peer);
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

	private static function serveOnceWithBody(response:String, body:Bytes):OneShotHttpServer {
		var fixture = new OneShotHttpServer();
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
				fixture.request = readRequest(peer);
				peer.output.writeString(response);
				if (body != null && body.length > 0) {
					peer.output.writeBytes(body, 0, body.length);
				}
				peer.output.flush();
			} catch (e:Dynamic) {
				fixture.error = e;
				fixture.ready.release();
			}

			closeQuietly(peer);
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

	private static function readRequest(peer:SysSocket):String {
		var lines:Array<String> = [];
		var contentLength = 0;
		while (true) {
			var line = peer.input.readLine();
			lines.push(line);
			if (line == "") {
				break;
			}

			var separator = line.indexOf(":");
			if (separator > 0 && line.substr(0, separator).toLowerCase() == "content-length") {
				contentLength = Std.parseInt(StringTools.trim(line.substr(separator + 1)));
			}
		}

		var body = contentLength > 0 ? peer.input.read(contentLength).toString() : "";
		return lines.join("\n") + "\n" + body;
	}

	private static function closeQuietly(socket:SysSocket):Void {
		try {
			if (socket != null) {
				socket.close();
			}
		} catch (_:Dynamic) {}
	}
}

#if !eval
/**
 * A server that keeps connections: each on a thread of its own, answering
 * every request on it as `respond(connection, request)` says, the indexes
 * count from zero, until that answers null, when it closes unanswered.
 */
private class KeptAliveServer {
	public var port(default, null):Int = 0;
	public var connections(get, never):Int;

	private final __lock:sys.thread.Mutex = new sys.thread.Mutex();
	private final __requests:Array<String> = [];
	private final __server:SysSocket = new SysSocket();
	private final __respond:(Int, Int) -> Null<String>;
	private var __connections:Int = 0;

	public function new(respond:(Int, Int) -> Null<String>) {
		__respond = respond;
		__server.bind(new Host("127.0.0.1"), 0);
		__server.listen(8);
		port = __server.host().port;
		Thread.create(__accept);
	}

	private function get_connections():Int {
		__lock.acquire();
		var count:Int = __connections;
		__lock.release();
		return count;
	}

	public function requestCount():Int {
		__lock.acquire();
		var count:Int = __requests.length;
		__lock.release();
		return count;
	}

	public function request(index:Int):String {
		__lock.acquire();
		var text:String = index < __requests.length ? __requests[index] : "";
		__lock.release();
		return text;
	}

	public function close():Void {
		try {
			__server.close();
		} catch (_:Dynamic) {}
	}

	private function __accept():Void {
		while (true) {
			var peer:SysSocket;
			try {
				peer = __server.accept();
			} catch (_:Dynamic) {
				return;
			}
			__lock.acquire();
			var index:Int = __connections++;
			__lock.release();
			Thread.create(() -> __serve(peer, index));
		}
	}

	private function __serve(peer:SysSocket, connection:Int):Void {
		var request:Int = 0;
		try {
			peer.setTimeout(5.0);
			while (true) {
				var text:String = __readRequest(peer);
				__lock.acquire();
				__requests.push(text);
				__lock.release();

				var answer:Null<String> = __respond(connection, request++);
				if (answer == null) {
					break;
				}
				peer.output.writeString(answer);
				peer.output.flush();
				if (answer.indexOf("Connection: close") >= 0) {
					break;
				}
			}
		} catch (_:Dynamic) {}
		try {
			peer.close();
		} catch (_:Dynamic) {}
	}

	private static function __readRequest(peer:SysSocket):String {
		var lines:Array<String> = [];
		var length:Int = 0;
		while (true) {
			var line:String = peer.input.readLine();
			if (line == "") {
				break;
			}
			lines.push(line);
			var colon:Int = line.indexOf(":");
			if (colon > 0 && line.substr(0, colon).toLowerCase() == "content-length") {
				length = Std.parseInt(StringTools.trim(line.substr(colon + 1)));
			}
		}
		if (length > 0) {
			lines.push(peer.input.read(length).toString());
		}
		return lines.join("\n");
	}
}
#end

private class TwoShotHttpServer {
	public var port:Int = 0;
	public var requests:Array<String> = [];
	public var error:Dynamic = null;
	public var ready:Lock = new Lock();
	public var done:Lock = new Lock();

	public function new() {}

	public function waitDone():Void {
		if (!done.wait(4.0)) {
			Assert.fail("Timed out waiting for HTTP fixture requests");
		}
		if (error != null) {
			Assert.fail("HTTP fixture request failed: " + error);
		}
	}
}

private class OneShotHttpServer {
	public var port:Int = 0;
	public var request:String = "";
	public var error:Dynamic = null;
	public var ready:Lock = new Lock();
	public var done:Lock = new Lock();

	/** Released once the request has been read. */
	public var requested:Lock = new Lock();

	/** How the server's wait for the client ended, where it waits for one. */
	public var ended:String = null;

	public function new() {}

	public function waitDone():Void {
		if (!done.wait(2.0)) {
			Assert.fail("Timed out waiting for HTTP fixture request");
		}
		if (error != null) {
			Assert.fail("HTTP fixture request failed: " + error);
		}
	}
}

/**
 * Cancelled at the start of its `hop`th connection attempt, counting from
 * zero: after `load()` has looked at the token, and before there is a socket
 * for the cancel to reach. A cancel from another thread lands there as often
 * as the timing allows; this lands there every time.
 */
private class CancelledOnTheWay extends Http {
	private var __cancelAt:Int;
	private var __attempts:Int = 0;

	public function new(url:String, hop:Int) {
		super(url);
		__cancelAt = hop;
	}

	override private function __tryRequest():Void {
		if (__attempts++ == __cancelAt) {
			cancelToken.cancel();
		}
		super.__tryRequest();
	}
}

private class FakeHTTP2Backend implements HTTPBackend {
	public var lastContext:HTTPRequestContext;
	private var response:String;

	public function new(response:String = "ok") {
		this.response = response;
	}

	public function supports(version:crossbyte.http.HTTPVersion):Bool {
		return version == HttpVersion.HTTP_2;
	}

	public function load(context:HTTPRequestContext):Void {
		lastContext = context;
		var bytes = Bytes.ofString(response);
		var headers:Map<String, String> = ["content-type" => "text/plain", "content-length" => Std.string(bytes.length)];

		// The order HTTPRequestContext documents: status, headers, progress,
		// then exactly one of onComplete/onError.
		context.onStatus(200);
		context.onHeaders(headers);
		context.onProgress(0, bytes.length);
		context.onProgress(bytes.length, bytes.length);
		context.onComplete(bytes);
	}
}

/** Something with a method to register on a token, as a request's owner has. **/
private class CancelCounter {
	public var stops:Int = 0;

	public function new() {}

	public function stop():Void {
		stops++;
	}
}
