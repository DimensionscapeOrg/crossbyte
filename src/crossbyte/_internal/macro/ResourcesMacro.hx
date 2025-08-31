package crossbyte._internal.macro;

#if macro
import haxe.io.Path;
import haxe.crypto.Crc32;
import sys.io.File;
import sys.FileSystem;
import haxe.macro.Context;
import haxe.macro.Expr;

using StringTools;

class ResourcesMacro {
	private static var projectDirectory:String;

	public static function ensureResources():Array<Field> {
		Context.onAfterGenerate(onAfterGenerate);

		projectDirectory = Sys.getCwd() + "resources/";
		if (!FileSystem.exists(projectDirectory)) {
			FileSystem.createDirectory(projectDirectory);
		}

		return Context.getBuildFields();
	}

	private static function onAfterGenerate():Void {
		var outputDir:String = Sys.getCwd();
		#if (windows)
		{
			if (Context.defined("cpp")) {
				outputDir += "/bin/windows/bin/";
			}
		}
		#end

		var resourcesDir:String = outputDir + "resources/";

		if (!FileSystem.exists(resourcesDir)) {
			FileSystem.createDirectory(resourcesDir);
		}

		moveResources(projectDirectory, resourcesDir);
	}

	private static function moveResources(from:String, to:String):Void {
		if (!FileSystem.exists(to)) {
			FileSystem.createDirectory(to);
		}

		for (file in FileSystem.readDirectory(from)) {
			var sourcePath = from + file;
			var destPath = to + file;

			if (FileSystem.isDirectory(sourcePath)) {
				moveResources(sourcePath + "/", destPath + "/");
			} else {
				if (needsOverwrite(sourcePath, destPath)) {
					File.copy(sourcePath, destPath);
					Context.info("Copied file to bin: " + Path.normalize(sourcePath), Context.currentPos());
				}
			}
		}
	}

	private static function needsOverwrite(src:String, dest:String):Bool {
		if (!FileSystem.exists(dest))
			return true;

		var srcStat = FileSystem.stat(src);
		var destStat = FileSystem.stat(dest);

		if (srcStat.size != destStat.size)
			return true;
		if (srcStat.mtime.getTime() > destStat.mtime.getTime())
			return true;

		return fileCRC32(src) != fileCRC32(dest);
	}

	private static function fileCRC32(path:String):Int {
		return Crc32.make(File.getBytes(path));
	}

	public static function buildResourceTree():Array<Field> {
		var rootPath = Context.resolvePath("resources");
		var allFields:Array<Field> = [];

		function capitalize(str:String):String {
			return str.charAt(0).toUpperCase() + str.substr(1);
		}

		function processDirectory(path:String, relativePath:String, className:String):Array<Field> {
			var entries = FileSystem.readDirectory(path);
			var subFields:Array<Field> = [];

			for (entry in entries) {
				var fullPath = path + "/" + entry;
				var relativeFilePath = (relativePath == "") ? entry : relativePath + "/" + entry;
				var fieldName = entry.replace(".", "_");

				if (FileSystem.isDirectory(fullPath)) {
					var subClassName = capitalize(fieldName + "_RTNode");
					var nestedFields = processDirectory(fullPath, relativeFilePath, subClassName);

					var classPath:TypePath = {pack: [], name: subClassName};
					var instanceExpr:Expr = macro new $classPath();
					var ct:ComplexType = TPath(classPath);

					subFields.push({
						name: fieldName,
						pos: Context.currentPos(),
						kind: FVar(macro :$ct, instanceExpr),
						access: [APublic]
					});

					nestedFields.push({
						name: "toString",
						pos: Context.currentPos(),
						meta: [{name: ":noCompletion", pos: Context.currentPos()}],
						kind: FFun({
							args: [],
							expr: macro return $v{relativeFilePath + "/"},
							ret: macro :String
						}),
						access: [APrivate]
					});

					nestedFields.push({
						name: "new",
						pos: Context.currentPos(),
						kind: FFun({
							args: [],
							expr: macro {},
							ret: null
						}),
						access: [APublic]
					});

					Context.defineType({
						pack: [],
						name: subClassName,
						pos: Context.currentPos(),
						meta: [],
						isExtern: false,
						kind: TDClass(),
						fields: nestedFields,
						params: []
					});
				} else {
					subFields.push({
						name: fieldName,
						pos: Context.currentPos(),
						kind: FVar(macro :String, macro $v{relativeFilePath}),
						access: [APublic]
					});
				}
			}

			return subFields;
		}

		allFields = processDirectory(rootPath, "", "ResourceTree");

		allFields.push({
			name: "new",
			pos: Context.currentPos(),
			kind: FFun({
				args: [],
				expr: macro {},
				ret: null
			}),
			access: [APublic]
		});

		return Context.getBuildFields().concat(allFields);
	}
}
#end
