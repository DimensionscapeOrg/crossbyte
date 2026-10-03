import crossbyte.core.ServerApplication;
import crossbyte.events.Event;
import crossbyte.http.HTTPServer;
import crossbyte.http.HTTPServerConfig;
import crossbyte.http.Router;
import crossbyte.io.ByteArray;
import crossbyte.io.File;

/**
	An HTTP server to measure from the outside: what a request costs the
	server in CPU, user and kernel apart, under a real load over loopback.

	usage: PerfHttpServer <scenario>
	  route    a Router answers GET /api with a small JSON object
	  mw       one bare middleware answers every request the same way
	  static   no middleware: GET /small.json (79 B) and /medium.json (4.7 KB)
	           are static files under a root
	  big      a middleware answers 64 KB of JSON with respondBytes

	Binds 127.0.0.1:0 and prints "READY <port>", then every second
	"STATS t=.. cpu=.. user=.. kernel=.. mem=.. served=..": process CPU
	seconds (user + kernel, and each), GC memory in use, requests answered.
	Exits after PERF_SECONDS.

	Environment:
	  PERF_SECONDS      lifetime (required: the runner relies on it)
	  PERF_HTTP2=1      HTTP/2 as well (prior knowledge over cleartext)
	  PERF_ROUTES=N     N - 1 decoy routes registered before /api (route);
	                    PERF_ROUTE_SHAPE=rest makes them /api/v1/resourceN/:id
	                    and the target /api/v1/items/:id
	  PERF_ACCESS_LOG   "on" keeps the default access log; off otherwise
	  PERF_STATS_FILE   READY and STATS to this file instead of stdout
	  PERF_MAX_CONNS, PERF_KEEPALIVE_TIMEOUT, PERF_REQUEST_TIMEOUT
	  PERF_PROFILE      with -D HXCPP_PROFILER: profile file to write
	  PERF_PROFILE_AFTER / PERF_PROFILE_SECONDS

	Drive it with runner.js (one run, pinned to CPUs 24-31) or suite.js (a
	list, repetitions interleaved); build it with perf-http.hxml (or the -jvm
	and -node ones), or with build-stage.ps1, which keeps each build as
	export/perf-http/bin/<stage>.exe for before-and-after runs.
	Windows: the runner pins with `start /affinity`, and CPU time is read with
	GetProcessTimes.
**/
#if (cpp && windows)
@:cppFileCode('
#include <windows.h>
static double perf_cpu_part(int which) {
	FILETIME created, exited, kernel, user;
	if (!GetProcessTimes(GetCurrentProcess(), &created, &exited, &kernel, &user)) return -1.0;
	FILETIME f = which == 0 ? user : kernel;
	ULARGE_INTEGER x;
	x.LowPart = f.dwLowDateTime;
	x.HighPart = f.dwHighDateTime;
	return (double)x.QuadPart / 10000000.0;
}
')
#end
class PerfHttpServer extends ServerApplication {
	static var __args:Array<String>;

	public static function main():Void {
		__args = Sys.args();
		new PerfHttpServer();
	}

	var served:Int = 0;
	var started:Float;
	var keep:Array<Dynamic> = [];

	public function new() {
		super();
		addEventListener(Event.INIT, __init);
	}

	static final SMALL:String = '{"ok":true,"id":12345,"name":"crossbyte","tags":["fast","small"],"score":98.5}';

	function __init(_:Event):Void {
		var scenario = __args.length > 0 ? __args[0] : "route";
		started = haxe.Timer.stamp();

		var config = new HTTPServerConfig("127.0.0.1", 0);
		// One client address: the default limiter would refuse it within a
		// second. Off, as for an API behind a proxy.
		config.rateLimitKey = _ -> null;
		// What a busy API sets; the default 100 makes every hundredth request
		// a reconnect, which is the load generator's cost as much as ours.
		config.keepAliveMaxRequests = 0;
		config.maxConnections = 4096;
		// The idle measurements: connections held open, timeouts on or off.
		var maxConns = Std.parseInt(Sys.getEnv("PERF_MAX_CONNS"));
		if (maxConns != null) {
			config.maxConnections = maxConns;
		}
		var keepAliveTimeout = Std.parseFloat(Sys.getEnv("PERF_KEEPALIVE_TIMEOUT"));
		if (!Math.isNaN(keepAliveTimeout)) {
			config.keepAliveTimeout = keepAliveTimeout;
		}
		var requestTimeout = Std.parseFloat(Sys.getEnv("PERF_REQUEST_TIMEOUT"));
		if (!Math.isNaN(requestTimeout)) {
			config.requestTimeout = requestTimeout;
		}
		if (Sys.getEnv("PERF_HTTP2") == "1") {
			config.http2Enabled = true;
		}
		if (Sys.getEnv("PERF_ACCESS_LOG") != "on") {
			crossbyte.utils.Logger.setLevel("http.access", crossbyte.utils.LogLevel.WARN);
		}

		switch (scenario) {
			case "route":
				var router = new Router();
				var routes = Std.parseInt(Sys.getEnv("PERF_ROUTES"));
				if (routes == null || routes < 1) {
					routes = 1;
				}
				if (Sys.getEnv("PERF_ROUTE_SHAPE") == "rest") {
					// A REST table: every decoy has the target's four segments,
					// /api/v1/<resource>/:id, and only the third differs. The
					// load asks for /api/v1/items/42.
					for (i in 0...routes - 1) {
						router.get('/api/v1/resource$i/:id', ctx -> ctx.handler.respond(200, "application/json", SMALL));
					}
					router.get("/api/v1/items/:id", ctx -> {
						served++;
						ctx.handler.respond(200, "application/json", SMALL);
					});
				} else {
					// Decoys shaped like a real API's table, none matching /api.
					var shapes = ["/users/:id", "/users/:id/posts", "/v1/items/:id/details", "/health", "/login", "/static/*rest", "/orders/:order/lines/:line"];
					for (i in 0...routes - 1) {
						var shape = shapes[i % shapes.length];
						router.get('/r$i' + shape, ctx -> ctx.handler.respond(200, "application/json", SMALL));
					}
					router.get("/api", ctx -> {
						served++;
						ctx.handler.respond(200, "application/json", SMALL);
					});
				}
				config.middleware.push(router.middleware());
			case "mw":
				config.middleware.push((handler, next) -> {
					served++;
					handler.respond(200, "application/json", SMALL);
				});
			case "big":
				// 64 KB, encoded once, as a server holds a Buffer: what each
				// protocol's writer does with a body of that size.
				var text = new StringBuf();
				text.add("[");
				var i = 0;
				while (text.length < 64 * 1024) {
					if (i > 0) {
						text.add(",");
					}
					text.add('{"id":$i,"name":"item number $i","inStock":${i % 3 != 0}}');
					i++;
				}
				text.add("]");
				var big = ByteArray.fromBytes(haxe.io.Bytes.ofString(text.toString()));
				config.middleware.push((handler, next) -> {
					served++;
					handler.respondBytes(200, "application/json", big);
				});
			case "static":
				var root = Sys.getEnv("PERF_ROOT");
				if (root == null || root == "") {
					root = Sys.getCwd() + "perf-www";
				}
				sys.FileSystem.createDirectory(root);
				sys.io.File.saveContent(root + "/small.json", SMALL);
				// 4 KB of JSON, compressible: what a gzip client is sent from
				// the kept compressed bodies.
				var medium = new StringBuf();
				medium.add("[");
				for (i in 0...60) {
					medium.add((i > 0 ? "," : "") + SMALL);
				}
				medium.add("]");
				sys.io.File.saveContent(root + "/medium.json", medium.toString());
				config.rootDirectory = new File(root);
				// Counted from the response event, since nothing of ours runs.
				config.middleware.push((handler, next) -> {
					served++;
					next();
				});
			default:
				__say("unknown scenario " + scenario);
				Sys.exit(2);
		}

		var server = new HTTPServer(config);
		keep.push(server);

		// On Node the port is known only once the listen has completed.
		var announce:Void->Void = null;
		announce = () -> {
			if (server.localPort > 0) {
				__say("READY " + server.localPort);
			} else {
				crossbyte.Timer.setTimeout(0.05, announce);
			}
		};
		announce();
		crossbyte.Timer.setInterval(1.0, 1.0, __stats);

		var seconds = Std.parseFloat(Sys.getEnv("PERF_SECONDS"));
		crossbyte.Timer.setTimeout(seconds > 0 ? seconds : 30.0, () -> Sys.exit(0));

		#if HXCPP_PROFILER
		var profile = Sys.getEnv("PERF_PROFILE");
		if (profile != null && profile != "") {
			var after = Std.parseFloat(Sys.getEnv("PERF_PROFILE_AFTER"));
			var length = Std.parseFloat(Sys.getEnv("PERF_PROFILE_SECONDS"));
			crossbyte.Timer.setTimeout(after > 0 ? after : 3.0, () -> {
				cpp.vm.Profiler.start(profile);
				__say("PROFILING");
				crossbyte.Timer.setTimeout(length > 0 ? length : 6.0, () -> {
					cpp.vm.Profiler.stop();
					__say("PROFILED " + profile);
				});
			});
		}
		#end
	}

	// Flushed at once: hxcpp flushes println only to a terminal.
	// PERF_STATS_FILE: READY and STATS go to this file instead of stdout, so
	// stdout can be a console window or a file the access log fills.
	static var __statsFile:Null<sys.io.FileOutput> = null;
	static var __statsChecked:Bool = false;

	static function __say(line:String):Void {
		if (!__statsChecked) {
			__statsChecked = true;
			var path = Sys.getEnv("PERF_STATS_FILE");
			if (path != null && path != "") {
				__statsFile = sys.io.File.write(path, false);
			}
		}
		if (__statsFile != null) {
			__statsFile.writeString(line + "\n");
			__statsFile.flush();
			return;
		}
		Sys.stdout().writeString(line + "\n");
		Sys.stdout().flush();
	}

	function __stats():Void {
		var mem:Float = 0;
		#if cpp
		mem = cpp.vm.Gc.memInfo64(cpp.vm.Gc.MEM_INFO_USAGE);
		#end
		var user:Float = -1;
		var kernel:Float = -1;
		#if (cpp && windows)
		user = untyped __cpp__("perf_cpu_part(0)");
		kernel = untyped __cpp__("perf_cpu_part(1)");
		#elseif nodejs
		// Sys.cpuTime is process.uptime() on Node: wall time, not CPU.
		var usage:Dynamic = js.Syntax.code("process.cpuUsage()");
		user = usage.user / 1e6;
		kernel = usage.system / 1e6;
		#end
		var cpu:Float = #if nodejs { var u:Dynamic = js.Syntax.code("process.cpuUsage()"); (u.user + u.system) / 1e6; } #else Sys.cpuTime() #end;
		#if jvm
		// Sys.cpuTime is System.nanoTime on the jvm: wall time. The runtime's
		// own thread instead, the server runs on it alone, which leaves out
		// the collector's and the JIT's threads.
		var threads = java.lang.management.ManagementFactory.getThreadMXBean();
		cpu = haxe.Int64.toInt(threads.getCurrentThreadCpuTime() / 1000) / 1e6;
		user = haxe.Int64.toInt(threads.getCurrentThreadUserTime() / 1000) / 1e6;
		kernel = cpu - user;
		#end
		var logged:Float = 0;
		var dropped:Float = 0;
		#if target.threaded
		logged = crossbyte._internal.http.AccessLog.__queuedTotal;
		dropped = crossbyte._internal.http.AccessLog.__droppedTotal;
		#end
		__say('STATS t=${haxe.Timer.stamp() - started} cpu=$cpu user=$user kernel=$kernel mem=$mem served=$served logged=$logged dropped=$dropped');
	}
}
