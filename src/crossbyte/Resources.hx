package crossbyte;

import sys.FileSystem;
import crossbyte.io.ByteArray;
import crossbyte.sys.System;
import haxe.Json;
import StringTools;
import crossbyte.io.File;

@:build(crossbyte._internal.macro.ResourcesMacro.ensureResources())
final class Resources {
	public static var resourcesDir(get, never):String;
	public static var tree:ResourceTree = new ResourceTree();

	public static inline function exists(relativePath:String):Bool {
		return FileSystem.exists(__resourcesDir + relativePath);
	}

	public static inline function getAbsolutePath(relativePath:String):String {
		return __resourcesDir + relativePath;
	}

	public static inline function getBytes(relativePath:String):ByteArray {
		return File.getFileBytes(__resourcesDir + relativePath);
	}

	public static inline function getJSON<T>(relativePath:String):TypedObject<T> {
		var jsonString:String = File.getFileText(__resourcesDir + relativePath);
		return Json.parse(jsonString);
	}

	public static inline function getLines(relativePath:String):Array<String> {
		var text:String = getText(relativePath);
		var normalized = text.split("\r\n").join("\n").split("\r").join("\n");
		var lines:Array<String> = normalized.split("\n");
		if (lines.length > 0 && lines[lines.length - 1] == "") {
			lines.pop();
		}

		return lines;
	}

	public static inline function listResources(subDir:String = ""):Array<String> {
		var dir = __resourcesDir + subDir;
		return FileSystem.exists(dir) && FileSystem.isDirectory(dir) ? FileSystem.readDirectory(dir) : [];
	}

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

	public static inline function getText(relativePath:String):String {
		return File.getFileText(__resourcesDir + relativePath);
	}

	public static function resourceSize(relativePath:String):Int {
		return exists(relativePath) ? FileSystem.stat(__resourcesDir + relativePath).size : -1;
	}

	private static inline function get_resourcesDir():String {
		return __resourcesDir;
	}

	@:noCompletion private static var __resourcesDir:String = System.appDir + File.separator + "resources" + File.separator;
}

@:build(crossbyte._internal.macro.ResourcesMacro.buildResourceTree())
final class ResourceTree {}
