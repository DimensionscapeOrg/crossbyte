package crossbyte._internal.compression;

import haxe.io.Bytes;
import haxe.ds.Vector;
import utest.Assert;
import crossbyte._internal.lz4.Lz4;
import crossbyte._internal.deflatex.HuffmanTree;
import crossbyte._internal.deflatex.HuffmanTable;

/**
 * Round-trip / robustness coverage for the internal compression primitives:
 * the pure-Haxe LZ4 codec and the Huffman tree (which exercises PriorityQueue).
 */
class CompressionRoundTripTest extends utest.Test {
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
		Assert.notNull(table);
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
