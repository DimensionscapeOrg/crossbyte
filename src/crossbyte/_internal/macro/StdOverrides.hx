package crossbyte._internal.macro;

// Macro-only: run from extraParams.hxml and the suites' build files. Guarded
// so a build that includes every module does not compile it for the target.
#if macro
import haxe.io.Path;
import haxe.macro.Compiler;
import haxe.macro.Context;

/**
	Puts CrossByte's fixes to the Haxe standard library ahead of it, on the
	targets each is for.

	- `std/java`, on the java targets: `haxe.ds.IntMap`, whose `lookup` in
	  Haxe 4.3.7 never stops at an empty bucket, so every miss reads the
	  whole table (110us a miss at 100,000 entries, where a hit takes
	  nothing measurable). Every `Map<Int, T>` on the jvm is one.
	- `std/timer`, wherever CrossByte runs the program's timers:
	  `haxe.Timer` on the runtime's scheduler and its monotonic clock, as
	  the standard library's runs only on an event loop of Haxe's own, which
	  a runtime's loop never returns to. Left out of a build for Lime's
	  native backend (`lime_cffi`), where `haxe.Timer` is Lime's own and its
	  application loop runs it: CrossByte then keeps to that class's public
	  members, and `haxe.Timer.stamp()` is Lime's clock.

	Run from `extraParams.hxml`, so `-lib crossbyte` gets it, and from every
	build file that uses `-cp src`. It defines `crossbyte_std_overrides`, by
	which `crossbyte.core.CrossByte` refuses a build it was left out of.

	The macro context is left as it was: the standard library's own modules
	still come first there, and the define does not reach it, so a macro
	keeps the interpreter's own `IntMap` and the standard `haxe.Timer`.
**/
class StdOverrides {
	public static function use():Void {
		if (Context.defined("java") || Context.defined("jvm")) {
			Compiler.addClassPath(__root() + "std/java/");
		}
		if (!Context.defined("lime_cffi")) {
			Compiler.addClassPath(__root() + "std/timer/");
		}
		Compiler.define("crossbyte_std_overrides");
	}

	// The repository root, found from this file: src/crossbyte/_internal/macro.
	// Made absolute first: resolvePath answers relative to the working
	// directory where the class path was given relative, as `-cp src` is,
	// and four levels up from that normalizes to "/".
	private static function __root():String {
		var here:String = sys.FileSystem.absolutePath(Context.resolvePath("crossbyte/_internal/macro/StdOverrides.hx"));
		return Path.addTrailingSlash(Path.normalize(Path.directory(here) + "/../../../.."));
	}
}
#end
