package crossbyte.ipc._internal;

import cpp.Pointer;
import crossbyte.ipc._internal.win.HANDLE;
import cpp.UInt8;

/**
 * ...
 * @author Christopher Speciale
 */
@:buildXml("
<files id='haxe'>
	<file name='../../src/crossbyte/ipc/_internal/NativeLocalConnection.cpp' if='windows'>
		<depend name='../../src/crossbyte/ipc/_internal/NativeLocalConnection.h'/>
	</file>
</files>
")
@:include("../../../../src/crossbyte/ipc/_internal/NativeLocalConnection.h")
extern class NativeLocalConnection {
	@:native('native_createInboundPipe') private static function __createInboundPipe(name:String):HANDLE;
	@:native('native_accept') private static function __accept(pipe:HANDLE):Bool;
	@:native('native_isOpen') private static function __isOpen(pipe:HANDLE):Bool;
	@:native('native_getBytesAvailable') private static function __getBytesAvailable(pipe:HANDLE):Int;
	@:native('native_read') private static function __read(pipe:HANDLE, buffer:Pointer<UInt8>, size:Int):Int;
	@:native('native_write') private static function __write(pipe:HANDLE, data:Pointer<UInt8>, size:Int):Bool;
	@:native('native_connect') private static function __connect(name:String):HANDLE;
	@:native('native_close') private static function __close(pipe:HANDLE):Void;
}
