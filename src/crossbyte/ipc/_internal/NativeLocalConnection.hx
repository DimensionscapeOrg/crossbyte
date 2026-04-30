package crossbyte.ipc._internal;

import cpp.Pointer;
import cpp.UInt8;
import crossbyte.ipc._internal.VoidPointer;

/**
 * ...
 * @author Christopher Speciale
 */
@:buildXml('<include name="${haxelib:crossbyte}/src/crossbyte/ipc/_internal/NativeLocalConnectionBuild.xml"/>')
@:keep
@:include("./NativeLocalConnection.h")
extern class NativeLocalConnection {
	@:native('native_createInboundPipe') private static function __createInboundPipe(name:String):VoidPointer;
	@:native('native_accept') private static function __accept(pipe:VoidPointer):Bool;
	@:native('native_isOpen') private static function __isOpen(pipe:VoidPointer):Bool;
	@:native('native_getBytesAvailable') private static function __getBytesAvailable(pipe:VoidPointer):Int;
	@:native('native_read') private static function __read(pipe:VoidPointer, buffer:Pointer<UInt8>, size:Int):Int;
	@:native('native_write') private static function __write(pipe:VoidPointer, data:Pointer<UInt8>, size:Int):Bool;
	@:native('native_connect') private static function __connect(name:String):VoidPointer;
	@:native('native_close') private static function __close(pipe:VoidPointer):Void;
}
