package crossbyte.ds;

import utest.Assert;

class BitSetTest extends utest.Test {
	// Lengths either side of each word boundary, where the masking lives.
	private static final LENGTHS:Array<Int> = [0, 1, 31, 32, 33, 63, 64, 65, 100, 200];

	private var seed:Int;

	public function setup():Void {
		seed = 0x2545F491;
	}

	// xorshift: shifts and xors only, so every target draws the same numbers.
	// A multiplicative generator loses its low bits in a JavaScript double.
	private function random(bound:Int):Int {
		seed ^= seed << 13;
		seed ^= seed >>> 17;
		seed ^= seed << 5;
		return (seed & 0x7FFFFFFF) % bound;
	}

	private function fill(length:Int, percent:Int):{bits:BitSet, model:Array<Bool>} {
		var bits = new BitSet(length);
		var model:Array<Bool> = [];
		for (i in 0...length) {
			var on:Bool = random(100) < percent;
			model.push(on);
			if (on) {
				bits.set(i, true);
			}
		}
		return {bits: bits, model: model};
	}

	private static function indicesOf(model:Array<Bool>):Array<Int> {
		return [for (i in 0...model.length) if (model[i]) i];
	}

	public function testNextSetBitVisitsExactlyTheSetBitsInOrder():Void {
		var mismatches:Array<String> = [];

		for (length in LENGTHS) {
			for (percent in [0, 3, 30, 97, 100]) {
				var sample = fill(length, percent);
				var expected:Array<Int> = indicesOf(sample.model);

				var walked:Array<Int> = [];
				var i:Int = sample.bits.nextSetBit(0);
				while (i >= 0) {
					walked.push(i);
					i = sample.bits.nextSetBit(i + 1);
				}
				var iterated:Array<Int> = [for (index in sample.bits) index];

				if (walked.join(",") != expected.join(",") || iterated.join(",") != expected.join(",")) {
					mismatches.push('length $length at $percent%');
				}
				if (sample.bits.countSetBits() != expected.length) {
					mismatches.push('count at length $length, $percent%');
				}
			}
		}

		Assert.same([], mismatches);
	}

	public function testTheTopBitOfEachWordIsFound():Void {
		// Bit 31 of a word is its sign bit, which is where shifting and
		// counting go wrong first -- on JavaScript above all.
		var bits = new BitSet(128);
		for (index in [0, 31, 63, 95, 127]) {
			bits.set(index, true);
		}

		Assert.same([0, 31, 63, 95, 127], [for (index in bits) index]);
		Assert.equals(31, bits.nextSetBit(1));
		Assert.equals(127, bits.nextSetBit(96));
		Assert.equals(-1, bits.nextSetBit(128));
	}

	public function testNextSetBitStartsFromInsideAWord():Void {
		var bits = new BitSet(64);
		for (index in [3, 5, 7, 40]) {
			bits.set(index, true);
		}

		Assert.equals(3, bits.nextSetBit(0));
		Assert.equals(5, bits.nextSetBit(4));
		Assert.equals(5, bits.nextSetBit(5));
		Assert.equals(7, bits.nextSetBit(6));
		Assert.equals(40, bits.nextSetBit(8));
		Assert.equals(-1, bits.nextSetBit(41));
		Assert.equals(-1, bits.nextSetBit(1000));
		Assert.raises(() -> bits.nextSetBit(-1));
	}

	public function testNextClearBitFindsTheFirstGapAndReadsPastTheEndAsClear():Void {
		var mismatches:Array<String> = [];

		for (length in LENGTHS) {
			for (percent in [0, 50, 90, 100]) {
				var sample = fill(length, percent);
				for (from in 0...length + 2) {
					var expected:Int = from;
					while (expected < length && sample.model[expected]) {
						expected++;
					}
					var found:Int = sample.bits.nextClearBit(from);
					if (found != expected) {
						mismatches.push('length $length, $percent%, from $from: $found, not $expected');
					}
				}
			}
		}

		Assert.same([], mismatches);

		var full = new BitSet(64);
		full.setAll();
		Assert.equals(64, full.nextClearBit(0));
		Assert.raises(() -> full.nextClearBit(-1));
	}

	public function testSetAlgebraMatchesItsDefinitions():Void {
		var mismatches:Array<String> = [];

		for (leftLength in LENGTHS) {
			for (rightLength in [0, 33, 64, 130]) {
				var left = fill(leftLength, 50);
				var right = fill(rightLength, 50);

				var ops:Array<{name:String, apply:BitSet->Void, rule:(Bool, Bool) -> Bool, grows:Bool}> = [
					{name: "and", apply: b -> b.and(right.bits), rule: (a, b) -> a && b, grows: false},
					{name: "or", apply: b -> b.or(right.bits), rule: (a, b) -> a || b, grows: true},
					{name: "xor", apply: b -> b.xor(right.bits), rule: (a, b) -> a != b, grows: true},
					{name: "andNot", apply: b -> b.andNot(right.bits), rule: (a, b) -> a && !b, grows: false}
				];

				for (op in ops) {
					var result:BitSet = left.bits.clone();
					op.apply(result);

					var expectedLength:Int = op.grows && rightLength > leftLength ? rightLength : leftLength;
					if (result.length != expectedLength) {
						mismatches.push('${op.name} $leftLength/$rightLength: length ${result.length}');
					}
					for (i in 0...expectedLength) {
						var a:Bool = i < leftLength && left.model[i];
						var b:Bool = i < rightLength && right.model[i];
						if (result.get(i) != op.rule(a, b)) {
							mismatches.push('${op.name} $leftLength/$rightLength at bit $i');
							break;
						}
					}
				}
			}
		}

		Assert.same([], mismatches);
	}

	public function testWhatEnteredAndWhatLeftBetweenTwoTicks():Void {
		var before = new BitSet(128);
		var now = new BitSet(128);
		for (slot in [1, 2, 3, 40]) {
			before.set(slot, true);
		}
		for (slot in [2, 3, 41, 99]) {
			now.set(slot, true);
		}

		var entered = now.clone();
		entered.andNot(before);
		var left = before.clone();
		left.andNot(now);

		Assert.same([41, 99], [for (slot in entered) slot]);
		Assert.same([1, 40], [for (slot in left) slot]);
	}

	public function testACloneIsSeparateAndEmptinessIsExact():Void {
		var bits = new BitSet(70);
		Assert.isTrue(bits.isEmpty());

		bits.set(69, true);
		Assert.isFalse(bits.isEmpty());

		var copy = bits.clone();
		copy.clear(69);
		Assert.isTrue(copy.isEmpty());
		Assert.isTrue(bits.get(69));
		Assert.equals(70, copy.length);

		Assert.isTrue(new BitSet(0).isEmpty());
		Assert.same([], [for (index in new BitSet(0)) index]);
	}

	public function testASetCombinedWithItselfBehaves():Void {
		var bits = new BitSet(40);
		bits.set(3, true);
		bits.set(39, true);

		bits.and(bits);
		Assert.same([3, 39], [for (index in bits) index]);
		bits.or(bits);
		Assert.same([3, 39], [for (index in bits) index]);
		bits.xor(bits);
		Assert.isTrue(bits.isEmpty());

		bits.set(7, true);
		bits.andNot(bits);
		Assert.isTrue(bits.isEmpty());
	}
}
