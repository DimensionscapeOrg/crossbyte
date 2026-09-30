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
import haxe.io.Bytes;

typedef EncodeDictionary = crossbyte._internal.brotli.codec.encode.Dictionary;
typedef DecodeDictionary = crossbyte._internal.brotli.codec.decode.Dictionary;

/**
	The pure Haxe Brotli codec: Google's reference encoder and decoder, ported,
	behind two calls.

	Both read the static dictionary and the lookup tables built from it, which
	are built once, on first use, by whichever thread gets here first. See
	`__ready` for how the others wait for that.
**/
@:noCompletion
class BrotliCodec {
	/*
	 * Whether the dictionary and its tables are built: 0 until they are, then
	 * 1. Set with a barrier as the last thing the build does and read with
	 * one, so a thread that sees 1 sees every table complete.
	 *
	 * It used to be a Bool set as the build began. A second thread arriving
	 * during the build saw it set and decoded against tables that were null
	 * or half filled -- the build pushes into arrays the encoder reads -- which
	 * natively was a segfault and on the jvm a NullPointerException. URLLoader
	 * decodes on up to sixteen pool threads, so a burst of loads at startup
	 * is a first use on several threads at once.
	 *
	 * An Int read atomically rather than a lock taken on every call: on cpp a
	 * Mutex enters and leaves a GC-free zone, about 250ns, and this sits in
	 * front of every request body and response the codec handles.
	 */
	#if (java || jvm)
	@:volatile
	#end
	@:noCompletion private static var __ready:Int = 0;

	#if target.threaded
	/** Held while the tables are built, so they are built once. **/
	@:noCompletion private static final __building:sys.thread.Mutex = new sys.thread.Mutex();
	#end

	/**
		@param maxOutputSize Bytes the result may reach before this gives up,
		       or `0` for no limit.
	**/
	public static function decompress(input:Bytes, maxOutputSize:Int = 0):Bytes {
		ensureTables();

		var content:Array<UInt> = __bytesToArray(input);
		var output = new Array<UInt>();
		var source:BrotliInput = BrotliInitMemInput(content, content.length);
		var decoded:BrotliOutput = BrotliInitMemOutput(output, maxOutputSize);

		if (BrotliDecompress(source, decoded) != 1) {
			throw "Brotli decompression failed";
		}

		return __arrayToBytes(decoded.data_.buffer, decoded.data_.pos);
	}

	public static function compress(input:Bytes, quality:Int):Bytes {
		if (quality < 0 || quality > 11) {
			throw "Brotli quality must be between 0 and 11";
		}

		ensureTables();

		var content:Array<UInt> = __bytesToArray(input);
		var params = new BrotliParams();
		params.quality = quality;

		var output = new BrotliMemOut(new Array<UInt>());
		if (!BrotliCompress(params, new BrotliMemIn(content, content.length), output)) {
			throw "Brotli compression failed";
		}

		return __arrayToBytes(output.buf_, output.position());
	}

	/** Builds the dictionary tables if no thread has yet. **/
	public static inline function ensureTables():Void {
		if (!__tablesReady()) {
			__buildTables();
		}
	}

	/**
		Forgets the tables, so a test can send several threads through their
		first use at once. Nothing may be using the codec while it runs.
	**/
	@:noCompletion public static function __forgetTables():Void {
		#if target.threaded
		__building.acquire();
		#end
		__publish(0);
		EncodeDictionary.kBrotliDictionary = null;
		DecodeDictionary.kBrotliDictionary = null;
		Dictionary_hash.kStaticDictionaryHash = null;
		Static_dict_lut.kStaticDictionaryBuckets = null;
		Static_dict_lut.kStaticDictionaryWords = null;
		#if target.threaded
		__building.release();
		#end
	}

	@:noCompletion private static inline function __tablesReady():Bool {
		#if cpp
		return (untyped __cpp__("_hx_atomic_load(&{0})", __ready) : Int) == 1;
		#elseif (neko || hl)
		// No barrier to read with here, so the lock is the barrier. It is
		// only contended while the tables are being built.
		__building.acquire();
		var ready:Bool = __ready == 1;
		__building.release();
		return ready;
		#else
		return __ready == 1;
		#end
	}

	@:noCompletion private static inline function __publish(state:Int):Void {
		#if cpp
		untyped __cpp__("_hx_atomic_store(&{0}, {1})", __ready, state);
		#else
		__ready = state;
		#end
	}

	@:noCompletion private static function __buildTables():Void {
		#if target.threaded
		__building.acquire();
		try {
		#end
			// Read plainly: the lock orders it against the build that set it.
			if (__ready == 0) {
				__fillTables();
				__publish(1);
			}
		#if target.threaded
		} catch (e:haxe.Exception) {
			__building.release();
			throw e;
		}
		__building.release();
		#end
	}

	/**
		Builds every table into a fresh array and assigns each only once it is
		complete. The encoder reads them through these statics, and nothing may
		read them before `__ready` says 1.
	**/
	@:noCompletion private static function __fillTables():Void {
		var dictionaryBytes:Bytes = crossbyte._internal.brotli.codec.dictionary.Dictionary.decode();
		var dictionary = new Vector<UInt>(dictionaryBytes.length);
		for (i in 0...dictionaryBytes.length) {
			dictionary[i] = dictionaryBytes.get(i);
		}

		var hashBytes:Bytes = DictionaryHash.decode();
		var bucketBytes:Bytes = DictionaryBuckets.decode();
		var staticDictionaryHash:Array<UInt> = [];
		var staticDictionaryBuckets:Array<UInt> = [];
		for (i in 0...32768) {
			staticDictionaryHash.push(__readU16(hashBytes, i * 2));
			staticDictionaryBuckets.push(__readU24(bucketBytes, i * 3));
		}

		var wordBytes:Bytes = DictionaryWords.decode();
		var staticDictionaryWords:Array<DictWord> = [];
		for (i in 0...31704) {
			var offset = i * 3;
			var second = __readByte(wordBytes, offset + 1);
			var len = second >> 3;
			var idx = ((second & 7) << 8) | __readByte(wordBytes, offset);
			var transform = __readByte(wordBytes, offset + 2);
			staticDictionaryWords.push(new DictWord(len, transform, idx));
		}

		EncodeDictionary.kBrotliDictionary = dictionary;
		DecodeDictionary.kBrotliDictionary = dictionary;
		Dictionary_hash.kStaticDictionaryHash = staticDictionaryHash;
		Static_dict_lut.kStaticDictionaryBuckets = staticDictionaryBuckets;
		Static_dict_lut.kStaticDictionaryWords = staticDictionaryWords;
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

	private static function __arrayToBytes(values:Array<UInt>, length:Int):Bytes {
		var out = Bytes.alloc(length);
		for (i in 0...length) {
			out.set(i, values[i] & 0xFF);
		}
		return out;
	}

	private static inline function __readByte(bytes:Bytes, offset:Int):UInt {
		return offset >= 0 && offset < bytes.length ? bytes.get(offset) : 0;
	}

	private static inline function __readU16(bytes:Bytes, offset:Int):UInt {
		return (__readByte(bytes, offset + 1) << 8) | __readByte(bytes, offset);
	}

	private static inline function __readU24(bytes:Bytes, offset:Int):UInt {
		return (__readByte(bytes, offset + 2) << 16) | (__readByte(bytes, offset + 1) << 8) | __readByte(bytes, offset);
	}
}
