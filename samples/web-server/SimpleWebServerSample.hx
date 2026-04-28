import haxe.io.Path;
import crossbyte.Timer;
import crossbyte.core.ServerApplication;
import crossbyte.events.Event;
import crossbyte.events.HTTPStatusEvent;
import crossbyte.events.IOErrorEvent;
import crossbyte.http.HTTPServer;
import crossbyte.http.HTTPServerConfig;
import crossbyte.io.File;
import crossbyte.url.URLLoader;
import crossbyte.url.URLRequest;
import crossbyte.url.URLRequestHeader;

class SimpleWebServerSample extends ServerApplication {
	private static var __args:Array<String> = [];

	public static function main():Void {
		#if !(sys && !eval)
		Sys.println("HTTPServer is only supported on native sys targets.");
		return;
		#end

		__args = Sys.args();
		new SimpleWebServerSample();
	}

	private var server:HTTPServer;
	private var loader:URLLoader;
	private var statusCode:Int = -1;
	private var failed:String = null;
	private var mode:String = "demo";
	private var docRootPath:String = null;

	public function new() {
		super();
		addEventListener(Event.INIT, __handleInit);
		addEventListener(Event.EXIT, __handleExit);
	}

	private function __handleInit(_event:Event):Void {
		mode = __args.length > 0 ? __args[0] : "demo";
		docRootPath = __prepareDocRoot();

		var config = new HTTPServerConfig("127.0.0.1", 0, new File(docRootPath));
		config.directoryIndex = ["index.html"];
		config.customHeaders = [new URLRequestHeader("X-CrossByte-Sample", "simple-web-server")];

		server = new HTTPServer(config);
		Sys.println('Simple web server listening on http://127.0.0.1:${server.localPort}/');
		Sys.println('doc root -> "$docRootPath"');

		switch (mode) {
			case "serve":
				Sys.println("Serving until the process exits.");
			case "demo":
				__runDemo();
			default:
				failed = 'Unknown mode "$mode". Expected "demo" or "serve".';
				shutdown();
		}
	}

	private function __runDemo():Void {
		loader = new URLLoader();
		loader.addEventListener(HTTPStatusEvent.HTTP_STATUS, event -> statusCode = event.status);
		loader.addEventListener(Event.COMPLETE, _ -> {
			Sys.println('demo status -> $statusCode');
			Sys.println('demo body -> "${Std.string(loader.data)}"');
			shutdown();
		});
		loader.addEventListener(IOErrorEvent.IO_ERROR, event -> {
			failed = event.text;
			shutdown();
		});

		Timer.setTimeout(0.05, function():Void {
			var request = new URLRequest('http://127.0.0.1:${server.localPort}/');
			loader.load(request);
		});
	}

	private function __handleExit(_event:Event):Void {
		if (loader != null) {
			loader.close();
			loader = null;
		}
		if (server != null) {
			server.close();
			server = null;
		}

		if (failed != null) {
			Sys.println('web server sample error -> $failed');
			Sys.exit(1);
		}
	}

	private static function __prepareDocRoot():String {
		var programDir = Path.directory(Sys.programPath());
		var root = Path.join([programDir, "doc-root"]);
		if (!sys.FileSystem.exists(root)) {
			sys.FileSystem.createDirectory(root);
		}

		sys.io.File.saveContent(Path.join([root, "index.html"]),
			"<html><body><h1>CrossByte Web Server Sample</h1><p>Hello from HTTPServer.</p></body></html>");
		sys.io.File.saveContent(Path.join([root, "status.txt"]), "ok");
		return root;
	}
}
