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
}
