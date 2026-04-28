package crossbyte._internal.brotli.codec;

import crossbyte._internal.brotli.codec.decode.Decode.*;
import crossbyte._internal.brotli.codec.decode.Streams.*;
import crossbyte._internal.brotli.codec.decode.streams.BrotliInput;
import crossbyte._internal.brotli.codec.decode.streams.BrotliOutput;
import crossbyte._internal.brotli.codec.encode.Dictionary_hash;
import crossbyte._internal.brotli.codec.encode.Encode.*;
import crossbyte._internal.brotli.codec.encode.Static_dict_lut;
import crossbyte._internal.brotli.codec.encode.encode.BrotliParams;
import crossbyte._internal.brotli.codec.encode.static_dict_lut.DictWord;
import crossbyte._internal.brotli.codec.encode.streams.BrotliMemIn;
import crossbyte._internal.brotli.codec.encode.streams.BrotliMemOut;
import crossbyte._internal.brotli.codec.dictionary.DictionaryBuckets;
import crossbyte._internal.brotli.codec.dictionary.DictionaryHash;
import crossbyte._internal.brotli.codec.dictionary.DictionaryWords;
import haxe.ds.Vector;

typedef EncodeDictionary = crossbyte._internal.brotli.codec.encode.Dictionary;
typedef DecodeDictionary = crossbyte._internal.brotli.codec.decode.Dictionary;

@:noCompletion
class BrotliCodec {
	private static var __initialized:Bool = false;

	public function new() {
		if (__initialized) {
			return;
		}
		__initialized = true;
		__initializeDictionaries();
	}

	public function decompressArray(content:Array<UInt>):Array<UInt> {
		var output = new Array<UInt>();
		var input:BrotliInput = BrotliInitMemInput(content, content.length);
		var decoded:BrotliOutput = BrotliInitMemOutput(output);

		if (BrotliDecompress(input, decoded) != 1) {
			throw "Brotli decompression failed";
		}

		return decoded.data_.buffer.slice(0, decoded.data_.pos);
	}

	public function compressArray(content:Array<UInt>, quality:Int):Array<UInt> {
		if (quality < 0 || quality > 11) {
			throw "Brotli quality must be between 0 and 11";
		}

		var params = new BrotliParams();
		params.quality = quality;

		var output = new BrotliMemOut(new Array<UInt>());
		if (!BrotliCompress(params, new BrotliMemIn(content, content.length), output)) {
			throw "Brotli compression failed";
		}

		return output.buf_.slice(0, output.position());
	}

	private static function __initializeDictionaries():Void {
		var dictionary = Vector.fromArrayCopy(crossbyte._internal.brotli.codec.dictionary.Dictionary.contents);
		var dictionaryHash = Vector.fromArrayCopy(DictionaryHash.contents);
		var dictionaryWords = Vector.fromArrayCopy(DictionaryWords.contents);
		var dictionaryBuckets = Vector.fromArrayCopy(DictionaryBuckets.contents);

		EncodeDictionary.kBrotliDictionary = dictionary;
		DecodeDictionary.kBrotliDictionary = dictionary;

		var staticDictionaryHash = Dictionary_hash.kStaticDictionaryHash;
		var staticDictionaryBuckets = Static_dict_lut.kStaticDictionaryBuckets;
		for (i in 0...32768) {
			staticDictionaryHash.push(__readU16(dictionaryHash, i * 2));
			staticDictionaryBuckets.push(__readU24(dictionaryBuckets, i * 3));
		}

		var staticDictionaryWords = Static_dict_lut.kStaticDictionaryWords;
		for (i in 0...31704) {
			var offset = i * 3;
			var second = __readByte(dictionaryWords, offset + 1);
			var len = second >> 3;
			var idx = ((second & 7) << 8) | __readByte(dictionaryWords, offset);
			var transform = __readByte(dictionaryWords, offset + 2);
			staticDictionaryWords.push(new DictWord(len, transform, idx));
		}
	}

	private static inline function __readByte(bytes:Vector<UInt>, offset:Int):UInt {
		return offset >= 0 && offset < bytes.length ? bytes[offset] : 0;
	}

	private static inline function __readU16(bytes:Vector<UInt>, offset:Int):UInt {
		return (__readByte(bytes, offset + 1) << 8) | __readByte(bytes, offset);
	}

	private static inline function __readU24(bytes:Vector<UInt>, offset:Int):UInt {
		return (__readByte(bytes, offset + 2) << 16) | (__readByte(bytes, offset + 1) << 8) | __readByte(bytes, offset);
	}
}
