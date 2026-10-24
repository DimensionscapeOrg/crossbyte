package crossbyte.ipc._internal;

// Not built for the browser: shared memory and IPC handles between OS processes.
#if !js

import cpp.Pointer;
import cpp.UInt8;
import crossbyte.ipc._internal.VoidPointer;

/**
 * Shared memory bindings for SharedObject: native-ipc's
 * `native_ipc/SharedMemory.h`, compiled in from the native-ipc haxelib.
 *
 * Every call that takes the region's lock waits at most `lockTimeoutMs` for
 * it, or for as long as it takes with 0 or less; `__lastError` then says why
 * a call failed.
 */
@:buildXml('<set name="NATIVE_IPC_NO_CHANNEL" value="1"/><include name="${haxelib:native-ipc}/project/Build.xml"/>')
@:keep
@:include("native_ipc/SharedMemory.h")
extern class NativeSharedObject {
	/** The last call on this thread did not fail. */
	public static inline var ERROR_NONE:Int = 0;

	/** Another participant held the region's lock past the call's deadline. */
	public static inline var ERROR_LOCK_TIMEOUT:Int = 1;

	/** The region could not be made, mapped, locked or read. */
	public static inline var ERROR_FAILED:Int = 2;

	/**
		Linux and macOS: what is under the name (the region, or on macOS its
		lock file) is not this user's own.
	**/
	public static inline var ERROR_NOT_OWNED:Int = 3;

	@:native('native_ipc_shm_open') private static function __open(name:String, maxSize:Int, lockTimeoutMs:Int):VoidPointer;
	@:native('native_ipc_shm_close') private static function __close(handle:VoidPointer):Void;
	/** The payload's length, and the payload copied into `buffer` when it fits; -1 when it cannot be read. **/
	@:native('native_ipc_shm_read') private static function __readPayload(handle:VoidPointer, buffer:Pointer<UInt8>, size:Int,
		lockTimeoutMs:Int):Int;
	@:native('native_ipc_shm_write') private static function __write(handle:VoidPointer, data:Pointer<UInt8>, size:Int, lockTimeoutMs:Int):Bool;
	/** Whether the region's lock was taken; a region not set up as one of ours is left as it is. **/
	@:native('native_ipc_shm_clear') private static function __clear(handle:VoidPointer, lockTimeoutMs:Int):Bool;
	@:native('native_ipc_shm_capacity') private static function __getCapacity(handle:VoidPointer, lockTimeoutMs:Int):Int;
	/** Why the last call on this thread failed: one of the `ERROR_` values. **/
	@:native('native_ipc_shm_last_error') private static function __lastError():Int;
	/** 1 when a region had the name and lost it, 0 when none had it (and always on Windows), -1 when it could not be done. **/
	@:native('native_ipc_shm_remove') private static function __remove(name:String, lockTimeoutMs:Int):Int;

	// Tests only: the region's lock, held on the calling thread until released
	// on the same thread: a participant stopped while holding it.
	@:native('native_ipc_shm_hold_lock_for_test') private static function __holdLockForTest(handle:VoidPointer):Bool;
	@:native('native_ipc_shm_release_lock_for_test') private static function __releaseLockForTest(handle:VoidPointer):Void;
}
#end
