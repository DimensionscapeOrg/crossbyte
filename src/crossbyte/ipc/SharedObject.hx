package crossbyte.ipc;

import crossbyte.Object;
import crossbyte.errors.ArgumentError;
import haxe.Serializer;
import haxe.Unserializer;
import haxe.io.Bytes;
import haxe.io.BytesData;
#if (cpp && (windows || linux || mac || macos))
import crossbyte.ipc._internal.NativeSharedObject;
import crossbyte.ipc._internal.VoidPointer;
import cpp.Pointer;
#end

#if (cpp && (windows || linux || mac || macos))
private typedef SharedObjectHandle = VoidPointer;
#else
private typedef SharedObjectHandle = Dynamic;
#end

/**
 * `SharedObject` provides inter-process IPC through a shared memory region.
 *
 * This class allows multiple processes to read/write structured values in the same
 * memory-mapped region by name.
 */
#if (cpp && (windows || linux || mac || macos))
@:access(crossbyte.ipc._internal.NativeSharedObject)
#end
class SharedObject {
	public static inline var isSupported:Bool = #if (cpp && (windows || linux || mac || macos)) true #else false #end;

	/** Shared region name used to identify the underlying memory mapping. */
	public var name(default, null):String;

	/** Shared object payload. */
	public var data:Object;

	@:noCompletion private var __capacity:Int;
	@:noCompletion private var __serializer:Serializer;
	@:noCompletion private var __handle:SharedObjectHandle;

	/**
	 * Creates or opens a shared memory region.
	 *
	 * @param name        Shared memory region name.
	 * @param maxSize     Optional maximum payload size for new regions (bytes).
	 * @param defaultData Optional object to initialize from when no shared data exists.
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

		var payloadLength:Int = __readPayloadLength(__handle);
		if (payloadLength > 0 && payloadLength <= __capacity) {
			var payload:Bytes = Bytes.alloc(payloadLength);
			if (__read(__handle, payload.getData(), payloadLength) == payloadLength) {
				data = __unserializeData(payload.toString());
			}
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

	/** Reloads payload from shared memory into `data`. */
	public function sync():Void {
		__requireConnected();

		var payloadLength:Int = __readPayloadLength(__handle);
		if (payloadLength <= 0) {
			data = {};
			return;
		}

		if (payloadLength > __capacity) {
			payloadLength = __capacity;
		}

		var payload:Bytes = Bytes.alloc(payloadLength);
		var read:Int = __read(__handle, payload.getData(), payloadLength);
		if (read != payloadLength) {
			throw new ArgumentError("Shared payload read was incomplete");
		}

		var parsed:Dynamic = __unserializeData(payload.toString());
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

	@:noCompletion private function __unserializeData(payload:String):Object {
		try {
			return Unserializer.run(payload);
		} catch (_:Dynamic) {}
		return {};
	}

	@:noCompletion private function __requireConnected():Void {
		if (__handle == null) {
			throw new ArgumentError("SharedObject is not connected");
		}
	}

	@:noCompletion private static function __open(name:String, maxSize:Int):SharedObjectHandle {
		#if (cpp && (windows || linux || mac || macos))
		return NativeSharedObject.__open(name, maxSize);
		#else
		return null;
		#end
	}

	@:noCompletion private static function __close(handle:SharedObjectHandle):Void {
		#if (cpp && (windows || linux || mac || macos))
		NativeSharedObject.__close(handle);
		#end
	}

	@:noCompletion private static function __read(handle:SharedObjectHandle, buffer:BytesData, size:Int):Int {
		#if (cpp && (windows || linux || mac || macos))
		return NativeSharedObject.__read(handle, Pointer.ofArray(buffer), size);
		#else
		return -1;
		#end
	}

	@:noCompletion private static function __write(handle:SharedObjectHandle, buffer:BytesData, size:Int):Bool {
		#if (cpp && (windows || linux || mac || macos))
		return NativeSharedObject.__write(handle, Pointer.ofArray(buffer), size);
		#else
		return false;
		#end
	}

	@:noCompletion private static function __clear(handle:SharedObjectHandle):Void {
		#if (cpp && (windows || linux || mac || macos))
		NativeSharedObject.__clear(handle);
		#end
	}

	@:noCompletion private static function __readPayloadLength(handle:SharedObjectHandle):Int {
		#if (cpp && (windows || linux || mac || macos))
		return NativeSharedObject.__getDataLength(handle);
		#else
		return 0;
		#end
	}

	@:noCompletion private static function __getCapacity(handle:SharedObjectHandle):Int {
		#if (cpp && (windows || linux || mac || macos))
		return NativeSharedObject.__getCapacity(handle);
		#else
		return 0;
		#end
	}

	@:noCompletion private static inline function __requireSupported():Void {
		if (!isSupported) {
			throw new ArgumentError("SharedObject is only supported on cpp targets.");
		}
	}
}
