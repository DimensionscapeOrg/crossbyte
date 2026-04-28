package crossbyte._internal.brotli;

import crossbyte._internal.brotli.codec.BrotliCodec;
import haxe.io.Bytes;

@:noCompletion
class PureBrotli {
	private static var __codec:BrotliCodec;

	public static function compress(bytes:Bytes, quality:Int = 4):Bytes {
		if (quality < 0 || quality > 11) {
			throw "Brotli quality must be between 0 and 11";
		}

		var encoded = __instance().compressArray(__bytesToArray(bytes), quality);
		return __arrayToBytes(encoded);
	}

	public static function decompress(bytes:Bytes):Bytes {
		var decoded = __instance().decompressArray(__bytesToArray(bytes));
		return __arrayToBytes(decoded);
	}

	private static function __instance():BrotliCodec {
		if (__codec == null) {
			__codec = new BrotliCodec();
		}
		return __codec;
	}

	private static function __bytesToArray(bytes:Bytes):Array<UInt> {
		if (bytes == null || bytes.length == 0) {
			return [];
		}

		var out:Array<UInt> = [];
		out.resize(bytes.length);
		for (i in 0...bytes.length) {
			out[i] = bytes.get(i);
		}
		return out;
	}

	private static function __arrayToBytes(values:Array<UInt>):Bytes {
		var length = values != null ? values.length : 0;
		var out = Bytes.alloc(length);
		for (i in 0...length) {
			out.set(i, values[i] & 0xFF);
		}
		return out;
	}
}
