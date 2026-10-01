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
import haxe.Unserializer;
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
 *
 * How long a region lives differs by OS. On Windows it goes when the last handle
 * to it closes, in whichever process, and the next process to open the name finds
 * it empty. On Linux and macOS it stays, holding what was last flushed and its
 * capacity in shared memory, until the machine restarts: `clear()` empties it,
 * and nothing here removes it. Name regions so that a fixed set is reused rather
 * than a new one made for each run. On macOS each name also has a small lock file,
 * `/tmp/cbso_<hash>.lock`, which stays with it: macOS cannot lock a region
 * itself.
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
	 *                    or nothing this build can read, another program's bytes,
	 *                    or a value naming a class this build does not have. A flush
	 *                    then replaces what the region held.
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

		__handle = __open(name, maxSize);
		if (__handle == null) {
			throw new ArgumentError("Failed to create or open shared object");
		}

		__capacity = __getCapacity(__handle);
		if (__capacity <= 0) {
			__capacity = maxSize;
		}

		// What the region holds when it can be read, and `defaultData`
		// otherwise. A payload that failed to parse, or that a flush
		// elsewhere had cut short, when the length and the bytes were two
		// reads, gave `{}` here, and `defaultData` was dropped.
		try {
			var payload:String = __readPayload();
			if (payload.length > 0) {
				data = Unserializer.run(payload);
			}
		} catch (_:Dynamic) {
			data = null;
		}

		if (data == null) {
			data = defaultData == null ? {} : defaultData;
		}
	}

	/** Flushes `data` into shared memory immediately. */
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

		if (!__write(__handle, payload.getData(), payload.length)) {
			throw new ArgumentError("Failed to write SharedObject payload");
		}
	}

	/**
	 * Reloads payload from shared memory into `data`: one whole payload, as one
	 * flush left it. An empty region gives `{}`.
	 *
	 * @throws IOError When the region holds a payload this build cannot read,
	 *         another program's bytes, or a value naming a class this build does
	 *         not have. `data` keeps what it had: an empty object in its place
	 *         would be written over the region by the next flush.
	 */
	public function sync():Void {
		__requireConnected();

		var payload:String = __readPayload();
		if (payload.length == 0) {
			data = {};
			return;
		}

		var parsed:Dynamic;
		try {
			parsed = Unserializer.run(payload);
		} catch (e:Dynamic) {
			throw new IOError('SharedObject "$name" holds a payload this build cannot read: $e');
		}
		data = parsed == null ? {} : parsed;
	}

	/** Clears the shared payload and resets local state. */
	public function clear():Void {
		__requireConnected();
		__clear(__handle);
		data = {};
	}

	/** Closes the connection to shared memory. */
	public function close():Void {
		if (__handle != null) {
			__close(__handle);
			__handle = null;
		}
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
	 */
	@:noCompletion private function __readPayload():String {
		var size:Int = __expectedLength;
		for (attempt in 0...3) {
			var buffer:Bytes = Bytes.alloc(size < 1 ? 1 : size);
			var length:Int = __read(__handle, buffer.getData(), buffer.length);
			if (length < 0) {
				break;
			}
			if (length <= buffer.length) {
				__expectedLength = length;
				return buffer.getString(0, length);
			}
			size = attempt == 0 ? length : __capacity;
		}
		throw new IOError('SharedObject "$name" could not be read from shared memory.');
	}

	@:noCompletion private function __requireConnected():Void {
		if (__handle == null) {
			throw new ArgumentError("SharedObject is not connected");
		}
	}

	@:noCompletion private static function __open(name:String, maxSize:Int):SharedObjectHandle {
		#if cpp
		return NativeSharedObject.__open(name, maxSize);
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
	@:noCompletion private static function __read(handle:SharedObjectHandle, buffer:BytesData, size:Int):Int {
		#if cpp
		return NativeSharedObject.__readPayload(handle, Pointer.ofArray(buffer), size);
		#else
		return -1;
		#end
	}

	@:noCompletion private static function __write(handle:SharedObjectHandle, buffer:BytesData, size:Int):Bool {
		#if cpp
		return NativeSharedObject.__write(handle, Pointer.ofArray(buffer), size);
		#else
		return false;
		#end
	}

	@:noCompletion private static function __clear(handle:SharedObjectHandle):Void {
		#if cpp
		NativeSharedObject.__clear(handle);
		#end
	}

	@:noCompletion private static function __getCapacity(handle:SharedObjectHandle):Int {
		#if cpp
		return NativeSharedObject.__getCapacity(handle);
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
