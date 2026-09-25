import crossbyte.Timer;
import crossbyte.core.ServerApplication;
import crossbyte.events.Event;
import crossbyte.events.HTTPStatusEvent;
import crossbyte.events.IOErrorEvent;
import crossbyte.http.HTTPServer;
import crossbyte.http.HTTPServerConfig;
import crossbyte.http.HTTPVersion;
import crossbyte.io.ByteArray;
import crossbyte.io.File;
import crossbyte.url.URLLoader;
import crossbyte.url.URLRequest;

/**
 * Serves and fetches over HTTP/2.
 *
 * Two things worth noticing, because neither needs any code here:
 *
 * - The listener sets one flag and then serves both versions. HTTP/2 clients
 *   get HTTP/2; HTTP/1.1 clients get HTTP/1.1 on the same port, decided per
 *   connection. Run it with `serve` and point a browser at it, and it will use
 *   HTTP/1.1; this sample's own client uses HTTP/2.
 * - The client asks for a version and nothing else. Requests to one host share
 *   a connection and travel as concurrent streams, and `URLLoader.close()`
 *   resets just that stream rather than dropping everyone else's.
 *
 * Run without arguments it fetches both pages, checks what came back and
 * exits: 0 when both arrived as served, 1 otherwise, so CI can run it. The
 * client never falls back to HTTP/1.1 -- a server that does not answer in
 * HTTP/2 fails the request -- so two correct bodies mean two HTTP/2 streams.
 */
class Http2Sample extends ServerApplication {
	// Long enough for a loaded CI runner, short enough that a hang fails the
	// run rather than stalling it.
	private static inline var DEADLINE_SECONDS:Float = 10;

	private static var __args:Array<String> = [];

	private static final PAGES:Map<String, String> = [
		"/index.html" => "<h1>Served over HTTP/2</h1>",
		"/about.html" => "<h1>About</h1>"
	];

	private var __server:HTTPServer;
	private var __outstanding:Int = 0;
	private var __failures:Array<String> = [];
	private var __deadline:Int = -1;

	public static function main():Void {
		#if !(sys && !eval)
		Sys.println("HTTPServer is only supported on native sys targets.");
		return;
		#end

		__args = Sys.args();
		new Http2Sample();
	}

	public function new() {
		super();
		addEventListener(Event.INIT, __handleInit);
		addEventListener(Event.EXIT, __handleExit);
	}

	private function __handleInit(_event:Event):Void {
		var root:File = File.createTempDirectory();
		for (path => html in PAGES) {
			__write(root, path.substr(1), html);
		}

		// Port 0, so a port someone else holds cannot fail the run.
		var config = new HTTPServerConfig("127.0.0.1", 0, root, null, ["index.html"]);

		// The whole of the server-side opt-in. Everything below the framing --
		// routing, middleware, static files, CORS -- is untouched by it.
		config.http2Enabled = true;

		__server = new HTTPServer(config);
		Sys.println('Serving HTTP/1.1 and HTTP/2 on http://127.0.0.1:${__server.localPort}');

		if (__args.length > 0 && __args[0] == "serve") {
			Sys.println("Serving until the process exits.");
			return;
		}

		__deadline = Timer.setTimeout(DEADLINE_SECONDS, function():Void {
			__failures.push('no answer within ${DEADLINE_SECONDS}s; still waiting on $__outstanding request(s)');
			shutdown();
		});

		// Two at once, to the same origin. They share one connection.
		for (path in PAGES.keys()) {
			__fetch(path);
		}
	}

	private function __fetch(path:String):Void {
		__outstanding++;

		var request = new URLRequest('http://127.0.0.1:${__server.localPort}$path');
		// Nothing else to arrange: the bundled backend registers itself the
		// first time a request asks for HTTP/2.
		request.httpVersion = HTTPVersion.HTTP_2;

		var status:Int = -1;
		var loader = new URLLoader();
		// HTTP_STATUS, a loader's own: HTTP_RESPONSE_STATUS is what a server's
		// request handler reports as it answers, and a loader never sees it.
		loader.addEventListener(HTTPStatusEvent.HTTP_STATUS, e -> status = e.status);
		loader.addEventListener(Event.COMPLETE, _ -> {
			var body:String = Std.string(loader.data);
			Sys.println('$path -> $status $body');
			if (status != 200) {
				__failures.push('$path: status $status');
			} else if (body != PAGES.get(path)) {
				__failures.push('$path: expected "${PAGES.get(path)}", received "$body"');
			}
			__finish();
		});
		loader.addEventListener(IOErrorEvent.IO_ERROR, e -> {
			Sys.println('$path -> failed: ${e.text}');
			__failures.push('$path: ${e.text}');
			__finish();
		});

		// loader.close() would cancel this one and leave the other running:
		// over HTTP/2 that is a stream reset, not a dropped connection.
		loader.load(request);
	}

	private function __finish():Void {
		if (--__outstanding > 0) {
			return;
		}

		// A beat, so the last response has finished leaving before the
		// listener goes away.
		Timer.setTimeout(0.05, function():Void {
			shutdown();
		});
	}

	private function __handleExit(_event:Event):Void {
		if (__deadline != -1) {
			Timer.clear(__deadline);
			__deadline = -1;
		}
		if (__server != null) {
			__server.close();
			__server = null;
		}

		// An exit status rather than a thrown error, as the websocket echo
		// sample does: hxcpp exits 127 on an uncaught throw, which reads as
		// "command not found" in a build log.
		if (__failures.length > 0) {
			for (failure in __failures) {
				Sys.println('FAIL: $failure');
			}
			Sys.exit(1);
		}

		Sys.println("OK: both pages arrived over HTTP/2.");
	}

	private function __write(root:File, name:String, html:String):Void {
		var bytes = new ByteArray();
		bytes.writeUTFBytes(html);
		root.resolvePath(name).save(bytes);
	}
}
