package crossbyte.timer;

import utest.Assert;

/**
	`haxe.Timer.stamp()` is the clock everything in CrossByte waits and measures
	by. These cases hold it to being a clock of elapsed time and not of the time
	of day, and hold the framework to reading no other.

	The HTTP/2 idle sweep closed every connection a quarter second in, on cpp
	and Node, because it subtracted a stamp from `Sys.time()`: two clocks, one
	counting from boot or the first call and one from 1970, so every connection
	looked idle for fifty-six years. No behavioural test saw it until one held a
	connection open past the first sweep. The last case here is the cheaper
	guard -- it reads the source.

	Apart from `TimerStampTest` because these need `sys`: a sleep, the time of
	day, and the file system.
**/
class ClockTest extends utest.Test {
	public function testTheClockAdvancesWithRealTime():Void {
		var before = haxe.Timer.stamp();
		Sys.sleep(0.05);
		var elapsed = haxe.Timer.stamp() - before;
		Assert.isTrue(elapsed >= 0.04 && elapsed < 2.0, 'a 50 ms sleep measured as $elapsed s');
	}

	public function testTheClockNeverRunsBackwards():Void {
		var last = haxe.Timer.stamp();
		var backwards = 0;
		for (_ in 0...200000) {
			var now = haxe.Timer.stamp();
			if (now < last) {
				backwards++;
			}
			last = now;
		}
		Assert.equals(0, backwards);
	}

	public function testTheClockIsNotTheTimeOfDay():Void {
		#if (cpp || java || jvm)
		// A monotonic clock counts from the first call or from boot; the time
		// of day counts from 1970. If these agree, stamp() has become the time
		// of day again, and a clock adjustment moves every deadline with it.
		var gap = Math.abs(haxe.Timer.stamp() - Sys.time());
		Assert.isTrue(gap > 1e6, 'stamp() is within ${gap}s of the time of day');
		#else
		// eval, hl and neko have no monotonic source and use Sys.time().
		Assert.pass();
		#end
	}

	// The case above cannot tell hxcpp's own stamp on Linux and macOS from a
	// monotonic one: it is gettimeofday less its first reading, so it is far
	// from the time of day while still moving whenever the time of day is set.
	// So on native POSIX the clock is pinned to CLOCK_MONOTONIC directly.
	public function testNativePosixReadsTheMonotonicClock():Void {
		var before:Float = MonotonicProbe.read();
		if (before < 0) {
			Assert.pass();
			return;
		}
		var stamp:Float = haxe.Timer.stamp();
		var after:Float = MonotonicProbe.read();
		Assert.isTrue(stamp >= before && stamp <= after, 'stamp() read $stamp between CLOCK_MONOTONIC readings of $before and $after');
	}

	public function testNothingThatWaitsReadsTheTimeOfDay():Void {
		var root = __sourceRoot();
		if (root == null) {
			Assert.fail("could not find src/crossbyte above " + Sys.getCwd());
			return;
		}

		var found:Array<String> = [];
		__scan(root, root, found);
		Assert.same([], found, "Sys.time() in the framework, where haxe.Timer.stamp() belongs; see this class's doc");
	}

	private static function __scan(root:String, dir:String, found:Array<String>):Void {
		for (name in sys.FileSystem.readDirectory(dir)) {
			var path = dir + "/" + name;
			if (sys.FileSystem.isDirectory(path)) {
				__scan(root, path, found);
				continue;
			}
			if (!StringTools.endsWith(name, ".hx")) {
				continue;
			}
			var lines = sys.io.File.getContent(path).split("\n");
			for (i in 0...lines.length) {
				var line = StringTools.trim(lines[i]);
				if (StringTools.startsWith(line, "//") || StringTools.startsWith(line, "*") || StringTools.startsWith(line, "/*")) {
					continue;
				}
				// A real use of the time of day says so where it is made, with
				// a `// time of day:` comment giving the reason.
				if (line.indexOf("Sys.time()") >= 0 && line.indexOf("// time of day:") < 0) {
					found.push(path.substr(root.length + 1) + ":" + (i + 1));
				}
			}
		}
	}

	// The test binaries run from the repository root or from a directory under
	// export/, depending on the target, so the source tree is looked for above.
	private static function __sourceRoot():Null<String> {
		var dir = ".";
		for (_ in 0...5) {
			if (sys.FileSystem.exists(dir + "/src/crossbyte/core/CrossByte.hx")) {
				return dir + "/src/crossbyte";
			}
			dir += "/..";
		}
		return null;
	}
}
