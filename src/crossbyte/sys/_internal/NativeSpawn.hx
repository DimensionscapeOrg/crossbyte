package crossbyte.sys._internal;

#if cpp
import haxe.io.BytesData;

/**
	A child process started in a directory and with an environment of the
	caller's choosing, which hxcpp's own `process_run` cannot do; see
	`NativeSpawn.h`. `ChildProcess` is what uses it.
**/
@:buildXml('<include name="${haxelib:crossbyte}/src/crossbyte/sys/_internal/NativeSpawnBuild.xml"/>')
@:include("./NativeSpawn.h")
extern class NativeSpawn {
	@:native("crossbyte_spawn_start")
	public static function start(executable:String, arguments:Array<String>, directory:Null<String>, environment:Null<Array<String>>):Dynamic;

	@:native("crossbyte_spawn_read")
	public static function read(handle:Dynamic, fromError:Bool, buffer:BytesData, offset:Int, length:Int):Int;

	@:native("crossbyte_spawn_write")
	public static function write(handle:Dynamic, buffer:BytesData, offset:Int, length:Int):Int;

	@:native("crossbyte_spawn_close_input")
	public static function closeInput(handle:Dynamic):Void;

	@:native("crossbyte_spawn_kill")
	public static function kill(handle:Dynamic):Void;

	@:native("crossbyte_spawn_wait")
	public static function wait(handle:Dynamic):Int;

	@:native("crossbyte_spawn_pid")
	public static function pid(handle:Dynamic):Int;

	@:native("crossbyte_spawn_close")
	public static function close(handle:Dynamic):Void;
}
#end
