package crossbyte.timer;

import utest.Assert;

/**
	`haxe.Timer.stamp()` is the clock everything in CrossByte waits and measures
	by. These cases hold it to being a clock of elapsed time and not of the time
	of day, and hold the framework to reading no other.

	Two clocks, one counting from boot or the first call and one from 1970,
	must never be mixed: an HTTP/2 idle sweep that subtracts a stamp from
	`Sys.time()` sees every connection idle for fifty-six years, and closes
	it a quarter second in, which only a test holding a connection past the
	first sweep would see. The last case here is the cheaper guard: it reads
	the source.

	Apart from `TimerStampTest` because these need `sys`: a sleep, the time of
	day, and the file system.
**/
class ClockTest extends utest.Test {
	public function testTheClockAdvancesWithRealTime():Void {
		var before = haxe.Timer.stamp();
		crossbyte.sys.System.sleep(0.05);
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
		var gap = Math.abs(haxe.Timer.stamp() - Sys.time()); // time of day: what the stamp must not be
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

	/**
		The tests (the suite, and the stress, soak, benchmark and interop
		programs beside it) wait and measure by the same clock.

		None of their waits and timings reads `Sys.time()`: a deadline in
		seconds of the time of day, which the system may set forward or back
		while a test waits (ending the wait early, or holding it past any
		deadline, where utest's own timeout does not reach a thread busy in its
		loop), and which is coarse on some targets.
	**/
	public function testNoTestWaitsByTheTimeOfDay():Void {
		var root = __sourceRoot();
		if (root == null) {
			Assert.fail("could not find src/crossbyte above " + Sys.getCwd());
			return;
		}

		var found:Array<String> = [];
		// The two that name what they look for.
		__scan(root + "/../../tests", root + "/../../tests", found, ["ClockTest.hx", "NetTestClockTest.hx"]);
		Assert.equals(0, found.length, "Sys.time() in the tests, where haxe.Timer.stamp() belongs (see this class's doc): " + found.join(", "));
	}

	private static function __scan(root:String, dir:String, found:Array<String>, ?skip:Array<String>):Void {
		for (name in sys.FileSystem.readDirectory(dir)) {
			var path = dir + "/" + name;
			if (sys.FileSystem.isDirectory(path)) {
				__scan(root, path, found, skip);
				continue;
			}
			if (!StringTools.endsWith(name, ".hx") || (skip != null && skip.indexOf(name) >= 0)) {
				continue;
			}
			var lines = sys.io.File.getContent(path).split("\n");
			// Inside a block comment opened at the start of a line: a doc
			// comment's lines need not start with `*`.
			var inBlock:Bool = false;
			for (i in 0...lines.length) {
				var line = StringTools.trim(lines[i]);
				if (inBlock) {
					inBlock = line.indexOf("*/") < 0;
					continue;
				}
				if (StringTools.startsWith(line, "/*")) {
					inBlock = line.indexOf("*/", 2) < 0;
					continue;
				}
				if (StringTools.startsWith(line, "//") || StringTools.startsWith(line, "*")) {
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
