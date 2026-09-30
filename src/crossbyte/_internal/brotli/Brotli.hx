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
			throw new crossbyte.errors.ArgumentError("Brotli quality must be between 0 and 11, not " + quality);
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

		The pure decoder refuses a meta-block that announces more than that as
		its header is read, and otherwise stops partway, where every decoded
		byte passes through. Its memory follows its output: the ring buffer
		grows with what has been decoded rather than being allocated at the
		window size the stream asks for. The native one cannot stop partway: it
		returns a finished buffer, so its result is measured after the fact and
		the allocation has already happened. That path is opt-in and off by
		default.

		@throws crossbyte.errors.IOError The data is not a valid Brotli stream.
		@throws crossbyte.errors.RangeError It decodes past `maxOutputSize`.
	**/
	public static function decompress(bytes:Bytes, maxOutputSize:UInt = 0):Bytes {
		#if crossbyte_brotli_native
		if (NativeBrotli.isAvailable()) {
			var native:Bytes = try {
				NativeBrotli.decompress(bytes);
			} catch (e:String) {
				throw new crossbyte.errors.IOError("Invalid Brotli data: " + e);
			}
			if (maxOutputSize > 0 && native != null && native.length > maxOutputSize) {
				throw new crossbyte.errors.RangeError("Brotli stream exceeded " + maxOutputSize + " bytes");
			}
			return native;
		}
		#end

		return PureBrotli.decompress(bytes, maxOutputSize);
	}
}
