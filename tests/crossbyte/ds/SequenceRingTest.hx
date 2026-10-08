package crossbyte.ds;

import utest.Assert;

class SequenceRingTest extends utest.Test {
	public function testValuesAreFoundByTheirNumber():Void {
		var ring = new SequenceRing<String>(8);
		for (tick in 1...6) {
			Assert.isTrue(ring.put(tick, 'snapshot $tick'));
		}

		Assert.equals("snapshot 1", ring.get(1));
		Assert.equals("snapshot 5", ring.get(5));
		Assert.isNull(ring.get(6));
		Assert.equals(5, ring.newest);
		Assert.isFalse(ring.isEmpty());
	}

	public function testANumberOlderThanTheWindowHasAgedOut():Void {
		var ring = new SequenceRing<Int>(8);
		for (tick in 1...21) {
			ring.put(tick, tick * 10);
		}

		// Newest 20, holding eight: 13 through 20.
		Assert.equals(130, ring.get(13));
		Assert.isNull(ring.get(12));
		Assert.isFalse(ring.has(12));
	}

	public function testASkippedStretchStillAgesOutWhatCameBefore():Void {
		// Tick 1's slot is never reused on the way to 10, but 1 is nine
		// behind in a ring of eight: gone all the same.
		var ring = new SequenceRing<String>(8);
		ring.put(1, "old");
		ring.put(10, "new");

		Assert.isNull(ring.get(1));
		Assert.equals("new", ring.get(10));
	}

	public function testNumbersMayArriveOutOfOrderWithinTheWindow():Void {
		var ring = new SequenceRing<Int>(8);
		ring.put(10, 10);
		Assert.isTrue(ring.put(7, 7));
		Assert.isTrue(ring.put(9, 9));
		Assert.isTrue(ring.put(3, 3));

		Assert.equals(7, ring.get(7));
		Assert.equals(9, ring.get(9));
		Assert.equals(3, ring.get(3));
		Assert.equals(10, ring.newest);

		// Eight behind is one too many.
		Assert.isFalse(ring.put(2, 2));
		Assert.isNull(ring.get(2));
	}

	public function testTheWrapIsInvisible():Void {
		var ring = new SequenceRing<Int>(8);
		var ticks:Array<Int> = [2147483646, 2147483647, -2147483647 - 1, -2147483647];
		for (tick in ticks) {
			Assert.isTrue(ring.put(tick, tick));
		}

		for (tick in ticks) {
			Assert.equals(tick, ring.get(tick));
		}
		Assert.equals(-2147483647, ring.newest);
	}

	public function testAnEmptyRingHoldsNothing():Void {
		// Every slot starts out numbered 0; none of them may answer for it.
		var ring = new SequenceRing<String>(4);
		Assert.isTrue(ring.isEmpty());
		Assert.isNull(ring.get(0));
		Assert.isFalse(ring.has(0));
	}

	public function testClearingForgetsEverything():Void {
		var ring = new SequenceRing<String>(4);
		ring.put(3, "three");
		ring.clear();

		Assert.isTrue(ring.isEmpty());
		Assert.isNull(ring.get(3));

		// And starts again from whatever comes next, however far back.
		Assert.isTrue(ring.put(-50, "again"));
		Assert.equals("again", ring.get(-50));
	}

	public function testCapacityIsAPowerOfTwo():Void {
		Assert.equals(1, new SequenceRing<Int>(1).capacity);
		Assert.equals(8, new SequenceRing<Int>(5).capacity);
		Assert.equals(64, new SequenceRing<Int>(64).capacity);
		Assert.raises(() -> new SequenceRing<Int>(0));
		Assert.raises(() -> new SequenceRing<Int>((1 << 30) + 1));
	}

	public function testRemovingTakesOutOneNumberAndLeavesTheWindow():Void {
		var ring = new SequenceRing<String>(8);
		ring.put(10, "ten");
		ring.put(12, "twelve");

		Assert.isTrue(ring.remove(10));
		Assert.isFalse(ring.has(10));
		Assert.isNull(ring.get(10));
		Assert.equals("twelve", ring.get(12));
		Assert.isFalse(ring.remove(10), "removed twice");
		Assert.isFalse(ring.remove(11), "never put");
		Assert.equals(12, ring.newest, "removing moved the window");
		Assert.isFalse(ring.isEmpty());

		// A number a ring's length away shares the slot, and is not the one
		// filed there.
		Assert.isFalse(ring.remove(20));
		Assert.equals("twelve", ring.get(12));
	}

	/**
		A receive window, as a reliable protocol keeps one: what arrived past
		a gap is held, taken out as the gap fills, and acknowledged by a map
		of bits: bit k of byte i for `from + 8i + k`.
	**/
	public function testBitsSayWhatIsHeldFromANumberOn():Void {
		var ring = new SequenceRing<String>(64);
		for (n in [101, 103, 108, 140, 162]) {
			ring.put(n, 'frame $n');
		}

		var out = haxe.io.Bytes.alloc(8);
		var used = ring.writeBits(101, out, 0, 8);
		// 101 and 103: bits 0 and 2; 108: byte 0 bit 7; 140: byte 4 bit 7;
		// 162: byte 7 bit 5, the last that is not zero.
		Assert.equals(8, used);
		Assert.same([0x85, 0, 0, 0, 0x80, 0, 0, 0x20], [for (i in 0...8) out.get(i)]);

		ring.remove(162);
		Assert.equals(5, ring.writeBits(101, out, 0, 8), "the length did not end at the last set byte");
		Assert.equals(0, out.get(7), "a removed number was still written");

		// From where `from` falls inside a byte of the ring.
		Assert.equals(1, ring.writeBits(103, out, 0, 1));
		Assert.equals((1 << 0) | (1 << 5), out.get(0));
	}

	public function testBitsMatchHasForAnyStartAcrossTheWrap():Void {
		var seed:Int = 7;
		function next(bound:Int):Int {
			seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
			return seed % bound;
		}
		for (capacity in [1, 4, 8, 64, 512]) {
			for (start in [0, 0x7FFFFFF0, -1, -1000]) {
				var ring = new SequenceRing<Int>(capacity);
				var count:Int = 1 + next(capacity);
				for (_ in 0...count) {
					// An Int first: a local function is called through Dynamic
					// natively, and `| 0` on what it returns does not compile.
					var offset:Int = next(capacity);
					ring.put((start + offset) | 0, 1);
				}
				for (from in [start, (start + 3) | 0, (start - 5) | 0]) {
					var bytes = Std.int(Math.max(1, (capacity + 15) >> 3));
					var out = haxe.io.Bytes.alloc(bytes + 2);
					out.fill(0, out.length, 0xAA);
					var used = ring.writeBits(from, out, 1, bytes);
					var last = 0;
					for (i in 0...(bytes << 3)) {
						var bit = (out.get(1 + (i >> 3)) >> (i & 7)) & 1;
						Assert.equals(ring.has((from + i) | 0) ? 1 : 0, bit, 'capacity $capacity, from $from, bit $i');
						if (bit == 1) {
							last = (i >> 3) + 1;
						}
					}
					Assert.equals(last, used);
					Assert.equals(0xAA, out.get(0), "wrote before `at`");
					Assert.equals(0xAA, out.get(bytes + 1), "wrote past `byteCount`");
				}
			}
		}
	}

	public function testBitsNeverNameANumberAgedOutOrAliased():Void {
		var ring = new SequenceRing<Int>(8);
		ring.put(1, 1);
		ring.put(9, 9);
		var out = haxe.io.Bytes.alloc(2);

		// 1 has aged out behind 9 in a ring of eight; 9 shares its slot.
		Assert.equals(2, ring.writeBits(1, out, 0, 2));
		Assert.equals(0, out.get(0), "an aged-out number was written");
		Assert.equals(1, out.get(1));
		// 17 shares the slot too, and was never put.
		Assert.equals(0, ring.writeBits(17, out, 0, 1));
	}

	public function testAnEmptyRingWritesZeroes():Void {
		var ring = new SequenceRing<Int>(16);
		var out = haxe.io.Bytes.alloc(2);
		out.fill(0, 2, 0xFF);
		Assert.equals(0, ring.writeBits(0, out, 0, 2));
		Assert.equals(0, out.get(0));
		Assert.equals(0, out.get(1));
		Assert.raises(() -> ring.writeBits(0, out, 1, 2), crossbyte.errors.RangeError);
		Assert.raises(() -> ring.writeBits(0, out, -1, 1), crossbyte.errors.RangeError);
		Assert.raises(() -> ring.writeBits(0, null, 0, 1));
	}
}
