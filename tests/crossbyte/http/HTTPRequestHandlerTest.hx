package crossbyte.http;

import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.ProgressEvent;
import crossbyte.io.ByteArray;
import crossbyte.io.File;
import crossbyte.net.Socket;
import crossbyte.utils.CompressionAlgorithm;
import haxe.Timer;
import crossbyte.http.HTTPTestSupport.HTTPTestResponse;
import crossbyte.errors.ArgumentError;
import utest.Assert;
import utest.Async;

@:access(crossbyte.http.HTTPRequestHandler)
// Every case here waits on a socket, and some wait on a server-side timeout
// deliberately -- an idle keep-alive connection closing, an incomplete request
// answering 408. utest allows an asynchronous case 250ms by default, which is
// shorter than the behaviour under test, so four of them reported "async is
// timed out" rather than what they measured. The budget is a ceiling on a hang,
// not a target: a healthy run spends nowhere near it.
@:timeout(20000)
class HTTPRequestHandlerTest extends utest.Test {
	public function testNoMiddlewarePreservesStaticRouting(async:Async):Void {
		__sendRequest(async, [], "GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n", function(response):Void {

			Assert.equals(200, response.status);
			Assert.equals("Hello from middleware test", response.body);
			async.done();
		});
	}

	public function testSplitHeadersWaitForCompleteRequest(async:Async):Void {
		__sendRequest(async, [], "GET /index.html HTTP/1.1\r\n", function(response):Void {

			Assert.equals(200, response.status);
			Assert.equals("Hello from middleware test", response.body);
			async.done();
		}, "Host: localhost\r\n\r\n");
	}

	public function testHttp11RequiresHostHeader(async:Async):Void {
		__sendRequest(async, [], "GET /index.html HTTP/1.1\r\n\r\n", function(response):Void {

			Assert.equals(400, response.status);
			Assert.equals("Bad Request", response.body);
			async.done();
		});
	}

	public function testHttp10AllowsMissingHostHeader(async:Async):Void {
		__sendRequest(async, [], "GET /index.html HTTP/1.0\r\n\r\n", function(response):Void {

			Assert.equals(200, response.status);
			Assert.equals("Hello from middleware test", response.body);
			async.done();
		});
	}

	public function testAbsoluteFormRequestTargetRoutesToPath(async:Async):Void {
		__sendRequest(async, [], "GET http://localhost/index.html?mode=absolute HTTP/1.1\r\nHost: localhost\r\n\r\n", function(response):Void {

			Assert.equals(200, response.status);
			Assert.equals("Hello from middleware test", response.body);
			async.done();
		});
	}

	public function testHeadReturnsContentLengthWithoutBody(async:Async):Void {
		__sendRequest(async, [], "HEAD /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n", function(response):Void {

			Assert.equals(200, response.status);
			Assert.equals("", response.body);
			Assert.equals("26", response.headers.get("content-length"));
			async.done();
		});
	}

	public function testRangeRequestReturnsPartialContent(async:Async):Void {
		__sendRequest(async, [], "GET /index.html HTTP/1.1\r\nHost: localhost\r\nRange: bytes=6-9\r\n\r\n", function(response):Void {

			Assert.equals(206, response.status);
			Assert.equals("from", response.body);
			Assert.equals("4", response.headers.get("content-length"));
			Assert.isTrue(response.headers.get("content-range").indexOf("bytes 6-9/") == 0);
			async.done();
		});
	}

	public function testSuffixRangeRequestReturnsTail(async:Async):Void {
		__sendRequest(async, [], "GET /index.html HTTP/1.1\r\nHost: localhost\r\nRange: bytes=-4\r\n\r\n", function(response):Void {

			Assert.equals(206, response.status);
			Assert.equals("test", response.body);
			Assert.equals("4", response.headers.get("content-length"));
			async.done();
		});
	}

	public function testInvalidRangeReturns416(async:Async):Void {
		__sendRequest(async, [], "GET /index.html HTTP/1.1\r\nHost: localhost\r\nRange: bytes=999-1000\r\n\r\n", function(response):Void {

			Assert.equals(416, response.status);
			Assert.equals("Requested Range Not Satisfiable", response.body);
			Assert.isTrue(response.headers.get("content-range").indexOf("bytes */") == 0);
			async.done();
		});
	}

	public function testIfModifiedSinceReturns304(async:Async):Void {
		// Nested rather than sequential because it has to be: the second
		// request carries the Last-Modified the first one answered with.
		__sendRequest(async, [], "GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n", function(first):Void {
			var lastModified = first.headers.get("last-modified");

			Assert.equals(200, first.status);
			Assert.notNull(lastModified);

			__sendRequest(async, [], 'GET /index.html HTTP/1.1\r\nHost: localhost\r\nIf-Modified-Since: ${lastModified}\r\n\r\n', function(second):Void {
				Assert.equals(304, second.status);
				Assert.equals("", second.body);
				async.done();
			});
		});
	}

	public function testMiddlewareHelpersAreAvailableAndCaseInsensitive(async:Async):Void {
		var method:String = null;
		var requestPath:String = null;
		var queryString:String = null;
		var uaHeader:String = null;
		var hasUaHeader:Bool = false;

		__sendRequest(async, [
			function(handler:HTTPRequestHandler, next:?Dynamic->Void):Void {
				method = handler.method;
				requestPath = handler.requestPath;
				queryString = handler.queryString;
				uaHeader = handler.getHeader("x-trace");
				hasUaHeader = handler.hasHeader("X-Trace");
				next();
			}
		], "GET /index.html?foo=bar&mode=test HTTP/1.1\r\nHost: localhost\r\nX-Trace: yes\r\n\r\n", function(response):Void {

			Assert.equals(200, response.status);
			Assert.equals("GET", method);
			Assert.equals("/index.html", requestPath);
			Assert.equals("foo=bar&mode=test", queryString);
			Assert.equals("yes", uaHeader);
			Assert.isTrue(hasUaHeader);
			async.done();
		});
	}

	public function testMiddlewareCanReadContentLengthRequestBody(async:Async):Void {
		var bodyText:String = null;
		var bodyLength:UInt = 0;
		__sendRequest(async, [
			function(handler:HTTPRequestHandler, next:?Dynamic->Void):Void {
				bodyText = handler.requestText;
				bodyLength = handler.requestBody.length;
				next();
			}
		], "POST /index.html HTTP/1.1\r\nHost: localhost\r\nContent-Length: 11\r\n\r\nhello world", function(response):Void {

			Assert.equals("hello world", bodyText);
			Assert.equals(11, bodyLength);
			Assert.equals(405, response.status);
			async.done();
		});
	}

	public function testMiddlewareCanReadChunkedRequestBody(async:Async):Void {
		var bodyText:String = null;
		__sendRequest(async, [
			function(handler:HTTPRequestHandler, next:?Dynamic->Void):Void {
				bodyText = handler.requestText;
				next();
			}
		], "POST /index.html HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n5;ext=1\r\npedia\r\n0\r\nX-Trailer: yes\r\n\r\n", function(response):Void {

			Assert.equals("Wikipedia", bodyText);
			Assert.equals(405, response.status);
			async.done();
		});
	}

	public function testMiddlewareCanReadGzipRequestBody(async:Async):Void {
		var bodyText:String = null;
		var body:ByteArray = new ByteArray();
		body.writeUTFBytes("hello world");
		body.compress(CompressionAlgorithm.GZIP);

		__sendRequest(async, [
			function(handler:HTTPRequestHandler, next:?Dynamic->Void):Void {
				bodyText = handler.requestText;
				next();
			}
		], 'POST /index.html HTTP/1.1\r\nHost: localhost\r\nContent-Encoding: gzip\r\nContent-Length: ${body.length}\r\n\r\n', function(response):Void {

			Assert.equals("hello world", bodyText);
			Assert.equals(405, response.status);
			async.done();
		}, null, false, body);
	}

	public function testMiddlewareCanReadDeflateRequestBody(async:Async):Void {
		var bodyText:String = null;
		var body:ByteArray = new ByteArray();
		body.writeUTFBytes("hello world");
		body.compress(CompressionAlgorithm.DEFLATE);

		__sendRequest(async, [
			function(handler:HTTPRequestHandler, next:?Dynamic->Void):Void {
				bodyText = handler.requestText;
				next();
			}
		], 'POST /index.html HTTP/1.1\r\nHost: localhost\r\nContent-Encoding: deflate\r\nContent-Length: ${body.length}\r\n\r\n', function(response):Void {

			Assert.equals("hello world", bodyText);
			Assert.equals(405, response.status);
			async.done();
		}, null, false, body);
	}

	public function testMiddlewareCanReadBrotliRequestBody(async:Async):Void {
		var bodyText:String = null;
		var body:ByteArray = new ByteArray();
		body.writeUTFBytes("hello world");
		body.compress(CompressionAlgorithm.BROTLI);

		__sendRequest(async, [
			function(handler:HTTPRequestHandler, next:?Dynamic->Void):Void {
				bodyText = handler.requestText;
				next();
			}
		], 'POST /index.html HTTP/1.1\r\nHost: localhost\r\nContent-Encoding: br\r\nContent-Length: ${body.length}\r\n\r\n', function(response):Void {

			Assert.equals("hello world", bodyText);
			Assert.equals(405, response.status);
			async.done();
		}, null, false, body);
	}

	public function testUnsupportedRequestContentEncodingReturns415AndSkipsRouting(async:Async):Void {
		var body:ByteArray = new ByteArray();
		body.writeUTFBytes("hello world");
		var middlewareCalled = false;

		__sendRequest(async, [
			function(_:HTTPRequestHandler, next:?Dynamic->Void):Void {
				middlewareCalled = true;
				next();
			}
		], 'POST /index.html HTTP/1.1\r\nHost: localhost\r\nContent-Encoding: zstd\r\nContent-Length: ${body.length}\r\n\r\n', function(response):Void {

			Assert.equals(415, response.status);
			Assert.equals("Unsupported Content-Encoding: zstd", response.body);
			Assert.isFalse(middlewareCalled);
			async.done();
		}, null, false, body);
	}

	public function testResponseCompressionNegotiatesGzip(async:Async):Void {
		__sendRequest(async, [], 'GET /index.html HTTP/1.1\r\nHost: localhost\r\nAccept-Encoding: gzip\r\n\r\n', function(response):Void {

			Assert.equals(200, response.status);
			Assert.equals("gzip", response.headers.get("content-encoding"));

			var decompressed = new ByteArray();
			decompressed.writeBytes(response.bodyBytes, 0, response.bodyBytes.length);
			decompressed.uncompress(CompressionAlgorithm.GZIP);
			Assert.equals("Hello from middleware test", decompressed.toString());
			Assert.notEquals("Hello from middleware test", response.body);
			async.done();
		}, null, true);
	}

	public function testWildcardNegotiationDoesNotReviveExplicitlyRejectedGzip(async:Async):Void {
		__sendRequest(async, [], 'GET /index.html HTTP/1.1\r\nHost: localhost\r\nAccept-Encoding: gzip;q=0, *;q=1\r\n\r\n', function(response):Void {

			Assert.equals(200, response.status);
			Assert.equals("deflate", response.headers.get("content-encoding"));

			var decompressed = new ByteArray();
			decompressed.writeBytes(response.bodyBytes, 0, response.bodyBytes.length);
			decompressed.uncompress(CompressionAlgorithm.DEFLATE);
			Assert.equals("Hello from middleware test", decompressed.toString());
			async.done();
		}, null, true);
	}

	public function testResponseCompressionCanNegotiateLz4(async:Async):Void {
		__sendRequest(async, [], 'GET /index.html HTTP/1.1\r\nHost: localhost\r\nAccept-Encoding: lz4\r\n\r\n', function(response):Void {

			Assert.equals(200, response.status);
			Assert.equals("lz4", response.headers.get("content-encoding"));

			var decompressed = new ByteArray();
			decompressed.writeBytes(response.bodyBytes, 0, response.bodyBytes.length);
			decompressed.uncompress(CompressionAlgorithm.LZ4);
			Assert.equals("Hello from middleware test", decompressed.toString());
			async.done();
		}, null, true);
	}

	public function testResponseCompressionCanNegotiateBrotli(async:Async):Void {
		__sendRequest(async, [], 'GET /index.html HTTP/1.1\r\nHost: localhost\r\nAccept-Encoding: br\r\n\r\n', function(response):Void {

			Assert.equals(200, response.status);
			Assert.equals("br", response.headers.get("content-encoding"));

			var decompressed = new ByteArray();
			decompressed.writeBytes(response.bodyBytes, 0, response.bodyBytes.length);
			decompressed.uncompress(CompressionAlgorithm.BROTLI);
			Assert.equals("Hello from middleware test", decompressed.toString());
			async.done();
		}, null, true);
	}

	public function testRangeResponseSkipsCompressionNegotiation(async:Async):Void {
		__sendRequest(async, [], "GET /index.html HTTP/1.1\r\nHost: localhost\r\nRange: bytes=6-9\r\nAccept-Encoding: gzip\r\n\r\n", function(response):Void {

			Assert.equals(206, response.status);
			Assert.equals("from", response.body);
			Assert.isNull(response.headers.get("content-encoding"));
			Assert.equals("4", response.headers.get("content-length"));
			async.done();
		});
	}

	public function testExpectContinueSendsInterimResponseAndReadsBody(async:Async):Void {
		var bodyText:String = null;
		__sendRequest(async, [
			function(handler:HTTPRequestHandler, next:?Dynamic->Void):Void {
				bodyText = handler.requestText;
				next();
			}
		], "POST /index.html HTTP/1.1\r\nHost: localhost\r\nExpect: 100-continue\r\nContent-Length: 7\r\n\r\npayload", function(response):Void {

			Assert.equals("payload", bodyText);
			Assert.isTrue(response.raw.indexOf("HTTP/1.1 100 Continue") == 0);
			Assert.equals(405, response.status);
			async.done();
		});
	}

	public function testUnknownExpectationReturns417(async:Async):Void {
		var middlewareCalled = false;
		__sendRequest(async, [
			function(_:HTTPRequestHandler, next:?Dynamic->Void):Void {
				middlewareCalled = true;
				next();
			}
		], "POST /index.html HTTP/1.1\r\nHost: localhost\r\nExpect: magic\r\nContent-Length: 7\r\n\r\npayload", function(response):Void {

			Assert.equals(417, response.status);
			Assert.equals("Expectation Failed", response.body);
			Assert.isFalse(middlewareCalled);
			async.done();
		});
	}

	public function testUnsupportedTransferEncodingReturns501(async:Async):Void {
		var middlewareCalled = false;
		__sendRequest(async, [
			function(_:HTTPRequestHandler, next:?Dynamic->Void):Void {
				middlewareCalled = true;
				next();
			}
		], "POST /index.html HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: gzip\r\n\r\npayload", function(response):Void {

			Assert.equals(501, response.status);
			Assert.equals("Transfer-Encoding not supported", response.body);
			Assert.isFalse(middlewareCalled);
			async.done();
		});
	}

	public function testMiddlewareRunsInOrderAndCanReturnStatusCode(async:Async):Void {
		var order:Array<String> = [];
		__sendRequest(async, [
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
		], "GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n", function(response):Void {

			Assert.equals(2, order.length);
			Assert.equals("1", order[0]);
			Assert.equals("2", order[1]);
			Assert.equals(404, response.status);
			Assert.equals("Not Found", response.body);
			async.done();
		});
	}

	public function testMiddlewareNextCalledTwiceIsIgnored(async:Async):Void {
		var calls = 0;
		__sendRequest(async, [
			function(_:HTTPRequestHandler, next:?Dynamic->Void):Void {
				calls++;
				next();
				next(500);
			}
		], "GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n", function(response):Void {

			Assert.equals(1, calls);
			Assert.equals(200, response.status);
			Assert.equals("Hello from middleware test", response.body);
			async.done();
		});
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

	public function testCorsPreflightReturnsConfiguredHeaders(async:Async):Void {
		__sendRequest(async, [], "OPTIONS /index.html HTTP/1.1\r\nHost: localhost\r\nOrigin: https://app.example\r\nAccess-Control-Request-Method: POST\r\nAccess-Control-Request-Headers: X-Test\r\n\r\n", function(response):Void {

			Assert.equals(204, response.status);
			Assert.equals("", response.body);
			Assert.equals("*", response.headers.get("access-control-allow-origin"));
			Assert.equals("POST", response.headers.get("access-control-allow-methods"));
			Assert.equals("X-Test", response.headers.get("access-control-allow-headers"));
			Assert.equals("GET, HEAD, OPTIONS, POST", response.headers.get("allow"));
			async.done();
		}, null, true);
	}


	public function testCorsPreflightKeepsTheConnectionAlive(async:Async):Void {
		// The preflight used to write its own response and close by hand, so
		// every one cost a fresh connection -- and a full TLS handshake where
		// enabled -- immediately before the request it was clearing. Browsers
		// send these ahead of a great many ordinary requests.
		__sendRequests(async, [], [
			"OPTIONS /index.html HTTP/1.1\r\nHost: localhost\r\nOrigin: https://app.example\r\nAccess-Control-Request-Method: POST\r\n\r\n",
			"GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n"
		], function(result):Void {

			Assert.equals(204, result.responses[0].status);
			Assert.equals(200, result.responses[1].status);
			Assert.isFalse(result.closeSeen);
			async.done();
		}, config -> config.corsEnabled = true);
	}

	public function testCorsPreflightGoesThroughTheSharedBuilder(async:Async):Void {
		// Proof that the preflight is built by the same path as every other
		// response rather than by hand: a header configured on the server,
		// which only the shared builder applies, has to appear on it.
		__sendRequest(async, [], "OPTIONS /index.html HTTP/1.1\r\nHost: localhost\r\nOrigin: https://app.example\r\nAccess-Control-Request-Method: POST\r\n\r\n", function(response):Void {

			Assert.equals(204, response.status);
			Assert.equals("shared-builder", response.headers.get("x-server-tag"));
			async.done();
		}, null, true, null, config -> {
			config.customHeaders.push(new crossbyte.url.URLRequestHeader("X-Server-Tag", "shared-builder"));
		});
	}

	public function testBodilessStatusesCarryNoContentLength(async:Async):Void {
		// RFC 7230 3.3.2 forbids Content-Length on a 204, and 3.3.3 has the
		// client end such a response at the blank line regardless -- so the
		// header was both disallowed and redundant. The preflight sent
		// "Content-Length: 0" for as long as it built its own response.
		__sendRequest(async, [], "OPTIONS /index.html HTTP/1.1\r\nHost: localhost\r\nOrigin: https://app.example\r\nAccess-Control-Request-Method: POST\r\n\r\n", function(response):Void {

			Assert.equals(204, response.status);
			Assert.isFalse(response.headers.exists("content-length"));
			async.done();
		}, null, true);
	}

	public function testStaleMiddlewareContinuationCannotReachALaterRequest(async:Async):Void {
		// The request-generation guard, isolated.
		//
		// A middleware is supposed to respond or call next(), not both. One
		// that responds and then calls next() later -- after an await, a timer,
		// a worker completion -- is calling into a request that has already
		// finished. The `alreadyCalled` latch beside the guard does not cover
		// it, because next() was never called the first time; and __responded
		// does not, because the connection has been reset for the next request
		// and it is false again. Only the generation stamp can tell that the
		// slot the continuation belongs to has closed.
		//
		// Firing the stale continuation from inside the SECOND request is what
		// makes this the guard rather than a restatement of the latch: the
		// generation only advances when request one is reset away, so a
		// continuation fired any earlier still matches its own slot and proves
		// nothing. Two earlier attempts at this test passed with the guard
		// deleted for exactly that reason.
		//
		// What breaks without it is not an extra response but a substituted
		// one: the revived chain runs request one's routing to completion and
		// its body lands in request two's slot, so a client that asked for
		// /second.html is served /index.html. Two responses, correct framing,
		// wrong contents -- which is why the body assertions below matter more
		// than the count.
		var stale:Null<?Dynamic->Void> = null;
		var runs:Int = 0;

		var middleware = function(handler:HTTPRequestHandler, ?next:?Dynamic->Void):Void {
			runs++;

			if (runs == 1) {
				// Respond and keep the continuation instead of calling it.
				stale = next;
				handler.respond(200, "text/plain", "first");
				return;
			}

			if (stale != null) {
				var fire = stale;
				stale = null;
				// Belongs to a request that is over. Must do nothing at all --
				// running it would push request one's remaining chain, and its
				// response, into request two's slot.
				fire();
			}

			next();
		};

		__sendRequests(async, [middleware], ["GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n", "GET /second.html HTTP/1.1\r\nHost: localhost\r\n\r\n"], function(result):Void {

			Assert.equals(2, result.responses.length);
			Assert.equals(200, result.responses[0].status);
			Assert.equals("first", result.responses[0].body);

			// Request two is answered once, by its own routing, with its own body.
			Assert.equals(200, result.responses[1].status);
			Assert.equals("Second fixture body", result.responses[1].body);

			// And nothing trailing: a revived chain would append a third response
			// to the same connection.
			Assert.equals(2, HTTPTestSupport.countResponses(result.raw));
			async.done();
		});
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

	public function testIncompleteRequestTimesOutWith408(async:Async):Void {
		// The rate limiter only runs once headers are complete, so a client
		// that trickles and stops would otherwise hold a slot forever. The
		// deadline is the only thing standing between that client and
		// maxConnections exhaustion.
		__sendRequest(async, [], "GET /index.html HTTP/1.1\r\nHost: partial", function(response):Void {

			Assert.equals(408, response.status);
			Assert.equals("Request Timeout", response.body);
			async.done();
		}, null, false, null, config -> config.requestTimeout = 0.25);
	}

	public function testKeepAliveServesTwoSequentialRequestsOnOneSocket(async:Async):Void {
		// The core promise of the lifecycle change: one connect, two
		// requests, two responses, no handshake in between.
		__sendRequests(async, [], [
			"GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n",
			"GET /second.html HTTP/1.1\r\nHost: localhost\r\n\r\n"
		], function(result):Void {

			Assert.equals(200, result.responses[0].status);
			Assert.equals("keep-alive", result.responses[0].headers.get("connection"));
			Assert.equals("Hello from middleware test", result.responses[0].body);
			Assert.equals(200, result.responses[1].status);
			Assert.equals("Second fixture body", result.responses[1].body);
			Assert.isFalse(result.closeSeen);
			async.done();
		});
	}

	public function testPipelinedRequestsAnsweredInOrder(async:Async):Void {
		// Both requests land in one flush, so request two is sitting in
		// __incomingBuffer when response one is written. The old
		// clear-at-response would have silently discarded it; distinct
		// bodies prove both answers arrive, in request order.
		__sendRequests(async, [], [
			"GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n",
			"GET /second.html HTTP/1.1\r\nHost: localhost\r\n\r\n"
		], function(result):Void {

			Assert.equals(2, result.responses.length);
			Assert.equals("Hello from middleware test", result.responses[0].body);
			Assert.equals("Second fixture body", result.responses[1].body);
			Assert.isFalse(result.closeSeen);
			async.done();
		}, null, true);
	}

	public function testConnectionCloseTokenClosesAfterResponse(async:Async):Void {
		// Token match, not substring: "Close" inside a multi-token value
		// must count...
		__sendRequests(async, [], [
			"GET /index.html HTTP/1.1\r\nHost: localhost\r\nConnection: foo, Close\r\n\r\n"
		], function(closing):Void {
			Assert.equals(200, closing.responses[0].status);
			Assert.equals("close", closing.responses[0].headers.get("connection"));
			Assert.isTrue(closing.closeSeen);

			// ...while a token merely containing "close" must not.
			__sendRequests(async, [], [
				"GET /index.html HTTP/1.1\r\nHost: localhost\r\nConnection: not-close\r\n\r\n",
				"GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n"
			], function(kept):Void {
				Assert.equals("keep-alive", kept.responses[0].headers.get("connection"));
				Assert.equals(200, kept.responses[1].status);
				Assert.isFalse(kept.closeSeen);
				async.done();
			});
		}, null, false, 2.0);
	}

	public function testHttp10WithoutTokenCloses(async:Async):Void {
		// HTTP/1.0 defaults to close; persistence is strictly opt-in.
		__sendRequests(async, [], ["GET /index.html HTTP/1.0\r\n\r\n"], function(result):Void {

			Assert.equals(200, result.responses[0].status);
			Assert.equals("close", result.responses[0].headers.get("connection"));
			Assert.isTrue(result.closeSeen);
			async.done();
		}, null, false, 2.0);
	}

	public function testHttp10KeepAliveTokenKeepsOpen(async:Async):Void {
		__sendRequests(async, [], [
			"GET /index.html HTTP/1.0\r\nConnection: keep-alive\r\n\r\n",
			"GET /second.html HTTP/1.0\r\nConnection: keep-alive\r\n\r\n"
		], function(result):Void {

			Assert.equals("keep-alive", result.responses[0].headers.get("connection"));
			Assert.equals("Second fixture body", result.responses[1].body);
			Assert.isFalse(result.closeSeen);
			async.done();
		});
	}

	public function testKeepAliveDisabledMatchesLegacyBehavior(async:Async):Void {
		__sendRequests(async, [], [
			"GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n"
		], function(result):Void {

			Assert.equals(200, result.responses[0].status);
			Assert.equals("close", result.responses[0].headers.get("connection"));
			Assert.isTrue(result.closeSeen);
			async.done();
		}, config -> config.keepAlive = false, false, 2.0);
	}

	public function testKeepAliveMaxRequestsClosesOnFinalResponse(async:Async):Void {
		// A limit of two means exactly two responses, the second already
		// carrying the close -- never a third request answered, never a
		// keep-alive header the server does not honor.
		__sendRequests(async, [], [
			"GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n",
			"GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n"
		], function(result):Void {

			Assert.equals("keep-alive", result.responses[0].headers.get("connection"));
			Assert.equals("close", result.responses[1].headers.get("connection"));
			Assert.isTrue(result.closeSeen);
			async.done();
		}, config -> config.keepAliveMaxRequests = 2, false, 2.0);
	}

	public function testDefaultConfigAnswers404ForAMissingPath(async:Async):Void {
		// No `configure` argument: the default is the point. It used to end
		// tryFiles with "/index.html", so every unmatched path answered 200
		// with the root index -- a single-page application fallback, on for
		// everyone. That was documented, but the failure it produces is the
		// silent one: a missing file answered 200 with unrelated HTML is
		// cached as valid, passes an uptime check and hides a broken link.
		// An SPA that wanted the fallback breaks loudly on the first refresh
		// and is one config line from fixed.
		__sendRequest(async, [], "GET /definitely-not-here.html HTTP/1.1\r\nHost: localhost\r\n\r\n", function(response):Void {

			Assert.equals(404, response.status);
			async.done();
		});
	}

	public function testDefaultConfigStillServesTheDirectoryIndex(async:Async):Void {
		// The other half, and why this is not simply "drop an entry": "$uri/"
		// still resolves a directory to its index, so the root goes on
		// answering with index.html. Only the fallback for a path that
		// resolves to nothing is gone.
		__sendRequest(async, [], "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n", function(response):Void {

			Assert.equals(200, response.status);
			Assert.equals("Hello from middleware test", response.body);
			async.done();
		});
	}

	public function testNotFoundKeepsConnectionUsable(async:Async):Void {
		// The proposal's motivating case: a page with a missing favicon
		// must not pay a new handshake for the 404. tryFiles is set here
		// rather than left to the default -- it is the same two entries the
		// default now carries, but a test that needs a 404 should say so
		// itself rather than depend on a default staying put.
		__sendRequests(async, [], [
			"GET /missing.html HTTP/1.1\r\nHost: localhost\r\n\r\n",
			"GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n"
		], function(result):Void {

			Assert.equals(404, result.responses[0].status);
			Assert.equals("keep-alive", result.responses[0].headers.get("connection"));
			Assert.equals(200, result.responses[1].status);
			Assert.equals("Hello from middleware test", result.responses[1].body);
			Assert.isFalse(result.closeSeen);
			async.done();
		}, config -> config.tryFiles = ["$uri", "$uri/"]);
	}

	public function testErrorStatusForcesClose(async:Async):Void {
		// After a 5xx the handler's state is suspect; the response says
		// close and the socket follows it.
		__sendRequests(async, [
			function(_:HTTPRequestHandler, next:?Dynamic->Void):Void {
				next(500);
			}
		], ["GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n"], function(result):Void {

			Assert.equals(500, result.responses[0].status);
			Assert.equals("close", result.responses[0].headers.get("connection"));
			Assert.isTrue(result.closeSeen);
			async.done();
		}, null, false, 2.0);
	}

	public function testIdleTimeoutClosesWithoutA408(async:Async):Void {
		// Sitting idle between requests is not a client fault: the reap
		// is a bare close, not a second response. Exactly one status line
		// may appear on the wire.
		__sendRequests(async, [], [
			"GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n"
		], function(result):Void {

			Assert.equals(200, result.responses[0].status);
			Assert.equals("keep-alive", result.responses[0].headers.get("connection"));
			Assert.isTrue(result.closeSeen);
			Assert.equals(1, __countOccurrences(result.raw, "HTTP/1.1 "));
			Assert.equals(-1, result.raw.indexOf("408"));
			async.done();
		}, config -> config.keepAliveTimeout = 0.25, false, 2.0);
	}

	public function testMidRequestTimeoutOnReusedConnectionStill408s(async:Async):Void {
		// The deadline swaps meaning when a reused connection leaves the
		// idle phase: a request that starts arriving and stalls gets the
		// same 408 a first request would.
		__sendRequests(async, [], [
			"GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n",
			"GET /index.html HTTP/1.1\r\nHost: partial"
		], function(result):Void {

			Assert.equals(200, result.responses[0].status);
			Assert.equals(408, result.responses[1].status);
			Assert.equals("Request Timeout", result.responses[1].body);
			Assert.isTrue(result.closeSeen);
			async.done();
		}, config -> config.requestTimeout = 0.25, false, 2.0);
	}

	public function testPostBodyThenSecondRequestOnSameSocket(async:Async):Void {
		// Pins the consumption boundary: the POST body is read out of the
		// buffer in full before the response, so the GET behind it is
		// parsed from the preserved tail, not from body bytes.
		var seenBody:String = null;
		__sendRequests(async, [
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
		], function(result):Void {

			Assert.equals("hello world", seenBody);
			Assert.equals(200, result.responses[0].status);
			Assert.equals("posted:hello world", result.responses[0].body);
			Assert.equals(200, result.responses[1].status);
			Assert.equals("Hello from middleware test", result.responses[1].body);
			Assert.isFalse(result.closeSeen);
			async.done();
		});
	}

	public function testRespondThenNextEmitsSingleResponse(async:Async):Void {
		// A middleware that violates the respond-xor-next contract must
		// produce one response, not two: the stale continuation is
		// suppressed, and the connection stays usable for the request
		// after it.
		__sendRequests(async, [
			function(handler:HTTPRequestHandler, next:?Dynamic->Void):Void {
				handler.respond(200, "text/plain", "from middleware");
				next();
			}
		], [
			"GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n",
			"GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n"
		], function(result):Void {

			Assert.equals(2, result.responses.length);
			Assert.equals("from middleware", result.responses[0].body);
			Assert.equals("from middleware", result.responses[1].body);
			Assert.equals(2, __countOccurrences(result.raw, "HTTP/1.1 "));
			Assert.isFalse(result.closeSeen);
			async.done();
		});
	}

	public function testExpectContinueOnKeptAliveConnection(async:Async):Void {
		// The interim 100 is written raw, before the builders, and must
		// neither count as the response nor confuse the per-response
		// framing on a connection that stays open afterwards.
		var bodyText:String = null;
		__sendRequests(async, [
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
		], function(result):Void {

			Assert.equals("payload", bodyText);
			Assert.isTrue(result.responses[0].raw.indexOf("HTTP/1.1 100 Continue") == 0);
			Assert.equals(200, result.responses[0].status);
			Assert.equals("got:payload", result.responses[0].body);
			Assert.equals(200, result.responses[1].status);
			Assert.isFalse(result.closeSeen);
			async.done();
		});
	}

	public function testHeadKeepsConnectionOpen(async:Async):Void {
		// HEAD advertises a length it never sends; the consumption logic
		// must not wait for a body that is not coming, on either side.
		__sendRequests(async, [], [
			"HEAD /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n",
			"GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n"
		], function(result):Void {

			Assert.equals(200, result.responses[0].status);
			Assert.equals("", result.responses[0].body);
			Assert.equals("26", result.responses[0].headers.get("content-length"));
			Assert.equals(200, result.responses[1].status);
			Assert.equals("Hello from middleware test", result.responses[1].body);
			Assert.isFalse(result.closeSeen);
			async.done();
		});
	}

	public function testLateAsynchronousNextCannotAnswerALaterRequest(async:Async):Void {
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
		__sendRequests(async, [
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
		], function(result):Void {

			Assert.equals(2, result.responses.length);
			Assert.equals("answered inline", result.responses[0].body);
			Assert.equals("Hello from middleware test", result.responses[1].body);
			// The count is the assertion that matters: a stale continuation that
			// got through would put a third status line on the wire.
			Assert.equals(2, __countOccurrences(result.raw, "HTTP/1.1 "));
			async.done();
		}, null, false, 0.6);
	}

	public function testPhpRewriteWithoutABridgeDoesNotCrash(async:Async):Void {
		// A PHP-flagged rewrite on a server with no bridge reached a null
		// pointer and took the process down -- not an error on that connection,
		// but the whole process, and every other connection with it.
		//
		// The rule is written out here because the defaults used to carry it:
		// every /api path to /index.php with the PHP flag, while phpEnabled
		// defaults to false. That is how a stock server segfaulted on a path a
		// great many services use. The defaults ship empty now, so this test
		// supplies its own -- and the guard still earns its place, because
		// rewrites is a public array a PHP rule can be added to at any time.
		__sendRequest(async, [], "GET /api/status HTTP/1.1\r\nHost: localhost\r\n\r\n", function(response):Void {

			Assert.equals(500, response.status);
			async.done();
		}, null, false, null, config -> {
			config.rewrites = [
				{pattern: "^/api/.*$", target: "/index.php", flags: ["L", "QSA", "PHP"], conditions: []}
			];
		});
	}

	public function testDirectoryIndexPrefersOneTheServerCanActuallyServe(async:Async):Void {
		// directoryIndex leads with index.php, so a directory holding both it
		// and an index.html selected the PHP file -- which without a bridge
		// cannot be served. Once serving it was refused the directory answered
		// 404 with a usable index sitting right beside it. Selection now skips
		// what cannot be delivered rather than picking it and failing later.
		//
		// tryFiles is stated rather than defaulted: a "/index.html" entry
		// would answer the directory request before the index is resolved,
		// and the test would pass without exercising the selection at all.
		__sendRequest(async, [], "GET /both/ HTTP/1.1\r\nHost: localhost\r\n\r\n", function(response):Void {

			Assert.equals(200, response.status);
			Assert.equals("REAL HTML INDEX", response.body);
			async.done();
		}, null, false, null, config -> {
			config.tryFiles = ["$uri", "$uri/"];
			config.directoryIndex = ["index.php", "index.html"];
			var dir = config.rootDirectory.resolvePath("both");
			dir.createDirectory();
			var php = new ByteArray();
			php.writeUTFBytes("<?php $SECRET = 1; ?>");
			dir.resolvePath("index.php").save(php);
			var html = new ByteArray();
			html.writeUTFBytes("REAL HTML INDEX");
			dir.resolvePath("index.html").save(html);
		});
	}

	public function testDefaultConfigShipsNoRewrites(async:Async):Void {
		// The defaults rewrote every /api path to /index.php with the PHP flag
		// while phpEnabled defaulted to false, so a stock server crashed on a
		// request path a great many services use. Nothing is routed anywhere
		// now unless it is asked for.
		var root = File.createTempDirectory();
		var config = new HTTPServerConfig("127.0.0.1", 0, root);
		Assert.equals(0, config.rewrites.length);

		__sendRequest(async, [], "GET /api/status HTTP/1.1\r\nHost: localhost\r\n\r\n", function(response):Void {
			Assert.isTrue(response.status != 500);
			async.done();
		});
	}

	public function testTryFilesMustBeSpelledInTheOrderTheServerUses():Void {
		// $uri and $uri/ are tested before this list is read and before the
		// rewrites, so a config that puts a literal first, omits them, or names
		// one twice describes an order that does not happen. Rejecting it is the
		// point: a config quietly meaning something else is how the /api default
		// came to crash a stock server.
		var root = File.createTempDirectory();

		var valid = new HTTPServerConfig("127.0.0.1", 0, root);
		valid.validate();
		Assert.pass();

		var literalFirst = new HTTPServerConfig("127.0.0.1", 0, root);
		literalFirst.tryFiles = ["/index.html", "$uri", "$uri/"];
		Assert.raises(() -> literalFirst.validate(), ArgumentError);

		var swapped = new HTTPServerConfig("127.0.0.1", 0, root);
		swapped.tryFiles = ["$uri/", "$uri"];
		Assert.raises(() -> swapped.validate(), ArgumentError);

		var omitted = new HTTPServerConfig("127.0.0.1", 0, root);
		omitted.tryFiles = ["/index.html"];
		Assert.raises(() -> omitted.validate(), ArgumentError);

		var repeated = new HTTPServerConfig("127.0.0.1", 0, root);
		repeated.tryFiles = ["$uri", "$uri/", "/index.html", "$uri"];
		Assert.raises(() -> repeated.validate(), ArgumentError);
	}

	public function testUnmappedStatusGetsItsClassNotOK(async:Async):Void {
		// A middleware can raise any status through next(code). Every code the
		// table did not know rendered "OK", so next(503) put
		// "HTTP/1.1 503 OK" on the wire — contradicting itself, and reading as
		// success to anything matching on the phrase.
		__sendRequest(async, [
			function(_:HTTPRequestHandler, next:?Dynamic->Void):Void {
				next(503);
			}
		], "GET /index.html HTTP/1.1
Host: localhost

", function(unavailable):Void {
			Assert.equals(503, unavailable.status);
			Assert.isTrue(unavailable.raw.indexOf("503 Service Unavailable") >= 0);
			Assert.isTrue(unavailable.raw.indexOf("503 OK") < 0);

			// One with no phrase of its own falls back to its class.
			__sendRequest(async, [
				function(_:HTTPRequestHandler, next:?Dynamic->Void):Void {
					next(418);
				}
			], "GET /index.html HTTP/1.1
Host: localhost

", function(teapot):Void {
				Assert.equals(418, teapot.status);
				Assert.isTrue(teapot.raw.indexOf("418 Client Error") >= 0);
				Assert.isTrue(teapot.raw.indexOf("418 OK") < 0);
				async.done();
			});
		});
	}

	public function testRejectedIdentityEncodingAnswersOneNotAcceptable(async:Async):Void {
		// identity;q=0 forbids the only coding an error body can be sent in,
		// so the 406 explaining that used to be negotiated against the very
		// header it was answering: reject, send 406, negotiate, reject. The
		// recursion had no floor and took the connection's thread with it.
		__sendRequest(async, [], "GET /index.html HTTP/1.1\r\nHost: localhost\r\nAccept-Encoding: identity;q=0\r\n\r\n", function(response):Void {

			Assert.equals(406, response.status);
			Assert.equals(1, __countOccurrences(response.raw, "HTTP/1.1 "));
			async.done();
		});
	}
	public function testLiteralPlusInPathServesThePlusNamedFile(async:Async):Void {
		// Form decoding read the `+` as a space, so this request used to
		// look up — and serve — the decoy. The decoy stays to keep the
		// failure mode a wrong body rather than a soft 404.
		var requestPath:String = null;
		__sendRequest(async, [
			function(handler:HTTPRequestHandler, next:?Dynamic->Void):Void {
				requestPath = handler.requestPath;
				next();
			}
		], "GET /a+b.html HTTP/1.1\r\nHost: localhost\r\n\r\n", function(response):Void {

			Assert.equals("/a+b.html", requestPath);
			Assert.equals(200, response.status);
			Assert.equals("17", response.headers.get("content-length"));
			Assert.equals("plus is a literal", response.body);
			async.done();
		}, null, false, null, config -> {
			__saveFixture(config, "a+b.html", "plus is a literal");
			__saveFixture(config, "a b.html", "decoy: the space-named file");
		});
	}

	public function testEncodedPlusDecodesToLiteralPlusAndQueryStaysRaw(async:Async):Void {
		var requestPath:String = null;
		var queryString:String = null;
		__sendRequest(async, [
			function(handler:HTTPRequestHandler, next:?Dynamic->Void):Void {
				requestPath = handler.requestPath;
				queryString = handler.queryString;
				next();
			}
		], "GET /a%2Bb.html?q=a+b%20c HTTP/1.1\r\nHost: localhost\r\n\r\n", function(response):Void {

			Assert.equals("/a+b.html", requestPath);
			Assert.equals("q=a+b%20c", queryString);
			Assert.equals(200, response.status);
			Assert.equals("plus is a literal", response.body);
			async.done();
		}, null, false, null, config -> {
			__saveFixture(config, "a+b.html", "plus is a literal");
		});
	}

	public function testMalformedPercentEscapeReturns400(async:Async):Void {
		__sendRequest(async, [], "GET /oops%zz.html HTTP/1.1\r\nHost: localhost\r\n\r\n", function(nonHex):Void {
			Assert.equals(400, nonHex.status);
			Assert.equals("Bad Request", nonHex.body);

			__sendRequest(async, [], "GET /oops%2 HTTP/1.1\r\nHost: localhost\r\n\r\n", function(truncated):Void {
				Assert.equals(400, truncated.status);
				Assert.equals("Bad Request", truncated.body);
				async.done();
			});
		});
	}

	public function testEncodedNulCannotSmuggleAPathPastTheBlacklist(async:Async):Void {
		// The filesystem reaches a C API through the string's `char*` and
		// stops at the NUL; the blacklist compares the whole string and
		// does not. Under the old decoder this request was checked as
		// `secret.txt\0.html`, matched nothing, then truncated on open and
		// served the blacklisted file.
		__sendRequest(async, [], "GET /secret.txt%00.html HTTP/1.1\r\nHost: localhost\r\n\r\n", function(response):Void {

			Assert.equals(400, response.status);
			Assert.equals("Bad Request", response.body);
			Assert.isFalse(response.raw.indexOf("the blacklisted contents") >= 0);
			async.done();
		}, null, false, null, config -> {
			__saveFixture(config, "secret.txt", "the blacklisted contents");
			config.blacklist.push(config.rootDirectory.resolvePath("secret.txt").nativePath);
		});
	}

	public function testPercentDecodePathDecodesEscapesAndNothingElse():Void {
		Assert.equals("/a+b", HTTPRequestHandler.__percentDecodePath("/a+b"));
		Assert.equals("/a+b", HTTPRequestHandler.__percentDecodePath("/a%2Bb"));
		Assert.equals("/a b", HTTPRequestHandler.__percentDecodePath("/a%20b"));
		Assert.equals("/AB+", HTTPRequestHandler.__percentDecodePath("/%41%42%2b"));
		// Adjacent escapes are one byte run read back as UTF-8, so a
		// two-byte character survives as itself; re-encoding is used as
		// the check because it is independent of the string's internal
		// representation on any one target.
		Assert.equals("%C3%A9", StringTools.urlEncode(HTTPRequestHandler.__percentDecodePath("%C3%A9")));

		Assert.raises(() -> HTTPRequestHandler.__percentDecodePath("/secret.txt%00.html"));
		Assert.raises(() -> HTTPRequestHandler.__percentDecodePath("/%"));
		Assert.raises(() -> HTTPRequestHandler.__percentDecodePath("/%2"));
		Assert.raises(() -> HTTPRequestHandler.__percentDecodePath("/%2G"));
		Assert.raises(() -> HTTPRequestHandler.__percentDecodePath("/%G2"));
	}

	private static function __saveFixture(config:HTTPServerConfig, name:String, content:String):Void {
		var bytes = new ByteArray();
		bytes.writeUTFBytes(content);
		config.rootDirectory.resolvePath(name).save(bytes);
	}

	public function testPhpSourceIsNotServedWhenNoBridgeIsConfigured(async:Async):Void {
		// phpEnabled is false by default, and a .php file used to fall through
		// to the static path when no bridge existed -- so a default server
		// answered this with 200 and the file itself. PHP source is where
		// credentials live; serving it verbatim hands them out.
		__sendRequest(async, [], "GET /config.php HTTP/1.1\r\nHost: localhost\r\n\r\n", function(response):Void {

			Assert.equals(404, response.status);
			Assert.isFalse(response.body.indexOf("hunter2") >= 0);
			Assert.isFalse(response.body.indexOf("<?php") >= 0);
			async.done();
		}, null, false, null, config -> {
			var secret = new ByteArray();
			secret.writeUTFBytes("<?php $DB_PASSWORD = 'hunter2'; ?>");
			config.rootDirectory.resolvePath("config.php").save(secret);
		});
	}

	public function testPhpSourceIsNotServedAsADirectoryIndex(async:Async):Void {
		// The same disclosure without naming the file: directoryIndex leads
		// with index.php, so a directory resolves to it and reaches the static
		// path through __serveFile's recursion rather than directly.
		//
		// Both config lines exist to make that route reachable, and this test
		// passed without either of them while the hole was still open. The
		// harness passes ["index.html"] as directoryIndex, so the directory
		// never resolved to a .php file at all; and a "/index.html" entry in
		// tryFiles answers a directory request before the index is looked up.
		// Either one alone is enough to make the test green against a server
		// that would have handed over the source.
		__sendRequest(async, [], "GET /private/ HTTP/1.1\r\nHost: localhost\r\n\r\n", function(response):Void {

			Assert.equals(404, response.status);
			Assert.isFalse(response.body.indexOf("sk-live-secret") >= 0);
			async.done();
		}, null, false, null, config -> {
			config.tryFiles = ["$uri", "$uri/"];
			config.directoryIndex = ["index.php", "index.html"];
			var dir = config.rootDirectory.resolvePath("private");
			dir.createDirectory();
			var secret = new ByteArray();
			secret.writeUTFBytes("<?php $API_KEY = 'sk-live-secret'; ?>");
			dir.resolvePath("index.php").save(secret);
		});
	}

	public function testUppercaseExtensionDoesNotBypassTheSourceGuard(async:Async):Void {
		// Windows opens config.PHP and config.php as the same file, so a guard
		// that compared the extension literally would be bypassable by asking
		// for the other case. __isPhp lowercases, and the guard reuses it
		// rather than repeating the test.
		__sendRequest(async, [], "GET /config.PHP HTTP/1.1\r\nHost: localhost\r\n\r\n", function(response):Void {

			Assert.equals(404, response.status);
			Assert.isFalse(response.body.indexOf("hunter2") >= 0);
			async.done();
		}, null, false, null, config -> {
			var secret = new ByteArray();
			secret.writeUTFBytes("<?php $DB_PASSWORD = 'hunter2'; ?>");
			config.rootDirectory.resolvePath("config.PHP").save(secret);
		});
	}

	public function testReportedFileSizeIsVerifiedAgainstTheFileItself():Void {
		// `FileSystem.stat` gives an Int, so a file past 2 GB wraps: between 2
		// and 4 GB it goes negative and is caught on sight, but at 4 GB and up
		// it comes back round positive and reads as a perfectly ordinary size.
		// Such a file used to be served truncated to the wrapped number, under
		// a Content-Length asserting that truncation was the whole file.
		//
		// Reproducing the wrap needs a file over 4 GB, which a test suite has
		// no business creating. What the guard actually decides is narrower --
		// whether any bytes exist past a stated length -- and a wrapped size is
		// just one way to arrive at a length that is too small. That question
		// is testable at any size, so it is tested at 100 bytes.
		var root = File.createTempDirectory();
		var payload = new ByteArray();
		for (i in 0...100) {
			payload.writeByte(i % 256);
		}
		var target = root.resolvePath("payload.bin");
		target.save(payload);

		// The truth: nothing lies beyond byte 100.
		Assert.isTrue(HTTPRequestHandler.__sizeIsComplete(target, 100));

		// A stated length short of the file, which is the shape a wrap
		// produces. There is data at offset 50, so the length is not the
		// file's own.
		Assert.isFalse(HTTPRequestHandler.__sizeIsComplete(target, 50));
		Assert.isFalse(HTTPRequestHandler.__sizeIsComplete(target, 0));

		// A genuinely empty file reports zero and means it -- the case that
		// must not be mistaken for a 4 GB file, which also reports zero.
		var empty = root.resolvePath("empty.bin");
		empty.save(new ByteArray());
		Assert.isTrue(HTTPRequestHandler.__sizeIsComplete(empty, 0));

		try {
			root.deleteDirectory(true);
		} catch (_:Dynamic) {}
	}

	private function __sendRequest(async:Async, middleware:Array<(HTTPRequestHandler, ?Dynamic->Void) -> Void>, requestText:String, done:HTTPTestResponse->Void,
			?secondChunk:String, corsEnabled:Bool = false, ?requestBody:ByteArray, ?configure:HTTPServerConfig->Void):Void {
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

		// HEAD responses end at their header terminator; waiting for the
		// advertised Content-Length would burn the whole pump timeout now
		// that a HEAD response no longer ends its connection.
		var headOnly:Bool = StringTools.startsWith(requestText, "HEAD ");

		/**
		 * Tears the world down, then either hands the response to the case or
		 * ends the case with the failure.
		 *
		 * A failure finishes the case here rather than throwing, because on
		 * Node this runs from a timer callback: a throw there does not reach
		 * utest, it reaches Node's uncaught handler and takes the whole run
		 * down with one line of output and no attribution.
		 */
		function finish(failure:Dynamic):Void {
			var response:HTTPTestResponse = failure == null ? HTTPTestSupport.parseResponse(rawResponse, rawResponseBytes) : null;

			try {
				client.close();
			} catch (_:Dynamic) {}
			try {
				server.close();
			} catch (_:Dynamic) {}
			try {
				root.deleteDirectory(true);
			} catch (_:Dynamic) {}

			if (failure != null) {
				Assert.fail("the request failed: " + Std.string(failure));
				async.done();
				return;
			}

			Assert.notNull(response);
			done(response);
		}

		try {
			HTTPTestSupport.connectThen(client, server, function():Void {
				HTTPTestSupport.pumpUntilAsync(() -> closeSeen || HTTPTestSupport.isResponseComplete(rawResponse, headOnly), 2.0, _ -> finish(null));
			});
		} catch (error:Dynamic) {
			finish(error);
		}
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
	private function __sendRequests(async:Async, middleware:Array<(HTTPRequestHandler, ?Dynamic->Void) -> Void>, requests:Array<String>,
			done:{responses:Array<HTTPTestResponse>, closeSeen:Bool, raw:String}->Void, ?configure:HTTPServerConfig->Void, pipelined:Bool = false,
			waitAfter:Float = 0):Void {
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
		var responses:Array<HTTPTestResponse> = [];

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

		function finish(failure:Dynamic):Void {
			// Snapshot before the harness closes its own end: Socket.close()
			// dispatches Event.CLOSE for a locally initiated close too, so
			// reading the flag afterwards would report every connection as
			// closed and the keep-alive assertions would test nothing.
			var serverClosedFirst = closeSeen;

			try {
				client.close();
			} catch (_:Dynamic) {}
			try {
				server.close();
			} catch (_:Dynamic) {}
			try {
				root.deleteDirectory(true);
			} catch (_:Dynamic) {}

			if (failure != null) {
				Assert.fail(Std.string(failure));
				async.done();
				return;
			}

			done({responses: responses, closeSeen: serverClosedFirst, raw: rawResponse});
		}

		var cursor = 0;

		/**
		 * Reads response `i`, then asks for the next.
		 *
		 * A recursion rather than the loop this was, because sequential mode
		 * cannot send request N+1 until response N is complete -- and waiting
		 * for that is the one thing a loop cannot do on Node.
		 */
		function step(i:Int):Void {
			if (i >= requests.length) {
				if (waitAfter > 0) {
					HTTPTestSupport.pumpUntilAsync(() -> closeSeen, waitAfter, _ -> finish(null));
					return;
				}

				finish(null);
				return;
			}

			var headOnly = StringTools.startsWith(requests[i], "HEAD ");
			var sliceEnd = -1;

			HTTPTestSupport.pumpUntilAsync(() -> {
				sliceEnd = HTTPTestSupport.responseEndAt(rawResponse, cursor, headOnly);
				return sliceEnd >= 0;
			}, 2.0, function(_):Void {
				if (sliceEnd < 0) {
					finish("response " + i + " never completed; received: " + rawResponse.substr(cursor));
					return;
				}

				var slice = rawResponse.substring(cursor, sliceEnd);
				var sliceBytes = new ByteArray();
				for (j in cursor...sliceEnd) {
					sliceBytes.writeByte(rawResponse.charCodeAt(j) & 0xFF);
				}
				responses.push(HTTPTestSupport.parseResponse(slice, sliceBytes));
				cursor = sliceEnd;

				if (!pipelined && i < requests.length - 1) {
					// The point of the sequential mode: the connection must
					// still be open when the next request goes out.
					Assert.isFalse(closeSeen);
					client.writeUTFBytes(requests[i + 1]);
					client.flush();
				}

				step(i + 1);
			});
		}

		try {
			HTTPTestSupport.connectThen(client, server, () -> step(0));
		} catch (error:Dynamic) {
			finish(error);
		}
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




}

