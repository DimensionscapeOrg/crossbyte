import crossbyte.core.ServerApplication;
import crossbyte.events.Event;
import crossbyte.http.HTTPRequestHandler;
import crossbyte.http.HTTPServer;
import crossbyte.http.HTTPServerConfig;
import crossbyte.net.RateLimiter;

/**
	The server half of the scaling measurement: an HTTPServer answering every
	request with five bytes, over HTTP/1.1 and HTTP/2 (cleartext, the first
	bytes decide), spread over a number of runtimes or on its own.

	    ScalingServer <port> <runtimes> [reuse]

	`runtimes` 0 serves on the application's runtime alone, as a server
	always has; above 0 it is `HTTPServerConfig.runtimeCount`. `reuse` sets
	`reusePort` (Linux). Prints `READY <port>` once listening, and serves
	until killed. Built with `-D scaling_base` it compiles against a
	CrossByte without spreading, for a before-and-after of the server on one
	runtime. ScalingLoad drives it; scaling.hxml builds both.
**/
class ScalingServer extends ServerApplication {
	private static var __args:Array<String> = [];

	private var __server:HTTPServer;

	public static function main():Void {
		__args = Sys.args();
		new ScalingServer();
	}

	public function new() {
		super();
		addEventListener(Event.INIT, __init);
	}

	private function __init(_):Void {
		var port:Null<Int> = __args.length > 0 ? Std.parseInt(__args[0]) : null;
		var runtimes:Null<Int> = __args.length > 1 ? Std.parseInt(__args[1]) : null;
		var reuse:Bool = __args.length > 2 && __args[2] == "reuse";

		// One line per request would be the measurement.
		crossbyte.utils.Logger.setLevel("http.access", crossbyte.utils.LogLevel.OFF);

		var config = new HTTPServerConfig("127.0.0.1", port == null ? 8090 : port);
		config.rateLimiter = new RateLimiter(1000000000, 1.0);
		config.http2Enabled = true;
		config.keepAliveMaxRequests = 0;
		config.keepAliveTimeout = 120;
		config.requestTimeout = 120;
		config.middleware.push(function(handler:HTTPRequestHandler, ?next:Dynamic->Void):Void {
			handler.respond(200, "text/plain", "hello");
		});
		#if !scaling_base
		if (runtimes != null && runtimes > 0) {
			config.runtimeCount = runtimes;
			config.reusePort = reuse;
		}
		#end

		__server = new HTTPServer(config);
		Sys.println("READY " + __server.localPort);
	}
}
