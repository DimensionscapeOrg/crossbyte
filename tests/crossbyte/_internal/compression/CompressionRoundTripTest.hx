package crossbyte._internal.compression;

import haxe.io.Bytes;
import haxe.ds.Vector;
import crossbyte.io.ByteArray;
import crossbyte.utils.CompressionAlgorithm;
import utest.Assert;
import crossbyte._internal.lz4.Lz4;
import crossbyte._internal.deflatex.HuffmanTree;
import crossbyte._internal.deflatex.HuffmanTable;
import crossbyte.test.Require;

/**
 * Round-trip / robustness coverage for the internal compression primitives:
 * the pure-Haxe LZ4 codec and the Huffman tree (which exercises PriorityQueue).
 */
class CompressionRoundTripTest extends utest.Test {
	/**
	 * The assertion this file did not have: that compressing makes the data
	 * smaller.
	 *
	 * Everything else here checks fidelity -- same length back, same bytes
	 * back -- and a codec that stores its input verbatim satisfies every one
	 * of those perfectly. Three of the four did exactly that.
	 * `Deflater.compress` wrote stored blocks and nothing else: a `0x01`
	 * header, the length, its complement, then the raw bytes. No Huffman
	 * coding, no LZ77. gzip wrapped the same, and `Lz4.compress` emitted one
	 * literal run without ever looking for a match. All three returned more
	 * bytes than they were given, and every round-trip case above passed
	 * throughout.
	 *
	 * That was not academic. `HTTPRequestHandler` serves `Content-Encoding:
	 * gzip` and `deflate` through these, so a server negotiating gzip sent
	 * more bytes than it would have uncompressed and made the client
	 * decompress them for nothing.
	 *
	 * So this asserts, for all four: a codec that stops compressing fails
	 * here rather than passing quietly on fidelity alone.
	 */
	public function testCompressionActuallyCompresses():Void {
		// Twelve bytes repeated five hundred times. Any real encoder collapses
		// this to almost nothing -- the four land between 23 and 77 bytes --
		// so a tenth of the input is a floor none of them can approach without
		// having genuinely stopped working.
		var sample = new ByteArray();

		for (i in 0...500) {
			sample.writeUTFBytes("compress me ");
		}

		var original:Int = sample.length;
		var ceiling:Int = Std.int(original / 10);

		for (algorithm in [
			CompressionAlgorithm.BROTLI,
			CompressionAlgorithm.DEFLATE,
			CompressionAlgorithm.GZIP,
			CompressionAlgorithm.LZ4
		]) {
			var size:Int = measure(algorithm, original);

			Assert.isTrue(size < ceiling,
				algorithm + " did not compress a highly repetitive payload: " + original + " bytes in, " + size + " out");
		}
	}

	/**
	 * That data with nothing to find does not grow much.
	 *
	 * The other half of an encoder being real. Deflate answers this with the
	 * stored block it falls back to, which costs five bytes per 64K; LZ4's
	 * block format has no stored form at all, so a little expansion is
	 * inherent there. Either way an encoder that inflates noise by a
	 * noticeable fraction is broken, and on an HTTP body that is the case
	 * where compressing is worse than not.
	 */
	public function testIncompressibleDataBarelyGrows():Void {
		var n:Int = 4096;
		var noise:Bytes = pseudoRandom(n);

		// Room for a stored block header and a token per literal run, and no
		// more: about 3% of the payload.
		var ceiling:Int = n + Std.int(n / 64) + 64;

		for (algorithm in [
			CompressionAlgorithm.BROTLI,
			CompressionAlgorithm.DEFLATE,
			CompressionAlgorithm.GZIP,
			CompressionAlgorithm.LZ4
		]) {
			var data = new ByteArray();
			data.writeBytes(noise, 0, noise.length);

			data.compress(algorithm);
			var size:Int = data.length;

			data.uncompress(algorithm);
			Assert.equals(n, data.length, algorithm + " did not round-trip incompressible data");

			Assert.isTrue(size <= ceiling, algorithm + " grew incompressible data from " + n + " to " + size);
		}
	}

	/**
	 * That a payload past 64K still works.
	 *
	 * Deflate's stored fallback has to emit more than one block above 65535,
	 * and only the last may carry the final-block bit; the match finder's
	 * window wraps somewhere in here too. Both are paths a small fixture never
	 * reaches.
	 */
	public function testLargePayloadRoundTripsAndCompresses():Void {
		var text = new ByteArray();
		while (text.length < 70000) {
			text.writeUTFBytes("CrossByte serves this body over HTTP. ");
		}

		var original:Int = text.length;

		for (algorithm in [
			CompressionAlgorithm.BROTLI,
			CompressionAlgorithm.DEFLATE,
			CompressionAlgorithm.GZIP,
			CompressionAlgorithm.LZ4
		]) {
			var data = new ByteArray();
			data.writeBytes(text, 0, original);

			data.compress(algorithm);
			var size:Int = data.length;

			data.uncompress(algorithm);
			Assert.equals(original, data.length, algorithm + " did not round-trip a large payload");
			Assert.isTrue(size < Std.int(original / 10),
				algorithm + " did not compress a large repetitive payload: " + original + " bytes in, " + size + " out");
		}
	}

	/**
	 * Deterministic noise, from shifts and xors only.
	 *
	 * The usual multiply-based generator is not portable here: Haxe's `*` is
	 * not 32-bit on js, so past 2^53 it loses its low bits and the sequence
	 * collapses into a short cycle -- which compresses, and would leave this
	 * fixture testing the opposite of what it means to.
	 */
	private function pseudoRandom(n:Int):Bytes {
		var b:Bytes = Bytes.alloc(n);
		var state:Int = 0x12345678;

		for (i in 0...n) {
			state ^= state << 13;
			state ^= state >>> 17;
			state ^= state << 5;
			b.set(i, (state >>> 16) & 0xFF);
		}

		return b;
	}

	/**
	 * Compresses a fresh sample and returns the compressed size, checking on
	 * the way back that whatever it did is reversible.
	 */
	private function measure(algorithm:CompressionAlgorithm, count:Int):Int {
		var data = new ByteArray();

		for (i in 0...Std.int(count / 12)) {
			data.writeUTFBytes("compress me ");
		}

		data.compress(algorithm);
		var compressed:Int = data.length;

		data.uncompress(algorithm);
		Assert.equals(count, data.length, algorithm + " did not round-trip");

		return compressed;
	}

	private function assertBytesEqual(expected:Bytes, actual:Bytes):Void {
		Assert.equals(expected.length, actual.length);
		if (expected.length != actual.length) {
			return;
		}
		var mismatch:Int = -1;
		for (i in 0...expected.length) {
			if (expected.get(i) != actual.get(i)) {
				mismatch = i;
				break;
			}
		}
		Assert.equals(-1, mismatch, "byte mismatch at index " + mismatch);
	}

	private function roundTrip(data:Bytes):Void {
		var packed:Bytes = Lz4.compress(data);
		var restored:Bytes = Lz4.decompress(packed);
		assertBytesEqual(data, restored);
	}

	public function testLz4RoundTripsEmpty():Void {
		roundTrip(Bytes.alloc(0));
	}

	public function testLz4RoundTripsFewBytes():Void {
		var b:Bytes = Bytes.alloc(5);
		b.set(0, 0x00);
		b.set(1, 0x7F);
		b.set(2, 0xFF);
		b.set(3, 0x10);
		b.set(4, 0xAB);
		roundTrip(b);
	}

	public function testLz4RoundTripsLongRuns():Void {
		// Highly repetitive data -> long literal/match runs.
		var n:Int = 4096;
		var b:Bytes = Bytes.alloc(n);
		for (i in 0...n) {
			b.set(i, (i % 7 == 0) ? 0x41 : 0x42);
		}
		roundTrip(b);
	}

	public function testLz4RoundTripsSingleByteRun():Void {
		var n:Int = 1000;
		var b:Bytes = Bytes.alloc(n);
		b.fill(0, n, 0x5A);
		roundTrip(b);
	}

	public function testLz4RoundTripsPseudoRandom():Void {
		// Deterministic LCG so the test is reproducible across runs/targets.
		var n:Int = 2048;
		var b:Bytes = Bytes.alloc(n);
		var state:Int = 0x12345678;
		for (i in 0...n) {
			state = (state * 1103515245 + 12345) & 0x7FFFFFFF;
			b.set(i, (state >> 16) & 0xFF);
		}
		roundTrip(b);
	}

	private function freqVector(values:Array<Int>):Vector<Int> {
		var v:Vector<Int> = new Vector<Int>(values.length);
		for (i in 0...values.length) {
			v[i] = values[i];
		}
		return v;
	}

	private function assertValidTable(tree:HuffmanTree, expectSymbols:Array<Int>):Void {
		var table:HuffmanTable = tree.getTable();
		for (sym in expectSymbols) {
			Assert.isTrue(table.codeLen[sym] > 0, "symbol " + sym + " should have a code length");
		}
	}

	public function testHuffmanSingleSymbol():Void {
		// numSymbols == 1, one non-zero frequency: must not read past the array
		// while padding the priority queue to two leaves. A single-symbol tree
		// is degenerate (the leaf sits at the root, depth 0) so we only assert
		// that the table is produced without crashing.
		var tree:HuffmanTree = new HuffmanTree(freqVector([5]), 15);
		var table:HuffmanTable = tree.getTable();
		Require.notNull(table);
		Assert.notNull(table.codeLen);
	}

	public function testHuffmanTwoSymbols():Void {
		var tree:HuffmanTree = new HuffmanTree(freqVector([3, 9]), 15);
		assertValidTable(tree, [0, 1]);
	}

	public function testHuffmanSparseFrequencies():Void {
		// Only a couple of non-zero frequencies among several symbols; the
		// padding loop must stay bounded by the symbol count.
		var tree:HuffmanTree = new HuffmanTree(freqVector([0, 0, 4, 0, 0]), 15);
		assertValidTable(tree, [2]);
	}

	public function testHuffmanManySymbols():Void {
		var tree:HuffmanTree = new HuffmanTree(freqVector([1, 2, 3, 4, 5, 6, 7, 8]), 15);
		assertValidTable(tree, [0, 1, 2, 3, 4, 5, 6, 7]);
	}
}
