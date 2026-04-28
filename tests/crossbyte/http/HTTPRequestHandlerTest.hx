package crossbyte.http;

import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.ProgressEvent;
import crossbyte.io.ByteArray;
import crossbyte.io.File;
import crossbyte.net.Socket;
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

	private function __sendRequest(middleware:Array<(HTTPRequestHandler, ?Dynamic->Void) -> Void>, requestText:String, ?secondChunk:String):HTTPTestResponse {
		var root = File.createTempDirectory();
		var indexFile = root.resolvePath("index.html");
		var fixture = new ByteArray();
		fixture.writeUTFBytes("Hello from middleware test");
		indexFile.save(fixture);

		var config = new HTTPServerConfig("127.0.0.1", 0, root, null, ["index.html"], null, null, null, middleware);
		var server = new HTTPServer(config);
		var client = new Socket();
		var rawResponse = "";
		var closeSeen = false;
		var response:HTTPTestResponse = null;

		client.addEventListener(Event.CONNECT, _ -> {
			client.writeUTFBytes(requestText);
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
				rawResponse += client.readUTFBytes(client.bytesAvailable);
			}
		});
		client.addEventListener(Event.CLOSE, _ -> closeSeen = true);
		var requestFailed:Dynamic = null;

		try {
			client.connect("127.0.0.1", server.localPort);
			__pumpUntil(() -> closeSeen || __isResponseComplete(rawResponse), 2.0);
			response = __parseResponse(rawResponse);
			client.close();
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

	private static function __parseResponse(raw:String):HTTPTestResponse {
		var lineEnd = raw.indexOf("\r\n");
		var statusLine = raw.substr(0, lineEnd);
		var status = 0;
		if (statusLine != null && statusLine.length >= 12) {
			status = Std.parseInt(statusLine.substr(9, 3));
		}

		var body = "";
		var headerEnd = raw.indexOf("\r\n\r\n");
		if (headerEnd >= 0) {
			body = raw.substr(headerEnd + 4);
		}

		return {
			status: status,
			body: body
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
	var body:String;
}
