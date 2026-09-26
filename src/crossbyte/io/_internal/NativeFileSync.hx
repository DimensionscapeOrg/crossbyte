package crossbyte.io._internal;

#if cpp
/**
 * The file operations Haxe's standard library has no call for, on hxcpp.
 *
 * `sys.FileSystem.rename` is `_wrename` on Windows, which refuses to replace
 * an existing file, and there is no fsync at all.
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

	/** Flushes a directory's entries on POSIX; nothing on Windows. **/
	@:native("crossbyte_file_sync_directory")
	public static function syncDirectory(path:String):Void;
}
#end
