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
		// At 10000 the targets really do set different bits, so this checks
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

	/** Clearing forgets everything added, and the filter is usable after. **/
	public function testClearForgetsEverything():Void {
		var bf = new BloomFilter(4096, 5);
		for (i in 0...300) {
			bf.add("seen-" + i);
			bf.addInt(i * 7919);
		}
		bf.clear();
		var still:Int = 0;
		for (i in 0...300) {
			if (bf.contains("seen-" + i) || bf.containsInt(i * 7919)) {
				still++;
			}
		}
		Assert.equals(0, still, still + " items were still there after clear()");
		bf.add("again");
		Assert.isTrue(bf.contains("again"));
	}

	/**
		Items that are not strings go in without being made into one: message
		ids as `Int`s, digests as bytes.
	**/
	public function testIntAndByteItems():Void {
		var bf = new BloomFilter(20000, 4);
		for (id in 0...1000) {
			bf.addInt(0x7FFFFF00 + id * 97);
		}
		var digest = haxe.io.Bytes.ofHex("00112233445566778899aabbccddeeff");
		bf.addBytes(digest);
		bf.addBytes(digest, 4, 8);

		var missing:Int = 0;
		for (id in 0...1000) {
			if (!bf.containsInt(0x7FFFFF00 + id * 97)) {
				missing++;
			}
		}
		Assert.equals(0, missing, "false negatives among Int items");
		Assert.isTrue(bf.containsBytes(digest));
		Assert.isTrue(bf.containsBytes(digest, 4, 8));
		Assert.isTrue(bf.containsBytes(haxe.io.Bytes.ofHex("445566778899aabb")), "a range is the item its bytes make");

		var falsePositives:Int = 0;
		for (id in 0...2000) {
			if (bf.containsInt(-1 - id)) {
				falsePositives++;
			}
		}
		Assert.isTrue(falsePositives < 100, "false positive rate too high: " + falsePositives + " / 2000");
	}

	/**
		A filter at any size sets its bits in range and finds what it holds,
		down to one bit and up past 2^30 positions stepped through.
	**/
	public function testOddSizesStayInRange():Void {
		for (size in [1, 2, 31, 32, 33, 1000003]) {
			var bf = new BloomFilter(size, 7);
			for (i in 0...50) {
				bf.add("x" + i);
			}
			var missing:Int = 0;
			for (i in 0...50) {
				if (!bf.contains("x" + i)) {
					missing++;
				}
			}
			Assert.equals(0, missing, "false negatives at size " + size);
		}
	}

	#if jvm
	private var __hits:Int = 0;

	/**
		A check allocates nothing, and a filter holds a bit per bit. Each call
		hashed a UTF-8 copy of the item and a second, concatenated copy, ~470
		bytes a check, and each bit was an array element: 38 MB on the jvm
		for a 10-million-bit filter.
	**/
	public function testChecksAllocateNothingAndBitsArePacked():Void {
		var bf = new BloomFilter(95851, 7);
		var items = [for (i in 0...1000) "msg-" + i];
		for (item in items) {
			bf.add(item);
		}
		// Counted in a field: a local captured and changed by the closure
		// would be boxed on the jvm, and counted against the filter.
		__hits = 0;
		var perCheck:Float = JvmAllocation.bytesBy(() -> {
			for (item in items) {
				if (bf.contains(item)) {
					__hits++;
				}
			}
		}) / items.length;
		Assert.isTrue(perCheck < 1, perCheck + " bytes allocated per check");
		Assert.equals(3000, __hits, "the three measured runs did not all find every item");

		var big:BloomFilter = null;
		var held:Float = JvmAllocation.bytesBy(() -> big = new BloomFilter(10000000, 7));
		Assert.isTrue(held < 2 * 1024 * 1024, "a 10-million-bit filter took " + held + " bytes");
		big.add("present");
		Assert.isTrue(big.contains("present"));
	}
	#end
}
