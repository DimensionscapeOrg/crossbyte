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
