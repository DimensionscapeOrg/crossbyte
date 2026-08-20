package crossbyte.io._internal;

import crossbyte.errors.IllegalOperationError;
import haxe.io.Bytes;

/**
 * Stands in for `sys.FileSystem` and `sys.io.File` where there is no
 * filesystem, so that `crossbyte.io.File` keeps its type and its whole API on
 * a target that cannot back them.
 *
 * The alternative was to compile `File` out of the browser build entirely, but
 * the type is threaded through the framework -- `FileListEvent` carries them,
 * and half a dozen packages reference it -- so removing it would take those
 * with it and there would be nothing left to unify. Keeping the class and
 * refusing the operation costs one shim instead of a stub per method, and the
 * refusal lands where the caller can see which call failed.
 *
 * Every member throws. None of them returns a plausible-looking empty value:
 * an `exists()` answering `false` reads as "no such file" rather than "this
 * target has no files", and a caller would go on to create it.
 *
 * A browser does have storage -- IndexedDB, and the origin-private file system
 * behind `showSaveFilePicker` -- but neither is a synchronous POSIX-shaped
 * filesystem, and pretending otherwise underneath a synchronous API is how a
 * write silently goes nowhere. Backing `File` with those is a real piece of
 * design, not a shim.
 */
class NoFileSystem {
	public static function exists(path:String):Bool {
		return refuse("check whether " + path + " exists");
	}

	public static function isDirectory(path:String):Bool {
		return refuse("check whether " + path + " is a directory");
	}

	public static function readDirectory(path:String):Array<String> {
		return refuse("read the directory " + path);
	}

	public static function createDirectory(path:String):Void {
		refuse("create the directory " + path);
	}

	public static function deleteDirectory(path:String):Void {
		refuse("delete the directory " + path);
	}

	public static function deleteFile(path:String):Void {
		refuse("delete " + path);
	}

	public static function stat(path:String):Dynamic {
		return refuse("stat " + path);
	}

	public static function getBytes(path:String):Bytes {
		return refuse("read " + path);
	}

	public static function getContent(path:String):String {
		return refuse("read " + path);
	}

	public static function saveBytes(path:String, bytes:Bytes):Void {
		refuse("write " + path);
	}

	public static function saveContent(path:String, content:String):Void {
		refuse("write " + path);
	}

	public static function copy(from:String, to:String):Void {
		refuse("copy " + from + " to " + to);
	}

	/**
	 * Typed as returning whatever the caller expects, so a shim member can end
	 * in `return refuse(...)` and still satisfy its signature. It never
	 * returns.
	 */
	private static function refuse<T>(what:String):T {
		throw new IllegalOperationError("Cannot " + what + ": this target has no filesystem.");
	}
}
