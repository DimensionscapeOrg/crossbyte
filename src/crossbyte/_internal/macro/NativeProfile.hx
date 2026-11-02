package crossbyte._internal.macro;

// Macro-only: run from extraParams.hxml.
#if macro
import haxe.io.Path;
import haxe.macro.Compiler;
import haxe.macro.Context;
import sys.FileSystem;
import sys.io.File;

/**
	Profile-guided optimisation of a native build, which hxcpp has no switch
	for. `-D crossbyte_pgo=generate` builds a program that counts where it
	spends its time; run it on real work, then `-D crossbyte_pgo=use`
	rebuilds it from those counts. docs/targets.md says how.

	Both turn on `HXCPP_OPTIMIZE_LINK`. The flags are in
	`NativeProfileBuild.xml`, attached to the runtime's class so every
	CrossByte program has them. The counts are kept in `pgo` in the output
	folder; MSVC keeps its own `.pgd` and `.pgc` files beside the executable.

	hxcpp rebuilds an object when its source changes, not its flags, so a
	build whose mode or defines differ from the last one's (dropping the
	define included) deletes the objects first and starts clean. Other
	defines matter under link-time code generation as well: a change to them
	rebuilds hxcpp's precompiled header, and MSVC then refuses at the link
	every object built against the old one (C1382). A debug build, or one
	that is not native, is left as it is.
**/
class NativeProfile {
	public static function use():Void {
		if (!Context.defined("cpp") || Context.defined("display")) {
			return;
		}
		var mode:String = Context.defined("crossbyte_pgo") ? Context.definedValue("crossbyte_pgo") : "";
		if (mode != "" && mode != "generate" && mode != "use") {
			Context.fatalError('crossbyte_pgo is "generate" or "use", not "$mode"', Context.currentPos());
		}
		if (Context.defined("debug")) {
			if (mode != "") {
				Context.warning("crossbyte_pgo is ignored in a debug build", Context.currentPos());
			}
			mode = "";
		}

		var output:String = Path.normalize(FileSystem.absolutePath(Compiler.getOutput()));
		if (mode == "") {
			__startCleanOnChange(output, mode);
			return;
		}

		// Refused before anything is deleted or recorded.
		var toolchain:String = __toolchain();
		var data:String = output + "/pgo";
		if (mode == "use") {
			__checkCounts(toolchain, output, data);
		}
		var defines:Map<String, String> = Context.getDefines();
		var keys:Array<String> = [for (key in defines.keys()) key];
		keys.sort(Reflect.compare);
		__startCleanOnChange(output, mode + "\n" + [for (key in keys) key + "=" + defines.get(key)].join("\n"));
		if (mode == "generate") {
			__clearCounts(output, data);
		}

		Compiler.define("HXCPP_OPTIMIZE_LINK");
		Compiler.define("crossbyte_pgo_" + mode);
		Compiler.define("crossbyte_pgo_" + toolchain);
		Compiler.define("crossbyte_pgo_dir", data);
		Compiler.addMetadata("@:buildXml('<include name=\"${haxelib:crossbyte}/src/crossbyte/_internal/macro/NativeProfileBuild.xml\"/>')",
			"crossbyte.core.CrossByte");
	}

	// MSVC on Windows, Clang on macOS and the BSDs, and on Linux whichever
	// CXX names (hxcpp's own choice), g++ unless it says clang.
	@:noCompletion private static function __toolchain():String {
		for (other in ["mingw", "xcompile", "android", "iphoneos", "iphonesim", "appletvos", "appletvsim", "emscripten", "winrt"]) {
			if (Context.defined(other)) {
				Context.fatalError('crossbyte_pgo builds for the machine it runs on with MSVC, GCC or Clang, not for $other',
					Context.currentPos());
			}
		}
		switch (Sys.systemName()) {
			case "Windows":
				return "msvc";
			case "Mac" | "BSD":
				return "clang";
			default:
				var cxx:String = Context.defined("CXX") ? Context.definedValue("CXX") : Sys.getEnv("CXX");
				return cxx != null && cxx.indexOf("clang") >= 0 ? "clang" : "gcc";
		}
	}

	// `build` is the mode and the defines, or empty for a build without the
	// option.
	@:noCompletion private static function __startCleanOnChange(output:String, build:String):Void {
		var objects:String = output + "/obj";
		var stamp:String = objects + "/crossbyte_pgo";
		var last:String = FileSystem.exists(stamp) ? File.getContent(stamp) : "";
		if (last == build) {
			return;
		}
		if (FileSystem.exists(objects)) {
			__delete(objects);
		}
		if (build != "") {
			FileSystem.createDirectory(objects);
			File.saveContent(stamp, build);
		}
	}

	// A new instrumented build starts new counts: what an older build
	// recorded would not match it.
	@:noCompletion private static function __clearCounts(output:String, data:String):Void {
		if (FileSystem.exists(data)) {
			__delete(data);
		}
		if (FileSystem.exists(output)) {
			for (name in FileSystem.readDirectory(output)) {
				if (Path.extension(name) == "pgc") {
					FileSystem.deleteFile(output + "/" + name);
				}
			}
		}
	}

	// A build from counts that are not there would be no faster, and say
	// nothing about it.
	@:noCompletion private static function __checkCounts(toolchain:String, output:String, data:String):Void {
		var found:Bool = switch (toolchain) {
			case "msvc": __has(output, "pgc", false);
			case "gcc": __has(data, "gcda", true);
			default: __mergeClangCounts(data);
		}
		if (!found) {
			Context.fatalError("crossbyte_pgo=use found no counts in " + (toolchain == "msvc" ? output : data)
				+ ": build with crossbyte_pgo=generate and run that program first", Context.currentPos());
		}
	}

	// Clang writes raw counts, which llvm-profdata merges into the file the
	// build reads: done here, so every compiler takes the same steps.
	@:noCompletion private static function __mergeClangCounts(data:String):Bool {
		var raw:Array<String> = FileSystem.exists(data) ? [
			for (name in FileSystem.readDirectory(data))
				if (Path.extension(name) == "profraw") data + "/" + name
		] : [];
		if (raw.length == 0) {
			return FileSystem.exists(data + "/default.profdata");
		}
		for (tool in __profdataTools()) {
			var code:Int = try new sys.io.Process(tool[0], tool.slice(1).concat(["merge", "-o", data + "/default.profdata"]).concat(raw)).exitCode() catch (_:Dynamic) -1;
			if (code == 0) {
				return true;
			}
		}
		Context.fatalError("crossbyte_pgo=use could not run llvm-profdata to merge the counts in " + data
			+ ": set LLVM_PROFDATA to the one that matches the compiler", Context.currentPos());
		return false;
	}

	// LLVM_PROFDATA if set; Xcode's on macOS; then the plain name, and the one
	// with the compiler's major version, as Debian and Ubuntu install it.
	@:noCompletion private static function __profdataTools():Array<Array<String>> {
		var env:String = Sys.getEnv("LLVM_PROFDATA");
		if (env != null && env != "") {
			return [[env]];
		}
		if (Sys.systemName() == "Mac") {
			return [["xcrun", "llvm-profdata"]];
		}
		var tools:Array<Array<String>> = [["llvm-profdata"]];
		var cxx:String = Context.defined("CXX") ? Context.definedValue("CXX") : Sys.getEnv("CXX");
		try {
			var version = new sys.io.Process(cxx == null ? "clang++" : cxx, ["-dumpversion"]);
			var major:String = StringTools.trim(version.stdout.readAll().toString()).split(".")[0];
			version.close();
			tools.push(["llvm-profdata-" + major]);
		} catch (_:Dynamic) {}
		return tools;
	}

	// GCC writes each object's counts under the object's own path, so its
	// are searched for below as well.
	@:noCompletion private static function __has(directory:String, extension:String, below:Bool):Bool {
		if (!FileSystem.exists(directory)) {
			return false;
		}
		for (name in FileSystem.readDirectory(directory)) {
			var path:String = directory + "/" + name;
			if (FileSystem.isDirectory(path) ? below && __has(path, extension, true) : Path.extension(name) == extension) {
				return true;
			}
		}
		return false;
	}

	@:noCompletion private static function __delete(path:String):Void {
		if (FileSystem.isDirectory(path)) {
			for (name in FileSystem.readDirectory(path)) {
				__delete(path + "/" + name);
			}
			FileSystem.deleteDirectory(path);
		} else {
			FileSystem.deleteFile(path);
		}
	}
}
#end
