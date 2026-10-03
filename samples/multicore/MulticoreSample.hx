import crossbyte.Timer;
import crossbyte.core.CrossByte;
import crossbyte.core.ServerApplication;
import crossbyte.events.Event;
import crossbyte.events.HTTPStatusEvent;
import crossbyte.events.IOErrorEvent;
import crossbyte.http.HTTPRequestHandler;
import crossbyte.http.HTTPServer;
import crossbyte.http.HTTPServerConfig;
import crossbyte.net.RateLimiter;
import crossbyte.url.URLLoader;
import crossbyte.url.URLRequest;
#if target.threaded
import sys.thread.Mutex;
#end

/**
 * One HTTP server on several cores.
 *
 * `runtimeCount` makes four runtimes, each a thread of its own, and the
 * server hands every connection it accepts to one of them; from then on that
 * connection's requests are served there. The middleware below therefore
 * runs on four threads at once, and shows the two ways what it touches can
 * be safe:
 *
 * - the table naming each runtime is only read once it is built, so every
 *   runtime can share it without a lock;
 * - the count of requests answered is changed by all of them, so it takes a
 *   lock.
 *
 * Run without arguments it fetches from itself, sixteen requests at once,
 * prints which runtime answered how many, drains the server and exits: 0 when
 * every request was answered and more than one runtime answered them, 1
 * otherwise, so CI can run it. `serve [runtimes]` keeps serving instead.
 */
class MulticoreSample extends ServerApplication {
	private static inline var DEADLINE_SECONDS:Float = 15;
	private static inline var REQUESTS:Int = 16;

	private static var __args:Array<String> = [];

	private var __server:HTTPServer;
	// Read by every runtime, written only before the first request arrives.
	private var __names:Map<CrossByte, String> = new Map();
	#if target.threaded
	private var __countLock:Mutex = new Mutex();
	#end
	private var __answered:Int = 0;

	private var __outstanding:Int = 0;
	private var __byRuntime:Map<String, Int> = new Map();
	private var __failures:Array<String> = [];
	private var __deadline:Int = -1;

	public static function main():Void {
		#if !(sys && !eval)
		Sys.println("This sample spreads a server over threads, natively.");
		return;
		#end

		__args = Sys.args();
		new MulticoreSample();
	}

	public function new() {
		super();
		addEventListener(Event.INIT, __handleInit);
		addEventListener(Event.EXIT, __handleExit);
	}

	private function __handleInit(_event:Event):Void {
		var serving:Bool = __args.length > 0 && __args[0] == "serve";
		var count:Null<Int> = __args.length > 1 ? Std.parseInt(__args[1]) : null;

		var config = new HTTPServerConfig("127.0.0.1", serving ? 8080 : 0);
		// The runtimes are made as the server starts, each a POLL loop, and
		// exit once drain() has finished.
		config.runtimeCount = count != null && count > 0 ? count : 4;
		// Every request here comes from one address; the default limiter would
		// see one very busy client.
		config.rateLimiter = new RateLimiter(1000000, 1.0);
		config.middleware.push(__answer);

		__server = new HTTPServer(config);
		var runtimes:Array<CrossByte> = __server.runtimes;
		for (i in 0...runtimes.length) {
			__names.set(runtimes[i], "runtime " + i);
		}
		Sys.println('Serving on http://127.0.0.1:${__server.localPort}/ with ${runtimes.length} runtimes');

		if (serving) {
			Sys.println("Serving until the process exits.");
			return;
		}

		__deadline = Timer.setTimeout(DEADLINE_SECONDS, function():Void {
			__failures.push('no answer within ${DEADLINE_SECONDS}s; still waiting on $__outstanding request(s)');
			shutdown();
		});
		for (i in 0...REQUESTS) {
			__fetch('/request/$i');
		}
	}

	/** The middleware: runs on the runtime holding the request's connection. **/
	private function __answer(handler:HTTPRequestHandler, ?next:Dynamic->Void):Void {
		var name:String = __names.get(CrossByte.current());

		#if target.threaded
		__countLock.acquire();
		#end
		__answered++;
		#if target.threaded
		__countLock.release();
		#end

		handler.respond(200, "text/plain", name);
	}

	private function __fetch(path:String):Void {
		__outstanding++;

		var status:Int = -1;
		var loader = new URLLoader();
		loader.addEventListener(HTTPStatusEvent.HTTP_STATUS, e -> status = e.status);
		loader.addEventListener(Event.COMPLETE, _ -> {
			var body:String = Std.string(loader.data);
			if (status != 200) {
				__failures.push('$path: status $status');
			} else {
				__byRuntime.set(body, (__byRuntime.exists(body) ? __byRuntime.get(body) : 0) + 1);
			}
			__finish();
		});
		loader.addEventListener(IOErrorEvent.IO_ERROR, e -> {
			__failures.push('$path: ${e.text}');
			__finish();
		});
		loader.load(new URLRequest('http://127.0.0.1:${__server.localPort}$path'));
	}

	private function __finish():Void {
		if (--__outstanding > 0) {
			return;
		}

		var names:Array<String> = [for (name in __byRuntime.keys()) name];
		names.sort((a, b) -> a < b ? -1 : a > b ? 1 : 0);
		for (name in names) {
			Sys.println('$name answered ${__byRuntime.get(name)} request(s)');
		}
		if (names.length < 2) {
			__failures.push('only ${names.length} runtime answered the requests');
		}

		// Every runtime drains its own connections; the server's runtime is
		// told once they all have.
		__server.drain(5.0, () -> shutdown());
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

		if (__answered != REQUESTS && __failures.length == 0) {
			__failures.push('the server counted $__answered requests answered, not $REQUESTS');
		}
		if (__failures.length > 0) {
			for (failure in __failures) {
				Sys.println('FAIL: $failure');
			}
			Sys.exit(1);
		}

		Sys.println('OK: $REQUESTS requests answered across ${Lambda.count(__byRuntime)} runtimes.');
	}
}
