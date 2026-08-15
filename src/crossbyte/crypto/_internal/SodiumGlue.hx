package crossbyte.crypto._internal;

#if cpp
import cpp.ConstPointer;
import cpp.Pointer;
import cpp.RawPointer;
import cpp.UInt8;
import haxe.io.Bytes;

/**
 * Shared pointer/availability glue for the public libsodium wrappers.
 */
@:noCompletion
class SodiumGlue {
	private static final __emptyBytes:Bytes = Bytes.alloc(1);

	public static inline function ptr(bytes:Bytes):RawPointer<UInt8> {
		return cast Pointer.arrayElem(bytes.getData(), 0);
	}

	public static inline function cptr(bytes:Bytes):ConstPointer<UInt8> {
		return Pointer.arrayElem(bytes.getData(), 0);
	}

	public static inline function cptrOrEmpty(bytes:Bytes):ConstPointer<UInt8> {
		return (bytes == null || bytes.length == 0) ? Pointer.arrayElem(__emptyBytes.getData(), 0) : Pointer.arrayElem(bytes.getData(), 0);
	}

	public static inline function len(bytes:Bytes):Int {
		return bytes == null ? 0 : bytes.length;
	}

	public static function availabilityMessage():String {
		var message = NativeSodium.statusMessage();
		return (message == null || message == "") ? "libsodium status is unavailable." : message;
	}

	public static function ensureAvailable():Void {
		if (!NativeSodium.isAvailable()) {
			throw availabilityMessage();
		}
	}
}
#end
