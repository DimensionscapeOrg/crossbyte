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

		projectDirectory = getProjectResourcesDirectory();
		if (!FileSystem.exists(projectDirectory)) {
			FileSystem.createDirectory(projectDirectory);
		}

		return Context.getBuildFields();
	}

	/**
		Copies the project's `resources` beside the program the build writes,
		which is where `Resources` looks for it: `File.applicationDirectory`.
	**/
	private static function onAfterGenerate():Void {
		if (projectDirectory == null) {
			projectDirectory = getProjectResourcesDirectory();
		}

		var outputDir:Null<String> = programDirectory();

		if (outputDir == null) {
			return;
		}

		var resourcesDir:String = Path.addTrailingSlash(outputDir) + "resources/";

		if (Path.normalize(FileSystem.absolutePath(resourcesDir)) == Path.normalize(FileSystem.absolutePath(projectDirectory))) {
			return;
		}

		if (!FileSystem.exists(resourcesDir)) {
			FileSystem.createDirectory(resourcesDir);
		}

		moveResources(projectDirectory, resourcesDir);
	}

	/**
		Where the program this build writes will be, or null when it writes
		none: the interpreter runs from here. hxcpp's output is a directory,
		with the executable inside it; every other target's is the program's
		own file.
	**/
	private static function programDirectory():Null<String> {
		if (Context.defined("interp")) {
			return null;
		}

		var output:Null<String> = haxe.macro.Compiler.getOutput();

		if (output == null || output == "") {
			return null;
		}

		if (Context.defined("cpp")) {
			return output;
		}

		var directory:String = Path.directory(output);
		return directory == "" ? Sys.getCwd() : directory;
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

	/**
		The field `Resources.tree` gives the file or directory `entry`: its
		name with every character that cannot be in a Haxe identifier made
		`_` (so `sample.txt` is `sample_txt` and `my-file.png` is
		`my_file_png`), a `_` before a leading digit, and a `_` after a name
		Haxe keeps for itself (`class`, `new`, `toString`).
	**/
	public static function fieldNameFor(entry:String):String {
		var name:StringBuf = new StringBuf();
		for (i in 0...entry.length) {
			var code:Int = StringTools.fastCodeAt(entry, i);
			var kept:Bool = (code >= "a".code && code <= "z".code) || (code >= "A".code && code <= "Z".code) || (code >= "0".code && code <= "9".code)
				|| code == "_".code;
			name.addChar(kept ? code : "_".code);
		}
		var field:String = name.toString();
		if (field == "" || (StringTools.fastCodeAt(field, 0) >= "0".code && StringTools.fastCodeAt(field, 0) <= "9".code)) {
			field = "_" + field;
		}
		return RESERVED.indexOf(field) >= 0 ? field + "_" : field;
	}

	// Haxe's keywords, which no field may be named; the two members every node
	// of the tree has of its own; and what every JavaScript object has, which
	// a field of that name would hide or, for __proto__, never become.
	private static final RESERVED:Array<String> = [
		"abstract", "break", "case", "cast", "catch", "class", "continue", "default", "do", "dynamic", "else", "enum", "extends", "extern",
		"false", "final", "for", "function", "if", "implements", "import", "in", "inline", "interface", "macro", "new", "null", "operator",
		"overload", "override", "package", "private", "public", "return", "static", "switch", "this", "throw", "true", "try", "typedef",
		"untyped", "using", "var", "while", "toString", "constructor", "hasOwnProperty", "isPrototypeOf", "propertyIsEnumerable",
		"toLocaleString", "valueOf", "__proto__", "__defineGetter__", "__defineSetter__", "__lookupGetter__", "__lookupSetter__", "__class__"
	];

	public static function buildResourceTree():Array<Field> {
		var rootPath = getProjectResourcesDirectory();
		var allFields:Array<Field> = [];
		// Node type names in use, lower-cased: the generated classes are files
		// natively and on the jvm, and two names differing only in case are
		// one file where the file system ignores case.
		var typeNames:Map<String, Bool> = new Map();

		function processDirectory(path:String, relativePath:String, className:String):Array<Field> {
			var entries = FileSystem.readDirectory(path);
			// Sorted, so which of two names that make one field keeps it does
			// not depend on the order a file system lists them in.
			entries.sort((a, b) -> a < b ? -1 : a > b ? 1 : 0);
			var subFields:Array<Field> = [];
			var fieldsTaken:Map<String, String> = new Map();

			for (entry in entries) {
				var fullPath = path + "/" + entry;
				var relativeFilePath = (relativePath == "") ? entry : relativePath + "/" + entry;
				var fieldName = fieldNameFor(entry);

				// Two names that make one field (`a.b` and `a_b`) cannot both
				// have it; the first keeps it, and the other is still read by
				// its path.
				if (fieldsTaken.exists(fieldName)) {
					Context.warning('Resources.tree leaves out "$relativeFilePath": its field, $fieldName, is "${fieldsTaken.get(fieldName)}"\'s. '
						+ 'Read it by its path.', Context.currentPos());
					continue;
				}
				fieldsTaken.set(fieldName, relativeFilePath);

				if (FileSystem.isDirectory(fullPath)) {
					// Named for the directory's whole path, so same-named
					// directories in different places are different types, and
					// numbered where two paths would still make one name.
					var subClassName = fieldNameFor(relativeFilePath.replace("/", "_"));
					var first:Int = StringTools.fastCodeAt(subClassName, 0);
					if (first >= "a".code && first <= "z".code) {
						subClassName = subClassName.charAt(0).toUpperCase() + subClassName.substr(1);
					} else if (first < "A".code || first > "Z".code) {
						subClassName = "Dir" + subClassName;
					}
					subClassName += "_RTNode";
					if (typeNames.exists(subClassName.toLowerCase())) {
						var n:Int = 2;
						while (typeNames.exists((subClassName + n).toLowerCase())) {
							n++;
						}
						subClassName += n;
					}
					typeNames.set(subClassName.toLowerCase(), true);
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

		if (FileSystem.exists(rootPath) && FileSystem.isDirectory(rootPath)) {
			allFields = processDirectory(rootPath, "", "ResourceTree");
		}

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

	private static inline function getProjectResourcesDirectory():String {
		return Path.addTrailingSlash(Sys.getCwd()) + "resources/";
	}
}
#end
