package crossbyte._internal.brotli;

import crossbyte._internal.brotli.codec.BrotliCodec;
import haxe.io.Bytes;

@:noCompletion
class PureBrotli {
	public static function compress(bytes:Bytes, quality:Int = 4):Bytes {
		if (quality < 0 || quality > 11) {
			throw "Brotli quality must be between 0 and 11";
		}

		return BrotliCodec.compress(bytes, quality);
	}

	public static function decompress(bytes:Bytes, maxOutputSize:UInt = 0):Bytes {
		return BrotliCodec.decompress(bytes, maxOutputSize);
	}
}
