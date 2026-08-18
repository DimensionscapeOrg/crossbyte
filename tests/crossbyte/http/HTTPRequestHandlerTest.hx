package crossbyte.http;

import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.ProgressEvent;
import crossbyte.io.ByteArray;
import crossbyte.io.File;
import crossbyte.net.Socket;
import crossbyte.utils.CompressionAlgorithm;
import haxe.Timer;
import utest.Assert;

@:access(crossbyte.http.HTTPRequestHandler)
class HTTPRequestHandlerTest extends utest.Test {
	public function testNoMiddlewarePreservesStaticRouting():Void {
		var response = __sendRequest([], "GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n");

		Assert.equals(200, response.status);
		Assert.equals("Hello from middleware test", response.body);
	}

	public function testSplitHeadersWaitForCompleteRequest():Void {
		var response = __sendRequest([], "GET /index.html HTTP/1.1\r\n", "Host: localhost\r\n\r\n");

		Assert.equals(200, response.status);
		Assert.equals("Hello from middleware test", response.body);
	}

	public function testHttp11RequiresHostHeader():Void {
		var response = __sendRequest([], "GET /index.html HTTP/1.1\r\n\r\n");

		Assert.equals(400, response.status);
		Assert.equals("Bad Request", response.body);
	}

	public function testHttp10AllowsMissingHostHeader():Void {
		var response = __sendRequest([], "GET /index.html HTTP/1.0\r\n\r\n");

		Assert.equals(200, response.status);
		Assert.equals("Hello from middleware test", response.body);
	}

	public function testAbsoluteFormRequestTargetRoutesToPath():Void {
		var response = __sendRequest([], "GET http://localhost/index.html?mode=absolute HTTP/1.1\r\nHost: localhost\r\n\r\n");

		Assert.equals(200, response.status);
		Assert.equals("Hello from middleware test", response.body);
	}

	public function testHeadReturnsContentLengthWithoutBody():Void {
		var response = __sendRequest([], "HEAD /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n");

		Assert.equals(200, response.status);
		Assert.equals("", response.body);
		Assert.equals("26", response.headers.get("content-length"));
	}

	public function testRangeRequestReturnsPartialContent():Void {
		var response = __sendRequest([], "GET /index.html HTTP/1.1\r\nHost: localhost\r\nRange: bytes=6-9\r\n\r\n");

		Assert.equals(206, response.status);
		Assert.equals("from", response.body);
		Assert.equals("4", response.headers.get("content-length"));
		Assert.isTrue(response.headers.get("content-range").indexOf("bytes 6-9/") == 0);
	}

	public function testSuffixRangeRequestReturnsTail():Void {
		var response = __sendRequest([], "GET /index.html HTTP/1.1\r\nHost: localhost\r\nRange: bytes=-4\r\n\r\n");

		Assert.equals(206, response.status);
		Assert.equals("test", response.body);
		Assert.equals("4", response.headers.get("content-length"));
	}

	public function testInvalidRangeReturns416():Void {
		var response = __sendRequest([], "GET /index.html HTTP/1.1\r\nHost: localhost\r\nRange: bytes=999-1000\r\n\r\n");

		Assert.equals(416, response.status);
		Assert.equals("Requested Range Not Satisfiable", response.body);
		Assert.isTrue(response.headers.get("content-range").indexOf("bytes */") == 0);
	}

	public function testIfModifiedSinceReturns304():Void {
		var first = __sendRequest([], "GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n");
		var lastModified = first.headers.get("last-modified");
		var second = __sendRequest([], 'GET /index.html HTTP/1.1\r\nHost: localhost\r\nIf-Modified-Since: ${lastModified}\r\n\r\n');

		Assert.equals(200, first.status);
		Assert.notNull(lastModified);
		Assert.equals(304, second.status);
		Assert.equals("", second.body);
	}

	public function testMiddlewareHelpersAreAvailableAndCaseInsensitive():Void {
		var method:String = null;
		var requestPath:String = null;
		var queryString:String = null;
		var uaHeader:String = null;
		var hasUaHeader:Bool = false;

		var response = __sendRequest([
			function(handler:HTTPRequestHandler, next:?Dynamic->Void):Void {
				method = handler.method;
				requestPath = handler.requestPath;
				queryString = handler.queryString;
				uaHeader = handler.getHeader("x-trace");
				hasUaHeader = handler.hasHeader("X-Trace");
				next();
			}
		], "GET /index.html?foo=bar&mode=test HTTP/1.1\r\nHost: localhost\r\nX-Trace: yes\r\n\r\n");

		Assert.equals(200, response.status);
		Assert.equals("GET", method);
		Assert.equals("/index.html", requestPath);
		Assert.equals("foo=bar&mode=test", queryString);
		Assert.equals("yes", uaHeader);
		Assert.isTrue(hasUaHeader);
	}

	public function testMiddlewareCanReadContentLengthRequestBody():Void {
		var bodyText:String = null;
		var bodyLength:UInt = 0;
		var response = __sendRequest([
			function(handler:HTTPRequestHandler, next:?Dynamic->Void):Void {
				bodyText = handler.requestText;
				bodyLength = handler.requestBody.length;
				next();
			}
		], "POST /index.html HTTP/1.1\r\nHost: localhost\r\nContent-Length: 11\r\n\r\nhello world");

		Assert.equals("hello world", bodyText);
		Assert.equals(11, bodyLength);
		Assert.equals(405, response.status);
	}

	public function testMiddlewareCanReadChunkedRequestBody():Void {
		var bodyText:String = null;
		var response = __sendRequest([
			function(handler:HTTPRequestHandler, next:?Dynamic->Void):Void {
				bodyText = handler.requestText;
				next();
			}
		], "POST /index.html HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n5;ext=1\r\npedia\r\n0\r\nX-Trailer: yes\r\n\r\n");

		Assert.equals("Wikipedia", bodyText);
		Assert.equals(405, response.status);
	}

	public function testMiddlewareCanReadGzipRequestBody():Void {
		var bodyText:String = null;
		var body:ByteArray = new ByteArray();
		body.writeUTFBytes("hello world");
		body.compress(CompressionAlgorithm.GZIP);

		var response = __sendRequest([
			function(handler:HTTPRequestHandler, next:?Dynamic->Void):Void {
				bodyText = handler.requestText;
				next();
			}
		], 'POST /index.html HTTP/1.1\r\nHost: localhost\r\nContent-Encoding: gzip\r\nContent-Length: ${body.length}\r\n\r\n', null, false, body);

		Assert.equals("hello world", bodyText);
		Assert.equals(405, response.status);
	}

	public function testMiddlewareCanReadDeflateRequestBody():Void {
		var bodyText:String = null;
		var body:ByteArray = new ByteArray();
		body.writeUTFBytes("hello world");
		body.compress(CompressionAlgorithm.DEFLATE);

		var response = __sendRequest([
			function(handler:HTTPRequestHandler, next:?Dynamic->Void):Void {
				bodyText = handler.requestText;
				next();
			}
		], 'POST /index.html HTTP/1.1\r\nHost: localhost\r\nContent-Encoding: deflate\r\nContent-Length: ${body.length}\r\n\r\n', null, false, body);

		Assert.equals("hello world", bodyText);
		Assert.equals(405, response.status);
	}

	public function testMiddlewareCanReadBrotliRequestBody():Void {
		var bodyText:String = null;
		var body:ByteArray = new ByteArray();
		body.writeUTFBytes("hello world");
		body.compress(CompressionAlgorithm.BROTLI);

		var response = __sendRequest([
			function(handler:HTTPRequestHandler, next:?Dynamic->Void):Void {
				bodyText = handler.requestText;
				next();
			}
		], 'POST /index.html HTTP/1.1\r\nHost: localhost\r\nContent-Encoding: br\r\nContent-Length: ${body.length}\r\n\r\n', null, false, body);

		Assert.equals("hello world", bodyText);
		Assert.equals(405, response.status);
	}

	public function testUnsupportedRequestContentEncodingReturns415AndSkipsRouting():Void {
		var body:ByteArray = new ByteArray();
		body.writeUTFBytes("hello world");
		var middlewareCalled = false;

		var response = __sendRequest([
			function(_:HTTPRequestHandler, next:?Dynamic->Void):Void {
				middlewareCalled = true;
				next();
			}
		], 'POST /index.html HTTP/1.1\r\nHost: localhost\r\nContent-Encoding: zstd\r\nContent-Length: ${body.length}\r\n\r\n', null, false, body);

		Assert.equals(415, response.status);
		Assert.equals("Unsupported Content-Encoding: zstd", response.body);
		Assert.isFalse(middlewareCalled);
	}

	public function testResponseCompressionNegotiatesGzip():Void {
		var response = __sendRequest([], 'GET /index.html HTTP/1.1\r\nHost: localhost\r\nAccept-Encoding: gzip\r\n\r\n', null, true);

		Assert.equals(200, response.status);
		Assert.equals("gzip", response.headers.get("content-encoding"));

		var decompressed = new ByteArray();
		decompressed.writeBytes(response.bodyBytes, 0, response.bodyBytes.length);
		decompressed.uncompress(CompressionAlgorithm.GZIP);
		Assert.equals("Hello from middleware test", decompressed.toString());
		Assert.notEquals("Hello from middleware test", response.body);
	}

	public function testWildcardNegotiationDoesNotReviveExplicitlyRejectedGzip():Void {
		var response = __sendRequest([], 'GET /index.html HTTP/1.1\r\nHost: localhost\r\nAccept-Encoding: gzip;q=0, *;q=1\r\n\r\n', null, true);

		Assert.equals(200, response.status);
		Assert.equals("deflate", response.headers.get("content-encoding"));

		var decompressed = new ByteArray();
		decompressed.writeBytes(response.bodyBytes, 0, response.bodyBytes.length);
		decompressed.uncompress(CompressionAlgorithm.DEFLATE);
		Assert.equals("Hello from middleware test", decompressed.toString());
	}

	public function testResponseCompressionCanNegotiateLz4():Void {
		var response = __sendRequest([], 'GET /index.html HTTP/1.1\r\nHost: localhost\r\nAccept-Encoding: lz4\r\n\r\n', null, true);

		Assert.equals(200, response.status);
		Assert.equals("lz4", response.headers.get("content-encoding"));

		var decompressed = new ByteArray();
		decompressed.writeBytes(response.bodyBytes, 0, response.bodyBytes.length);
		decompressed.uncompress(CompressionAlgorithm.LZ4);
		Assert.equals("Hello from middleware test", decompressed.toString());
	}

	public function testResponseCompressionCanNegotiateBrotli():Void {
		var response = __sendRequest([], 'GET /index.html HTTP/1.1\r\nHost: localhost\r\nAccept-Encoding: br\r\n\r\n', null, true);

		Assert.equals(200, response.status);
		Assert.equals("br", response.headers.get("content-encoding"));

		var decompressed = new ByteArray();
		decompressed.writeBytes(response.bodyBytes, 0, response.bodyBytes.length);
		decompressed.uncompress(CompressionAlgorithm.BROTLI);
		Assert.equals("Hello from middleware test", decompressed.toString());
	}

	public function testRangeResponseSkipsCompressionNegotiation():Void {
		var response = __sendRequest([], "GET /index.html HTTP/1.1\r\nHost: localhost\r\nRange: bytes=6-9\r\nAccept-Encoding: gzip\r\n\r\n");

		Assert.equals(206, response.status);
		Assert.equals("from", response.body);
		Assert.isNull(response.headers.get("content-encoding"));
		Assert.equals("4", response.headers.get("content-length"));
	}

	public function testExpectContinueSendsInterimResponseAndReadsBody():Void {
		var bodyText:String = null;
		var response = __sendRequest([
			function(handler:HTTPRequestHandler, next:?Dynamic->Void):Void {
				bodyText = handler.requestText;
				next();
			}
		], "POST /index.html HTTP/1.1\r\nHost: localhost\r\nExpect: 100-continue\r\nContent-Length: 7\r\n\r\npayload");

		Assert.equals("payload", bodyText);
		Assert.isTrue(response.raw.indexOf("HTTP/1.1 100 Continue") == 0);
		Assert.equals(405, response.status);
	}

	public function testUnknownExpectationReturns417():Void {
		var middlewareCalled = false;
		var response = __sendRequest([
			function(_:HTTPRequestHandler, next:?Dynamic->Void):Void {
				middlewareCalled = true;
				next();
			}
		], "POST /index.html HTTP/1.1\r\nHost: localhost\r\nExpect: magic\r\nContent-Length: 7\r\n\r\npayload");

		Assert.equals(417, response.status);
		Assert.equals("Expectation Failed", response.body);
		Assert.isFalse(middlewareCalled);
	}

	public function testUnsupportedTransferEncodingReturns501():Void {
		var middlewareCalled = false;
		var response = __sendRequest([
			function(_:HTTPRequestHandler, next:?Dynamic->Void):Void {
				middlewareCalled = true;
				next();
			}
		], "POST /index.html HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: gzip\r\n\r\npayload");

		Assert.equals(501, response.status);
		Assert.equals("Transfer-Encoding not supported", response.body);
		Assert.isFalse(middlewareCalled);
	}

	public function testMiddlewareRunsInOrderAndCanReturnStatusCode():Void {
		var order:Array<String> = [];
		var response = __sendRequest([
			function(_:HTTPRequestHandler, next:?Dynamic->Void):Void {
				order.push("1");
				next();
			},
			function(_:HTTPRequestHandler, next:?Dynamic->Void):Void {
				order.push("2");
				next(404);
			},
			function(_:HTTPRequestHandler, next:?Dynamic->Void):Void {
				order.push("3");
				next();
			}
		], "GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n");

		Assert.equals(2, order.length);
		Assert.equals("1", order[0]);
		Assert.equals("2", order[1]);
		Assert.equals(404, response.status);
		Assert.equals("Not Found", response.body);
	}

	public function testMiddlewareNextCalledTwiceIsIgnored():Void {
		var calls = 0;
		var response = __sendRequest([
			function(_:HTTPRequestHandler, next:?Dynamic->Void):Void {
				calls++;
				next();
				next(500);
			}
		], "GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n");

		Assert.equals(1, calls);
		Assert.equals(200, response.status);
		Assert.equals("Hello from middleware test", response.body);
	}

	public function testRootContainmentRejectsSiblingPrefix():Void {
		#if windows
		var root = "C:\\www";
		Assert.isTrue(HTTPRequestHandler.__isWithinRoot(root, "C:\\www"));
		Assert.isTrue(HTTPRequestHandler.__isWithinRoot(root, "C:\\www\\static\\index.html"));
		Assert.isTrue(HTTPRequestHandler.__isWithinRoot(root, "c:/WWW/static/index.html"));
		Assert.isFalse(HTTPRequestHandler.__isWithinRoot(root, "C:\\www2\\secret.txt"));
		#else
		var root = "/var/www";
		Assert.isTrue(HTTPRequestHandler.__isWithinRoot(root, "/var/www"));
		Assert.isTrue(HTTPRequestHandler.__isWithinRoot(root, "/var/www/static/index.html"));
		Assert.isFalse(HTTPRequestHandler.__isWithinRoot(root, "/var/www2/secret.txt"));
		#end
	}

	public function testCorsPreflightReturnsConfiguredHeaders():Void {
		var response = __sendRequest([], "OPTIONS /index.html HTTP/1.1\r\nHost: localhost\r\nOrigin: https://app.example\r\nAccess-Control-Request-Method: POST\r\nAccess-Control-Request-Headers: X-Test\r\n\r\n", null, true);

		Assert.equals(204, response.status);
		Assert.equals("", response.body);
		Assert.equals("*", response.headers.get("access-control-allow-origin"));
		Assert.equals("POST", response.headers.get("access-control-allow-methods"));
		Assert.equals("X-Test", response.headers.get("access-control-allow-headers"));
		Assert.equals("GET, HEAD, OPTIONS, POST", response.headers.get("allow"));
	}


	public function testHeaderScanResumesAcrossChunkBoundaries():Void {
		// The completeness scan carries its last three bytes between data
		// events, so a CRLFCRLF split across arrivals must still be seen —
		// and a rescan-from-zero regression would pass this test too slowly
		// to notice, so the boundary placement is the real assertion here.
		var handler = new HTTPRequestHandler(new Socket(), new HTTPServerConfig(), null);
		var buffer = new ByteArray();

		var chunks = ["GET / HT", "TP/1.1\r", "\nHost: x", "\r", "\n\r", "\n"];
		for (i in 0...chunks.length - 1) {
			buffer.position = buffer.length;
			buffer.writeUTFBytes(chunks[i]);
			buffer.position = 0;
			Assert.isFalse(handler.__hasCompleteHeaderBlock(buffer));
			Assert.equals(0, buffer.position);
		}

		buffer.position = buffer.length;
		buffer.writeUTFBytes(chunks[chunks.length - 1]);
		buffer.position = 0;
		Assert.isTrue(handler.__hasCompleteHeaderBlock(buffer));
		Assert.equals(0, buffer.position);

		// Finding the block resets the scan, so a cleared buffer starts over
		// rather than resuming at an offset into bytes that no longer exist.
		buffer.clear();
		buffer.writeUTFBytes("GET /two HTTP/1.1\nHost: y\n");
		buffer.position = 0;
		Assert.isFalse(handler.__hasCompleteHeaderBlock(buffer));
		buffer.position = buffer.length;
		buffer.writeUTFBytes("\n");
		buffer.position = 0;
		// Bare LF LF terminates a block too; the rewrite must keep that.
		Assert.isTrue(handler.__hasCompleteHeaderBlock(buffer));
	}

	public function testReadLineKeepsByteExactSemantics():Void {
		// One byte in, one code point out — no UTF-8 decoding. A header
		// value carrying 0xE9 must read back as 0xE9, not as a decode error
		// or a replacement character.
		var handler = new HTTPRequestHandler(new Socket(), new HTTPServerConfig(), null);
		var buffer = new ByteArray();
		buffer.writeByte(0x41);
		buffer.writeByte(0xE9);
		buffer.writeByte(13);
		buffer.writeByte(10);
		buffer.position = 0;

		var line = handler.__readLine(buffer);
		Assert.notNull(line);
		Assert.equals(4, line.length);
		Assert.equals(0x41, line.charCodeAt(0));
		Assert.equals(0xE9, line.charCodeAt(1));

		// An incomplete line leaves the buffer where it started.
		var partial = new ByteArray();
		partial.writeUTFBytes("no newline yet");
		partial.position = 0;
		Assert.isNull(handler.__readLine(partial));
		Assert.equals(0, partial.position);
	}

	public function testIncompleteRequestTimesOutWith408():Void {
		// The rate limiter only runs once headers are complete, so a client
		// that trickles and stops would otherwise hold a slot forever. The
		// deadline is the only thing standing between that client and
		// maxConnections exhaustion.
		var response = __sendRequest([], "GET /index.html HTTP/1.1\r\nHost: partial", null, false, null, config -> config.requestTimeout = 0.25);

		Assert.equals(408, response.status);
		Assert.equals("Request Timeout", response.body);
	}

	public function testKeepAliveServesTwoSequentialRequestsOnOneSocket():Void {
		// The core promise of the lifecycle change: one connect, two
		// requests, two responses, no handshake in between.
		var result = __sendRequests([], [
			"GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n",
			"GET /second.html HTTP/1.1\r\nHost: localhost\r\n\r\n"
		]);

		Assert.equals(200, result.responses[0].status);
		Assert.equals("keep-alive", result.responses[0].headers.get("connection"));
		Assert.equals("Hello from middleware test", result.responses[0].body);
		Assert.equals(200, result.responses[1].status);
		Assert.equals("Second fixture body", result.responses[1].body);
		Assert.isFalse(result.closeSeen);
	}

	public function testPipelinedRequestsAnsweredInOrder():Void {
		// Both requests land in one flush, so request two is sitting in
		// __incomingBuffer when response one is written. The old
		// clear-at-response would have silently discarded it; distinct
		// bodies prove both answers arrive, in request order.
		var result = __sendRequests([], [
			"GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n",
			"GET /second.html HTTP/1.1\r\nHost: localhost\r\n\r\n"
		], null, true);

		Assert.equals(2, result.responses.length);
		Assert.equals("Hello from middleware test", result.responses[0].body);
		Assert.equals("Second fixture body", result.responses[1].body);
		Assert.isFalse(result.closeSeen);
	}

	public function testConnectionCloseTokenClosesAfterResponse():Void {
		// Token match, not substring: "Close" inside a multi-token value
		// must count...
		var closing = __sendRequests([], [
			"GET /index.html HTTP/1.1\r\nHost: localhost\r\nConnection: foo, Close\r\n\r\n"
		], null, false, 2.0);

		Assert.equals(200, closing.responses[0].status);
		Assert.equals("close", closing.responses[0].headers.get("connection"));
		Assert.isTrue(closing.closeSeen);

		// ...while a token merely containing "close" must not.
		var kept = __sendRequests([], [
			"GET /index.html HTTP/1.1\r\nHost: localhost\r\nConnection: not-close\r\n\r\n",
			"GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n"
		]);

		Assert.equals("keep-alive", kept.responses[0].headers.get("connection"));
		Assert.equals(200, kept.responses[1].status);
		Assert.isFalse(kept.closeSeen);
	}

	public function testHttp10WithoutTokenCloses():Void {
		// HTTP/1.0 defaults to close; persistence is strictly opt-in.
		var result = __sendRequests([], ["GET /index.html HTTP/1.0\r\n\r\n"], null, false, 2.0);

		Assert.equals(200, result.responses[0].status);
		Assert.equals("close", result.responses[0].headers.get("connection"));
		Assert.isTrue(result.closeSeen);
	}

	public function testHttp10KeepAliveTokenKeepsOpen():Void {
		var result = __sendRequests([], [
			"GET /index.html HTTP/1.0\r\nConnection: keep-alive\r\n\r\n",
			"GET /second.html HTTP/1.0\r\nConnection: keep-alive\r\n\r\n"
		]);

		Assert.equals("keep-alive", result.responses[0].headers.get("connection"));
		Assert.equals("Second fixture body", result.responses[1].body);
		Assert.isFalse(result.closeSeen);
	}

	public function testKeepAliveDisabledMatchesLegacyBehavior():Void {
		var result = __sendRequests([], [
			"GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n"
		], config -> config.keepAlive = false, false, 2.0);

		Assert.equals(200, result.responses[0].status);
		Assert.equals("close", result.responses[0].headers.get("connection"));
		Assert.isTrue(result.closeSeen);
	}

	public function testKeepAliveMaxRequestsClosesOnFinalResponse():Void {
		// A limit of two means exactly two responses, the second already
		// carrying the close -- never a third request answered, never a
		// keep-alive header the server does not honor.
		var result = __sendRequests([], [
			"GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n",
			"GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n"
		], config -> config.keepAliveMaxRequests = 2, false, 2.0);

		Assert.equals("keep-alive", result.responses[0].headers.get("connection"));
		Assert.equals("close", result.responses[1].headers.get("connection"));
		Assert.isTrue(result.closeSeen);
	}

	public function testNotFoundKeepsConnectionUsable():Void {
		// The proposal's motivating case: a page with a missing favicon
		// must not pay a new handshake for the 404. tryFiles is pared
		// down because its default "/index.html" fallback would otherwise
		// turn the miss into a 200.
		var result = __sendRequests([], [
			"GET /missing.html HTTP/1.1\r\nHost: localhost\r\n\r\n",
			"GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n"
		], config -> config.tryFiles = ["$uri"]);

		Assert.equals(404, result.responses[0].status);
		Assert.equals("keep-alive", result.responses[0].headers.get("connection"));
		Assert.equals(200, result.responses[1].status);
		Assert.equals("Hello from middleware test", result.responses[1].body);
		Assert.isFalse(result.closeSeen);
	}

	public function testErrorStatusForcesClose():Void {
		// After a 5xx the handler's state is suspect; the response says
		// close and the socket follows it.
		var result = __sendRequests([
			function(_:HTTPRequestHandler, next:?Dynamic->Void):Void {
				next(500);
			}
		], ["GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n"], null, false, 2.0);

		Assert.equals(500, result.responses[0].status);
		Assert.equals("close", result.responses[0].headers.get("connection"));
		Assert.isTrue(result.closeSeen);
	}

	public function testIdleTimeoutClosesWithoutA408():Void {
		// Sitting idle between requests is not a client fault: the reap
		// is a bare close, not a second response. Exactly one status line
		// may appear on the wire.
		var result = __sendRequests([], [
			"GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n"
		], config -> config.keepAliveTimeout = 0.25, false, 2.0);

		Assert.equals(200, result.responses[0].status);
		Assert.equals("keep-alive", result.responses[0].headers.get("connection"));
		Assert.isTrue(result.closeSeen);
		Assert.equals(1, __countOccurrences(result.raw, "HTTP/1.1 "));
		Assert.equals(-1, result.raw.indexOf("408"));
	}

	public function testMidRequestTimeoutOnReusedConnectionStill408s():Void {
		// The deadline swaps meaning when a reused connection leaves the
		// idle phase: a request that starts arriving and stalls gets the
		// same 408 a first request would.
		var result = __sendRequests([], [
			"GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n",
			"GET /index.html HTTP/1.1\r\nHost: partial"
		], config -> config.requestTimeout = 0.25, false, 2.0);

		Assert.equals(200, result.responses[0].status);
		Assert.equals(408, result.responses[1].status);
		Assert.equals("Request Timeout", result.responses[1].body);
		Assert.isTrue(result.closeSeen);
	}

	public function testPostBodyThenSecondRequestOnSameSocket():Void {
		// Pins the consumption boundary: the POST body is read out of the
		// buffer in full before the response, so the GET behind it is
		// parsed from the preserved tail, not from body bytes.
		var seenBody:String = null;
		var result = __sendRequests([
			function(handler:HTTPRequestHandler, next:?Dynamic->Void):Void {
				if (handler.method == "POST") {
					seenBody = handler.requestText;
					handler.respond(200, "text/plain", "posted:" + handler.requestText);
				} else {
					next();
				}
			}
		], [
			"POST /index.html HTTP/1.1\r\nHost: localhost\r\nContent-Length: 11\r\n\r\nhello world",
			"GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n"
		]);

		Assert.equals("hello world", seenBody);
		Assert.equals(200, result.responses[0].status);
		Assert.equals("posted:hello world", result.responses[0].body);
		Assert.equals(200, result.responses[1].status);
		Assert.equals("Hello from middleware test", result.responses[1].body);
		Assert.isFalse(result.closeSeen);
	}

	public function testRespondThenNextEmitsSingleResponse():Void {
		// A middleware that violates the respond-xor-next contract must
		// produce one response, not two: the stale continuation is
		// suppressed, and the connection stays usable for the request
		// after it.
		var result = __sendRequests([
			function(handler:HTTPRequestHandler, next:?Dynamic->Void):Void {
				handler.respond(200, "text/plain", "from middleware");
				next();
			}
		], [
			"GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n",
			"GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n"
		]);

		Assert.equals(2, result.responses.length);
		Assert.equals("from middleware", result.responses[0].body);
		Assert.equals("from middleware", result.responses[1].body);
		Assert.equals(2, __countOccurrences(result.raw, "HTTP/1.1 "));
		Assert.isFalse(result.closeSeen);
	}

	public function testExpectContinueOnKeptAliveConnection():Void {
		// The interim 100 is written raw, before the builders, and must
		// neither count as the response nor confuse the per-response
		// framing on a connection that stays open afterwards.
		var bodyText:String = null;
		var result = __sendRequests([
			function(handler:HTTPRequestHandler, next:?Dynamic->Void):Void {
				if (handler.method == "POST") {
					bodyText = handler.requestText;
					handler.respond(200, "text/plain", "got:" + handler.requestText);
				} else {
					next();
				}
			}
		], [
			"POST /index.html HTTP/1.1\r\nHost: localhost\r\nExpect: 100-continue\r\nContent-Length: 7\r\n\r\npayload",
			"GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n"
		]);

		Assert.equals("payload", bodyText);
		Assert.isTrue(result.responses[0].raw.indexOf("HTTP/1.1 100 Continue") == 0);
		Assert.equals(200, result.responses[0].status);
		Assert.equals("got:payload", result.responses[0].body);
		Assert.equals(200, result.responses[1].status);
		Assert.isFalse(result.closeSeen);
	}

	public function testHeadKeepsConnectionOpen():Void {
		// HEAD advertises a length it never sends; the consumption logic
		// must not wait for a body that is not coming, on either side.
		var result = __sendRequests([], [
			"HEAD /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n",
			"GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n"
		]);

		Assert.equals(200, result.responses[0].status);
		Assert.equals("", result.responses[0].body);
		Assert.equals("26", result.responses[0].headers.get("content-length"));
		Assert.equals(200, result.responses[1].status);
		Assert.equals("Hello from middleware test", result.responses[1].body);
		Assert.isFalse(result.closeSeen);
	}

	public function testLateAsynchronousNextCannotAnswerALaterRequest():Void {
		// testRespondThenNextEmitsSingleResponse covers the synchronous
		// violation. This covers the asynchronous one: request one answers
		// inline and leaves a continuation to fire ticks later, while
		// request two deliberately holds its own slot open so the stale
		// continuation lands while a request is in flight rather than
		// after it.
		//
		// What this pins is the observable contract — two requests, two
		// responses, no third status line on the wire. It does NOT isolate
		// any single guard: the connection carries three overlapping ones
		// (`alreadyCalled` per continuation, `__responded` per slot, and
		// the generation stamp), and this case still passes with the
		// generation check deleted, so some combination of the other two
		// covers this particular timing. Deleting the generation stamp on
		// the strength of that would be a mistake — it is the only guard
		// that can refuse a continuation whose slot has already been
		// answered and replaced — but no test here proves it, and this
		// comment is the honest record of that gap.
		var seen:Int = 0;
		var result = __sendRequests([
			function(handler:HTTPRequestHandler, next:?Dynamic->Void):Void {
				seen++;
				if (seen == 1) {
					handler.respond(200, "text/plain", "answered inline");
					Timer.delay(function() {
						next();
					}, 60);
				} else {
					Timer.delay(function() {
						next();
					}, 220);
				}
			}
		], [
			"GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n",
			"GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n"
		], null, false, 0.6);

		Assert.equals(2, result.responses.length);
		Assert.equals("answered inline", result.responses[0].body);
		Assert.equals("Hello from middleware test", result.responses[1].body);
		// The count is the assertion that matters: a stale continuation that
		// got through would put a third status line on the wire.
		Assert.equals(2, __countOccurrences(result.raw, "HTTP/1.1 "));
	}

	public function testRejectedIdentityEncodingAnswersOneNotAcceptable():Void {
		// identity;q=0 forbids the only coding an error body can be sent in,
		// so the 406 explaining that used to be negotiated against the very
		// header it was answering: reject, send 406, negotiate, reject. The
		// recursion had no floor and took the connection's thread with it.
		var response = __sendRequest([], "GET /index.html HTTP/1.1\r\nHost: localhost\r\nAccept-Encoding: identity;q=0\r\n\r\n");

		Assert.equals(406, response.status);
		Assert.equals(1, __countOccurrences(response.raw, "HTTP/1.1 "));
	}
	private function __sendRequest(middleware:Array<(HTTPRequestHandler, ?Dynamic->Void) -> Void>, requestText:String, ?secondChunk:String, corsEnabled:Bool = false, ?requestBody:ByteArray, ?configure:HTTPServerConfig->Void):HTTPTestResponse {
		var root = File.createTempDirectory();
		var indexFile = root.resolvePath("index.html");
		var fixture = new ByteArray();
		fixture.writeUTFBytes("Hello from middleware test");
		indexFile.save(fixture);

		var config = new HTTPServerConfig("127.0.0.1", 0, root, null, ["index.html"], null, null, null, middleware, null, corsEnabled);
		if (configure != null) {
			configure(config);
		}
		var server = new HTTPServer(config);
		var client = new Socket();
		var rawResponse = "";
		var closeSeen = false;
		var response:HTTPTestResponse = null;
		var rawResponseBytes = new ByteArray();

		client.addEventListener(Event.CONNECT, _ -> {
			client.writeUTFBytes(requestText);
			if (requestBody != null) {
				client.writeBytes(requestBody, 0, requestBody.length);
			}
			client.flush();
			if (secondChunk != null) {
				Timer.delay(function() {
					if (client.connected) {
						client.writeUTFBytes(secondChunk);
						client.flush();
					}
				}, 10);
			}
		});
		client.addEventListener(ProgressEvent.SOCKET_DATA, _ -> {
			if (client.bytesAvailable > 0) {
				var chunk:ByteArray = new ByteArray();
				client.readBytes(chunk, 0, client.bytesAvailable);
				rawResponseBytes.writeBytes(chunk, 0, chunk.length);
				for (i in 0...chunk.length) {
					rawResponse += String.fromCharCode(chunk[i]);
				}
			}
		});
		client.addEventListener(Event.CLOSE, _ -> closeSeen = true);
		var requestFailed:Dynamic = null;

		// HEAD responses end at their header terminator; waiting for the
		// advertised Content-Length would burn the whole pump timeout now
		// that a HEAD response no longer ends its connection.
		var headOnly:Bool = StringTools.startsWith(requestText, "HEAD ");
		try {
			client.connect("127.0.0.1", server.localPort);
			__pumpUntil(() -> closeSeen || __isResponseComplete(rawResponse, headOnly), 2.0);
			response = __parseResponse(rawResponse, rawResponseBytes);
			try {
				client.close();
			} catch (_:Dynamic) {}
		} catch (error:Dynamic) {
			requestFailed = error;
		}

		try {
			server.close();
		} catch (_:Dynamic) {}
		try {
			root.deleteDirectory(true);
		} catch (_:Dynamic) {}

		if (requestFailed != null) {
			throw requestFailed;
		}

		Assert.notNull(response);
		return response;
	}

	/**
	 * Sends several requests over ONE socket and splits the byte stream
	 * back into responses — the single-connect-many-responses shape that
	 * keep-alive exists to produce and that `__sendRequest` cannot
	 * observe.
	 *
	 * Sequential mode writes each request only after the previous
	 * response is complete, asserting the connection is still open at
	 * that moment; pipelined mode writes everything in one flush and
	 * walks the same cursor over however many responses come back.
	 * `waitAfter` keeps pumping after the last response so a test can
	 * observe (or rule out) a server-initiated close.
	 */
	private function __sendRequests(middleware:Array<(HTTPRequestHandler, ?Dynamic->Void) -> Void>, requests:Array<String>, ?configure:HTTPServerConfig->Void,
			pipelined:Bool = false, waitAfter:Float = 0):{responses:Array<HTTPTestResponse>, closeSeen:Bool, raw:String} {
		var root = File.createTempDirectory();
		var indexFile = root.resolvePath("index.html");
		var fixture = new ByteArray();
		fixture.writeUTFBytes("Hello from middleware test");
		indexFile.save(fixture);
		// A second, distinct fixture so ordering tests can tell response
		// N from response N+1 by body alone.
		var secondFile = root.resolvePath("second.html");
		var secondFixture = new ByteArray();
		secondFixture.writeUTFBytes("Second fixture body");
		secondFile.save(secondFixture);

		var config = new HTTPServerConfig("127.0.0.1", 0, root, null, ["index.html"], null, null, null, middleware);
		if (configure != null) {
			configure(config);
		}
		var server = new HTTPServer(config);
		var client = new Socket();
		var rawResponse = "";
		var closeSeen = false;
		var serverClosedFirst = false;
		var responses:Array<HTTPTestResponse> = [];
		var requestFailed:Dynamic = null;

		client.addEventListener(Event.CONNECT, _ -> {
			client.writeUTFBytes(pipelined ? requests.join("") : requests[0]);
			client.flush();
		});
		client.addEventListener(ProgressEvent.SOCKET_DATA, _ -> {
			if (client.bytesAvailable > 0) {
				var chunk:ByteArray = new ByteArray();
				client.readBytes(chunk, 0, client.bytesAvailable);
				for (i in 0...chunk.length) {
					rawResponse += String.fromCharCode(chunk[i]);
				}
			}
		});
		client.addEventListener(Event.CLOSE, _ -> closeSeen = true);

		try {
			client.connect("127.0.0.1", server.localPort);

			var cursor = 0;
			for (i in 0...requests.length) {
				var headOnly = StringTools.startsWith(requests[i], "HEAD ");
				var sliceEnd = -1;
				__pumpUntil(() -> {
					sliceEnd = __responseEndAt(rawResponse, cursor, headOnly);
					return sliceEnd >= 0;
				}, 2.0);
				if (sliceEnd < 0) {
					throw 'response ${i} never completed; received: ${rawResponse.substr(cursor)}';
				}

				var slice = rawResponse.substring(cursor, sliceEnd);
				var sliceBytes = new ByteArray();
				for (j in cursor...sliceEnd) {
					sliceBytes.writeByte(rawResponse.charCodeAt(j) & 0xFF);
				}
				responses.push(__parseResponse(slice, sliceBytes));
				cursor = sliceEnd;

				if (!pipelined && i < requests.length - 1) {
					// The point of the sequential mode: the connection must
					// still be open when the next request goes out.
					Assert.isFalse(closeSeen);
					client.writeUTFBytes(requests[i + 1]);
					client.flush();
				}
			}

			if (waitAfter > 0) {
				__pumpUntil(() -> closeSeen, waitAfter);
			}

			// Snapshot before the harness closes its own end: Socket.close()
			// dispatches Event.CLOSE for a locally initiated close too, so
			// reading the flag afterwards would report every connection as
			// closed and the keep-alive assertions would test nothing.
			serverClosedFirst = closeSeen;

			try {
				client.close();
			} catch (_:Dynamic) {}
		} catch (error:Dynamic) {
			requestFailed = error;
		}

		try {
			server.close();
		} catch (_:Dynamic) {}
		try {
			root.deleteDirectory(true);
		} catch (_:Dynamic) {}

		if (requestFailed != null) {
			throw requestFailed;
		}

		return {responses: responses, closeSeen: serverClosedFirst, raw: rawResponse};
	}

	private static function __countOccurrences(haystack:String, needle:String):Int {
		var count = 0;
		var at = haystack.indexOf(needle);
		while (at >= 0) {
			count++;
			at = haystack.indexOf(needle, at + needle.length);
		}
		return count;
	}

	private static function __isResponseComplete(raw:String, headOnly:Bool = false):Bool {
		return __responseEndAt(raw, 0, headOnly) >= 0;
	}

	/**
	 * Absolute index one past the end of the response that starts at
	 * `start`, or -1 while it is still incomplete. Skips leading 1xx
	 * interim blocks (Expect: 100-continue), which carry no framing of
	 * their own; without that skip a kept-alive connection never closes
	 * and completeness would only ever be decided by the pump timeout.
	 * `headOnly` ends the response at its header terminator, since a HEAD
	 * response advertises a Content-Length it will never send.
	 */
	private static function __responseEndAt(raw:String, start:Int, headOnly:Bool):Int {
		while (raw.indexOf("HTTP/1.1 100 ", start) == start || raw.indexOf("HTTP/1.0 100 ", start) == start) {
			var interimEnd = raw.indexOf("\r\n\r\n", start);
			if (interimEnd < 0) {
				return -1;
			}
			start = interimEnd + 4;
		}

		var headerEnd = raw.indexOf("\r\n\r\n", start);
		if (headerEnd < 0) {
			return -1;
		}

		var bodyStart = headerEnd + 4;
		if (headOnly) {
			return bodyStart;
		}

		for (line in raw.substring(start, headerEnd).split("\r\n")) {
			var lower = StringTools.trim(line).toLowerCase();
			if (lower.indexOf("content-length:") == 0) {
				var len:Null<Int> = Std.parseInt(StringTools.trim(lower.substr(15)));
				if (len == null) {
					return -1;
				}
				return raw.length >= bodyStart + len ? bodyStart + len : -1;
			}
		}
		return -1;
	}

	private static function __parseResponse(raw:String, rawBytes:ByteArray):HTTPTestResponse {
		var originalRaw = raw;
		var parseText = raw;
		var parseBytes = rawBytes;
		while (parseText.indexOf("HTTP/1.1 100 ") == 0 || parseText.indexOf("HTTP/1.0 100 ") == 0) {
			var interimEnd = parseText.indexOf("\r\n\r\n");
			if (interimEnd < 0) {
				break;
			}
			var drop = interimEnd + 4;
			parseText = parseText.substr(drop);
			if (parseBytes != null) {
				var next = new ByteArray();
				if (parseBytes.length > drop) {
					next.writeBytes(parseBytes, drop, parseBytes.length - drop);
				}
				parseBytes = next;
			}
		}

		while (raw.indexOf("HTTP/1.1 100 ") == 0 || raw.indexOf("HTTP/1.0 100 ") == 0) {
			var interimEnd = raw.indexOf("\r\n\r\n");
			if (interimEnd < 0) {
				break;
			}
			raw = raw.substr(interimEnd + 4);
		}

		var lineEnd = parseText.indexOf("\r\n");
		var statusLine = parseText.substr(0, lineEnd);
		var status = 0;
		if (statusLine != null && statusLine.length >= 12) {
			status = Std.parseInt(statusLine.substr(9, 3));
		}

		var body = "";
		var headers:Map<String, String> = new Map();
		var headerEnd = parseText.indexOf("\r\n\r\n");
		if (headerEnd >= 0) {
			var headerLines = parseText.substr(lineEnd + 2, headerEnd - lineEnd - 2).split("\r\n");
			for (line in headerLines) {
				var separator = line.indexOf(":");
				if (separator > 0) {
					headers.set(StringTools.trim(line.substr(0, separator)).toLowerCase(), StringTools.trim(line.substr(separator + 1)));
				}
			}
			body = parseText.substr(headerEnd + 4);
		}

		var responseBody = new ByteArray();
		if (parseBytes != null && headerEnd >= 0 && parseBytes.length >= (headerEnd + 4)) {
			var bodyStart:Int = headerEnd + 4;
			responseBody.writeBytes(parseBytes, bodyStart, parseBytes.length - bodyStart);
		}

		return {
			status: status,
			headers: headers,
			body: body,
			bodyBytes: responseBody,
			raw: originalRaw
		};
	}

	private function __pumpUntil(done:Void->Bool, timeout:Float):Void {
		var runtime = CrossByte.current();
		var deadline = Sys.time() + timeout;
		while (!done() && Sys.time() < deadline) {
			runtime.pump(1 / 60, 0);
			Sys.sleep(0.001);
		}
	}
}

typedef HTTPTestResponse = {
	var status:Int;
	var headers:Map<String, String>;
	var body:String;
	var bodyBytes:ByteArray;
	var raw:String;
}
