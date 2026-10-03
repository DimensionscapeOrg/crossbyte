import crossbyte.core.ServerApplication;
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.url.URLLoader;
import crossbyte.url.URLRequest;

/**
	The client side of the http performance audit: `URLLoader` fetching one
	URL back to back, `PERF_LOADERS` loads in flight, over keep-alive.

	usage: PerfHttpClient <url>

	Prints "READY" and then STATS lines like PerfHttpServer's, where
	`served` counts completed loads. Exits after PERF_SECONDS.
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
class PerfHttpClient extends ServerApplication {
	static var __args:Array<String>;

	public static function main():Void {
		__args = Sys.args();
		new PerfHttpClient();
	}

	var served:Int = 0;
	var failed:Int = 0;
	var started:Float;
	var loaders:Array<URLLoader> = [];

	public function new() {
		super();
		addEventListener(Event.INIT, __init);
	}

	function __init(_:Event):Void {
		var url:String = __args[0];
		started = haxe.Timer.stamp();
		var count:Null<Int> = Std.parseInt(Sys.getEnv("PERF_LOADERS"));
		if (count == null || count < 1) {
			count = 1;
		}
		for (_ in 0...count) {
			var loader = new URLLoader();
			loaders.push(loader);
			var request = new URLRequest(url);
			loader.addEventListener(Event.COMPLETE, _ -> {
				served++;
				loader.load(request);
			});
			loader.addEventListener(IOErrorEvent.IO_ERROR, (e:IOErrorEvent) -> {
				failed++;
				if (failed < 5) {
					__say("ERROR " + e.text);
				}
				loader.load(request);
			});
			loader.load(request);
		}

		__say("READY 0");
		crossbyte.Timer.setInterval(1.0, 1.0, __stats);
		var seconds = Std.parseFloat(Sys.getEnv("PERF_SECONDS"));
		crossbyte.Timer.setTimeout(seconds > 0 ? seconds : 20.0, () -> Sys.exit(0));
	}

	static function __say(line:String):Void {
		Sys.stdout().writeString(line + "\n");
		Sys.stdout().flush();
	}

	function __stats():Void {
		var mem:Float = cpp.vm.Gc.memInfo64(cpp.vm.Gc.MEM_INFO_USAGE);
		var user:Float = -1;
		var kernel:Float = -1;
		#if (cpp && windows)
		user = untyped __cpp__("perf_cpu_part(0)");
		kernel = untyped __cpp__("perf_cpu_part(1)");
		#end
		__say('STATS t=${haxe.Timer.stamp() - started} cpu=${Sys.cpuTime()} user=$user kernel=$kernel mem=$mem served=$served failed=$failed');
	}
}
