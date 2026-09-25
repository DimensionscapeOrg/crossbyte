package crossbyte.io;

import crossbyte.errors.ArgumentError;
import crossbyte.errors.EOFError;
import crossbyte.errors.RangeError;
import haxe.io.FPHelper;
import utest.Assert;

class BitPackingTest extends utest.Test {
	private var seed:Int;

	public function setup():Void {
		seed = 0x7F4A7C15;
	}

	private function next():Int {
		seed ^= seed << 13;
		seed ^= seed >>> 17;
		seed ^= seed << 5;
		return seed;
	}

	private function below(bound:Int):Int {
		return (next() & 0x7FFFFFFF) % bound;
	}

	// ------------------------------------------------------------- layout

	public function testTheLayoutIsTheSameBytesOnEveryTarget():Void {
		var writer = new BitWriter();
		writer.writeBits(5, 3);
		writer.writeBool(true);
		writer.writeBits(0xABC, 12);
		writer.writeBits(0xDEADBEEF, 32);
		writer.writeBool(true);

		// Worked by hand: bits fill 32-bit words from the bottom and words are
		// stored little-endian. Word 0 is 0xBEEFABCD -- 101, 1, 0xABC and the
		// low half of 0xDEADBEEF -- and word 1 is 0x0001DEAD, trimmed to the
		// 49 bits written.
		Assert.equals(49, writer.bitLength);
		Assert.equals("cdabefbeadde01", hex(writer.finish()));
	}

	public function testTheLengthIsTheBitsRoundedUpToWholeBytes():Void {
		for (bits in [0, 1, 7, 8, 9, 31, 32, 33, 63, 64, 65, 100]) {
			var writer = new BitWriter(0);
			var left = bits;
			while (left > 0) {
				var width = left > 13 ? 13 : left;
				writer.writeBits(0, width);
				left -= width;
			}
			Assert.equals(bits, writer.bitLength, '$bits bits');
			Assert.equals(Std.int((bits + 7) / 8), writer.length, '$bits bits');
			Assert.equals(writer.length, writer.finish().length, '$bits bits');
		}
	}

	// --------------------------------------------------------- round trips

	public function testEveryWidthRoundTripsInAnyMixture():Void {
		var writer = new BitWriter(0);
		var widths:Array<Int> = [];
		var values:Array<Int> = [];
		for (i in 0...4000) {
			var bits = 1 + below(32);
			// Plenty of edge values: zero, all ones, and random.
			var value = switch (below(4)) {
				case 0: 0;
				// `| 0`: on JavaScript `(1 << 31) - 1` is not 0x7FFFFFFF but
				// -2147483649, a number no 31-bit field holds.
				case 1: bits == 32 ? -1 : ((1 << bits) - 1) | 0;
				default: bits == 32 ? next() : next() & ((1 << bits) - 1);
			}
			widths.push(bits);
			values.push(value);
			writer.writeBits(value, bits);
		}

		var reader = new BitReader(writer.toByteArray());
		var wrong:Array<String> = [];
		for (i in 0...widths.length) {
			var got = reader.readBits(widths[i]);
			if (got != values[i] && wrong.length < 5) {
				wrong.push('field $i, ${widths[i]} bits: ${values[i]} came back as $got');
			}
		}
		Assert.same([], wrong);
		Assert.isTrue(reader.bitsRemaining < 8, "more than a byte's padding was left");
	}

	public function testSignedValuesKeepTheirSign():Void {
		var writer = new BitWriter();
		var expected:Array<Int> = [];
		var widths:Array<Int> = [];
		for (bits in 1...33) {
			var lowest = bits == 32 ? -2147483647 - 1 : -(1 << (bits - 1));
			var highest = bits == 32 ? 2147483647 : (1 << (bits - 1)) - 1;
			for (value in [lowest, highest, -1, 0]) {
				if (value < lowest || value > highest) continue;
				writer.writeInt(value, bits);
				expected.push(value);
				widths.push(bits);
			}
		}

		var reader = new BitReader(writer.finish());
		var got = [for (bits in widths) reader.readInt(bits)];
		Assert.same(expected, got);
	}

	public function testRangesUseOnlyTheBitsTheyNeed():Void {
		Assert.equals(0, BitWriter.bitsFor(7, 7));
		Assert.equals(1, BitWriter.bitsFor(0, 1));
		Assert.equals(8, BitWriter.bitsFor(0, 255));
		Assert.equals(9, BitWriter.bitsFor(0, 256));
		Assert.equals(4, BitWriter.bitsFor(-5, 5));
		Assert.equals(31, BitWriter.bitsFor(-2147483647 - 1, -1));

		var writer = new BitWriter();
		writer.writeRange(7, 7, 7);
		Assert.equals(0, writer.bitLength, "a range of one value takes no bits");
		writer.writeRange(-5, -5, 5);
		writer.writeRange(5, -5, 5);
		writer.writeRange(300, 0, 1000);
		Assert.equals(4 + 4 + 10, writer.bitLength);

		var reader = new BitReader(writer.finish());
		Assert.equals(7, reader.readRange(7, 7));
		Assert.equals(-5, reader.readRange(-5, 5));
		Assert.equals(5, reader.readRange(-5, 5));
		Assert.equals(300, reader.readRange(0, 1000));
	}

	public function testQuantizedValuesComeBackWithinHalfAStep():Void {
		var worst:Array<String> = [];
		for (bits in [1, 2, 7, 8, 12, 16, 20, 24, 31]) {
			var min = -123.25;
			var max = 4567.5;
			var step = (max - min) / (bits == 31 ? 2147483647.0 : (1 << bits) - 1);
			var writer = new BitWriter();
			var values = [for (_ in 0...200) min + (below(1000000) / 1000000) * (max - min)];
			for (v in values) {
				writer.writeQuantized(v, min, max, bits);
			}
			var reader = new BitReader(writer.finish());
			for (v in values) {
				var back = reader.readQuantized(min, max, bits);
				// Half a step, plus the rounding a double makes on numbers this
				// size -- which at 31 bits is not negligible beside the step.
				if (Math.abs(back - v) > step / 2 + 1e-9 && worst.length < 5) {
					worst.push('$bits bits: $v came back as $back, more than half of $step away');
				}
			}
		}
		Assert.same([], worst);
	}

	public function testQuantizedEndsAreExactAndOutsideIsClamped():Void {
		var writer = new BitWriter();
		for (value in [-0.1, 0.3, -5.0, 9.0]) {
			writer.writeQuantized(value, -0.1, 0.3, 10);
		}
		var reader = new BitReader(writer.finish());
		Assert.equals(-0.1, reader.readQuantized(-0.1, 0.3, 10));
		Assert.equals(0.3, reader.readQuantized(-0.1, 0.3, 10), "the top end landed off it");
		Assert.equals(-0.1, reader.readQuantized(-0.1, 0.3, 10), "below the range was not clamped");
		Assert.equals(0.3, reader.readQuantized(-0.1, 0.3, 10), "above the range was not clamped");
	}

	public function testFloatsComeBackBitForBit():Void {
		var values:Array<Float> = [0.0, -0.0, 1.5, -3.25, 3.4028234663852886e38, 1.401298464324817e-45, Math.POSITIVE_INFINITY,
			Math.NEGATIVE_INFINITY, Math.NaN];
		var writer = new BitWriter();
		writer.writeBool(true); // so every float straddles a word
		for (v in values) {
			writer.writeFloat(v);
		}
		var reader = new BitReader(writer.finish());
		Assert.isTrue(reader.readBool());
		for (v in values) {
			var back = reader.readFloat();
			Assert.equals(FPHelper.floatToI32(v), FPHelper.floatToI32(back), 'the bits of $v');
		}
	}

	// ------------------------------------------------------------- refusals

	public function testWhatDoesNotFitIsRefused():Void {
		var writer = new BitWriter();
		Assert.raises(() -> writer.writeBits(8, 3), ArgumentError);
		Assert.raises(() -> writer.writeBits(-1, 31), ArgumentError);
		Assert.raises(() -> writer.writeBits(1, 0), ArgumentError);
		Assert.raises(() -> writer.writeBits(1, 33), ArgumentError);
		Assert.raises(() -> writer.writeInt(4, 3), ArgumentError);
		Assert.raises(() -> writer.writeInt(-5, 3), ArgumentError);
		Assert.raises(() -> writer.writeRange(11, 0, 10), ArgumentError);
		Assert.raises(() -> writer.writeRange(0, 10, 0), ArgumentError);
		Assert.raises(() -> BitWriter.bitsFor(-2147483647 - 1, 2147483647), ArgumentError);
		Assert.raises(() -> writer.writeQuantized(Math.NaN, 0, 1, 8), ArgumentError);
		Assert.raises(() -> writer.writeQuantized(0.5, 1, 1, 8), ArgumentError);
		Assert.raises(() -> writer.writeQuantized(0.5, 0, Math.POSITIVE_INFINITY, 8), ArgumentError);
		Assert.raises(() -> writer.writeQuantized(0.5, 0, 1, 32), ArgumentError);
		Assert.equals(0, writer.bitLength, "a refused value was written anyway");

		// Every Int is a 32-bit pattern.
		writer.writeBits(-1, 32);
		Assert.equals(32, writer.bitLength);
	}

	public function testReadingPastTheEndThrows():Void {
		var writer = new BitWriter();
		writer.writeBits(5, 5);
		var reader = new BitReader(writer.finish());
		Assert.equals(8, reader.bitsRemaining, "one byte: five bits and three of padding");
		Assert.equals(5, reader.readBits(8));
		Assert.raises(() -> reader.readBits(1), EOFError);
		Assert.raises(() -> reader.readBits(0), ArgumentError);
	}

	public function testAReaderKeepsToItsWindow():Void {
		// Three bytes of message with a wall of ones either side: nothing the
		// reader returns may come from outside them.
		var bytes = new ByteArray();
		for (b in [0xFF, 0xFF, 0x01, 0x02, 0x03, 0xFF, 0xFF, 0xFF, 0xFF]) {
			bytes.writeByte(b);
		}
		var reader = new BitReader(bytes, 2, 3);
		Assert.equals(24, reader.bitsRemaining);
		Assert.equals(0x030201, reader.readBits(24));
		Assert.raises(() -> reader.readBits(1), EOFError);

		// A truncated message: a field that would need the bytes past the
		// window is refused, not assembled from them.
		reader.reset(bytes, 2, 3);
		reader.readBits(4);
		Assert.raises(() -> reader.readBits(21), EOFError);

		Assert.raises(() -> reader.reset(bytes, -1, 2), RangeError);
		Assert.raises(() -> reader.reset(bytes, 8, 2), RangeError);
		Assert.raises(() -> reader.reset(bytes, 10, 0), RangeError);
	}

	public function testARangeValuePastItsMaximumIsRefused():Void {
		// Three bits for 0 to 5; a peer can still send 6 or 7.
		var writer = new BitWriter();
		writer.writeBits(7, 3);
		var reader = new BitReader(writer.finish());
		Assert.raises(() -> reader.readRange(0, 5), RangeError);
	}

	// --------------------------------------------------------- the writer

	public function testAlignKeepsReaderAndWriterInStep():Void {
		var writer = new BitWriter();
		writer.writeBits(3, 3);
		writer.align();
		writer.writeBits(0xAB, 8);
		var aligned = writer.bitLength;
		writer.align();
		Assert.equals(aligned, writer.bitLength, "aligning on a byte boundary wrote something");
		Assert.equals("03ab", hex(writer.finish()));

		var reader = new BitReader(writer.finish());
		Assert.equals(3, reader.readBits(3));
		reader.align();
		Assert.equals(0xAB, reader.readBits(8));
	}

	public function testResetStartsCleanAndWritingMayContinueAfterFinish():Void {
		var writer = new BitWriter(4);
		writer.writeBits(-1, 32);
		writer.writeBits(-1, 32);
		writer.writeBits(0x7FFFFFFF, 31);
		writer.finish();
		writer.reset();
		writer.writeBits(0, 3);
		Assert.equals("00", hex(writer.finish()), "something survived the reset");

		writer.reset();
		writer.writeBits(0x15, 5);
		Assert.equals("15", hex(writer.finish()));
		writer.writeBits(0x1F, 5);
		Assert.equals("f503", hex(writer.finish()), "writing after finish lost its place");
	}

	public function testFinishLendsTheBufferAndToByteArrayCopiesIt():Void {
		var writer = new BitWriter();
		writer.writeBits(0x1234, 16);
		var lent = writer.finish();
		Assert.equals(lent, writer.finish());
		var copy = writer.toByteArray();
		Assert.notEquals(lent, copy);
		Assert.equals(hex(lent), hex(copy));
		writer.reset();
		writer.writeBits(0xFFFF, 16);
		writer.finish();
		Assert.equals("3412", hex(copy), "the copy changed with the writer");
	}

	public function testALargeMessageGrowsFromNothing():Void {
		var writer = new BitWriter(0);
		for (i in 0...10000) {
			writer.writeBits(i & 0x1FFF, 13);
			writer.writeBool((i & 1) == 1);
		}
		Assert.equals(10000 * 14, writer.bitLength);
		var reader = new BitReader(writer.finish());
		var wrong = -1;
		for (i in 0...10000) {
			if (reader.readBits(13) != (i & 0x1FFF) || reader.readBool() != ((i & 1) == 1)) {
				wrong = i;
				break;
			}
		}
		Assert.equals(-1, wrong, "the first record out of place");
	}

	// ------------------------------------------------------------- helpers

	private static function hex(bytes:ByteArray):String {
		var out = new StringBuf();
		for (i in 0...bytes.length) {
			out.add(StringTools.hex(bytes[i], 2).toLowerCase());
		}
		return out.toString();
	}
}
