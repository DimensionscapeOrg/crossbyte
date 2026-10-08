package crossbyte.test;

#if macro
import haxe.macro.Context;
import sys.FileSystem;
import sys.io.File;

/**
 * Fails the build where anything but the sleep behind `System.sleep` calls
 * `Sys.sleep`.
 *
 * On the interpreter under Windows `Sys.sleep` can sleep for 49 days (see
 * `crossbyte.sys.System.sleep` for why), hanging whichever test calls it.
 * Every sleep in the library, the tests and the samples goes through
 * `System.sleep`, and a call left behind, or one added later, would be one
 * more place to hang, so it is a compile error rather than something a
 * review has to catch.
 *
 * Run from `SuiteCoverage.check()`, so every suite build asks.
 */
class SleepCheck {
	private static final ROOTS:Array<String> = ["src", "tests", "samples"];
	private static inline var ALLOWED:String = "src/crossbyte/_internal/system/Sleep.hx";
	// Joined so that this file does not match itself.
	private static final CALL:String = "Sys." + "sleep(";

	public static function check():Void {
		if (!FileSystem.exists(ALLOWED)) {
			// Not compiled from the repository root: nothing to inspect.
			return;
		}

		var found:Array<{path:String, at:Int}> = [];
		for (root in ROOTS) {
			if (FileSystem.exists(root)) {
				scan(root, found);
			}
		}

		if (found.length > 0) {
			var first = found[0];
			var others = [for (i in 1...found.length) found[i].path];
			Context.error("Sleeps with Sys.sleep, which can hang for good on the interpreter under Windows; use crossbyte.sys.System.sleep, or crossbyte._internal.system.Sleep.sleep inside the library"
				+ (others.length > 0 ? ". Also: " + others.join(", ") : ""),
				Context.makePosition({min: first.at, max: first.at + CALL.length, file: first.path}));
		}
	}

	private static function scan(dir:String, found:Array<{path:String, at:Int}>):Void {
		for (name in FileSystem.readDirectory(dir)) {
			var path = dir + "/" + name;
			if (FileSystem.isDirectory(path)) {
				scan(path, found);
			} else if (StringTools.endsWith(name, ".hx") && path != ALLOWED) {
				var at = File.getContent(path).indexOf(CALL);
				if (at >= 0) {
					found.push({path: path, at: at});
				}
			}
		}
	}
}
#end
