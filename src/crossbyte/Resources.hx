package crossbyte;

import sys.FileSystem;
import crossbyte.io.ByteArray;
import crossbyte.sys.System;
import haxe.Json;
import crossbyte.io.File;

@:build(crossbyte._internal.macro.ResourcesMacro.ensureResources())

final class Resources {

    public static var resourcesDir(get, never):String;
    public static var tree:ResourceTree = new ResourceTree();
    
    public static inline function exists(relativePath:String):Bool {
        return FileSystem.exists(__resourcesDir + relativePath);
    }

    public static inline function getAbsolutePath(relativePath:String):String{
        return __resourcesDir + relativePath;
    }

    public static inline function getBytes(relativePath:String):ByteArray{
        return File.getFileBytes(__resourcesDir + relativePath);
    }

    public static inline function getJSON<T>(relativePath:String):TypedObject<T>{
        var jsonString:String = File.getFileText(__resourcesDir + relativePath);
        return Json.parse(jsonString);
    }

    public static inline function getLines(relativePath:String):Array<String>{
        var text:String = getText(relativePath);
        var lines:Array<String> = text.split(File.lineEnding);
        
        return lines;
    }

    public static inline function listResources(subDir:String = ""):Array<String> {
        var dir = __resourcesDir + subDir;
        return FileSystem.exists(dir) && FileSystem.isDirectory(dir) ? FileSystem.readDirectory(dir) : [];
    }

    public static function listResourcesRecursive(subDir:String = ""):Array<String> {
        var dir = __resourcesDir + subDir;
        var files:Array<String> = [];
        
        function scan(path:String) {
            if (!FileSystem.exists(path) || !FileSystem.isDirectory(path)) return;
            for (file in FileSystem.readDirectory(path)) {
                var fullPath = path + File.separator + file;
                files.push(fullPath.substr(__resourcesDir.length)); // Store relative path
                if (FileSystem.isDirectory(fullPath)) scan(fullPath); // Recursively scan subdirectories
            }
        }
        
        scan(dir);
        return files;
    }

    public static inline function getText(relativePath:String):String {
        return File.getFileText(__resourcesDir + relativePath);
    }

    public static function resourceSize(relativePath:String):Int {
        return exists(relativePath) ? FileSystem.stat(__resourcesDir + relativePath).size : -1;
    }

    private static inline function get_resourcesDir():String{
        return __resourcesDir;
    }

    @:noCompletion private static var __resourcesDir:String = System.appDir + File.separator + "resources" + File.separator;
}


@:build(crossbyte._internal.macro.ResourcesMacro.buildResourceTree())
final class ResourceTree {}
