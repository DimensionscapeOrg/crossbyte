package crossbyte.io._internal.store;

#if !(js && !nodejs)
import crossbyte.io.ByteArray;
import haxe.io.Bytes;
import sys.FileSystem;
import sys.io.File as SysFile;

/**
 * A `Store` over a directory, for every target with a filesystem.
 *
 * One file per key, under a directory named for the store, inside the
 * application storage directory. A single index file was the alternative and
 * is worse: every write would rewrite the whole index, and a value larger than
 * memory could never be streamed in later without changing the format. A
 * directory is also inspectable, which matters the first time someone has to
 * find out what their application actually saved.
 *
 * Keys are encoded rather than used as file names. A key is any string and a
 * file name is not -- `a/b`, `..`, `CON` on Windows, and case-insensitive
 * collisions between `Token` and `token` are all real keys and all impossible
 * or dangerous as paths.
 *
 * Writes are atomic: a temporary file, then a rename. A store that corrupts on
 * a power cut is worse than no store, because it is trusted. Rename is the only
 * operation a filesystem gives that is atomic enough to build on.
 *
 * Asynchronous by signature and synchronous underneath. That is deliberate and
 * it is not a lie: the callback contract is what lets a target that genuinely
 * cannot block -- the browser -- implement the same API, and it lets this one
 * grow a thread or a queue later without any caller changing. What it must not
 * do is pretend to be non-blocking, so this is said plainly here rather than
 * implied by the shape.
 */
class FileStore implements IStoreBackend {
	private static inline var TEMP_SUFFIX:String = ".writing";
	private static inline var ENTRY_SUFFIX:String = ".value";

	private final name:String;
	private var directory:String;
	private var closed:Bool = false;

	public function new(name:String) {
		this.name = name;
	}

	public function open(done:String->Void):Void {
		try {
			var root:String = File.applicationStorageDirectory.nativePath;
			directory = haxe.io.Path.join([root, "stores", name]);

			if (!FileSystem.exists(directory)) {
				FileSystem.createDirectory(directory);
			}

			if (!FileSystem.isDirectory(directory)) {
				done("Store path exists and is not a directory: " + directory);
				return;
			}

			// Anything left behind by a write that died mid-rename. Removed on
			// open rather than ignored, so a crash does not slowly fill the
			// directory with debris that looks like data.
			for (entry in FileSystem.readDirectory(directory)) {
				if (StringTools.endsWith(entry, TEMP_SUFFIX)) {
					try {
						FileSystem.deleteFile(haxe.io.Path.join([directory, entry]));
					} catch (_:Dynamic) {}
				}
			}

			done(null);
		} catch (e:Dynamic) {
			done("Could not open the store: " + Std.string(e));
		}
	}

	public function get(key:String, done:(error:String, value:Null<ByteArray>) -> Void):Void {
		try {
			var path:String = __pathFor(key);

			if (!FileSystem.exists(path)) {
				// Absent, and only that. Never an empty ByteArray standing in
				// for a missing one.
				done(null, null);
				return;
			}

			done(null, ByteArray.fromBytes(SysFile.getBytes(path)));
		} catch (e:Dynamic) {
			done("Could not read '" + key + "': " + Std.string(e), null);
		}
	}

	public function put(key:String, value:ByteArray, done:String->Void):Void {
		var temporary:String = null;

		try {
			var path:String = __pathFor(key);
			temporary = path + TEMP_SUFFIX;

			var bytes:Bytes = value;
			SysFile.saveBytes(temporary, bytes);

			// Rename over the old value rather than truncating and rewriting
			// it. A reader either sees the whole previous value or the whole
			// new one; truncate-then-write has a window where it sees neither.
			if (FileSystem.exists(path)) {
				FileSystem.deleteFile(path);
			}

			FileSystem.rename(temporary, path);
			temporary = null;
			done(null);
		} catch (e:Dynamic) {
			if (temporary != null) {
				try {
					FileSystem.deleteFile(temporary);
				} catch (_:Dynamic) {}
			}

			done("Could not write '" + key + "': " + Std.string(e));
		}
	}

	public function remove(key:String, done:String->Void):Void {
		try {
			var path:String = __pathFor(key);

			if (FileSystem.exists(path)) {
				FileSystem.deleteFile(path);
			}

			done(null);
		} catch (e:Dynamic) {
			done("Could not remove '" + key + "': " + Std.string(e));
		}
	}

	public function keys(prefix:Null<String>, done:(error:String, keys:Array<String>) -> Void):Void {
		try {
			var found:Array<String> = [];

			for (entry in FileSystem.readDirectory(directory)) {
				if (!StringTools.endsWith(entry, ENTRY_SUFFIX)) {
					continue;
				}

				var key:String = __decode(entry.substr(0, entry.length - ENTRY_SUFFIX.length));

				if (key == null) {
					continue;
				}

				if (prefix == null || StringTools.startsWith(key, prefix)) {
					found.push(key);
				}
			}

			done(null, found);
		} catch (e:Dynamic) {
			done("Could not list the store: " + Std.string(e), null);
		}
	}

	public function clear(done:String->Void):Void {
		try {
			for (entry in FileSystem.readDirectory(directory)) {
				try {
					FileSystem.deleteFile(haxe.io.Path.join([directory, entry]));
				} catch (_:Dynamic) {}
			}

			done(null);
		} catch (e:Dynamic) {
			done("Could not clear the store: " + Std.string(e));
		}
	}

	public function close():Void {
		closed = true;
	}

	/**
	 * A key as a file name.
	 *
	 * Hex, not the key itself and not an escape scheme. A key is any string; a
	 * file name is not. `a/b` is a path, `..` is the parent, `CON` and `NUL`
	 * are devices on Windows, a long key exceeds the name limit, and `Token`
	 * and `token` are the same file on a case-insensitive volume and different
	 * keys everywhere. Hex has none of those problems and is reversible, which
	 * `keys()` needs.
	 */
	private function __pathFor(key:String):String {
		return haxe.io.Path.join([directory, Bytes.ofString(key).toHex() + ENTRY_SUFFIX]);
	}

	private function __decode(encoded:String):Null<String> {
		try {
			// Anything not written by __pathFor is not ours; skipped rather
			// than guessed at.
			if (encoded.length % 2 != 0 || !~/^[0-9a-f]*$/.match(encoded)) {
				return null;
			}

			return Bytes.ofHex(encoded).toString();
		} catch (_:Dynamic) {
			return null;
		}
	}
}
#end
