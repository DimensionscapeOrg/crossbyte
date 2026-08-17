import haxe.io.Path;
import crossbyte.core.ServerApplication;
import crossbyte.events.Event;
import crossbyte.http.HTTPServer;
import crossbyte.http.HTTPServerConfig;
import crossbyte.io.File;
import crossbyte.sys.ProcessLifecycle;
import crossbyte.utils.Logger;

/**
	A server that survives being stopped by the Windows Service Control Manager,
	and behaves identically when run from a console.

	This is the shape a real service needs, and every piece of it is here
	because leaving it out breaks something specific:

	- `installServiceControl` rather than `installDefaultHandlers`, because a
	  process started by the SCM has no console and is sent none of the `CTRL_*`
	  events. Without it a `sc stop` runs no callback at all.
	- `exitOnShutdown = false`, because the drain is asynchronous and polls the
	  connection count on each tick. Left at its default the runtime would exit
	  the moment the callback returned, and the drain would never get another
	  tick to finish on.
	- `deferServiceStop = true`, because `poll()` reports the service stopped as
	  soon as the callbacks return, which for an asynchronous drain would tell
	  the SCM the work was finished while connections were still being served.
	- A log file, because a service has no stdout to print to. Without one there
	  is no way to see whether the drain ran.
**/
class WindowsServiceSample extends ServerApplication {
	private static inline var SERVICE_NAME:String = "CrossByteSample";
	private static inline var DEFAULT_PORT:Int = 8080;
	private static inline var DRAIN_SECONDS:Float = 20;

	private static var __args:Array<String> = [];

	public static function main():Void {
		#if !(sys && !eval)
		Sys.println("The service sample requires a native sys target.");
		return;
		#end

		__args = Sys.args();
		new WindowsServiceSample();
	}

	private var server:HTTPServer;

	public function new() {
		super();
		addEventListener(Event.INIT, __handleInit);
		addEventListener(Event.EXIT, __handleExit);
	}

	private function __handleInit(_event:Event):Void {
		var programDir:String = Path.directory(Sys.programPath());
		__installFileLogging(Path.join([programDir, "service-sample.log"]));

		var config = new HTTPServerConfig("127.0.0.1", __resolvePort(), new File(__prepareDocRoot(programDir)));
		config.directoryIndex = ["index.html"];
		server = new HTTPServer(config);

		// Arranged before attaching, so a stop arriving immediately after the
		// service reports itself running still finds a drain to run.
		ProcessLifecycle.exitOnShutdown = false;
		ProcessLifecycle.deferServiceStop = true;
		ProcessLifecycle.onShutdown(__handleShutdown);

		var attached:Bool = ProcessLifecycle.installServiceControl(SERVICE_NAME);

		Logger.info(attached ? "started under the service control manager" : "started as a console process", [
			"port" => Std.string(server.localPort),
			"service" => Std.string(ProcessLifecycle.isService)
		]);
	}

	private function __handleShutdown():Void {
		Logger.info("stop requested; draining", ["connections" => Std.string(server.activeConnections)]);

		// Asking for longer than the drain can take. The SCM assumes a service
		// that has said nothing for its wait hint has hung, and kills it -- so
		// the hint has to cover the whole drain, not the optimistic case.
		ProcessLifecycle.reportServiceStopPending(Std.int(DRAIN_SECONDS * 1000) + 10000);

		server.drain(DRAIN_SECONDS, function():Void {
			Logger.info("drain complete; reporting service stopped");

			// Reported before tearing the runtime down, not after: the SCM is
			// entitled to kill the process the moment it sees this, and by here
			// the drain -- the part worth protecting -- has already finished.
			// Leaving it until after shutdown() risks the process ending first,
			// which the SCM records as "terminated unexpectedly".
			ProcessLifecycle.reportServiceStopped(0);
			shutdown();
		});
	}

	private function __handleExit(_event:Event):Void {
		Logger.info("exiting");

		if (server != null) {
			server.close();
			server = null;
		}
	}

	private static function __resolvePort():Int {
		if (__args.length == 0) {
			return DEFAULT_PORT;
		}

		var parsed:Null<Int> = Std.parseInt(__args[0]);
		return parsed == null ? DEFAULT_PORT : parsed;
	}

	private static function __installFileLogging(logPath:String):Void {
		Logger.timestamps = true;

		// Reopened per line rather than held open: a sample that is going to be
		// killed by a service-control timeout at least once while you are
		// testing it should not be able to lose the lines explaining why.
		Logger.sink = function(line:String):Void {
			try {
				var out = sys.io.File.append(logPath, false);
				out.writeString(line + "\n");
				out.close();
			} catch (_:Dynamic) {}

			// Useful in a console run, invisible under the SCM, harmless in both.
			Sys.println(line);
		};
	}

	private static function __prepareDocRoot(programDir:String):String {
		var root:String = Path.join([programDir, "doc-root"]);

		if (!sys.FileSystem.exists(root)) {
			sys.FileSystem.createDirectory(root);
		}

		sys.io.File.saveContent(Path.join([root, "index.html"]),
			"<html><body><h1>CrossByte Service Sample</h1><p>Stop the service and watch the drain run.</p></body></html>");

		return root;
	}
}
