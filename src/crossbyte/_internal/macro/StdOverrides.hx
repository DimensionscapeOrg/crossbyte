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
	  Haxe 4.3.7 never stopped at an empty bucket, so every miss read the
	  whole table, 110us a miss at 100,000 entries, where a hit took
	  nothing measurable. Every `Map<Int, T>` on the jvm is one.

	Run from `extraParams.hxml`, so `-lib crossbyte` gets it, and from the
	suites' build files, which use `-cp src`. The macro context is left as it
	was: a macro keeps the interpreter's own `IntMap`.
**/
class StdOverrides {
	public static function use():Void {
		if (Context.defined("java") || Context.defined("jvm")) {
			Compiler.addClassPath(__root() + "std/java/");
		}
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
