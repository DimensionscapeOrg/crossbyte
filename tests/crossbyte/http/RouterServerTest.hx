package crossbyte.http;

import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.ProgressEvent;
import crossbyte.io.ByteArray;
import crossbyte.io.File;
import crossbyte.net.Socket;
import utest.Assert;

class RouterServerTest extends utest.Test {
	public function testGetRouteResponds():Void {
		var router = new Router();
		router.get("/hello", ctx -> ctx.handler.respond(200, "text/plain", "hello route"));

		var response = __roundTrip(router, "GET /hello HTTP/1.1\r\nHost: localhost\r\n\r\n");

		Assert.equals(200, response.status);
		Assert.equals("hello route", response.body);
	}

	public function testPostRouteReadsItsBody():Void {
		// The body is read before middleware runs, so a route handler sees
		// it fully buffered rather than racing the socket.
		var router = new Router();
		router.post("/echo", ctx -> ctx.handler.respond(200, "text/plain", ctx.handler.requestText));

		var response = __roundTrip(router, "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 11\r\n\r\nhello world");

		Assert.equals(200, response.status);
		Assert.equals("hello world", response.body);
	}

	public function testWrongMethodAnswers405WithAllow():Void {
		var router = new Router();
		router.get("/users/:id", ctx -> ctx.handler.respond(200, "text/plain", "user"));
		router.put("/users/:id", ctx -> ctx.handler.respond(200, "text/plain", "updated"));

		// Falling through would turn this wrong-method API call into a
		// filesystem probe; the route's own Allow list is the useful answer.
		var response = __roundTrip(router, "POST /users/42 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\n\r\nhi");

		Assert.equals(405, response.status);
		Assert.equals("GET, PUT", response.headers.get("allow"));
		Assert.equals("405 Method Not Allowed", response.body);
		// The reason phrase comes from the handler's status table; a
		// regression there would ship "405 OK" status lines.
		Assert.isTrue(response.raw.indexOf("HTTP/1.1 405 Method Not Allowed") == 0);
	}

	public function testUnroutedPathFallsThroughToStaticServing():Void {
		var router = new Router();
		router.get("/hello", ctx -> ctx.handler.respond(200, "text/plain", "hello route"));

		// A path no route claims must be served exactly as if the router
		// were absent.
		var response = __roundTrip(router, "GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n");

		Assert.equals(200, response.status);
		Assert.equals("static fallback", response.body);
	}

	public function testUnroutedOptionsPreflightStillReachesCors():Void {
		// Registering a POST route must not swallow the CORS preflight for
		// its path: a router 405 carries no Access-Control-Allow-Methods,
		// so the browser would fail the preflight and cross-origin POSTs
		// would silently stop working.
		var router = new Router();
		router.post("/submit", ctx -> ctx.handler.respond(201, "text/plain", "created"));

		var response = __roundTrip(router,
			"OPTIONS /submit HTTP/1.1\r\nHost: localhost\r\nOrigin: https://app.example\r\nAccess-Control-Request-Method: POST\r\n\r\n", false,
			config -> config.corsEnabled = true);

		Assert.equals(204, response.status);
		Assert.equals("", response.body);
		Assert.equals("*", response.headers.get("access-control-allow-origin"));
		Assert.equals("POST", response.headers.get("access-control-allow-methods"));
	}

	public function testThrowingHandlerYieldsTheChains500AndCloses():Void {
		var router = new Router();
		router.get("/boom", _ -> throw "route exploded");

		// The router adds no error vocabulary: the middleware chain's own
		// catch answers 500 and closes the connection.
		var response = __roundTrip(router, "GET /boom HTTP/1.1\r\nHost: localhost\r\n\r\n", true);

		Assert.equals(500, response.status);
		Assert.equals("Internal Server Error", response.body);
		Assert.isTrue(response.closed);
	}

	public function testPutRouteRoundTripsItsBody():Void {
		// PUT sits outside the static dispatch gate's ALLOWED_METHODS;
		// reaching a handler with its body proves middleware runs ahead of
		// that gate and that body reads are framing-driven, not
		// method-driven.
		var router = new Router();
		router.put("/config/:name", ctx -> ctx.handler.respond(200, "text/plain", ctx.params.get("name") + "=" + ctx.handler.requestText));

		var response = __roundTrip(router, "PUT /config/depth HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\n\r\n42");

		Assert.equals(200, response.status);
		Assert.equals("depth=42", response.body);
	}

	/**
	 * One request against a real server whose only middleware is the
	 * router, answered from a temp docroot holding an index.html so
	 * fallthrough has something static to reach.
	 */
	private function __roundTrip(router:Router, requestText:String, waitForClose:Bool = false, ?configure:HTTPServerConfig->Void):RouterRoundTrip {
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
		var result:RouterRoundTrip = null;
		var failure:Dynamic = null;

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

		try {
			client.connect("127.0.0.1", server.localPort);
			HTTPTestSupport.pumpUntil(() -> closeSeen || __isComplete(raw), 2.0);
			if (waitForClose) {
				// The chain's error path closes the connection itself; give
				// the close event time to arrive behind the response bytes.
				HTTPTestSupport.pumpUntil(() -> closeSeen, 1.0);
			}
			result = __parse(raw, closeSeen);
			try {
				client.close();
			} catch (_:Dynamic) {}
		} catch (error:Dynamic) {
			failure = error;
		}

		try {
			server.close();
		} catch (_:Dynamic) {}
		try {
			root.deleteDirectory(true);
		} catch (_:Dynamic) {}

		if (failure != null) {
			throw failure;
		}

		Assert.notNull(result);
		return result;
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
