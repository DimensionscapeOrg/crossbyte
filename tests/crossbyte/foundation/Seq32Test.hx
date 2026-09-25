package crossbyte.foundation;

import crossbyte.Seq32;
import haxe.io.Bytes;
import utest.Assert;

/**
	`Seq32` arithmetic wraps at 32 bits on every target, JavaScript included.

	JavaScript has no 32-bit integer arithmetic: `+` and `++` on a Haxe `Int`
	there go on past 2^31 - 1, where every other target wraps. Ordering
	survived, because the comparison runs through `^`, which truncates. But a
	sequence counted up past 2^31 no longer equalled the same sequence read
	off the wire -- which is wrapped -- and a reliable session reaching it
	stopped delivering. Sessions start at a random point in the 32-bit range,
	so some started close to it.

	Registered in the portable suite, so it runs on Node and in a browser,
	which is where it matters.
**/
class Seq32Test extends utest.Test {
	static inline var TOP:Int = 0x7FFFFFFF;
	static inline var BOTTOM:Int = 0x80000000;

	public function testIncrementWrapsAtTheTopOfTheRange():Void {
		var postfix:Seq32 = TOP;
		postfix++;
		Assert.equals(BOTTOM, (postfix : Int));

		var prefix:Seq32 = TOP;
		++prefix;
		Assert.equals(BOTTOM, (prefix : Int));

		var returned:Seq32 = TOP;
		Assert.equals(TOP, (returned++ : Int), "a postfix increment returned the new value");
	}

	public function testDecrementWrapsAtTheBottomOfTheRange():Void {
		var postfix:Seq32 = BOTTOM;
		postfix--;
		Assert.equals(TOP, (postfix : Int));

		var prefix:Seq32 = BOTTOM;
		--prefix;
		Assert.equals(TOP, (prefix : Int));
	}

	public function testAdditionAndSubtractionWrap():Void {
		var top:Seq32 = TOP;
		var bottom:Seq32 = BOTTOM;
		var minusOne:Seq32 = -1;

		Assert.equals(BOTTOM, ((top + 1) : Int));
		Assert.equals(BOTTOM + 9, ((top + 10) : Int));
		Assert.equals(TOP, ((bottom - 1) : Int));
		Assert.equals(0, ((minusOne + 1) : Int));
		// Far past the range, as a large difference is.
		Assert.equals(-2, ((top + top) : Int));
	}

	public function testMultiplicationWraps():Void {
		var big:Seq32 = 0x10000;
		Assert.equals(0, ((big * big) : Int));
		// (2^31 - 1)^2 is 2^62 - 2^32 + 1, which is 1 in 32 bits. A double
		// holds the product only to 53 bits, so wrapping it afterwards loses
		// the answer: it has to be multiplied in halves.
		var top:Seq32 = TOP;
		Assert.equals(1, ((top * top) : Int));
	}

	public function testACountedSequenceIsTheOneReadOffTheWire():Void {
		// What a receiver does: count up from what it expects, and compare
		// with what arrives, as values and as map keys.
		var expected:Seq32 = TOP - 2;
		for (_ in 0...5) {
			expected++;
		}

		var wire = Bytes.alloc(4);
		wire.setInt32(0, BOTTOM + 2);
		var arrived:Seq32 = wire.getInt32(0);

		Assert.isTrue(expected == arrived, 'counted to ${(expected : Int)}, read ${(arrived : Int)}');

		var held = new Map<Int, String>();
		held.set(arrived, "frame");
		Assert.equals("frame", held.get(expected), "a frame held under its wire sequence was not found by the counted one");
	}

	public function testOrderHoldsAcrossTheTopOfTheRange():Void {
		var before:Seq32 = TOP;
		var after:Seq32 = before + 1;

		Assert.isTrue(before < after);
		Assert.isTrue(after > before);
		Assert.equals(1, ((after - before) : Int));
	}
}
