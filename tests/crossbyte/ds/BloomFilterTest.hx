package crossbyte.ds;

import utest.Assert;

class BloomFilterTest extends utest.Test {
	public function testNoFalseNegatives():Void {
		var bf = new BloomFilter(8192, 4);
		var items = [];
		for (i in 0...200) {
			var s = "item-" + i;
			items.push(s);
			bf.add(s);
		}
		// A Bloom filter must never report a false negative for an added item.
		for (s in items) {
			Assert.isTrue(bf.contains(s));
		}
	}

	public function testHoldsAtASizeThatIsNotAPowerOfTwo():Void {
		// Both other cases size the filter to a power of two, and that is the
		// one shape where the index arithmetic cannot differ between targets:
		// `i * h2` wraps where an Int is 32 bits and does not on js, the two
		// differ by exactly 2^32, and a power-of-two size divides that away.
		// At 10000 the targets really do set different bits -- so this checks
		// that the guarantee survives it, which is the part that matters.
		var bf = new BloomFilter(10000, 4);
		var items = [];

		for (i in 0...200) {
			var s = "odd-size-" + i;
			items.push(s);
			bf.add(s);
		}

		for (s in items) {
			Assert.isTrue(bf.contains(s), "false negative for " + s);
		}

		var falsePositives = 0;

		for (i in 0...2000) {
			if (bf.contains("missing-" + i)) {
				falsePositives++;
			}
		}

		Assert.isTrue(falsePositives < 200, "false positive rate too high: " + falsePositives + " / 2000");
	}

	public function testFalsePositiveRateIsLow():Void {
		// Regression guard: the previous hash collapsed every input to ~16 bucket
		// values, so the filter saturated and reported almost everything present.
		// A correct hash spread keeps the false-positive rate far below this bound.
		var bf = new BloomFilter(16384, 4);
		for (i in 0...500) {
			bf.add("present-" + i);
		}

		var falsePositives = 0;
		var trials = 2000;
		for (i in 0...trials) {
			if (bf.contains("absent-" + i)) {
				falsePositives++;
			}
		}

		Assert.isTrue(falsePositives < Std.int(trials / 10), "false positive rate too high: " + falsePositives + " / " + trials);
	}
}
