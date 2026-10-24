package crossbyte.ipc._internal;

// Not built for the browser: an OS-level IPC channel.
#if !js

import cpp.Pointer;
import cpp.UInt8;
import crossbyte.ipc._internal.VoidPointer;

/**
 * native-ipc's primitives (`native_ipc/Pipe.h`), which `LocalConnection`
 * runs its reader thread over. Compiled in from the native-ipc haxelib, with
 * every call that waits doing so outside the collector's reach.
 *
 * A handle is a listener or a connection: `__listen` makes the first, and
 * `__accept` and `__connect` the second.
 */
@:buildXml('<set name="NATIVE_IPC_NO_CHANNEL" value="1"/><include name="${haxelib:native-ipc}/project/Build.xml"/>')
@:keep
@:include("native_ipc/Pipe.h")
extern class NativeLocalConnection {
	@:native('native_ipc_listen') private static function __listen(name:String):VoidPointer;
	/** A client the listener has taken, as a connection of its own; null when there is none yet. **/
	@:native('native_ipc_accept') private static function __accept(listener:VoidPointer):VoidPointer;
	@:native('native_ipc_connect') private static function __connect(name:String, timeoutMs:Int):VoidPointer;
	@:native('native_ipc_close') private static function __close(handle:VoidPointer):Void;
	@:native('native_ipc_bytes_available') private static function __getBytesAvailable(connection:VoidPointer):Int;
	@:native('native_ipc_read') private static function __read(connection:VoidPointer, buffer:Pointer<UInt8>, size:Int):Int;
	@:native('native_ipc_write_some') private static function __writeSome(connection:VoidPointer, data:Pointer<UInt8>, size:Int):Int;
	@:native('native_ipc_write') private static function __write(connection:VoidPointer, data:Pointer<UInt8>, size:Int):Bool;
	@:native('native_ipc_is_open') private static function __isOpen(connection:VoidPointer):Bool;
	/** Keeps a listener's lock file from looking unused: see native_ipc_keep_name. **/
	@:native('native_ipc_keep_name') private static function __keepName(handle:VoidPointer):Void;

	/** The last listen, accept or connect on this thread did not fail. **/
	public static inline var ERROR_NONE:Int = 0;

	/** The name cannot be used, or something else failed. **/
	public static inline var ERROR_FAILED:Int = 1;

	/** What is under the name is not this user's own. **/
	public static inline var ERROR_NOT_OWNED:Int = 2;

	/** The peer does not speak native-ipc's protocol, or this version of it. **/
	public static inline var ERROR_PROTOCOL:Int = 3;

	/** Another listener of this user's has the name. **/
	public static inline var ERROR_IN_USE:Int = 4;

	/** Nothing listened on the name, or took this client, in the time allowed. **/
	public static inline var ERROR_TIMEOUT:Int = 5;

	/** Why the last `__listen`, `__accept` or `__connect` on this thread failed: one of the `ERROR_` values. **/
	@:native('native_ipc_last_error') private static function __lastError():Int;

	// Tests only: whether a listener's pipe admits anyone but this user and
	// SYSTEM, or another owns it. Always false off Windows.
	@:native('native_ipc_admits_others_for_test') private static function __admitsOthersForTest(listener:VoidPointer):Bool;

	/** What a reader waits on for `handle`: its socket on Linux and macOS, its doorbell on Windows; -1 for none. **/
	@:native('native_ipc_descriptor_of') private static function __descriptorOf(handle:VoidPointer):Int;

	/** Waits up to `timeoutMs` for `fd` to be readable or writable, as asked: whether it woke for that. **/
	@:native('native_ipc_wait_for_work') private static function __waitForWork(fd:Int, read:Bool, write:Bool, timeoutMs:Int):Bool;

	// Tests only: the buffer size asked of each socket connected or taken
	// from now on; 0 leaves the system's. Nothing on Windows.
	@:native('native_ipc_set_socket_buffer_for_test') private static function __setSocketBufferForTest(bytes:Int):Void;
}
#end
