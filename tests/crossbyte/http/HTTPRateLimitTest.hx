package crossbyte.http;

import crossbyte.http.HTTPTestSupport.HTTPTestResponse;
import crossbyte.net.RateLimiter;
import utest.Assert;
import utest.Async;

/**
 * Who the server's rate limiter counts a request against, and what a refused
 * request is told.
 */
@:timeout(20000)
class HTTPRateLimitTest extends utest.Test {
	public function testA429SaysWhenToComeBack(async:Async):Void {
		// The 429 says when to try again, so a client need not guess.
		var server:HTTPServer = __serve(config -> config.rateLimiter = new RateLimiter(1, 60.0));

		HTTPTestSupport.exchangeEach(server, [__get("/"), __get("/")], function(responses:Array<HTTPTestResponse>):Void {
			try server.close() catch (_:Dynamic) {}

			Assert.equals(200, responses[0].status);
			Assert.equals(429, responses[1].status);
			Assert.equals("60", responses[1].headers.get("retry-after"));
			async.done();
		});
	}

	public function testTheKeyCanComeFromTheRequest(async:Async):Void {
		// The limiter keys on what the application chooses, not only the
		// address it is handed, so a server behind a proxy need not limit the
		// proxy, and a login route can limit per account without reaching into
		// the handler.
		var server:HTTPServer = __serve(config -> {
			config.rateLimiter = new RateLimiter(1, 60.0);
			config.rateLimitKey = handler -> handler.getHeader("x-user");
		});

		HTTPTestSupport.exchangeEach(server, [
			__get("/", "X-User: ada\r\n"),
			__get("/", "X-User: grace\r\n"),
			__get("/", "X-User: ada\r\n"),
			// No key at all: not limited.
			__get("/"),
			__get("/")
		], function(responses:Array<HTTPTestResponse>):Void {
			try server.close() catch (_:Dynamic) {}

			Assert.same([200, 200, 429, 200, 200], [for (response in responses) response.status]);
			async.done();
		});
	}

	public function testTheClientsAddressIsPublic(async:Async):Void {
		var seen:Array<String> = [];
		var server:HTTPServer = __serve(config -> config.middleware.unshift(function(handler:HTTPRequestHandler, next:?Dynamic->Void):Void {
			seen.push(handler.remoteAddress);
			next();
		}));

		HTTPTestSupport.exchangeEach(server, [__get("/")], function(responses:Array<HTTPTestResponse>):Void {
			try server.close() catch (_:Dynamic) {}

			Assert.equals(200, responses[0].status);
			Assert.equals(1, seen.length);
			if (seen.length == 1) {
				// A dual-stack listener may report the mapped form.
				Assert.equals("127.0.0.1", RateLimiter.addressKey(seen[0]));
			}
			async.done();
		});
	}

	private static function __get(path:String, extra:String = ""):String {
		return "GET " + path + " HTTP/1.1\r\nHost: x\r\n" + extra + "\r\n";
	}

	private function __serve(configure:HTTPServerConfig->Void):HTTPServer {
		var router:Router = new Router();
		router.get("/", ctx -> ctx.handler.respond(200, "text/plain", "ok"));

		var config:HTTPServerConfig = new HTTPServerConfig("127.0.0.1", 0);
		config.middleware.push(router.middleware());
		configure(config);
		return new HTTPServer(config);
	}
}
