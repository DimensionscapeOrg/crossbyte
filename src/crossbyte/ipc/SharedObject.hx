package crossbyte.ipc;

// Not built for the browser: shared memory and IPC handles between OS processes.
#if !js

import crossbyte.Object;
import crossbyte.errors.ArgumentError;
import crossbyte.errors.IOError;
#if !cpp
import crossbyte.crypto._internal.NativeOnly;
#end
import haxe.Serializer;
import crossbyte._internal.serial.BoundedUnserializer;
import haxe.io.Bytes;
import haxe.io.BytesData;
#if cpp
import crossbyte.ipc._internal.NativeSharedObject;
import crossbyte.ipc._internal.VoidPointer;
import cpp.Pointer;
#end

#if cpp
private typedef SharedObjectHandle = VoidPointer;
#else
private typedef SharedObjectHandle = Dynamic;
#end

/**
 * `SharedObject` provides inter-process IPC through a shared memory region.
 *
 * This class allows multiple processes to read/write structured values in the same
 * memory-mapped region by name.
 *
 * Each `flush()` replaces the whole payload, and each `sync()` reads one whole
 * payload, under a lock every participant takes: a sync never sees part of a
 * flush. The last flush wins; nothing merges what two participants changed.
 * The lock is waited for at most `lockTimeout`, five seconds by default.
 *
 * How long a region lives differs by OS. On Windows it goes when the last handle
 * to it closes, in whichever process, and the next process to open the name finds
 * it empty. On Linux and macOS it stays, holding what was last flushed and its
 * capacity in shared memory, until `remove(name)` takes it away or the machine
 * restarts: `clear()` only empties it. Name regions so that a fixed set is reused
 * rather than a new one made for each run, or remove each when done with it. On
 * macOS each name also has a small lock file, `/tmp/cbso_<hash>.lock`, which
 * stays with the region and goes with it: macOS cannot lock a region itself.
 * `remove(name)` is the only thing that takes it away; `close()` leaves it,
 * since other participants may hold it. If something else does -- macOS
 * deletes files in /tmp that nobody has touched for three days -- the next
 * participant to lock the region makes it again, and those already open
 * move to the new one before they read or write; a lock file in use has its
 * times brought up to date hourly, so that it is not found old.
 *
 * On Linux and macOS a region belongs to the user that made it: it is made
 * readable and writable by that user alone, as is its lock file, and one
 * under the name that another user made -- or a link, a FIFO or a
 * directory where a lock file should be -- is not used: the constructor,
 * or whichever call finds it, throws an `IOError` saying so. A region used
 * to be made readable by every local user, and one another user had made
 * first, writable by all, was shared with them. On Windows a region is in
 * the session's own namespace, and opened with the user's own default
 * permissions.
 */
#if cpp
@:access(crossbyte.ipc._internal.NativeSharedObject)
#end
class SharedObject {
	/**
	 * Whether this target has shared memory regions: natively (cpp) on Windows,
	 * Linux and macOS. Elsewhere the constructor throws an
	 * `IllegalOperationError` naming the target.
	 */
	public static inline var isSupported:Bool = #if cpp true #else false #end;

	/** Shared region name used to identify the underlying memory mapping. */
	public var name(default, null):String;

	/** Shared object payload. */
	public var data:Object;

	/**
		The longest, in milliseconds, that `flush()`, `sync()` and `clear()`
		wait for the region's lock. A participant holds it while it copies a
		payload in or out, which takes it microseconds; one stopped while
		holding it -- suspended in a debugger, sent SIGSTOP, starved on a
		loaded machine -- stopped every other participant with it, for as
		long as it stayed stopped. Past the deadline the call throws an
		`IOError` saying the region's lock was not released in time, and
		reads, writes and clears nothing.

		0 means no deadline. The default is 5,000 (five seconds), which is
		also as long as the constructor waits. A participant that dies
		holding the lock releases it, on every OS.
	**/
	public var lockTimeout:Int = DEFAULT_LOCK_TIMEOUT;

	@:noCompletion private static inline var DEFAULT_LOCK_TIMEOUT:Int = 5000;

	@:noCompletion private var __capacity:Int;
	@:noCompletion private var __serializer:Serializer;
	@:noCompletion private var __handle:SharedObjectHandle;
	// The length the last read found: the next one's first guess.
	@:noCompletion private var __expectedLength:Int = 0;

	/**
	 * Creates or opens a shared memory region.
	 *
	 * @param name        Shared memory region name.
	 * @param maxSize     Optional maximum payload size for new regions (bytes).
	 * @param defaultData Optional object to start from when the region holds nothing,
	 *                    or nothing this build can read -- another program's bytes,
	 *                    a value naming a class this build does not have, or values
	 *                    nested more than 256 deep. A flush then replaces what the
	 *                    region held.
	 * @throws IOError When another participant holds the region's lock for longer
	 *         than `lockTimeout`'s default, five seconds; or, on Linux and macOS,
	 *         when the region under the name, or its lock file, is not this
	 *         user's own.
	 */
	public function new(name:String, maxSize:Int = 65536, ?defaultData:Dynamic) {
		__requireSupported();
		if (name == null || name.length == 0) {
			throw new ArgumentError("SharedObject name cannot be empty");
		}
		if (maxSize < 1) {
			throw new ArgumentError("SharedObject maxSize must be greater than 0");
		}

		this.name = name;
		__serializer = new Serializer();
		__serializer.useCache = false;

		__handle = __open(name, maxSize, lockTimeout);
		if (__handle == null) {
			if (__lockTimedOut()) {
				throw __lockNotReleased();
			}
			if (__notOwned()) {
				throw __notOwnedError(name);
			}
			throw new ArgumentError("Failed to create or open shared object");
		}

		__capacity = __getCapacity(__handle, lockTimeout);
		if (__capacity <= 0) {
			if (__lockTimedOut()) {
				close();
				throw __lockNotReleased();
			}
			__capacity = maxSize;
		}

		// What the region holds when it can be read, and `defaultData`
		// otherwise. A payload that failed to parse -- or that a flush
		// elsewhere had cut short, when the length and the bytes were two
		// reads -- gave `{}` here, and `defaultData` was dropped. A lock not
		// released in time is not a region holding nothing: starting from
		// `defaultData` then, a flush would write it over what is there.
		var payload:Null<String>;
		try {
			payload = __readPayload();
		} catch (e:IOError) {
			close();
			throw e;
		}
		if (payload != null && payload.length > 0) {
			try {
				data = BoundedUnserializer.run(payload);
			} catch (_:Dynamic) {
				data = null;
			}
		}

		if (data == null) {
			data = defaultData == null ? {} : defaultData;
		}
	}

	/**
	 * Flushes `data` into shared memory immediately.
	 *
	 * @throws IOError When another participant holds the region's lock for
	 *         longer than `lockTimeout`. Nothing is written.
	 */
	public function flush():Void {
		__requireConnected();

		__resetSerializer();
		__serializer.serialize(data);
		var payload = Bytes.ofString(__serializer.toString());
		if (payload.length == 0) {
			payload = Bytes.alloc(0);
		}

		if (payload.length > __capacity) {
			throw new ArgumentError("Shared payload is larger than shared region capacity");
		}

		if (!__write(__handle, payload.getData(), payload.length, lockTimeout)) {
			if (__lockTimedOut()) {
				throw __lockNotReleased();
			}
			if (__notOwned()) {
				throw __notOwnedError(name);
			}
			throw new ArgumentError("Failed to write SharedObject payload");
		}
	}

	/**
	 * Reloads payload from shared memory into `data`: one whole payload, as one
	 * flush left it. An empty region gives `{}`.
	 *
	 * @throws IOError When the region holds a payload this build cannot read --
	 *         another program's bytes, a value naming a class this build does not
	 *         have, or values nested more than 256 deep -- or when another
	 *         participant holds the region's lock for longer than `lockTimeout`.
	 *         `data` keeps what it had: an empty object in its place would be
	 *         written over the region by the next flush. The nesting is bounded
	 *         because reading takes a frame per level: natively a payload nested
	 *         6,000 deep, which any process writing the region could leave,
	 *         overflowed the stack and ended the process reading it.
	 */
	public function sync():Void {
		__requireConnected();

		var payload:Null<String> = __readPayload();
		if (payload == null) {
			throw new IOError('SharedObject "$name" could not be read from shared memory.');
		}
		if (payload.length == 0) {
			data = {};
			return;
		}

		var parsed:Dynamic;
		try {
			parsed = BoundedUnserializer.run(payload);
		} catch (e:Dynamic) {
			throw new IOError('SharedObject "$name" holds a payload this build cannot read: $e');
		}
		data = parsed == null ? {} : parsed;
	}

	/**
	 * Clears the shared payload and resets local state.
	 *
	 * @throws IOError When another participant holds the region's lock for
	 *         longer than `lockTimeout`. Nothing is cleared, and `data` keeps
	 *         what it had.
	 */
	public function clear():Void {
		__requireConnected();
		if (!__clear(__handle, lockTimeout)) {
			throw __lockTimedOut() ? __lockNotReleased() : __notOwned() ? __notOwnedError(name) : new IOError('SharedObject "$name" could not be cleared.');
		}
		data = {};
	}

	/** Closes the connection to shared memory. */
	public function close():Void {
		if (__handle != null) {
			__close(__handle);
			__handle = null;
		}
	}

	/**
		Takes the region `name` away, so that the next `SharedObject` opened
		under the name starts a new, empty one. Handles already open on it, in
		this process or another, keep the region they have and go on sharing it
		until they close.

		On Linux and macOS a region outlives every handle until the machine
		restarts, and this is how it goes sooner -- on macOS with its lock file.
		On Windows a region goes when its last handle closes, in whichever
		process, and has no name to take away while one is open: `remove`
		does nothing there and answers `false`.

		@param name The name the region was opened under.
		@return Whether a region was removed: `false` when none had the name.
		@throws IOError When a region has the name and cannot be removed --
		        another user's, say -- or, on macOS, when another participant
		        holds its lock for longer than `lockTimeout`'s default, five
		        seconds.
	**/
	public static function remove(name:String):Bool {
		__requireSupported();
		if (name == null || name.length == 0) {
			throw new ArgumentError("SharedObject name cannot be empty");
		}
		#if cpp
		var removed:Int = NativeSharedObject.__remove(name, DEFAULT_LOCK_TIMEOUT);
		if (removed < 0) {
			throw __lockTimedOut() ? __lockError(name, DEFAULT_LOCK_TIMEOUT) : __notOwned() ? __notOwnedError(name) : new IOError('SharedObject "$name" could not be removed.');
		}
		return removed > 0;
		#else
		return false;
		#end
	}

	@:noCompletion private function __resetSerializer():Void {
		__serializer = new Serializer();
		__serializer.useCache = false;
	}

	/**
	 * The region's payload, its length and bytes read under one acquisition of
	 * the lock. They were two reads, and a flush between them left a copy cut
	 * to the old length, which failed to parse, or short of the new, which
	 * threw.
	 *
	 * Read into a buffer the size the last read found; one that is too small
	 * learns the length from the same call, and the third try takes the whole
	 * capacity, which every payload fits.
	 *
	 * Null when the region cannot be read; throws the `IOError` of a lock not
	 * released within `lockTimeout`.
	 */
	@:noCompletion private function __readPayload():Null<String> {
		var size:Int = __expectedLength;
		for (attempt in 0...3) {
			var buffer:Bytes = Bytes.alloc(size < 1 ? 1 : size);
			var length:Int = __read(__handle, buffer.getData(), buffer.length, lockTimeout);
			if (length < 0) {
				if (__lockTimedOut()) {
					throw __lockNotReleased();
				}
				if (__notOwned()) {
					throw __notOwnedError(name);
				}
				return null;
			}
			if (length <= buffer.length) {
				__expectedLength = length;
				return buffer.getString(0, length);
			}
			size = attempt == 0 ? length : __capacity;
		}
		return null;
	}

	@:noCompletion private function __requireConnected():Void {
		if (__handle == null) {
			throw new ArgumentError("SharedObject is not connected");
		}
	}

	@:noCompletion private function __lockNotReleased():IOError {
		return __lockError(name, lockTimeout);
	}

	@:noCompletion private static function __lockError(name:String, timeout:Int):IOError {
		return new IOError('SharedObject "$name": the region\'s lock was not released within $timeout ms');
	}

	/** Whether the last native call on this thread failed for a lock not released in time. */
	@:noCompletion private static function __lockTimedOut():Bool {
		#if cpp
		return NativeSharedObject.__lastError() == NativeSharedObject.ERROR_LOCK_TIMEOUT;
		#else
		return false;
		#end
	}

	/** Whether the last native call on this thread failed for something under the name that is not this user's. */
	@:noCompletion private static function __notOwned():Bool {
		#if cpp
		return NativeSharedObject.__lastError() == NativeSharedObject.ERROR_NOT_OWNED;
		#else
		return false;
		#end
	}

	@:noCompletion private static function __notOwnedError(name:String):IOError {
		return new IOError('SharedObject "$name": what is under the name -- the region, or on macOS its lock file -- '
			+ 'is not this user\'s own, and is not used: another user made it, or it is not a file of ours');
	}

	@:noCompletion private static function __open(name:String, maxSize:Int, lockTimeout:Int):SharedObjectHandle {
		#if cpp
		return NativeSharedObject.__open(name, maxSize, lockTimeout);
		#else
		return null;
		#end
	}

	@:noCompletion private static function __close(handle:SharedObjectHandle):Void {
		#if cpp
		NativeSharedObject.__close(handle);
		#end
	}

	/** The payload's length, and the payload copied into `buffer` when it fits; -1 when it cannot be read. */
	@:noCompletion private static function __read(handle:SharedObjectHandle, buffer:BytesData, size:Int, lockTimeout:Int):Int {
		#if cpp
		return NativeSharedObject.__readPayload(handle, Pointer.ofArray(buffer), size, lockTimeout);
		#else
		return -1;
		#end
	}

	@:noCompletion private static function __write(handle:SharedObjectHandle, buffer:BytesData, size:Int, lockTimeout:Int):Bool {
		#if cpp
		return NativeSharedObject.__write(handle, Pointer.ofArray(buffer), size, lockTimeout);
		#else
		return false;
		#end
	}

	/** Whether the region's lock was taken. */
	@:noCompletion private static function __clear(handle:SharedObjectHandle, lockTimeout:Int):Bool {
		#if cpp
		return NativeSharedObject.__clear(handle, lockTimeout);
		#else
		return false;
		#end
	}

	@:noCompletion private static function __getCapacity(handle:SharedObjectHandle, lockTimeout:Int):Int {
		#if cpp
		return NativeSharedObject.__getCapacity(handle, lockTimeout);
		#else
		return 0;
		#end
	}

	@:noCompletion private static inline function __requireSupported():Void {
		#if !cpp
		throw NativeOnly.error("SharedObject");
		#end
	}
}
#end
