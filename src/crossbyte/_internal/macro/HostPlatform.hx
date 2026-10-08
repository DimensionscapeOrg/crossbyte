package crossbyte._internal.macro;

// Macro-only: run from extraParams.hxml. Guarded so a build that includes every module (`--macro include('crossbyte')`) does not try to compile it for the target.
#if macro
import haxe.macro.Compiler;
import haxe.macro.Context;

/**
	Says which OS a native build is for when nothing else has.

	CrossByte's native code paths (processes, local IPC, thread priority)
	hang off `windows`, `linux` and `mac`. Aedifex and Lime define one;
	plain `haxe` does not, and a build from an .hxml would compile those
	paths out without a word. A native build that names no OS is taken to
	be for the machine building it. Run from `extraParams.hxml`; a build
	that names its OS, or is not native, is left as it is.

	hl and neko are left alone on purpose. Their bytecode runs unchanged on
	any OS, so the machine that builds it says nothing about the one that
	will run it, and a define taken from it would compile one OS's branch
	into a file another runs. `NativeProcess` runs on both without one, and
	what differs by OS is asked while running (`System.isWindows`).
**/
class HostPlatform {
	private static final __platforms:Array<String> = ["windows", "linux", "mac", "macos", "android", "ios", "iphoneos", "iphonesim", "tvos", "emscripten"];

	public static function define():Void {
		if (!Context.defined("cpp")) {
			return;
		}
		for (platform in __platforms) {
			if (Context.defined(platform)) {
				return;
			}
		}
		switch (Sys.systemName()) {
			case "Windows":
				Compiler.define("windows");
			case "Linux":
				Compiler.define("linux");
			case "Mac":
				Compiler.define("mac");
			case "BSD":
				Compiler.define("bsd");
			default:
		}
	}
}
#end
