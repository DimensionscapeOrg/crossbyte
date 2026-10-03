import haxe.Json;

/**
	Latencies, in a form that crosses a process boundary: buckets two percent
	wide on a log scale of microseconds, sent as `bucket:count` pairs and
	added up wherever they arrive. Percentiles read back to within that two
	percent, which is closer than any two runs of the same load agree.

	Sorting every sample would be exact, and would need every sample: at a
	hundred thousand round trips a second, a ten-minute run is sixty million
	of them, held by a client process whose own memory is part of what a
	run is watching.
**/
class Histogram {
	static inline var BASE:Float = 1.02;
	static inline var BUCKETS:Int = 1024;

	var counts:Array<Int>;

	public var count(default, null):Int = 0;
	public var max(default, null):Float = 0;

	static var LOG_BASE:Float = Math.log(BASE);

	public function new() {
		counts = [for (_ in 0...BUCKETS) 0];
	}

	/** Records one sample, in milliseconds. **/
	public inline function add(ms:Float):Void {
		var us:Float = ms * 1000;
		var bucket:Int = us <= 1 ? 0 : Std.int(Math.log(us) / LOG_BASE);
		if (bucket >= BUCKETS) {
			bucket = BUCKETS - 1;
		}
		counts[bucket]++;
		count++;
		if (ms > max) {
			max = ms;
		}
	}

	/** The `p` quantile, 0 to 1, in milliseconds; 0 with no samples. **/
	public function percentile(p:Float):Float {
		if (count == 0) {
			return 0;
		}
		var wanted:Float = count * p;
		var seen:Int = 0;
		for (bucket in 0...BUCKETS) {
			seen += counts[bucket];
			if (seen >= wanted && seen > 0) {
				// The middle of the bucket, never past the largest sample.
				var ms:Float = Math.pow(BASE, bucket + 0.5) / 1000;
				return ms > max ? max : ms;
			}
		}
		return max;
	}

	public function merge(other:Histogram):Void {
		for (bucket in 0...BUCKETS) {
			counts[bucket] += other.counts[bucket];
		}
		count += other.count;
		if (other.max > max) {
			max = other.max;
		}
	}

	public function clear():Void {
		for (bucket in 0...BUCKETS) {
			counts[bucket] = 0;
		}
		count = 0;
		max = 0;
	}

	/** `max|bucket:count,bucket:count...`, only the buckets that hold any. **/
	public function encode():String {
		var buf = new StringBuf();
		buf.add(Math.round(max * 1000) / 1000);
		buf.add("|");
		var first:Bool = true;
		for (bucket in 0...BUCKETS) {
			var n:Int = counts[bucket];
			if (n > 0) {
				if (!first) {
					buf.add(",");
				}
				first = false;
				buf.add(bucket);
				buf.add(":");
				buf.add(n);
			}
		}
		return buf.toString();
	}

	public static function decode(text:Null<String>):Histogram {
		var histogram = new Histogram();
		if (text == null || text == "") {
			return histogram;
		}
		var bar:Int = text.indexOf("|");
		histogram.max = Std.parseFloat(text.substr(0, bar));
		var rest:String = text.substr(bar + 1);
		if (rest == "") {
			return histogram;
		}
		for (pair in rest.split(",")) {
			var colon:Int = pair.indexOf(":");
			var bucket:Null<Int> = Std.parseInt(pair.substr(0, colon));
			var n:Null<Int> = Std.parseInt(pair.substr(colon + 1));
			if (bucket != null && n != null && bucket >= 0 && bucket < BUCKETS) {
				histogram.counts[bucket] += n;
				histogram.count += n;
			}
		}
		return histogram;
	}

	/** `{n, p50, p99, max}` in milliseconds, rounded for a report. **/
	public function summary():Dynamic {
		return {
			n: count,
			p50: round(percentile(0.5)),
			p99: round(percentile(0.99)),
			max: round(max)
		};
	}

	public static inline function round(value:Float):Float {
		return Math.round(value * 1000) / 1000;
	}
}

/**
	What the operating system says this process costs: processor time split
	into user and kernel, resident and private memory, and the handles
	(Windows) or descriptors (Linux) it holds, the last being how a leaked
	socket shows when nothing in the heap does.

	Read in-process, so a run needs no second tool beside it. Natively on
	Windows and Linux; elsewhere what the target can say, and -1 for what it
	cannot.
**/
#if (cpp && windows)
@:cppFileCode('
#include <windows.h>
#include <psapi.h>
')
#end
class ProcessStats {
	/** Seconds of user-mode processor time, all threads. **/
	public var user:Float = -1;

	/** Seconds of kernel-mode processor time, all threads. **/
	public var kernel:Float = -1;

	/** Resident bytes: the working set on Windows, VmRSS on Linux. **/
	public var rss:Float = -1;

	/** Bytes committed privately: PrivateUsage on Windows, RssAnon on Linux. **/
	public var privateBytes:Float = -1;

	/** Open handles on Windows, open descriptors on Linux. **/
	public var handles:Int = -1;

	/** The collector's heap: in use at the last collection, now, and reserved. **/
	public var heapLive:Float = -1;

	public var heapNow:Float = -1;
	public var heapReserved:Float = -1;

	public function new() {}

	public static function sample():ProcessStats {
		var s = new ProcessStats();
		#if cpp
		s.heapLive = cpp.vm.Gc.memInfo64(cpp.vm.Gc.MEM_INFO_USAGE);
		s.heapNow = cpp.vm.Gc.memInfo64(cpp.vm.Gc.MEM_INFO_CURRENT);
		s.heapReserved = cpp.vm.Gc.memInfo64(cpp.vm.Gc.MEM_INFO_RESERVED);
		#else
		s.heapNow = crossbyte.sys.System.memoryUsage();
		#end

		#if (cpp && windows)
		var times:Array<Float> = [0.0, 0.0, 0.0, 0.0, 0.0];
		untyped __cpp__('
			{
				FILETIME created, exited, kernelTime, userTime;
				HANDLE self = GetCurrentProcess();
				if (GetProcessTimes(self, &created, &exited, &kernelTime, &userTime)) {
					ULARGE_INTEGER k, u;
					k.LowPart = kernelTime.dwLowDateTime; k.HighPart = kernelTime.dwHighDateTime;
					u.LowPart = userTime.dwLowDateTime; u.HighPart = userTime.dwHighDateTime;
					{0}[0] = (double)u.QuadPart / 1e7;
					{0}[1] = (double)k.QuadPart / 1e7;
				}
				PROCESS_MEMORY_COUNTERS_EX counters;
				counters.cb = sizeof(counters);
				if (K32GetProcessMemoryInfo(self, (PROCESS_MEMORY_COUNTERS *)&counters, sizeof(counters))) {
					{0}[2] = (double)counters.WorkingSetSize;
					{0}[3] = (double)counters.PrivateUsage;
				}
				DWORD handleCount = 0;
				if (GetProcessHandleCount(self, &handleCount)) {
					{0}[4] = (double)handleCount;
				}
			}
		', times);
		s.user = times[0];
		s.kernel = times[1];
		s.rss = times[2];
		s.privateBytes = times[3];
		s.handles = Std.int(times[4]);
		#elseif (sys && !windows)
		__readLinux(s);
		#end
		return s;
	}

	#if (sys && !windows)
	static var __ticksPerSecond:Float = 100;

	static function __readLinux(s:ProcessStats):Void {
		try {
			// Fields 14 and 15 of /proc/self/stat, counted after the command,
			// which is in parentheses and may hold spaces.
			var stat:String = sys.io.File.getContent("/proc/self/stat");
			var fields = stat.substr(stat.lastIndexOf(")") + 2).split(" ");
			s.user = Std.parseFloat(fields[11]) / __ticksPerSecond;
			s.kernel = Std.parseFloat(fields[12]) / __ticksPerSecond;
		} catch (_:Dynamic) {}
		try {
			for (line in sys.io.File.getContent("/proc/self/status").split("\n")) {
				if (StringTools.startsWith(line, "VmRSS:")) {
					s.rss = __kilobytes(line);
				} else if (StringTools.startsWith(line, "RssAnon:")) {
					s.privateBytes = __kilobytes(line);
				}
			}
		} catch (_:Dynamic) {}
		try {
			s.handles = sys.FileSystem.readDirectory("/proc/self/fd").length;
		} catch (_:Dynamic) {}
	}

	static function __kilobytes(line:String):Float {
		var digits = ~/([0-9]+)/;
		return digits.match(line) ? Std.parseFloat(digits.matched(1)) * 1024 : -1;
	}
	#end

	/** Megabytes, to one decimal: what a report prints. **/
	public static inline function mb(bytes:Float):Float {
		return bytes < 0 ? -1 : Math.round(bytes / 104857.6) / 10;
	}
}

/** The one shape every process in a run reports in. **/
class Report {
	public static inline var PREFIX:String = "LOAD ";

	/** One line, flushed at once: a parent reads it from a pipe. **/
	public static function emit(record:Dynamic):Void {
		Sys.stdout().writeString(PREFIX + Json.stringify(record) + "\n");
		Sys.stdout().flush();
	}

	public static function say(line:String):Void {
		Sys.stdout().writeString(line + "\n");
		Sys.stdout().flush();
	}

	/** A record from a child's line, or null for any other line. **/
	public static function parse(line:String):Null<Dynamic> {
		if (!StringTools.startsWith(line, PREFIX)) {
			return null;
		}
		try {
			return Json.parse(line.substr(PREFIX.length));
		} catch (_:Dynamic) {
			return null;
		}
	}
}
