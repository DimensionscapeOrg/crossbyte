package crossbyte;

import sys.FileSystem;
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
 */
final class Resources {
	/** Absolute path to the runtime resources directory. */
	public static var resourcesDir(get, never):String;
	/** Macro-generated tree that mirrors compile-time resources when available. */
	public static var tree:ResourceTree = new ResourceTree();

	/** Returns `true` when a resource exists relative to `resourcesDir`. */
	public static inline function exists(relativePath:String):Bool {
		return FileSystem.exists(__resourcesDir + relativePath);
	}

	/** Resolves a resource path to an absolute filesystem path. */
	public static inline function getAbsolutePath(relativePath:String):String {
		return __resourcesDir + relativePath;
	}

	/** Loads a resource as a `ByteArray`. */
	public static inline function getBytes(relativePath:String):ByteArray {
		return File.getFileBytes(__resourcesDir + relativePath);
	}

	/** Loads and parses a JSON resource into the requested typed object shape. */
	public static inline function getJSON<T>(relativePath:String):TypedObject<T> {
		var jsonString:String = File.getFileText(__resourcesDir + relativePath);
		return Json.parse(jsonString);
	}

	/** Loads a text resource and returns normalized lines. */
	public static inline function getLines(relativePath:String):Array<String> {
		var text:String = getText(relativePath);
		var normalized = text.split("\r\n").join("\n").split("\r").join("\n");
		var lines:Array<String> = normalized.split("\n");
		if (lines.length > 0 && lines[lines.length - 1] == "") {
			lines.pop();
		}

		return lines;
	}

	/** Lists direct children of a resource subdirectory. */
	public static inline function listResources(subDir:String = ""):Array<String> {
		var dir = __resourcesDir + subDir;
		return FileSystem.exists(dir) && FileSystem.isDirectory(dir) ? FileSystem.readDirectory(dir) : [];
	}

	/** Recursively lists files below a resource subdirectory using forward-slash relative paths. */
	public static function listResourcesRecursive(subDir:String = ""):Array<String> {
		var dir = __resourcesDir + subDir;
		var files:Array<String> = [];
		var relativeRoot = StringTools.replace(subDir, "\\", "/");
		while (StringTools.endsWith(relativeRoot, "/")) {
			relativeRoot = relativeRoot.substr(0, relativeRoot.length - 1);
		}

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

	/** Loads a resource as UTF-8 text. */
	public static inline function getText(relativePath:String):String {
		return File.getFileText(__resourcesDir + relativePath);
	}

	/** Returns the resource size in bytes, or `-1` when the resource does not exist. */
	public static function resourceSize(relativePath:String):Int {
		return exists(relativePath) ? FileSystem.stat(__resourcesDir + relativePath).size : -1;
	}

	private static inline function get_resourcesDir():String {
		return __resourcesDir;
	}

	@:noCompletion private static var __resourcesDir:String = System.appDir + File.separator + "resources" + File.separator;
}

@:build(crossbyte._internal.macro.ResourcesMacro.buildResourceTree())
/** Placeholder type populated by `ResourcesMacro` with the compile-time resource tree. */
final class ResourceTree {}
