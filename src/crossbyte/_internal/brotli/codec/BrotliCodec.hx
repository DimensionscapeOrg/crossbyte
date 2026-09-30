package crossbyte._internal.brotli.codec;

import crossbyte._internal.brotli.codec.decode.Decode.*;
import crossbyte._internal.brotli.codec.decode.streams.BrotliOutput;
import crossbyte._internal.brotli.codec.encode.Dictionary_hash;
import crossbyte._internal.brotli.codec.encode.Static_dict_lut;
import crossbyte._internal.brotli.codec.encode.encode.BrotliCompressor;
import crossbyte._internal.brotli.codec.encode.encode.BrotliParams;
import crossbyte._internal.brotli.codec.encode.static_dict_lut.DictWord;
import crossbyte._internal.brotli.codec.dictionary.DictionaryBuckets;
import crossbyte._internal.brotli.codec.dictionary.DictionaryHash;
import crossbyte._internal.brotli.codec.dictionary.DictionaryWords;
import crossbyte.errors.ArgumentError;
import crossbyte.errors.IOError;
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

		// Read where it lies and written to Bytes, where this used to copy the
		// input into an Array<UInt> and the output out of one: several bytes
		// of memory per byte on every target, eight or more on Node.
		var output = new BrotliOutput(maxOutputSize);
		if (BrotliDecompress(input == null ? Bytes.alloc(0) : input, output) != 1) {
			// An IOError, as every codec here throws for data it cannot read,
			// so a caller can tell a damaged stream from a fault in the code.
			// This was a bare String, which the HTTP client took for the name
			// of an unsupported content coding.
			throw new IOError("Invalid Brotli data");
		}

		return output.getBytes();
	}

	public static function compress(input:Bytes, quality:Int):Bytes {
		if (quality < 0 || quality > 11) {
			throw new ArgumentError("Brotli quality must be between 0 and 11, not " + quality);
		}

		ensureTables();

		var length:Int = input == null ? 0 : input.length;
		var params = new BrotliParams();
		params.quality = quality;
		params.lgwin = windowBitsFor(length);

		// The whole input is here, so the compressor is told its size and
		// sizes its ring buffer and tables to it, and is fed straight from
		// the Bytes, a block at a time. It used to be handed an Array<UInt>
		// copy through a reader that copied each block again, and to build a
		// window's worth of everything whatever the input.
		var compressor = new BrotliCompressor(params, length);
		var blockSize:Int = compressor.input_block_size();
		var output = new haxe.io.BytesBuffer();
		var outSize:Array<Int> = [0];
		var out:Array<Vector<UInt>> = [];
		var offset:Int = 0;
		var last:Bool = false;
		while (!last) {
			var n:Int = length - offset < blockSize ? length - offset : blockSize;
			if (n > 0) {
				compressor.CopyBytesToRingBuffer(input, offset, n);
				offset += n;
			}
			last = offset >= length;
			outSize[0] = 0;
			if (!compressor.WriteBrotliData(last, false, outSize, out)) {
				throw "Brotli compression failed";
			}
			var storage:Vector<UInt> = out.length > 0 ? out[0] : null;
			for (i in 0...outSize[0]) {
				output.addByte(storage[i] & 0xFF);
			}
		}

		return output.getBytes();
	}

	/**
		The smallest window from 2^16 up that reaches back over all of `length`
		bytes, and at most the 2^22 the encoder used for everything.

		A window only has to cover the distances a stream can use, and in a
		stream of `length` bytes none is longer than that. Every input got 2^22,
		so every decoder was told to keep 4 MB to read two bytes. Not below
		2^16, and never 2^17: the format spends one bit on 2^16, four on 2^18
		and up, and seven on the others, and neither encoder nor decoder here
		sizes its memory by the window any more.
	**/
	public static function windowBitsFor(length:Int):Int {
		if (length <= (1 << 16) - 16) {
			return 16;
		}
		var bits:Int = 18;
		while (bits < 22 && (1 << bits) - 16 < length) {
			bits++;
		}
		return bits;
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
