package crossbyte.net;

import utest.Assert;

/**
	The networking tests wait by `haxe.Timer.stamp()`, the one monotonic
	clock, as the framework they test does (see `ClockTest`).

	Their helpers timed deadlines and pauses by `Sys.time()`, the time of
	day: a clock the system can set back or forward while a test waits. Set
	forward, a wait ends early and a test fails for nothing; set back, it
	holds the test far past its deadline -- and nothing else ends it, since
	these loops are the tests' own and utest's timeout does not reach a
	thread that is busy in one. `Sys.time()` is for the time of day, and says
	so with a `// time of day:` comment where it is used.
**/
class NetTestClockTest extends utest.Test {
	#if sys
	public function testNoNetworkTestWaitsByTheTimeOfDay():Void {
		var root:Null<String> = __testRoot();
		if (root == null) {
			Assert.fail("could not find tests/crossbyte/net above " + Sys.getCwd());
			return;
		}

		var found:Array<String> = [];
		__scan(root, root, found);
		Assert.equals(0, found.length, "Sys.time() in the networking tests, where haxe.Timer.stamp() belongs (see this class's doc): " + found.join(", "));
	}

	private static function __scan(root:String, dir:String, found:Array<String>):Void {
		for (name in sys.FileSystem.readDirectory(dir)) {
			var path:String = dir + "/" + name;
			if (sys.FileSystem.isDirectory(path)) {
				__scan(root, path, found);
				continue;
			}
			// This one names what it looks for.
			if (!StringTools.endsWith(name, ".hx") || name == "NetTestClockTest.hx") {
				continue;
			}
			var lines:Array<String> = sys.io.File.getContent(path).split("\n");
			for (i in 0...lines.length) {
				var line:String = StringTools.trim(lines[i]);
				if (StringTools.startsWith(line, "//") || StringTools.startsWith(line, "*")) {
					continue;
				}
				if (line.indexOf("Sys.time()") >= 0 && line.indexOf("// time of day:") < 0) {
					found.push(path.substr(root.length + 1) + ":" + (i + 1));
				}
			}
		}
	}

	// The binaries run from the repository root or from a directory under
	// export/, depending on the target, so the tree is looked for above.
	private static function __testRoot():Null<String> {
		var dir:String = ".";
		for (_ in 0...5) {
			if (sys.FileSystem.exists(dir + "/tests/crossbyte/net/NetPump.hx")) {
				return dir + "/tests/crossbyte/net";
			}
			dir += "/..";
		}
		return null;
	}
	#end
}
