package crossbyte._internal.http;

import crossbyte.http.HTTPBackend;
import crossbyte.http.HTTPBackendRegistry;
import crossbyte.http.HTTPCancelToken;
import crossbyte.http.HTTPRequestContext;
import crossbyte.io.ByteArray;
import crossbyte.utils.CompressionAlgorithm;
import crossbyte.url.URL;
import haxe.io.Bytes;
import haxe.exceptions.NotImplementedException;
import sys.net.Host;
import sys.net.Socket as SysSocket;
import sys.thread.Lock;
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

	public function testValidateHttpVersionOnlyAllowsImplementedVersions():Void {
		Assert.isTrue(Http.validateHttpVersion(HttpVersion.HTTP_1));
		Assert.isTrue(Http.validateHttpVersion(HttpVersion.HTTP_1_1));
		Assert.isFalse(Http.validateHttpVersion(HttpVersion.HTTP_2));
		Assert.isFalse(Http.validateHttpVersion(HttpVersion.HTTP_3));
	}

	public function testVersionWithNoBackendAnywhereIsRejected():Void {
		HTTPBackendRegistry.clear();

		// HTTP/3 is QUIC and nothing here implements it, so it still fails at
		// construction. HTTP/2 no longer does -- see the next case.
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

	public function testLoadReportsResponseHeadersAndJoinsRepeatedFields():Void {
		var fixture = serveOnce("HTTP/1.1 200 OK
"
			+ "Content-Length: 2
"
			+ "X-Multi: a
"
			+ "X-Multi: b
"
			+ "Set-Cookie: one=1
"
			+ "Set-Cookie: two=2
"
			+ "
hi");
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

	public function testLoadReportsOnlyTheFinalHeaderBlockAfterAnInformationalResponse():Void {
		var fixture = serveOnce("HTTP/1.1 100 Continue

" + "HTTP/1.1 200 OK
Content-Length: 2
X-Final: yes

hi");
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
		var http = new Http("http://example.com/dir/page");
		var base = new URL("http://example.com/dir/page");

		Assert.equals("https://other.example/path?q=1", http.__resolveLocation(base, "https://other.example/path?q=1"));
		Assert.equals("http://example.com/root?x=1", http.__resolveLocation(base, "/root?x=1"));
	}

	public function testResolveLocationKeepsNonDefaultPortAndRelativeDirectory():Void {
		var http = new Http("http://example.com:8080/dir/page");
		var base = new URL("http://example.com:8080/dir/page");

		Assert.equals("http://example.com:8080/dir/next", http.__resolveLocation(base, "next"));
		Assert.equals("http://example.com:8080/dir/sub/next?x=1", http.__resolveLocation(base, "sub/next?x=1"));
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
		Assert.isTrue(fixture.request.indexOf("Connection: close") >= 0);
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
		// size line used to read as 5 and the body came back as "hello" --
		// this client agreeing with nobody about where the chunk ended.
		var fixture = serveOnce("HTTP/1.1 200 OK
Transfer-Encoding: chunked

5 junk
hello
0

");
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
		// NumberFormatException on jvm, and 4294967295 on node -- neither
		// null nor negative, so node walked straight past the guard.
		var fixture = serveOnce("HTTP/1.1 200 OK
Transfer-Encoding: chunked

FFFFFFFF
");
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

	public function testChunkedThatIsNotTheFinalCodingIsNotChunkDecoded():Void {
		// RFC 9112 6.1: chunked frames the body only when it is the last
		// coding applied. With something after it the body is not chunk
		// framed at all, and the length comes from the connection closing.
		// Reading it as chunks took the body's first line for a chunk size.
		var fixture = serveOnce("HTTP/1.1 200 OK
Transfer-Encoding: chunked, gzip

not chunk framed");
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

			var fixture = serveOnceWithBody("HTTP/1.1 200 OK
Content-Encoding: gzip
Content-Length: " + encoded.length + "

", encoded);
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

			var fixture = serveOnceWithBody("HTTP/1.1 200 OK
Content-Encoding: br
Content-Length: " + encoded.length + "

", encoded);
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
		var fixture = serveOnce("HTTP/1.1 200 OK
Content-Encoding: gzip, gzip, gzip
Content-Length: 4

xxxx");
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

	private static function serveOnce(response:String):OneShotHttpServer {
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
		var fixture = serveTwice("HTTP/1.1 302 Found
Location: /landing
Set-Cookie: session=abc123; Path=/; HttpOnly
Content-Length: 0

",
			"HTTP/1.1 200 OK
Content-Length: 2

ok");

		var http = new Http('http://127.0.0.1:${fixture.port}/signin');
		http.onError = (message, ?data) -> Assert.fail("request failed: " + message);
		http.load();
		fixture.waitDone();

		Assert.equals(2, fixture.requests.length, "the redirect was not followed");
		Assert.isTrue(fixture.requests[0].toLowerCase().indexOf("cookie:") < 0, "a cookie was sent before anything set one");
		Assert.isTrue(fixture.requests[1].indexOf("Cookie: session=abc123") >= 0,
			"the session cookie did not survive the redirect:
" + fixture.requests[1]);
	}

	public function testManageCookiesOffSendsNothingBack():Void {
		var fixture = serveTwice("HTTP/1.1 302 Found
Location: /landing
Set-Cookie: session=abc123
Content-Length: 0

",
			"HTTP/1.1 200 OK
Content-Length: 2

ok");

		var http = new Http('http://127.0.0.1:${fixture.port}/signin', "GET", null, null, null, null, HttpVersion.HTTP_1_1, 10000, "CrossByte", true,
			false);
		http.onError = (message, ?data) -> Assert.fail("request failed: " + message);
		http.load();
		fixture.waitDone();

		Assert.equals(2, fixture.requests.length, "the redirect was not followed");
		Assert.isTrue(fixture.requests[1].toLowerCase().indexOf("cookie:") < 0,
			"a cookie went out with manageCookies off:
" + fixture.requests[1]);
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
