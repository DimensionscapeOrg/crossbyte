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

	public static function decompress(bytes:Bytes):Bytes {
		#if crossbyte_brotli_native
		if (NativeBrotli.isAvailable()) {
			return NativeBrotli.decompress(bytes);
		}
		#end

		return PureBrotli.decompress(bytes);
	}
}
