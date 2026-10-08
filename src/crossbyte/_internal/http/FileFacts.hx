package crossbyte._internal.http;

// Server-side, like the static resolver it serves: a page has no filesystem.
#if !(js && !nodejs)

/**
	What the static file server needs to know of a path (whether something
	is there, whether it is a directory, its size and when it was last
	modified), asked of the system once.

	Asking `File` takes about seven system calls to serve one static file,
	at about 19 us a call on Windows. Natively this is one `stat` and, for a
	file, the exact size by `NativeFileSync.size` (the `stat` size is an
	`Int`, and wraps past 2 GB on Linux); on the jvm one `readAttributes`;
	on Node one `statSync`.

	`FAST` is false on the targets where none of that is to hand (eval,
	neko, HashLink), and the callers ask `File`. `of`
	answers `NONE` when nothing is there, and `UNKNOWN` for a path the system
	has but will not describe in one call (natively, a file past 2 GB on
	Windows, where `_stat` fails), which the callers ask `File` about too.
**/
@:noCompletion
final class FileFacts {
	/** Whether `of` is the one-call path here; see the class. */
	public static inline var FAST:Bool = #if (cpp || jvm || nodejs) true #else false #end;

	/** A path that is there but not described: ask `File`. */
	public static final UNKNOWN:FileFacts = new FileFacts(false, -1, 0, false);

	/** Nothing at the path. */
	public static final NONE:FileFacts = new FileFacts(false, -1, 0, true, false);

	/** False for `NONE`. */
	public final exists:Bool;

	public final directory:Bool;

	/** Bytes; exact, past 2 GB too. Meaningless for a directory. */
	public final size:Float;

	/** Milliseconds since 1970, as `Date.getTime()` reads `File.modificationDate`. */
	public final modified:Float;

	/** False for `UNKNOWN`. */
	public final known:Bool;

	private function new(directory:Bool, size:Float, modified:Float, known:Bool = true, exists:Bool = true) {
		this.exists = exists;
		this.directory = directory;
		this.size = size;
		this.modified = modified;
		this.known = known;
	}

	/** Whether this is a regular file, described: what the static server can serve from these facts alone. */
	public var servable(get, never):Bool;

	private inline function get_servable():Bool {
		return exists && known && !directory;
	}

	/**
		What is at `path`. Never throws.

		@param describeHuge Whether a file the system will not describe in one
		       call is `UNKNOWN` (true) or `NONE` (false). False costs a missing
		       path one call natively rather than two: for a probe, such as for
		       a precompressed sibling, where a file too large to describe is as
		       good as none.
	**/
	public static function of(path:String, describeHuge:Bool = true):FileFacts {
		#if cpp
		var stat:sys.FileStat = null;
		try {
			stat = sys.FileSystem.stat(path);
		} catch (_:Dynamic) {
			stat = null;
		}
		// hxcpp answers a failed stat with zeros rather than a throw; a file or
		// a directory always has its type in `mode`.
		if (stat == null || stat.mode == 0) {
			// Nothing there, or something `_stat` will not describe: a file
			// past 2 GB on Windows, which its own size call can still see.
			if (!describeHuge) {
				return NONE;
			}
			return crossbyte.io._internal.NativeFileSync.size(path) < 0 ? NONE : UNKNOWN;
		}
		if ((stat.mode & 0xF000) == 0x4000) {
			return new FileFacts(true, 0, stat.mtime.getTime());
		}
		var size:Float = crossbyte.io._internal.NativeFileSync.size(path);
		if (size < 0) {
			return NONE;
		}
		return new FileFacts(false, size, stat.mtime.getTime());
		#elseif jvm
		try {
			var attributes = java.nio.file.Files.readAttributes(java.nio.file.Paths.get(path), "basic:isDirectory,size,lastModifiedTime");
			var directory:Bool = (cast attributes.get("isDirectory") : java.lang.Boolean).booleanValue();
			var size:Float = (cast attributes.get("size") : java.lang.Long).doubleValue();
			var modified:Float = __longToFloat((cast attributes.get("lastModifiedTime") : java.nio.file.attribute.FileTime).toMillis());
			return new FileFacts(directory, size, modified);
		} catch (_:Dynamic) {
			return NONE;
		}
		#elseif nodejs
		try {
			var stat = js.node.Fs.statSync(path);
			return new FileFacts(stat.isDirectory(), (stat.size : Float), stat.mtime.getTime());
		} catch (_:Dynamic) {
			return NONE;
		}
		#else
		return UNKNOWN;
		#end
	}

	#if jvm
	// A Java long as a Float, from its two halves.
	private static function __longToFloat(value:haxe.Int64):Float {
		var low:Float = haxe.Int64.getLow(value);
		if (low < 0) {
			low += 4294967296.0;
		}
		return haxe.Int64.getHigh(value) * 4294967296.0 + low;
	}
	#end
}
#end
