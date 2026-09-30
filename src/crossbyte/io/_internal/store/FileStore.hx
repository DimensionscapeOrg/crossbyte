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
 * file name is not, `a/b`, `..`, `CON` on Windows, and case-insensitive
 * collisions between `Token` and `token` are all real keys and all impossible
 * or dangerous as paths.
 *
 * Writes are atomic: a temporary file of the writer's own, flushed to disk,
 * then renamed over the old value in one step. A store that corrupts on a power
 * cut is worse than no store, because it is trusted. Rename is the only
 * operation a filesystem gives that is atomic enough to build on, as long as
 * it is one rename. This used to delete the old value and then rename, because
 * the standard library's rename refuses to replace a file on Windows; a process
 * that died between the two lost the key, and the next open threw away the
 * complete new value as debris. Every writer also shared one temporary name,
 * and nothing was flushed.
 *
 * The flush is what the interpreter cannot do: eval has no fsync. There a
 * power cut can cost the latest write, though never tear one.
 *
 * Asynchronous by signature and synchronous underneath. That is deliberate and
 * it is not a lie: the callback contract is what lets a target that genuinely
 * cannot block, the browser, implement the same API, and it lets this one
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

			// Anything left behind by a write that died before its rename.
			// Removed on open rather than ignored, so a crash does not slowly
			// fill the directory with debris that looks like data: a write that
			// never renamed never completed, and the old value is still there.
			//
			// With one exception. The previous writer deleted the old value
			// before renaming, and used `<key>.value.writing` for every write;
			// a process that died between those two steps left that file as
			// the only copy of the key. It is promoted, not deleted.
			for (entry in FileSystem.readDirectory(directory)) {
				if (!StringTools.endsWith(entry, TEMP_SUFFIX)) {
					continue;
				}

				var temporary:String = haxe.io.Path.join([directory, entry]);
				var stem:String = entry.substr(0, entry.length - TEMP_SUFFIX.length);

				if (StringTools.endsWith(stem, ENTRY_SUFFIX)) {
					var value:String = haxe.io.Path.join([directory, stem]);

					if (!FileSystem.exists(value)) {
						try {
							__replace(temporary, value);
							continue;
						} catch (_:Dynamic) {}
					}
				}

				try {
					FileSystem.deleteFile(temporary);
				} catch (_:Dynamic) {}
			}

			done(null);
		} catch (e:Dynamic) {
			done("Could not open the store: " + Std.string(e));
		}
	}

	public function get(key:String, done:(error:String, value:Null<ByteArray>) -> Void):Void {
		try {
			var path:String = __pathFor(key);

			var bytes:Null<Bytes> = FileSystem.exists(path) ? __read(path) : null;

			if (bytes == null) {
				// Absent, and only that. Never an empty ByteArray standing in
				// for a missing one.
				done(null, null);
				return;
			}

			done(null, ByteArray.fromBytes(bytes));
		} catch (e:Dynamic) {
			done("Could not read '" + key + "': " + Std.string(e), null);
		}
	}

	public function put(key:String, value:ByteArray, done:String->Void):Void {
		var temporary:String = null;

		try {
			var path:String = __pathFor(key);
			// The writer's own: two runtimes, or two processes, writing one key
			// at once each write a whole file of their own, and the last rename
			// wins. A shared name let their bytes interleave in one file.
			temporary = path + "." + __writerTag() + TEMP_SUFFIX;

			var bytes:Bytes = value;
			SysFile.saveBytes(temporary, bytes);

			// On disk before it has a name a reader can find: renaming data the
			// operating system has not written yet can leave, after a power cut,
			// a value of the right name and the wrong contents.
			__sync(temporary);

			// Over the old value in one step. A reader sees the whole previous
			// value or the whole new one, and there is no moment in which the
			// key is absent.
			__replace(temporary, path);
			temporary = null;
			__syncDirectory(directory);
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

	public function forEach(prefix:Null<String>, visit:(key:String, value:ByteArray) -> Bool, done:String->Void):Void {
		try {
			// The directory listing is unavoidable, a filesystem has no
			// cursor, but the values are not, and those are what a large
			// store is made of. One is read, handed over, and released before
			// the next is touched.
			for (entry in FileSystem.readDirectory(directory)) {
				if (!StringTools.endsWith(entry, ENTRY_SUFFIX)) {
					continue;
				}

				var key:String = __decode(entry.substr(0, entry.length - ENTRY_SUFFIX.length));

				if (key == null || (prefix != null && !StringTools.startsWith(key, prefix))) {
					continue;
				}

				var path:String = haxe.io.Path.join([directory, entry]);

				// Deleted between listing and reading, by another runtime, or
				// by the visitor itself removing as it goes. Skipped, because a
				// key that is gone is not an error for an iteration that has
				// already promised nothing about ordering or a snapshot.
				var bytes:Null<Bytes> = FileSystem.exists(path) ? __read(path) : null;

				if (bytes == null) {
					continue;
				}

				if (!visit(key, ByteArray.fromBytes(bytes))) {
					break;
				}
			}

			done(null);
		} catch (e:Dynamic) {
			done("Could not iterate the store: " + Std.string(e));
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

	/**
	 * A value's bytes, or `null` if it is gone.
	 *
	 * On Windows a file that is being renamed over refuses to open for the
	 * moment the replace takes, where POSIX hands a reader the old file or the
	 * new one. That is a write in progress, not a failed read, so it is ridden
	 * out, briefly, and only there, rather than reported.
	 */
	private static function __read(path:String):Null<Bytes> {
		var attempt:Int = 0;

		while (true) {
			try {
				return SysFile.getBytes(path);
			} catch (e:Dynamic) {
				if (!crossbyte.sys.System.isWindows || ++attempt >= 200) {
					if (!FileSystem.exists(path)) {
						return null;
					}

					throw e;
				}

				Sys.sleep(0.001);
			}
		}
	}

	private static var __writes:Int = 0;

	/**
	 * Distinct per write, in this process and against any other.
	 *
	 * The random half is two draws of sixteen bits rather than one below
	 * 0x7FFFFFFF, a bound neko's 31-bit Int cannot hold: its `Std.random`
	 * refused it, and every `put` there threw before writing anything.
	 */
	private static function __writerTag():String {
		__writes = (__writes + 1) & 0x7FFFFFFF;
		return StringTools.hex(Std.random(0x10000), 4) + StringTools.hex(Std.random(0x10000), 4) + StringTools.hex(__writes, 8);
	}

	/**
	 * Renames `from` over `to`, replacing it, in one step.
	 *
	 * The standard library's rename does that on POSIX, and on Node and eval
	 * everywhere, but on hxcpp for Windows it is `_wrename` and on the jvm
	 * `File.renameTo`, and both refuse to replace a file there.
	 */
	private static function __replace(from:String, to:String):Void {
		#if cpp
		var failure:String = crossbyte.io._internal.NativeFileSync.replace(from, to);

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

	/** Flushes a file to stable storage, where the target can. **/
	private static function __sync(path:String):Void {
		#if cpp
		var failure:String = crossbyte.io._internal.NativeFileSync.sync(path);

		if (failure != null && failure != "") {
			throw failure;
		}
		#elseif jvm
		// Cast: Haxe sees a Java enum as an enum, not as the interface it
		// implements.
		var write:java.nio.file.OpenOption = cast java.nio.file.StandardOpenOption.WRITE;
		var channel = java.nio.channels.FileChannel.open(java.nio.file.Paths.get(path), write);

		try {
			channel.force(true);
		} catch (e:Dynamic) {
			channel.close();
			throw e;
		}

		channel.close();
		#elseif nodejs
		var fd:Int = js.node.Fs.openSync(path, "r+");

		try {
			js.node.Fs.fsyncSync(fd);
		} catch (e:Dynamic) {
			js.node.Fs.closeSync(fd);
			throw e;
		}

		js.node.Fs.closeSync(fd);
		#end
	}

	/**
	 * Flushes the directory, so the rename in it survives a power cut too. POSIX
	 * keeps a name separately from the file it names. Best effort: nothing to
	 * do on Windows, and some filesystems refuse.
	 */
	private static function __syncDirectory(path:String):Void {
		#if cpp
		crossbyte.io._internal.NativeFileSync.syncDirectory(path);
		#elseif nodejs
		if (crossbyte.sys.System.isWindows) {
			return;
		}

		try {
			var fd:Int = js.node.Fs.openSync(path, "r");

			try {
				js.node.Fs.fsyncSync(fd);
			} catch (_:Dynamic) {}

			js.node.Fs.closeSync(fd);
		} catch (_:Dynamic) {}
		#end
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
