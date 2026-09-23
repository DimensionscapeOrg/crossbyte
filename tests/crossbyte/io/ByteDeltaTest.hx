package crossbyte.io;

import utest.Assert;

class ByteDeltaTest extends utest.Test {
	private var seed:Int;

	public function setup():Void {
		seed = 0x1B873593;
	}

	// xorshift, so every target draws the same bytes.
	private function random(bound:Int):Int {
		seed ^= seed << 13;
		seed ^= seed >>> 17;
		seed ^= seed << 5;
		return (seed & 0x7FFFFFFF) % bound;
	}

	private function randomBytes(length:Int):ByteArray {
		var bytes = new ByteArray();
		for (_ in 0...length) {
			bytes.writeByte(random(256));
		}
		bytes.position = 0;
		return bytes;
	}

	private static function copyOf(source:ByteArray, from:Int, length:Int):ByteArray {
		var bytes = new ByteArray();
		for (i in from...from + length) {
			bytes.writeByte(source[i]);
		}
		bytes.position = 0;
		return bytes;
	}

	private static function hex(bytes:ByteArray):String {
		var out = new StringBuf();
		for (i in 0...bytes.length) {
			out.add(StringTools.hex(bytes[i], 2));
		}
		return out.toString();
	}

	private static function roundTrip(current:ByteArray, baseline:Null<ByteArray>):ByteArray {
		var delta:ByteArray = ByteDelta.encode(current, baseline);
		delta.position = 0;
		return ByteDelta.decode(delta, baseline);
	}

	// The next snapshot, changed from `baseline` in one of the ways a real
	// one is: not at all, in a few fields, grown, shrunk, shifted by an
	// insertion, replaced outright, or emptied.
	private function successor(baseline:ByteArray, shape:Int):ByteArray {
		var length:Int = baseline.length;
		switch (shape) {
			case 0:
				return copyOf(baseline, 0, length);
			case 1:
				var next = copyOf(baseline, 0, length);
				for (_ in 0...1 + random(4)) {
					if (length > 0) {
						next[random(length)] = random(256);
					}
				}
				return next;
			case 2:
				var next = copyOf(baseline, 0, length);
				next.position = length;
				for (_ in 0...1 + random(40)) {
					next.writeByte(random(256));
				}
				next.position = 0;
				return next;
			case 3:
				return copyOf(baseline, 0, length == 0 ? 0 : random(length));
			case 4:
				var at:Int = length == 0 ? 0 : random(length);
				var next = copyOf(baseline, 0, at);
				next.position = at;
				next.writeByte(random(256));
				for (i in at...length) {
					next.writeByte(baseline[i]);
				}
				next.position = 0;
				return next;
			case 5:
				return randomBytes(random(300));
			default:
				return new ByteArray();
		}
	}

	public function testEveryShapeOfChangeRoundTrips():Void {
		var failures:Array<String> = [];

		for (round in 0...700) {
			var baseline:ByteArray = randomBytes(random(300));
			var current:ByteArray = successor(baseline, round % 7);

			if (hex(roundTrip(current, baseline)) != hex(current)) {
				failures.push('shape ${round % 7}, ${baseline.length} -> ${current.length} bytes');
			}
			if (hex(roundTrip(current, null)) != hex(current)) {
				failures.push('no baseline, ${current.length} bytes');
			}
		}

		Assert.same([], failures);
	}

	public function testAnUnchangedSnapshotCostsAFewBytes():Void {
		var snapshot:ByteArray = randomBytes(1000);
		var delta:ByteArray = ByteDelta.encode(copyOf(snapshot, 0, 1000), snapshot);

		// The length (2 bytes), then one pair copying all 1000 (2 + 1).
		Assert.equals(5, delta.length);
	}

	public function testOneChangedFieldCostsItsOwnBytes():Void {
		var baseline:ByteArray = randomBytes(1000);
		var current:ByteArray = copyOf(baseline, 0, 1000);
		for (i in 500...504) {
			current[i] = baseline[i] ^ 0xFF;
		}

		var delta:ByteArray = ByteDelta.encode(current, baseline);

		// Length 2, a pair copying 500 and carrying 4 (2 + 1), the 4 bytes,
		// and a pair copying the other 496 (2 + 1).
		Assert.equals(12, delta.length);
		delta.position = 0;
		Assert.equals(hex(current), hex(ByteDelta.decode(delta, baseline)));
	}

	public function testWithoutABaselineEverythingIsCarried():Void {
		var snapshot:ByteArray = randomBytes(100);
		var delta:ByteArray = ByteDelta.encode(snapshot);

		// Length, then one pair copying nothing and carrying all 100.
		Assert.equals(103, delta.length);
		delta.position = 0;
		Assert.equals(hex(snapshot), hex(ByteDelta.decode(delta)));
	}

	public function testADeltaCanSitInsideALargerMessage():Void {
		var baseline:ByteArray = randomBytes(64);
		var current:ByteArray = successor(baseline, 1);

		var message = new ByteArray();
		message.writeByte(0xAA);
		ByteDelta.encode(current, baseline, message);
		message.writeByte(0xBB);

		message.position = 1;
		var rebuilt:ByteArray = ByteDelta.decode(message, baseline);
		Assert.equals(hex(current), hex(rebuilt));
		Assert.equals(0xBB, message.readUnsignedByte());
		Assert.equals(0, rebuilt.position);
	}

	public function testEncodingMovesNeitherInput():Void {
		var baseline:ByteArray = randomBytes(40);
		var current:ByteArray = successor(baseline, 1);
		baseline.position = 7;
		current.position = 5;

		ByteDelta.encode(current, baseline);

		Assert.equals(7, baseline.position);
		Assert.equals(5, current.position);
	}

	private static function craft(varints:Array<Int>, ?tail:Array<Int>):ByteArray {
		var bytes = new ByteArray();
		for (value in varints) {
			bytes.writeVarInt(value);
		}
		if (tail != null) {
			for (value in tail) {
				bytes.writeByte(value);
			}
		}
		bytes.position = 0;
		return bytes;
	}

	public function testAHostileDeltaIsRefusedRatherThanObeyed():Void {
		var baseline:ByteArray = randomBytes(5);

		// A length above the limit, refused before anything is built -- and
		// this one is otherwise well formed, so nothing else would stop it.
		Assert.raises(() -> ByteDelta.decode(craft([2000, 0, 2000], [for (_ in 0...2000) 7]), baseline, 1000));
		Assert.raises(() -> ByteDelta.decode(craft([1 << 30]), baseline, 1000));
		// Copying more of the baseline than there is.
		Assert.raises(() -> ByteDelta.decode(craft([10, 10, 0]), baseline));
		// Carrying bytes the delta does not contain.
		Assert.raises(() -> ByteDelta.decode(craft([10, 0, 10], [1, 2, 3]), baseline));
		// A pair that makes no progress. Each pair spends two bytes of the
		// delta, so this cannot loop forever -- but no encoder writes one.
		Assert.raises(() -> ByteDelta.decode(craft([10, 0, 0, 0, 0, 0, 10], [for (_ in 0...10) 1]), baseline));
		// A pair running past the declared length.
		Assert.raises(() -> ByteDelta.decode(craft([5, 0, 10], [for (_ in 0...10) 0]), baseline));
		// Two lengths whose sum overflows into something plausible.
		Assert.raises(() -> ByteDelta.decode(craft([10, 0x7FFFFFFF, 0x7FFFFFFF]), baseline));
		// Ending inside a varint.
		var truncated = new ByteArray();
		truncated.writeByte(0x80);
		truncated.position = 0;
		Assert.raises(() -> ByteDelta.decode(truncated, baseline));
		// A delta needing a baseline, given none.
		var needsBaseline:ByteArray = ByteDelta.encode(copyOf(baseline, 0, 5), baseline);
		needsBaseline.position = 0;
		Assert.raises(() -> ByteDelta.decode(needsBaseline, null));
	}

	public function testRandomBytesNeverBuildMoreThanTheLimit():Void {
		var baseline:ByteArray = randomBytes(128);
		var built:Int = 0;
		var refused:Int = 0;
		var overreached:Int = 0;

		for (_ in 0...3000) {
			var garbage:ByteArray = randomBytes(random(64));
			try {
				var result:ByteArray = ByteDelta.decode(garbage, baseline, 256);
				built++;
				if (result.length > 256) {
					overreached++;
				}
			} catch (_:Dynamic) {
				refused++;
			}
		}

		Assert.equals(0, overreached);
		Assert.equals(3000, built + refused);
	}
}
