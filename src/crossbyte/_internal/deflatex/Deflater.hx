package crossbyte._internal.deflatex;

import crossbyte._internal.deflatex.LZPair.Symbols;
import crossbyte._internal.deflatex.utils.BitsOutput;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import haxe.ds.Vector;

/**
 * Deflates a given stream of data.
 *
 * Emits one fixed-Huffman block (BTYPE=01) over an LZ77 pass, falling back to
 * stored blocks when that would not be smaller -- so the output is never worse
 * than the input by more than a stored block's five bytes per 64K.
 *
 * Fixed rather than dynamic Huffman: the code lengths are the ones in RFC 1951
 * section 3.2.6, so nothing has to be described in the stream, and what is left
 * to get right is the match finder. Dynamic tables would win a few more percent
 * on a large body, at considerably more risk.
 */
class Deflater {
	/*
	 * Match bounds, and the furthest back a match may reach
	 * (see RFC 1951, section 3.2.5)
	 */
	private static final MIN_MATCH:Int = 3;
	private static final MAX_MATCH:Int = 258;
	private static final WINDOW_SIZE:Int = 32768;

	/*
	 * The most one stored block can carry.
	 */
	private static final MAX_STORED:Int = 0xFFFF;

	private static final END_OF_BLOCK:Int = 256;

	/*
	 * Match finder tuning.
	 *
	 * MAX_CHAIN bounds how many earlier positions a single hash bucket will
	 * compare against. Without it, input that hashes into few buckets -- a long
	 * run of one byte, say -- degrades to scanning the whole window per
	 * position.
	 *
	 * TOO_FAR drops a shortest-possible match found a long way back. Under the
	 * fixed tables such a match spends a 7-bit length code, a 5-bit distance
	 * code and up to 13 extra bits, which is more than the three 8-bit literals
	 * it would have replaced.
	 */
	private static final MAX_HASH_SIZE:Int = 1 << 15;
	private static final MIN_TABLE_SIZE:Int = 256;
	private static final MAX_CHAIN:Int = 128;
	private static final TOO_FAR:Int = 4096;
	private static final NIL:Int = -1;

	/*
	 * Symbol lookups, derived from LZPair's description of the format.
	 *
	 * Built as the class is initialised, which happens before any other thread
	 * can call in: at startup natively, and under the class-initialisation
	 * lock on the jvm. They were built on first use and published by setting
	 * `lengthSymbol` last, but nothing orders six plain stores as another
	 * thread sees them -- a compiler may reorder them, and so may a weakly
	 * ordered CPU -- so a thread that saw `lengthSymbol` set could still read
	 * a null `lengthBase`. There are about nine hundred entries.
	 *
	 * From a Symbols of their own rather than LZPair.SYMBOLS, so nothing here
	 * depends on which class Haxe initialises first.
	 */
	private static final __tables:SymbolTables = new SymbolTables(new Symbols(), MIN_MATCH, MAX_MATCH);
	private static final lengthSymbol:Vector<Int> = __tables.lengthSymbol;
	private static final lengthBase:Vector<Int> = __tables.lengthBase;
	private static final lengthExtra:Vector<Int> = __tables.lengthExtra;
	private static final distanceSymbol:Vector<Int> = __tables.distanceSymbol;
	private static final distanceBase:Vector<Int> = __tables.distanceBase;
	private static final distanceExtra:Vector<Int> = __tables.distanceExtra;

	/*
	 * Hash chains over the window. `head` holds the most recent position whose
	 * three bytes hash to a bucket; `prev` links each position to the one
	 * before it in the same bucket.
	 */
	private var head:Vector<Int>;
	private var prev:Vector<Int>;
	private var hashMask:Int;
	private var windowMask:Int;
	private var windowSize:Int;

	/** The highest position already entered into the chains. */
	private var inserted:Int;

	/** Distance of the match `findLongest` last returned. */
	private var matchDistance:Int;

	/**
	 * Create a new Deflater.
	 */
	public function new() {}

	/**
	 * Applies the deflate compression on the supplied stream.
	 *
	 * It computed a CRC of every input as well, which only gzip reads; gzip
	 * computes its own.
	 *
	 * @return Bytes holding the compressed data
	 */
	public function compress(stream:Bytes):Bytes {
		var compressed:Bytes = deflateFixed(stream);
		if (compressed.length < storedLength(stream.length)) {
			return compressed;
		}

		// Incompressible: a stored block costs five bytes per 64K and copies
		// the input, which beats a Huffman block that found nothing to do.
		return stored(stream);
	}

	/**
	 * Encode the whole stream as a single fixed-Huffman block.
	 */
	private function deflateFixed(stream:Bytes):Bytes {
		var output:BitsOutput = new BitsOutput();

		// BFINAL = 1, then BTYPE = 01. Both are plain values, so least
		// significant bit first; the Huffman codes below go the other way.
		output.writeBits(1, 1);
		output.writeBits(1, 2);

		var litCode:Vector<Int> = HuffmanTable.LIT.code;
		var litCodeLen:Vector<Int> = HuffmanTable.LIT.codeLen;
		var n:Int = stream.length;

		prepare(n);

		var i:Int = 0;
		while (i < n) {
			var length:Int = 0;
			var distance:Int = 0;

			if (i + MIN_MATCH <= n) {
				length = findAt(stream, i, n);
				distance = matchDistance;
			}

			if (length < MIN_MATCH) {
				var b:Int = stream.get(i);
				output.writeBitsR(litCode[b], litCodeLen[b]);
				i++;
				continue;
			}

			// Lazy matching: if a longer match starts one byte later, spend
			// position i as a literal and take that one instead. Costs an extra
			// search per match and buys a few percent on text.
			if (length < MAX_MATCH && i + 1 + MIN_MATCH <= n) {
				var next:Int = findAt(stream, i + 1, n);
				if (next > length) {
					var b:Int = stream.get(i);
					output.writeBitsR(litCode[b], litCodeLen[b]);
					i++;
					length = next;
					distance = matchDistance;
				}
			}

			writeMatch(output, distance, length);
			insertThrough(stream, i + length - 1, n);
			i += length;
		}

		output.writeBitsR(litCode[END_OF_BLOCK], litCodeLen[END_OF_BLOCK]);
		output.flushBits();

		return output.getBytes();
	}

	/**
	 * Enter `at` into the chains and return the longest match reaching it,
	 * leaving the distance in `matchDistance`.
	 */
	private function findAt(stream:Bytes, at:Int, n:Int):Int {
		// Every earlier position has to be in the chains before this bucket is
		// read, and `at` itself must not be: relinking a position already in a
		// chain points it at itself, which walks as a match at distance zero --
		// not a distance deflate can encode. `insertThrough` leaves `inserted`
		// at exactly `at - 1`, and the loop only ever calls this with `at`
		// above it, so the bucket read below cannot return `at`.
		insertThrough(stream, at - 1, n);

		var bucket:Int = hash(stream, at);
		var candidate:Int = head[bucket];
		prev[at & windowMask] = candidate;
		head[bucket] = at;
		inserted = at;

		var maxLength:Int = n - at;
		if (maxLength > MAX_MATCH) {
			maxLength = MAX_MATCH;
		}

		return findLongest(stream, at, candidate, maxLength);
	}

	/**
	 * Walk one hash chain for the longest match at `at`.
	 */
	private function findLongest(stream:Bytes, at:Int, candidate:Int, maxLength:Int):Int {
		var best:Int = 0;
		var bestDistance:Int = 0;

		// Positions at or below this have fallen out of the window. Held at -1
		// at the least, so the NIL ending a chain always stops the walk.
		var limit:Int = at - windowSize;
		if (limit < 0) {
			limit = NIL;
		}

		var chain:Int = MAX_CHAIN;
		while (candidate > limit && chain > 0) {
			chain--;

			// Nothing can beat `best` unless it also matches at that offset,
			// and one byte is far cheaper to reject on than a full compare.
			if (stream.get(candidate + best) == stream.get(at + best)) {
				var length:Int = 0;
				while (length < maxLength && stream.get(candidate + length) == stream.get(at + length)) {
					length++;
				}
				if (length > best) {
					best = length;
					bestDistance = at - candidate;
					if (best >= maxLength) {
						break;
					}
				}
			}

			candidate = prev[candidate & windowMask];
		}

		if (best == MIN_MATCH && bestDistance > TOO_FAR) {
			best = 0;
			bestDistance = 0;
		}

		matchDistance = bestDistance;
		return best;
	}

	/**
	 * Enter every position not yet in the chains, up to and including `upTo`.
	 * Insertion stays in order, so a position is never linked to itself.
	 */
	private function insertThrough(stream:Bytes, upTo:Int, n:Int):Void {
		while (inserted < upTo) {
			var at:Int = ++inserted;
			if (at + MIN_MATCH <= n) {
				var bucket:Int = hash(stream, at);
				prev[at & windowMask] = head[bucket];
				head[bucket] = at;
			}
		}
	}

	/**
	 * Hash the three bytes at `at`.
	 *
	 * The multiply is deliberately spelled as a shift and a subtract: Haxe's
	 * `*` is not 32-bit on js, where a product past 2^53 quietly loses its low
	 * bits and would hash differently there than everywhere else.
	 */
	private inline function hash(stream:Bytes, at:Int):Int {
		var h:Int = stream.get(at);
		h = (((h << 5) - h) + stream.get(at + 1)) & 0xFFFFFF;
		h = (((h << 5) - h) + stream.get(at + 2)) & 0xFFFFFF;
		return (h ^ (h >>> 12)) & hashMask;
	}

	/**
	 * Write one length/distance pair.
	 */
	private function writeMatch(output:BitsOutput, distance:Int, length:Int):Void {
		var symbol:Int = lengthSymbol[length];
		var index:Int = symbol - 257;
		output.writeBitsR(HuffmanTable.LIT.code[symbol], HuffmanTable.LIT.codeLen[symbol]);
		if (lengthExtra[index] > 0) {
			output.writeBits(length - lengthBase[index], lengthExtra[index]);
		}

		// Distances up to 256 index the table directly. Past that every
		// distance code spans at least 128 values and starts on a multiple of
		// 128 away from 1, so which block of 128 a distance falls in already
		// identifies its code.
		var code:Int = distance <= 256 ? distanceSymbol[distance - 1] : distanceSymbol[256 + ((distance - 1) >> 7)];
		output.writeBitsR(HuffmanTable.DIST.code[code], HuffmanTable.DIST.codeLen[code]);
		if (distanceExtra[code] > 0) {
			output.writeBits(distance - distanceBase[code], distanceExtra[code]);
		}
	}

	/**
	 * Size the chains for this input, so compressing a short response does not
	 * cost clearing a quarter of a megabyte first.
	 */
	private function prepare(n:Int):Void {
		var window:Int = MIN_TABLE_SIZE;
		var reach:Int = n < WINDOW_SIZE ? n : WINDOW_SIZE;
		while (window < reach) {
			window <<= 1;
		}
		windowSize = window;
		windowMask = window - 1;

		var buckets:Int = MIN_TABLE_SIZE;
		while (buckets < MAX_HASH_SIZE && buckets < n) {
			buckets <<= 1;
		}
		hashMask = buckets - 1;

		head = new Vector<Int>(buckets);
		for (i in 0...buckets) {
			head[i] = NIL;
		}
		prev = new Vector<Int>(window);
		for (i in 0...window) {
			prev[i] = NIL;
		}

		inserted = NIL;
		matchDistance = 0;
	}

	/**
	 * The size this data would take as stored blocks.
	 */
	private static function storedLength(length:Int):Int {
		if (length == 0) {
			return 5;
		}
		return length + Std.int((length + MAX_STORED - 1) / MAX_STORED) * 5;
	}

	/**
	 * Copy the input into stored blocks (BTYPE=00).
	 */
	private static function stored(stream:Bytes):Bytes {
		var output:BytesBuffer = new BytesBuffer();
		var offset:Int = 0;
		var remaining:Int = stream.length;

		if (remaining == 0) {
			output.addByte(0x01);
			output.addByte(0x00);
			output.addByte(0x00);
			output.addByte(0xFF);
			output.addByte(0xFF);
			return output.getBytes();
		}

		while (remaining > 0) {
			var blockLen:Int = remaining > MAX_STORED ? MAX_STORED : remaining;
			var finalBlock:Bool = (remaining == blockLen);
			output.addByte(finalBlock ? 0x01 : 0x00);
			output.addByte(blockLen & 0xFF);
			output.addByte((blockLen >>> 8) & 0xFF);
			var nlen:Int = blockLen ^ 0xFFFF;
			output.addByte(nlen & 0xFF);
			output.addByte((nlen >>> 8) & 0xFF);
			output.addBytes(stream, offset, blockLen);
			offset += blockLen;
			remaining -= blockLen;
		}

		return output.getBytes();
	}

	/**
	 * Applies the deflate compression on the supplied bytes.
	 * @return Compressed output
	 */
	public static function apply(stream:Bytes):Bytes {
		return new Deflater().compress(stream);
	}
}

/**
 * The symbol lookups `Deflater` writes matches with, derived from the ranges
 * in LZPair.
 */
private class SymbolTables {
	public final lengthSymbol:Vector<Int>;
	public final lengthBase:Vector<Int>;
	public final lengthExtra:Vector<Int>;
	public final distanceSymbol:Vector<Int>;
	public final distanceBase:Vector<Int>;
	public final distanceExtra:Vector<Int>;

	public function new(symbols:Symbols, minMatch:Int, maxMatch:Int) {
		lengthSymbol = new Vector<Int>(maxMatch + 1);
		for (i in 0...maxMatch + 1) {
			lengthSymbol[i] = 0;
		}
		for (length in minMatch...maxMatch + 1) {
			for (i in 0...29) {
				if (length <= symbols.lenUpper[i]) {
					lengthSymbol[length] = 257 + i;
					break;
				}
			}
		}

		lengthBase = new Vector<Int>(29);
		lengthExtra = new Vector<Int>(29);
		for (i in 0...29) {
			lengthBase[i] = symbols.lenLower[i];
			lengthExtra[i] = symbols.lenNBits[i];
		}

		// 0..255 index distance-1 directly, 256..511 index it in blocks of 128.
		distanceSymbol = new Vector<Int>(512);
		for (i in 0...512) {
			var distance:Int = i < 256 ? i + 1 : ((i - 256) << 7) + 1;
			distanceSymbol[i] = 0;
			for (j in 0...30) {
				if (distance <= symbols.distUpper[j]) {
					distanceSymbol[i] = j;
					break;
				}
			}
		}

		distanceBase = new Vector<Int>(30);
		distanceExtra = new Vector<Int>(30);
		for (i in 0...30) {
			distanceBase[i] = symbols.distLower[i];
			distanceExtra[i] = symbols.distNBits[i];
		}
	}
}
