package crossbyte.http;

import crossbyte.http.HTTPTestSupport.HTTPTestResponse;
import utest.Assert;
import utest.Async;

/**
 * Where one request ends and the next begins, as a peer can bend it.
 *
 * A server and whatever stands in front of it have to agree on that, or a
 * request can travel inside another: the proxy passes one request it
 * inspected, and the server reads two. So every case here sends what should
 * be one request, and checks both the answer and that nothing after it was
 * parsed as a second.
 */
@:timeout(20000)
class HTTPRequestFramingTest extends utest.Test {
	/**
		A `Content-Length` no `Int` can hold is refused rather than read as
		some smaller number.

		On Linux and macOS native, `Std.parseInt` is `strtol` cast to an
		`int`, so 4294967296 read as 0 and 4294967396 as 100. At 0 the server
		read no body and parsed the body as the next request, a smuggled
		request, unseen by anything that inspected the outer one. On the jvm
		the same field threw and was answered 500. The request carried in the
		body here must never reach the application.
	**/
	public function testALengthNoIntCanHoldIsRefused(async:Async):Void {
		var seen:Array<String> = [];
		var server:HTTPServer = __serve(seen);
		var smuggled:String = "GET /smuggled HTTP/1.1\r\nHost: x\r\n\r\n";

		HTTPTestSupport.exchangeEach(server, [
			"POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 4294967296\r\n\r\n" + smuggled,
			"POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 4294967396\r\n\r\n" + smuggled,
			"POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 18446744073709551616\r\n\r\n" + smuggled,
			"POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 99999999999999999999999\r\n\r\n" + smuggled
		], function(responses:Array<HTTPTestResponse>):Void {
			try server.close() catch (_:Dynamic) {}

			for (i in 0...responses.length) {
				Assert.equals(400, responses[i].status, "request " + i + " was not refused as malformed");
				Assert.equals(1, HTTPTestSupport.countResponses(responses[i].raw), "request " + i + " drew more than one response");
			}
			Assert.equals(0, seen.length, "a request reached the application: " + seen.join(", "));
			async.done();
		}, true);
	}

	/** RFC 9112 6.3: repeated lengths that disagree are refused, equal ones read. **/
	public function testRepeatedLengthsMustAgree(async:Async):Void {
		var seen:Array<String> = [];
		var server:HTTPServer = __serve(seen);

		HTTPTestSupport.exchangeEach(server, [
			"POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\nhello!",
			"POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 5, 5\r\n\r\nhello",
			"POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: +5\r\n\r\nhello",
			"POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 0x5\r\n\r\nhello"
		], function(responses:Array<HTTPTestResponse>):Void {
			try server.close() catch (_:Dynamic) {}

			Assert.equals(400, responses[0].status, "5 and 6 were accepted together");
			Assert.equals(200, responses[1].status, "an agreeing repeat was refused");
			Assert.equals("got 5", responses[1].body);
			Assert.equals(400, responses[2].status, "a signed length was accepted");
			Assert.equals(400, responses[3].status, "a hex length was accepted");
			Assert.equals(1, seen.length, "only the agreeing request should have reached the application");
			async.done();
		});
	}

	private function __serve(seen:Array<String>):HTTPServer {
		var router:Router = new Router();
		router.post("/upload", ctx -> ctx.handler.respond(200, "text/plain", "got " + ctx.handler.requestBody.length));

		var config:HTTPServerConfig = new HTTPServerConfig("127.0.0.1", 0);
		config.middleware.push(function(handler:HTTPRequestHandler, next:?Dynamic->Void):Void {
			seen.push(handler.method + " " + handler.requestPath);
			next();
		});
		config.middleware.push(router.middleware());
		return new HTTPServer(config);
	}
}
