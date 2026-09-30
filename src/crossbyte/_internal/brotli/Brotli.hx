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
		window size the stream asks for.

		The native one, from `crossbyte-brotli` with `-D crossbyte_brotli_native`,
		is handed the limit as well: it is given room for that much output and
		stopped when it asks for more, by which time it may have decoded up to
		one window ahead into its ring buffer, 16 MB at most. It used to decode
		the whole stream and leave the measuring to this function, afterwards.

		@throws crossbyte.errors.IOError The data is not a valid Brotli stream.
		@throws crossbyte.errors.RangeError It decodes past `maxOutputSize`.
	**/
	public static function decompress(bytes:Bytes, maxOutputSize:UInt = 0):Bytes {
		#if crossbyte_brotli_native
		if (NativeBrotli.isAvailable()) {
			// It stops at the limit itself, and throws the same two errors.
			return NativeBrotli.decompress(bytes, maxOutputSize);
		}
		#end

		return PureBrotli.decompress(bytes, maxOutputSize);
	}
}
