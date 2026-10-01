package crossbyte;

#if (js && !nodejs)
import crossbyte.io._internal.NoFileSystem as FileSystem;
#else
import sys.FileSystem;
#end
import crossbyte.errors.SecurityError;
import crossbyte.io.ByteArray;
import crossbyte.sys.System;
import haxe.Json;
import StringTools;
import crossbyte.io.File;

@:build(crossbyte._internal.macro.ResourcesMacro.ensureResources())
/**
 * Provides access to files inside the application's `resources` directory.
 *
 * `Resources` resolves paths relative to the runtime resources root and offers
 * convenience helpers for loading bytes, text, JSON, and directory listings.
 *
 * **The resources directory is beside the program.** `resourcesDir` is the
 * `resources` directory inside `File.applicationDirectory`: next to the
 * executable natively, the jar on the jvm, the script on Node and the
 * bytecode file on neko and HashLink -- found wherever the program is started
 * from, a Windows service's System32 included. It was the working
 * directory's. The build puts it there: the project's `resources` directory
 * is copied beside the program the build writes. A tool that moves the
 * program afterwards must carry `resources` with it. On the interpreter,
 * which has no program file, it is the working directory's `resources`.
 *
 * **Paths stay inside `resourcesDir`.** A path is a relative one, separated by
 * `/` or `\`, with no `..` segment, no leading separator and no `:` -- so no
 * drive letter, no `C:` drive-relative path and no NTFS stream name. Anything
 * else is refused: `exists` answers `false` and `resourceSize` `-1`, and the
 * rest throw `SecurityError`. Paths were joined to the directory as given, so
 * a server loading a map by the name a client sent,
 * `getText("maps/" + name)`, read whatever `"../../config.json"` named.
 * Empty and `.` segments are dropped, so `"./maps//a.txt"` is `"maps/a.txt"`.
 */
final class Resources {
	/**
		Absolute path to the runtime resources directory: `resources` inside
		`File.applicationDirectory`, with a separator at the end.
	**/
	public static var resourcesDir(get, never):String;
	/** Macro-generated tree that mirrors compile-time resources when available. */
	public static var tree:ResourceTree = new ResourceTree();

	/** Returns `true` when a resource exists relative to `resourcesDir`. */
	public static function exists(relativePath:String):Bool {
		var path:Null<String> = __confine(relativePath);
		return path != null && FileSystem.exists(__resourcesDir + path);
	}

	/**
	 * Resolves a resource path to an absolute filesystem path.
	 *
	 * @throws SecurityError If the path would leave `resourcesDir`.
	 */
	public static function getAbsolutePath(relativePath:String):String {
		return __resourcesDir + __require(relativePath);
	}

	/**
	 * Loads a resource as a `ByteArray`.
	 *
	 * @throws SecurityError If the path would leave `resourcesDir`.
	 */
	public static function getBytes(relativePath:String):ByteArray {
		return File.getFileBytes(__resourcesDir + __require(relativePath));
	}

	/**
	 * Loads and parses a JSON resource into the requested typed object shape.
	 *
	 * @throws SecurityError If the path would leave `resourcesDir`.
	 */
	public static function getJSON<T>(relativePath:String):TypedObject<T> {
		var jsonString:String = File.getFileText(__resourcesDir + __require(relativePath));
		return Json.parse(jsonString);
	}

	/**
	 * Loads a text resource and returns normalized lines.
	 *
	 * @throws SecurityError If the path would leave `resourcesDir`.
	 */
	public static function getLines(relativePath:String):Array<String> {
		var text:String = getText(relativePath);
		var normalized = text.split("\r\n").join("\n").split("\r").join("\n");
		var lines:Array<String> = normalized.split("\n");
		if (lines.length > 0 && lines[lines.length - 1] == "") {
			lines.pop();
		}

		return lines;
	}

	/**
	 * Lists direct children of a resource subdirectory.
	 *
	 * @throws SecurityError If the path would leave `resourcesDir`.
	 */
	public static function listResources(subDir:String = ""):Array<String> {
		var dir = __resourcesDir + __require(subDir);
		return FileSystem.exists(dir) && FileSystem.isDirectory(dir) ? FileSystem.readDirectory(dir) : [];
	}

	/**
	 * Recursively lists files below a resource subdirectory using forward-slash relative paths.
	 *
	 * @throws SecurityError If the path would leave `resourcesDir`.
	 */
	public static function listResourcesRecursive(subDir:String = ""):Array<String> {
		var relativeRoot:String = __require(subDir);
		var dir = __resourcesDir + relativeRoot;
		var files:Array<String> = [];

		function scan(path:String, relativePath:String) {
			if (!FileSystem.exists(path) || !FileSystem.isDirectory(path))
				return;
			for (file in FileSystem.readDirectory(path)) {
				var fullPath = path + File.separator + file;
				var childRelativePath = relativePath == "" ? file : relativePath + "/" + file;
				if (FileSystem.isDirectory(fullPath)) {
					scan(fullPath, childRelativePath);
				} else {
					files.push(childRelativePath);
				}
			}
		}

		scan(dir, relativeRoot);
		return files;
	}

	/**
	 * Loads a resource as UTF-8 text.
	 *
	 * @throws SecurityError If the path would leave `resourcesDir`.
	 */
	public static function getText(relativePath:String):String {
		return File.getFileText(__resourcesDir + __require(relativePath));
	}

	/** Returns the resource size in bytes, or `-1` when the resource does not exist. */
	public static function resourceSize(relativePath:String):Int {
		var path:Null<String> = __confine(relativePath);
		if (path == null || !FileSystem.exists(__resourcesDir + path)) {
			return -1;
		}
		return FileSystem.stat(__resourcesDir + path).size;
	}

	private static inline function get_resourcesDir():String {
		return __resourcesDir;
	}

	/**
		`relativePath` as a path below `resourcesDir`, `/`-separated with
		empty and `.` segments dropped, or null when it names somewhere
		else: a `..` segment, a leading separator (an absolute or UNC path),
		a `:` (a drive letter, a drive-relative `C:x`, an NTFS stream, a
		URL) or a NUL, which a native call would cut the path at.

		`\` counts as a separator on every target, since Windows reads one as
		such and `..\..` would otherwise climb out there.
	**/
	@:noCompletion private static function __confine(relativePath:String):Null<String> {
		if (relativePath == null) {
			return null;
		}
		if (relativePath.indexOf(":") >= 0 || relativePath.indexOf("\x00") >= 0) {
			return null;
		}

		var path:String = StringTools.replace(relativePath, "\\", "/");
		if (StringTools.startsWith(path, "/")) {
			return null;
		}

		var kept:Array<String> = [];
		for (segment in path.split("/")) {
			if (segment == "" || segment == ".") {
				continue;
			}
			if (segment == "..") {
				return null;
			}
			kept.push(segment);
		}
		return kept.join("/");
	}

	@:noCompletion private static function __require(relativePath:String):String {
		var path:Null<String> = __confine(relativePath);
		if (path == null) {
			throw new SecurityError('"$relativePath" is not a path inside the resources directory.');
		}
		return path;
	}

	@:noCompletion private static var __resourcesDir:String = haxe.io.Path.removeTrailingSlashes(System.appDir) + File.separator + "resources" + File.separator;
}

@:build(crossbyte._internal.macro.ResourcesMacro.buildResourceTree())
/** Placeholder type populated by `ResourcesMacro` with the compile-time resource tree. */
final class ResourceTree {}
