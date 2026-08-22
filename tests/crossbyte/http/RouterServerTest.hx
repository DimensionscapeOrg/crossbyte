package crossbyte.http;

import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.ProgressEvent;
import crossbyte.io.ByteArray;
import crossbyte.io.File;
import crossbyte.net.Socket;
import utest.Assert;
import utest.Async;

/**
 * The router in front of a real server.
 *
 * Every case here is asynchronous, which it did not need to be while these ran
 * only on the native targets: a `while` loop pumping the runtime delivers
 * socket I/O there perfectly well. It delivers nothing on Node, where I/O
 * arrives by returning to the event loop, so a synchronous round trip cannot
 * observe a response at all -- and does not fail saying so, it times out
 * looking like a slow test. `HTTPTestSupport.pumpUntilAsync` keeps the native
 * path synchronous underneath and calls back inline, so nothing here got
 * slower or harder to debug; what changed is that the same case now means
 * something on both.
 */
// Every case here waits on a socket, and some wait on a server-side timeout
// deliberately -- an idle keep-alive connection closing, an incomplete request
// answering 408. utest allows an asynchronous case 250ms by default, which is
// shorter than the behaviour under test, so four of them reported "async is
// timed out" rather than what they measured. The budget is a ceiling on a hang,
// not a target: a healthy run spends nowhere near it.
@:timeout(20000)
class RouterServerTest extends utest.Test {
	public function testGetRouteResponds(async:Async):Void {
		var router = new Router();
		router.get("/hello", ctx -> ctx.handler.respond(200, "text/plain", "hello route"));

		__roundTrip(router, "GET /hello HTTP/1.1\r\nHost: localhost\r\n\r\n", function(response):Void {
			Assert.equals(200, response.status);
			Assert.equals("hello route", response.body);
			async.done();
		});
	}

	public function testPostRouteReadsItsBody(async:Async):Void {
		// The body is read before middleware runs, so a route handler sees
		// it fully buffered rather than racing the socket.
		var router = new Router();
		router.post("/echo", ctx -> ctx.handler.respond(200, "text/plain", ctx.handler.requestText));

		__roundTrip(router, "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 11\r\n\r\nhello world", function(response):Void {
			Assert.equals(200, response.status);
			Assert.equals("hello world", response.body);
			async.done();
		});
	}

	public function testWrongMethodAnswers405WithAllow(async:Async):Void {
		var router = new Router();
		router.get("/users/:id", ctx -> ctx.handler.respond(200, "text/plain", "user"));
		router.put("/users/:id", ctx -> ctx.handler.respond(200, "text/plain", "updated"));

		// Falling through would turn this wrong-method API call into a
		// filesystem probe; the route's own Allow list is the useful answer.
		__roundTrip(router, "POST /users/42 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\n\r\nhi", function(response):Void {
			Assert.equals(405, response.status);
			Assert.equals("GET, PUT", response.headers.get("allow"));
			Assert.equals("405 Method Not Allowed", response.body);
			// The reason phrase comes from the handler's status table; a
			// regression there would ship "405 OK" status lines.
			Assert.isTrue(response.raw.indexOf("HTTP/1.1 405 Method Not Allowed") == 0);
			async.done();
		});
	}

	public function testUnroutedPathFallsThroughToStaticServing(async:Async):Void {
		var router = new Router();
		router.get("/hello", ctx -> ctx.handler.respond(200, "text/plain", "hello route"));

		// A path no route claims must be served exactly as if the router
		// were absent.
		__roundTrip(router, "GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n", function(response):Void {
			Assert.equals(200, response.status);
			Assert.equals("static fallback", response.body);
			async.done();
		});
	}

	public function testUnroutedOptionsPreflightStillReachesCors(async:Async):Void {
		// Registering a POST route must not swallow the CORS preflight for
		// its path: a router 405 carries no Access-Control-Allow-Methods,
		// so the browser would fail the preflight and cross-origin POSTs
		// would silently stop working.
		var router = new Router();
		router.post("/submit", ctx -> ctx.handler.respond(201, "text/plain", "created"));

		__roundTrip(router, "OPTIONS /submit HTTP/1.1\r\nHost: localhost\r\nOrigin: https://app.example\r\nAccess-Control-Request-Method: POST\r\n\r\n",
			function(response):Void {
				Assert.equals(204, response.status);
				Assert.equals("", response.body);
				Assert.equals("*", response.headers.get("access-control-allow-origin"));
				Assert.equals("POST", response.headers.get("access-control-allow-methods"));
				async.done();
			}, false, config -> config.corsEnabled = true);
	}

	public function testThrowingHandlerYieldsTheChains500AndCloses(async:Async):Void {
		var router = new Router();
		router.get("/boom", _ -> throw "route exploded");

		// The router adds no error vocabulary: the middleware chain's own
		// catch answers 500 and closes the connection.
		__roundTrip(router, "GET /boom HTTP/1.1\r\nHost: localhost\r\n\r\n", function(response):Void {
			Assert.equals(500, response.status);
			Assert.equals("Internal Server Error", response.body);
			Assert.isTrue(response.closed);
			async.done();
		}, true);
	}

	public function testPutRouteRoundTripsItsBody(async:Async):Void {
		// PUT sits outside the static dispatch gate's ALLOWED_METHODS;
		// reaching a handler with its body proves middleware runs ahead of
		// that gate and that body reads are framing-driven, not
		// method-driven.
		var router = new Router();
		router.put("/config/:name", ctx -> ctx.handler.respond(200, "text/plain", ctx.params.get("name") + "=" + ctx.handler.requestText));

		__roundTrip(router, "PUT /config/depth HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\n\r\n42", function(response):Void {
			Assert.equals(200, response.status);
			Assert.equals("depth=42", response.body);
			async.done();
		});
	}

	/**
	 * One request against a real server whose only middleware is the
	 * router, answered from a temp docroot holding an index.html so
	 * fall-through has something to find.
	 */
	private function __roundTrip(router:Router, requestText:String, done:RouterRoundTrip->Void, waitForClose:Bool = false,
			?configure:HTTPServerConfig->Void):Void {
		var root = File.createTempDirectory();
		var indexFile = root.resolvePath("index.html");
		var fixture = new ByteArray();
		fixture.writeUTFBytes("static fallback");
		indexFile.save(fixture);

		var config = new HTTPServerConfig("127.0.0.1", 0, root, null, ["index.html"], null, null, null, [router.middleware()]);
		if (configure != null) {
			configure(config);
		}
		var server = new HTTPServer(config);
		var client = new Socket();
		var raw = "";
		var closeSeen = false;

		client.addEventListener(Event.CONNECT, _ -> {
			client.writeUTFBytes(requestText);
			client.flush();
		});
		client.addEventListener(ProgressEvent.SOCKET_DATA, _ -> {
			if (client.bytesAvailable > 0) {
				raw += client.readUTFBytes(client.bytesAvailable);
			}
		});
		client.addEventListener(Event.CLOSE, _ -> closeSeen = true);

		function finish():Void {
			var result = __parse(raw, closeSeen);

			try {
				client.close();
			} catch (_:Dynamic) {}
			try {
				server.close();
			} catch (_:Dynamic) {}
			try {
				root.deleteDirectory(true);
			} catch (_:Dynamic) {}

			Assert.notNull(result);
			done(result);
		}

		HTTPTestSupport.connectThen(client, server, function():Void {
			HTTPTestSupport.pumpUntilAsync(() -> closeSeen || __isComplete(raw), 2.0, function(_):Void {
				if (waitForClose) {
					// The chain's error path closes the connection itself; give
					// the close event time to arrive behind the response bytes.
					HTTPTestSupport.pumpUntilAsync(() -> closeSeen, 1.0, _ -> finish());
					return;
				}

				finish();
			});
		});
	}

	private static function __isComplete(raw:String):Bool {
		return HTTPTestSupport.isResponseComplete(raw);
	}

	/**
	 * Adapts the shared parser to this suite's result, which additionally
	 * carries whether the connection closed -- the router's 405 and its
	 * throwing-handler 500 differ from a routed 200 in exactly that.
	 */
	private static function __parse(raw:String, closed:Bool):RouterRoundTrip {
		var parsed = HTTPTestSupport.parseResponse(raw);
		return {status: parsed.status, headers: parsed.headers, body: parsed.body, closed: closed, raw: parsed.raw};
	}
}

typedef RouterRoundTrip = {
	var status:Int;
	var headers:Map<String, String>;
	var body:String;
	var closed:Bool;
	var raw:String;
}
