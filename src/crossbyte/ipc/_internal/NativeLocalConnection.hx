package crossbyte.ipc._internal;

// Not built for the browser: an OS-level IPC channel.
#if !js

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
	@:native('native_disconnect') private static function __disconnect(pipe:VoidPointer):Bool;
	@:native('native_writeSome') private static function __writeSome(pipe:VoidPointer, data:Pointer<UInt8>, size:Int):Int;
	@:native('native_isOpen') private static function __isOpen(pipe:VoidPointer):Bool;
	@:native('native_getBytesAvailable') private static function __getBytesAvailable(pipe:VoidPointer):Int;
	@:native('native_read') private static function __read(pipe:VoidPointer, buffer:Pointer<UInt8>, size:Int):Int;
	@:native('native_write') private static function __write(pipe:VoidPointer, data:Pointer<UInt8>, size:Int):Bool;
	@:native('native_connect') private static function __connect(name:String):VoidPointer;
	@:native('native_connectWithTimeout') private static function __connectWithTimeout(name:String, timeoutMs:Int):VoidPointer;
	@:native('native_close') private static function __close(pipe:VoidPointer):Void;
	/** Keeps a listener's lock file from looking unused: see NativeLocalConnection.cpp. **/
	@:native('native_keepName') private static function __keepName(pipe:VoidPointer):Void;

	/** The last listen or connect on this thread did not fail. **/
	public static inline var ERROR_NONE:Int = 0;

	/** The name is in use, nothing listens on it, or it cannot be used. **/
	public static inline var ERROR_FAILED:Int = 1;

	/** What is under the name is not this user's own. **/
	public static inline var ERROR_NOT_OWNED:Int = 2;

	/** Why the last `__createInboundPipe` or `__connectWithTimeout` on this thread failed: one of the `ERROR_` values. **/
	@:native('native_localConnectionLastError') private static function __lastError():Int;

	// Tests only: whether a listener's pipe admits anyone but this user and
	// SYSTEM, or another owns it. Always false off Windows.
	@:native('native_admitsOthersForTest') private static function __admitsOthersForTest(pipe:VoidPointer):Bool;

	/** The descriptor a reader waits on for `pipe`: -1 for none, and always on Windows. **/
	@:native('native_descriptorOf') private static function __descriptorOf(pipe:VoidPointer):Int;

	/** Waits up to `timeoutMs` for `fd` to be readable or writable, as asked: whether it woke for that. **/
	@:native('native_waitForWork') private static function __waitForWork(fd:Int, read:Bool, write:Bool, timeoutMs:Int):Bool;

	// Tests only: the buffer size asked of each socket connected or taken
	// from now on; 0 leaves the system's. Nothing on Windows.
	@:native('native_setSocketBufferForTest') private static function __setSocketBufferForTest(bytes:Int):Void;
}
#end
