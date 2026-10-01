package crossbyte.ipc._internal;

// Not built for the browser: shared memory and IPC handles between OS processes.
#if !js

import cpp.Pointer;
import cpp.UInt8;
import crossbyte.ipc._internal.VoidPointer;

/**
 * Shared memory bindings for SharedObject.
 */
@:buildXml('<include name="${haxelib:crossbyte}/src/crossbyte/ipc/_internal/NativeSharedObjectBuild.xml"/>')
@:keep
@:include("./NativeSharedObject.h")
extern class NativeSharedObject {
	@:native('native_sharedObjectOpen') private static function __open(name:String, maxSize:Int):VoidPointer;
	@:native('native_sharedObjectClose') private static function __close(handle:VoidPointer):Void;
	/** The payload's length, and the payload copied into `buffer` when it fits; -1 when it cannot be read. **/
	@:native('native_sharedObjectReadPayload') private static function __readPayload(handle:VoidPointer, buffer:Pointer<UInt8>, size:Int):Int;
	@:native('native_sharedObjectWrite') private static function __write(handle:VoidPointer, data:Pointer<UInt8>, size:Int):Bool;
	@:native('native_sharedObjectClear') private static function __clear(handle:VoidPointer):Void;
	@:native('native_sharedObjectGetCapacity') private static function __getCapacity(handle:VoidPointer):Int;
}
#end
