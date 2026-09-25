package crossbyte.io;

import crossbyte.errors.ArgumentError;
import haxe.io.Bytes;
import haxe.io.FPHelper;

/**
 * Values packed into as few bits as they need, for messages sent often
 * enough that the bytes add up: snapshots, inputs, anything per entity per
 * tick. `BitReader` reads them back.
 *
 * ```haxe
 * var writer = new BitWriter();
 * for (entity in view) {
 * 	writer.writeBits(entity.slot, 10);                    // 0..1023
 * 	writer.writeQuantized(entity.x, 0, WORLD, 16);        // WORLD / 65535 apart
 * 	writer.writeQuantized(entity.y, 0, WORLD, 16);
 * 	writer.writeBool(entity.moving);
 * }
 * var bytes:ByteArray = writer.finish();
 * socket.send(bytes, 0, bytes.length, DeliveryMode.sequenced(0));
 * writer.reset();
 * ```
 *
 * **Layout.** Bits fill 32-bit words from the lowest bit up, and each word is
 * stored little-endian, so the first value written is in the low bits of the
 * first byte. The result is trimmed to whole bytes -- `length` is the bits
 * written rounded up to the next eight -- and is the same bytes on every
 * target.
 *
 * **Speed.** Values gather in one 32-bit word and go into the buffer a word at
 * a time; a value that straddles two words is split with two shifts. Nothing
 * is allocated per value, and the buffer is kept across `reset`, so a writer
 * reused every tick allocates nothing once it has grown to the largest
 * message.
 *
 * **With `ByteDelta`.** A delta finds unchanged bytes, and packing shifts
 * every later field when an earlier one changes width. Give each record a
 * fixed number of bits and `align` after it, and unchanged records stay
 * unchanged bytes.
 *
 * **Out of range is refused, not truncated.** A value that does not fit the
 * bits asked for throws rather than losing its high bits, which would decode
 * as a different, plausible value.
 *
 * **Threading.** None.
 */
final class BitWriter {
	/**
	 * Bits written so far.
	 */
	public var bitLength(get, never):Int;

	/**
	 * Bytes the written bits occupy: `bitLength` rounded up to whole bytes.
	 */
	public var length(get, never):Int;

	// Whole words land here; the buffer is a ByteArray so `finish` can hand
	// it over as one, but it is written as the Bytes it is underneath.
	private var __buffer:ByteArray;

	// Bytes of whole words written so far.
	private var __wordAt:Int = 0;

	// Bytes the buffer holds before it must grow. Tracked here rather than
	// read from the ByteArray, whose length `finish` shortens to hand it over:
	// restoring that once per message costs a short fill, where lengthening it
	// word by word would cost a call per word.
	private var __capacity:Int;

	// Bits gathered and not yet stored, lowest first, and how many.
	private var __scratch:Int = 0;
	private var __scratchBits:Int = 0;

	/**
	 * @param capacity Bytes to make room for at the start; the buffer grows as
	 *        needed and is kept across `reset`.
	 */
	public function new(capacity:Int = 64) {
		if (capacity < 0) {
			throw new ArgumentError("capacity cannot be negative.");
		}
		__buffer = new ByteArray();
		__capacity = (capacity + 3) & ~3;
		__buffer.length = __capacity;
	}

	/**
	 * Writes the low `bits` bits of `value`, 1 to 32 of them.
	 *
	 * @throws ArgumentError If `bits` is outside 1 to 32, or `value` does not
	 *         fit in them as an unsigned number. At 32 every Int fits.
	 */
	public function writeBits(value:Int, bits:Int):Void {
		if (bits < 1 || bits > 32) {
			throw new ArgumentError('A field is 1 to 32 bits, not $bits.');
		}
		// Every bit above `bits` must be zero, a negative's sign bit included.
		if (bits < 32 && (value >>> bits) != 0) {
			throw new ArgumentError('$value does not fit in $bits unsigned bits.');
		}
		__put(value, bits);
	}

	/**
	 * Writes one bit.
	 */
	public inline function writeBool(value:Bool):Void {
		__put(value ? 1 : 0, 1);
	}

	/**
	 * Writes a signed value in `bits` bits, two's complement; `BitReader.readInt`
	 * restores the sign.
	 *
	 * @throws ArgumentError If `value` is outside what `bits` signed bits hold:
	 *         -2^(bits-1) to 2^(bits-1) - 1.
	 */
	public function writeInt(value:Int, bits:Int):Void {
		if (bits < 1 || bits > 32) {
			throw new ArgumentError('A field is 1 to 32 bits, not $bits.');
		}
		if (bits < 32) {
			var half:Int = 1 << (bits - 1);
			if (value < -half || value >= half) {
				throw new ArgumentError('$value does not fit in $bits signed bits.');
			}
			value &= (1 << bits) - 1;
		}
		__put(value, bits);
	}

	/**
	 * Writes an integer known to lie in `min` to `max`, in only the bits that
	 * range needs -- none at all when `min == max`. `BitReader.readRange` with
	 * the same bounds reads it back.
	 *
	 * @throws ArgumentError If `max < min`, the range spans more than 2^31 - 1,
	 *         or `value` is outside it.
	 */
	public function writeRange(value:Int, min:Int, max:Int):Void {
		var bits:Int = bitsFor(min, max);
		if (value < min || value > max) {
			throw new ArgumentError('$value is outside $min to $max.');
		}
		if (bits > 0) {
			__put(value - min, bits);
		}
	}

	/**
	 * Writes `value` as one of 2^`bits` evenly spaced points from `min` to
	 * `max`, both ends included. What comes back is within half a step of what
	 * went in, a step being (`max` - `min`) / (2^`bits` - 1). A value outside
	 * the range is clamped to it.
	 *
	 * @param bits 1 to 31.
	 * @throws ArgumentError If `bits` is outside 1 to 31, the range is not
	 *         finite with `max` above `min`, or `value` is NaN.
	 */
	public function writeQuantized(value:Float, min:Float, max:Float, bits:Int):Void {
		var steps:Float = quantizedSteps(min, max, bits);
		if (Math.isNaN(value)) {
			throw new ArgumentError("A quantized value cannot be NaN.");
		}
		var t:Float = value <= min ? 0.0 : (value >= max ? 1.0 : (value - min) / (max - min));
		// Rounded as floor(x + 0.5), which is the same arithmetic on every
		// target -- Math.round is not specified identically for halves.
		__put(Std.int(t * steps + 0.5), bits);
	}

	/**
	 * Writes a float as its 32-bit IEEE pattern, which is exact for anything
	 * a 32-bit float holds.
	 */
	public inline function writeFloat(value:Float):Void {
		__put(FPHelper.floatToI32(value), 32);
	}

	/**
	 * Pads with zero bits to the next whole byte, if not already on one.
	 * `BitReader.align` skips the same padding.
	 */
	public inline function align():Void {
		var partial:Int = __scratchBits & 7;
		if (partial != 0) {
			__put(0, 8 - partial);
		}
	}

	/**
	 * What has been written, as bytes: the writer's own buffer, `length` long
	 * and positioned at 0, not a copy. Valid until the next write or `reset`;
	 * writing may continue after it, and a later `finish` includes both.
	 */
	public function finish():ByteArray {
		var bytes:Int = length;
		if (__buffer.length < __wordAt + 4) {
			__ensure(__wordAt + 4);
		}
		// The unfinished word, stored whole; `length` then trims it to the
		// bytes the bits reach.
		(__buffer : Bytes).setInt32(__wordAt, __scratch);
		__buffer.length = bytes;
		__buffer.position = 0;
		return __buffer;
	}

	/**
	 * What has been written, in a ByteArray of its own.
	 */
	public function toByteArray():ByteArray {
		var view:ByteArray = finish();
		var copy = new ByteArray();
		if (view.length > 0) {
			copy.length = view.length;
			(copy : Bytes).blit(0, view, 0, view.length);
		}
		copy.position = 0;
		return copy;
	}

	/**
	 * Starts again from nothing, keeping the buffer.
	 */
	public inline function reset():Void {
		__wordAt = 0;
		__scratch = 0;
		__scratchBits = 0;
	}

	/**
	 * The bits an integer from `min` to `max` needs: 0 when they are equal,
	 * and the width of `max - min` otherwise.
	 *
	 * @throws ArgumentError If `max < min` or the span passes 2^31 - 1.
	 */
	public static function bitsFor(min:Int, max:Int):Int {
		// `| 0` because JavaScript does not wrap Int arithmetic: the full Int
		// range there comes out as 4294967295 rather than negative, and was
		// taken for 32 bits where every other target refuses it.
		var span:Int = (max - min) | 0;
		// Negative when max is below min, or when the subtraction overflowed.
		if (max < min || span < 0) {
			throw new ArgumentError('$min to $max is not a range of at most 2^31 - 1.');
		}
		var bits:Int = 0;
		while (span != 0) {
			bits++;
			span >>>= 1;
		}
		return bits;
	}

	/**
	 * The highest quantized value `bits` bits hold, as the Float it is divided
	 * by, after checking the range and width a quantized field is given.
	 */
	@:noCompletion public static function quantizedSteps(min:Float, max:Float, bits:Int):Float {
		if (bits < 1 || bits > 31) {
			throw new ArgumentError('A quantized field is 1 to 31 bits, not $bits.');
		}
		if (!Math.isFinite(min) || !Math.isFinite(max) || !(max > min)) {
			throw new ArgumentError('A quantized range needs finite bounds with the maximum above the minimum, not $min to $max.');
		}
		return bits == 31 ? 2147483647.0 : ((1 << bits) - 1 : Float);
	}

	private inline function get_bitLength():Int {
		return (__wordAt << 3) + __scratchBits;
	}

	private inline function get_length():Int {
		return ((__wordAt << 3) + __scratchBits + 7) >> 3;
	}

	// Gathers `bits` bits of `value`, already known to fit, and stores the
	// word when it fills. The part of the value that did not fit the word
	// starts the next one.
	private inline function __put(value:Int, bits:Int):Void {
		__scratch |= value << __scratchBits;
		var total:Int = __scratchBits + bits;
		if (total < 32) {
			__scratchBits = total;
		} else {
			__store(__scratch);
			var used:Int = 32 - __scratchBits;
			// `>>> 32` is `>>> 0` on the targets that mask the count, which
			// would bring the whole value back: none of it is left over then.
			__scratch = used == 32 ? 0 : value >>> used;
			__scratchBits = total - 32;
		}
	}

	private inline function __store(word:Int):Void {
		var end:Int = __wordAt + 4;
		if (__buffer.length < end) {
			__ensure(end);
		}
		(__buffer : Bytes).setInt32(__wordAt, word);
		__wordAt = end;
	}

	// Room for `end` bytes: doubling when the buffer is outgrown, and
	// restoring its full length after `finish` shortened it.
	private function __ensure(end:Int):Void {
		if (end > __capacity) {
			__capacity = end > __capacity * 2 ? end : __capacity * 2;
		}
		__buffer.length = __capacity;
	}
}
