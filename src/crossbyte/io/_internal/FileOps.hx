package crossbyte.io._internal;

#if !(js && !nodejs)
import sys.FileSystem;
#end

/**
	File operations `File` and the file `Store` share, which the standard
	library lacks or does differently on each target.

	A browser has no file system, and `File` refuses every operation there
	before reaching any of these; they compile there so that `File` does.
**/
class FileOps {
	/**
		The file at `path` as `"<volume>:<index>"`, the same for every name
		the file has, or null where the target cannot say -- the path is
		missing, or the target's `stat` has no file index (neko and hl on
		Windows report 0 for every file).
	**/
	public static function identity(path:String):Null<String> {
		#if (js && !nodejs)
		return null;
		#elseif cpp
		var key:String = NativeFileSync.identity(path);
		return key == null || key == "" ? null : key;
		#elseif jvm
		try {
			var key:Dynamic = java.nio.file.Files.getAttribute(java.nio.file.Paths.get(path), "basic:fileKey");
			// null on Windows, where the JVM keeps no key; sameFile asks
			// isSameFile there instead.
			return key == null ? null : Std.string(key);
		} catch (_:Dynamic) {
			return null;
		}
		#elseif nodejs
		try {
			// BigInts: a Windows file index passes 2^53, and as a double two
			// files could read as one.
			var stats:Dynamic = js.Syntax.code("require('fs').statSync({0}, {bigint: true})", path);
			var index:String = js.Syntax.code("String({0}.ino)", stats);
			return index == "0" ? null : js.Syntax.code("String({0}.dev)", stats) + ":" + index;
		} catch (_:Dynamic) {
			return null;
		}
		#else
		try {
			var stat = FileSystem.stat(path);
			return stat.ino == 0 ? null : stat.dev + ":" + stat.ino;
		} catch (_:Dynamic) {
			return null;
		}
		#end
	}

	/**
		Whether `a` and `b` name one file: the same path once normalized --
		compared without regard to case on Windows -- or, where both exist,
		the same identity. Missing files are the same only by name.
	**/
	public static function sameFile(a:String, b:String, windows:Bool):Bool {
		#if (js && !nodejs)
		return FilePath.normalize(a, windows) == FilePath.normalize(b, windows);
		#else
		var left:String = FilePath.normalize(FileSystem.absolutePath(a), windows);
		var right:String = FilePath.normalize(FileSystem.absolutePath(b), windows);

		if (windows ? left.toLowerCase() == right.toLowerCase() : left == right) {
			return true;
		}

		if (!FileSystem.exists(a) || !FileSystem.exists(b)) {
			return false;
		}

		#if jvm
		try {
			return java.nio.file.Files.isSameFile(java.nio.file.Paths.get(a), java.nio.file.Paths.get(b));
		} catch (_:Dynamic) {
			return false;
		}
		#else
		var first:Null<String> = identity(a);
		var second:Null<String> = identity(b);
		return first != null && first == second;
		#end
		#end
	}

	/**
		Whether a rename can carry `path` into `directory`: whether the two
		are on one volume. Both must exist. Where the target cannot tell, the
		roots of the two paths decide.
	**/
	public static function sameVolume(path:String, directory:String, windows:Bool):Bool {
		#if (js && !nodejs)
		return true;
		#else
		#if jvm
		try {
			var one:java.lang.Object = cast java.nio.file.Files.getFileStore(java.nio.file.Paths.get(path));
			var two:java.lang.Object = cast java.nio.file.Files.getFileStore(java.nio.file.Paths.get(directory));
			return one.equals(two);
		} catch (_:Dynamic) {}
		#elseif cpp
		var first:Null<String> = identity(path);
		var second:Null<String> = identity(directory);
		if (first != null && second != null) {
			return first.substr(0, first.indexOf(":")) == second.substr(0, second.indexOf(":"));
		}
		#elseif nodejs
		try {
			var one:Dynamic = js.Syntax.code("require('fs').statSync({0}, {bigint: true})", path);
			var two:Dynamic = js.Syntax.code("require('fs').statSync({0}, {bigint: true})", directory);
			return js.Syntax.code("{0}.dev === {1}.dev", one, two);
		} catch (_:Dynamic) {}
		#else
		try {
			return FileSystem.stat(path).dev == FileSystem.stat(directory).dev;
		} catch (_:Dynamic) {}
		#end

		var a = FilePath.parse(FileSystem.absolutePath(path), windows);
		var b = FilePath.parse(FileSystem.absolutePath(directory), windows);
		return FilePath.sameRoot(a.root, b.root, windows);
		#end
	}

	/**
		`path` opened to be written from empty, as `sys.io.File.write` promises
		and on the jvm under Windows does not keep: it deletes the file and
		opens it afresh, Windows refuses the delete while any other handle has
		the file open, and the old file is then opened without being cut --
		its start overwritten, its old length kept, and nothing said. Cut here
		through the handle, which Windows allows. Dynamic in a browser, where
		the sys package cannot be named.
	**/
	public static function write(path:String):#if (js && !nodejs) Dynamic #else sys.io.FileOutput #end {
		#if (js && !nodejs)
		throw new crossbyte.errors.IllegalOperationError("Cannot write " + path + ": this target has no filesystem.");
		#else
		var output:sys.io.FileOutput = sys.io.File.write(path, true);

		#if jvm
		try {
			@:privateAccess output.f.setLength(haxe.Int64.ofInt(0));
		} catch (e:Dynamic) {
			try {
				output.close();
			} catch (_:Dynamic) {}
			throw e;
		}
		#end

		return output;
		#end
	}

	/** `bytes` as the whole of the file at `path`, through `write`. **/
	public static function saveBytes(path:String, bytes:haxe.io.Bytes):Void {
		#if (js && !nodejs)
		throw new crossbyte.errors.IllegalOperationError("Cannot write " + path + ": this target has no filesystem.");
		#else
		var output:sys.io.FileOutput = write(path);

		try {
			output.writeFullBytes(bytes, 0, bytes.length);
		} catch (e:Dynamic) {
			try {
				output.close();
			} catch (_:Dynamic) {}
			throw e;
		}

		output.close();
		#end
	}

	/**
		Cuts the file at `path` to `length` bytes, or extends it with zeros.
		Through the system's own truncate where the target reaches one; the
		interpreter, neko and hl have none, and there the kept part is read
		and written back.
	**/
	public static function truncate(path:String, length:Int):Void {
		#if (js && !nodejs)
		throw new crossbyte.errors.IllegalOperationError("Cannot truncate " + path + ": this target has no filesystem.");
		#elseif cpp
		var failure:String = NativeFileSync.truncate(path, length);

		if (failure != null && failure != "") {
			throw failure;
		}
		#elseif jvm
		var file = new java.io.RandomAccessFile(path, "rw");

		try {
			file.setLength(haxe.Int64.ofInt(length));
		} catch (e:Dynamic) {
			file.close();
			throw e;
		}

		file.close();
		#elseif nodejs
		js.node.Fs.truncateSync(path, length);
		#else
		var kept:haxe.io.Bytes = haxe.io.Bytes.alloc(length);
		var input = sys.io.File.read(path, true);
		var got:Int = 0;

		try {
			while (got < length) {
				var read:Int = input.readBytes(kept, got, length - got);
				if (read <= 0) {
					break;
				}
				got += read;
			}
		} catch (_:haxe.io.Eof) {}

		input.close();
		sys.io.File.saveBytes(path, kept);
		#end
	}

	/**
		Renames `from` over `to`, replacing it, in one step.

		The standard library's rename does that on POSIX, and on Node and eval
		everywhere, but on hxcpp for Windows it is `_wrename` and on the jvm
		`File.renameTo`, and both refuse to replace a file there.
	**/
	public static function replace(from:String, to:String):Void {
		#if (js && !nodejs)
		throw new crossbyte.errors.IllegalOperationError("Cannot replace " + to + ": this target has no filesystem.");
		#elseif cpp
		var failure:String = NativeFileSync.replace(from, to);

		if (failure != null && failure != "") {
			throw failure;
		}
		#elseif jvm
		// Cast: Haxe sees a Java enum as an enum, not as the interface it
		// implements.
		var replace:java.nio.file.CopyOption = cast java.nio.file.StandardCopyOption.REPLACE_EXISTING;
		var atomic:java.nio.file.CopyOption = cast java.nio.file.StandardCopyOption.ATOMIC_MOVE;
		java.nio.file.Files.move(java.nio.file.Paths.get(from), java.nio.file.Paths.get(to), replace, atomic);
		#elseif (nodejs || eval)
		FileSystem.rename(from, to);
		#else
		// No single-step replace to reach for here. The old two-step
		// replacement, which is what every target did before, and only where
		// the one step refused.
		try {
			FileSystem.rename(from, to);
		} catch (e:Dynamic) {
			if (!FileSystem.exists(to)) {
				throw e;
			}

			FileSystem.deleteFile(to);
			FileSystem.rename(from, to);
		}
		#end
	}
}
