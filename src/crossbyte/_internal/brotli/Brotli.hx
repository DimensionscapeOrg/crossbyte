package crossbyte._internal.brotli;

import haxe.io.Bytes;
#if crossbyte_brotli_native
import crossbyte.brotli.NativeBrotli;
#end

@:noCompletion
class Brotli {
	public static inline function isNativeAvailable():Bool {
		#if crossbyte_brotli_native
		return NativeBrotli.isAvailable();
		#else
		return false;
		#end
	}

	public static inline function backendName():String {
		#if crossbyte_brotli_native
		return NativeBrotli.isAvailable() ? "native" : "haxe";
		#else
		return "haxe";
		#end
	}

	public static function compress(bytes:Bytes, quality:Int = 4):Bytes {
		if (quality < 0 || quality > 11) {
			throw "Brotli quality must be between 0 and 11";
		}

		#if crossbyte_brotli_native
		if (NativeBrotli.isAvailable()) {
			return NativeBrotli.compress(bytes, quality);
		}
		#end

		return PureBrotli.compress(bytes, quality);
	}

	/**
		@param maxOutputSize Bytes to produce before giving up, or `0` for no
		       limit. Brotli ratios have no ceiling, so anything decoding a
		       stream it did not author wants to name one.

		The pure decoder stops partway, inside the function every decoded byte
		passes through. The native one cannot: it returns a finished buffer, so
		its result is measured after the fact and the allocation has already
		happened. That path is opt-in and off by default.
	**/
	public static function decompress(bytes:Bytes, maxOutputSize:UInt = 0):Bytes {
		#if crossbyte_brotli_native
		if (NativeBrotli.isAvailable()) {
			var native:Bytes = NativeBrotli.decompress(bytes);
			if (maxOutputSize > 0 && native != null && native.length > maxOutputSize) {
				throw new haxe.Exception("Brotli stream exceeded " + maxOutputSize + " bytes");
			}
			return native;
		}
		#end

		return PureBrotli.decompress(bytes, maxOutputSize);
	}
}
