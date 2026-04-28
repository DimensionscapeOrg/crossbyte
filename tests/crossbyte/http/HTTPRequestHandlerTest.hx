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

	public function testUnsupportedRequestContentEncodingReturns415AndSkipsRouting():Void {
		var body:ByteArray = new ByteArray();
		body.writeUTFBytes("hello world");
		var middlewareCalled = false;

		var response = __sendRequest([
			function(_:HTTPRequestHandler, next:?Dynamic->Void):Void {
				middlewareCalled = true;
				next();
			}
		], 'POST /index.html HTTP/1.1\r\nHost: localhost\r\nContent-Encoding: br\r\nContent-Length: ${body.length}\r\n\r\n', null, false, body);

		Assert.equals(415, response.status);
		Assert.equals("Unsupported Content-Encoding: br", response.body);
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

	private function __sendRequest(middleware:Array<(HTTPRequestHandler, ?Dynamic->Void) -> Void>, requestText:String, ?secondChunk:String, corsEnabled:Bool = false, ?requestBody:ByteArray):HTTPTestResponse {
		var root = File.createTempDirectory();
		var indexFile = root.resolvePath("index.html");
		var fixture = new ByteArray();
		fixture.writeUTFBytes("Hello from middleware test");
		indexFile.save(fixture);

		var config = new HTTPServerConfig("127.0.0.1", 0, root, null, ["index.html"], null, null, null, middleware, null, corsEnabled);
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

		try {
			client.connect("127.0.0.1", server.localPort);
			__pumpUntil(() -> closeSeen || __isResponseComplete(rawResponse), 2.0);
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

	private static function __isResponseComplete(raw:String):Bool {
		var headerEnd = raw.indexOf("\r\n\r\n");
		if (headerEnd < 0) {
			return false;
		}

		var headers = raw.substr(0, headerEnd).split("\r\n");
		for (line in headers) {
			var lower = StringTools.trim(line).toLowerCase();
			if (lower.indexOf("content-length:") == 0) {
				var len:Int = Std.parseInt(StringTools.trim(line.substr(15)));
				if (len == 0) {
					return true;
				}
				return raw.length >= headerEnd + 4 + len;
			}
		}
		return false;
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
