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
 *   connection. Point a browser at it and it will use HTTP/1.1; point this
 *   sample's client at it and it will use HTTP/2.
 * - The client asks for a version and nothing else. Requests to one host share
 *   a connection and travel as concurrent streams, and `URLLoader.close()`
 *   resets just that stream rather than dropping everyone else's.
 */
class Http2Sample extends ServerApplication {
	private static inline var PORT:Int = 8742;

	private var __server:HTTPServer;
	private var __outstanding:Int = 0;

	public static function main():Void {
		#if !(sys && !eval)
		Sys.println("HTTPServer is only supported on native sys targets.");
		return;
		#end

		new Http2Sample();
	}

	public function new() {
		super();
		addEventListener(Event.INIT, __handleInit);
	}

	private function __handleInit(_event:Event):Void {
		var root:File = File.createTempDirectory();
		__write(root, "index.html", "<h1>Served over HTTP/2</h1>");
		__write(root, "about.html", "<h1>About</h1>");

		var config = new HTTPServerConfig("127.0.0.1", PORT, root, null, ["index.html"]);

		// The whole of the server-side opt-in. Everything below the framing --
		// routing, middleware, static files, CORS -- is untouched by it.
		config.http2Enabled = true;

		__server = new HTTPServer(config);
		__server.listen();
		Sys.println('Serving HTTP/1.1 and HTTP/2 on http://127.0.0.1:$PORT');

		// Two at once, to the same origin. They share one connection.
		__fetch("/index.html");
		__fetch("/about.html");
	}

	private function __fetch(path:String):Void {
		__outstanding++;

		var request = new URLRequest('http://127.0.0.1:$PORT$path');
		// Nothing else to arrange: the bundled backend registers itself the
		// first time a request asks for HTTP/2.
		request.httpVersion = HTTPVersion.HTTP_2;

		var loader = new URLLoader();
		loader.addEventListener(Event.COMPLETE, _ -> {
			Sys.println('$path -> ${loader.data}');
			__finish();
		});
		loader.addEventListener(HTTPStatusEvent.HTTP_RESPONSE_STATUS, e -> Sys.println('$path -> status ${e.status}'));
		loader.addEventListener(IOErrorEvent.IO_ERROR, e -> {
			Sys.println('$path -> failed: ${e.text}');
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
			__server.close();
			Sys.println("Done.");
		});
	}

	private function __write(root:File, name:String, html:String):Void {
		var bytes = new ByteArray();
		bytes.writeUTFBytes(html);
		root.resolvePath(name).save(bytes);
	}
}
