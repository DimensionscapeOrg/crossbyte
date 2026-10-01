package crossbyte.io._internal;

#if cpp
/**
 * The file operations Haxe's standard library has no call for, on hxcpp.
 *
 * `sys.FileSystem.rename` is `_wrename` on Windows, which refuses to replace
 * an existing file; `sys.FileSystem.stat` reports a size that is an Int; and
 * there is no fsync, and no way to create a file only if it is not there.
 */
@:buildXml('<include name="${haxelib:crossbyte}/src/crossbyte/io/_internal/NativeFileSyncBuild.xml"/>')
@:include("./NativeFileSync.h")
extern class NativeFileSync {
	/** Moves `from` over `to` atomically. Empty on success, else why not. **/
	@:native("crossbyte_file_replace")
	public static function replace(from:String, to:String):String;

	/** Flushes a file to stable storage. Empty on success, else why not. **/
	@:native("crossbyte_file_sync")
	public static function sync(path:String):String;

	/** A file's size, exact past 2 GB, or `-1` if it cannot be examined. **/
	@:native("crossbyte_file_size")
	public static function size(path:String):Float;

	/** Flushes a directory's entries on POSIX; nothing on Windows. **/
	@:native("crossbyte_file_sync_directory")
	public static function syncDirectory(path:String):Void;

	/** `0` created, `1` something was already there, `-1` any other failure. **/
	@:native("crossbyte_file_create_exclusive")
	public static function createExclusive(path:String, directory:Bool):Int;

	/**
		The file at `path` as `"<volume>:<index>"`, the same for every name it
		has, or `""` if it cannot be examined. hxcpp's `stat` has no index on
		Windows: it reports 0 for every file.
	**/
	@:native("crossbyte_file_identity")
	public static function identity(path:String):String;

	/** Cuts or extends a file to `length` bytes. Empty on success, else why not. **/
	@:native("crossbyte_file_truncate")
	public static function truncate(path:String, length:Float):String;

	/**
		When the file was created, in milliseconds since 1970: `-1` if the
		system keeps no creation time for it, `-2` if it cannot be examined.
		Not `stat`'s ctime, which on POSIX is when its status last changed.
	**/
	@:native("crossbyte_file_created")
	public static function created(path:String):Float;

	/**
		The file system's own path for `path` -- links followed, names in
		their case on disk -- or `""` if there is no such file.
	**/
	@:native("crossbyte_file_real_path")
	public static function realPath(path:String):String;

	/**
		`1` if Windows marks the file hidden, `0` if not, `-1` if it cannot be
		examined -- and always on POSIX, which keeps no such attribute.
	**/
	@:native("crossbyte_file_hidden")
	public static function hidden(path:String):Int;

	/**
		The bytes this process could still write on the volume the file or
		directory is on, or `-1` if it cannot be examined.
	**/
	@:native("crossbyte_file_space_available")
	public static function spaceAvailable(path:String):Float;
}
#end
