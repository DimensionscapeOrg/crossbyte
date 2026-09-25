package crossbyte.io;

import crossbyte.errors.ArgumentError;
import crossbyte.errors.EOFError;
import crossbyte.errors.RangeError;
import haxe.io.Bytes;
import haxe.io.FPHelper;

/**
 * Reads back what a `BitWriter` wrote, in the same order and widths.
 *
 * ```haxe
 * var reader = new BitReader(message);
 * while (reader.bitsRemaining >= RECORD_BITS) {
 * 	var slot = reader.readBits(10);
 * 	var x = reader.readQuantized(0, WORLD, 16);
 * 	var y = reader.readQuantized(0, WORLD, 16);
 * 	var moving = reader.readBool();
 * }
 * ```
 *
 * The bytes are the peer's, so nothing here trusts them: every read checks
 * that the bits it asks for are there and throws `EOFError` when they are
 * not, a range that decodes past its maximum throws `RangeError`, and the
 * last few bytes -- fewer than a whole word -- are read one at a time rather
 * than as a word that would run past the end.
 *
 * One reader can be pointed at message after message with `reset`, so
 * reading allocates nothing.
 *
 * **Threading.** None.
 */
final class BitReader {
	/**
	 * Bits left to read. Includes the zero padding a writer's final byte ends
	 * with, which is fewer than eight.
	 */
	public var bitsRemaining(get, never):Int;

	private var __bytes:Bytes;
	private var __wordAt:Int = 0;
	private var __end:Int = 0;
	private var __scratch:Int = 0;
	private var __scratchBits:Int = 0;

	/**
	 * @param bytes What to read; nothing, until `reset` gives it something.
	 * @param offset Where in `bytes` the packed bits begin.
	 * @param length How many bytes they take; the rest of `bytes` by default.
	 */
	public function new(?bytes:ByteArray, offset:Int = 0, length:Int = -1) {
		if (bytes != null) {
			reset(bytes, offset, length);
		}
	}

	/**
	 * Starts reading `bytes` from the beginning, forgetting what came before.
	 *
	 * @throws RangeError If `offset` and `length` do not lie within `bytes`.
	 */
	public function reset(bytes:ByteArray, offset:Int = 0, length:Int = -1):Void {
		var total:Int = bytes.length;
		if (length < 0) {
			length = total - offset;
		}
		if (offset < 0 || offset > total || length < 0 || length > total - offset) {
			throw new RangeError("The supplied range is out of bounds.");
		}
		__bytes = bytes;
		__wordAt = offset;
		__end = offset + length;
		__scratch = 0;
		__scratchBits = 0;
	}

	/**
	 * Reads `bits` bits, 1 to 32, as an unsigned number -- which at 32 bits is
	 * whatever Int those bits make.
	 *
	 * @throws ArgumentError If `bits` is outside 1 to 32.
	 * @throws EOFError If fewer than `bits` bits are left.
	 */
	public function readBits(bits:Int):Int {
		if (bits < 1 || bits > 32) {
			throw new ArgumentError('A field is 1 to 32 bits, not $bits.');
		}
		return __take(bits);
	}

	/**
	 * Reads one bit.
	 *
	 * @throws EOFError If none is left.
	 */
	public inline function readBool():Bool {
		return __take(1) != 0;
	}

	/**
	 * Reads a signed value `BitWriter.writeInt` wrote in `bits` bits.
	 */
	public function readInt(bits:Int):Int {
		var value:Int = readBits(bits);
		if (bits == 32) {
			return value;
		}
		var shift:Int = 32 - bits;
		return (value << shift) >> shift;
	}

	/**
	 * Reads an integer `BitWriter.writeRange` wrote with the same bounds.
	 *
	 * @throws RangeError If the bits decode past `max`, which a writer given
	 *         the same bounds cannot produce.
	 */
	public function readRange(min:Int, max:Int):Int {
		var bits:Int = BitWriter.bitsFor(min, max);
		if (bits == 0) {
			return min;
		}
		var offset:Int = __take(bits);
		if (offset > max - min) {
			throw new RangeError('A value past the range $min to $max was read.');
		}
		return min + offset;
	}

	/**
	 * Reads a value `BitWriter.writeQuantized` wrote with the same range and
	 * width. The ends come back exactly.
	 */
	public function readQuantized(min:Float, max:Float, bits:Int):Float {
		var steps:Float = BitWriter.quantizedSteps(min, max, bits);
		var t:Float = __take(bits) / steps;
		// Interpolated rather than min + t * (max - min), which can land an
		// ulp past `max` when t is 1.
		return min * (1 - t) + max * t;
	}

	/**
	 * Reads a float `BitWriter.writeFloat` wrote.
	 */
	public inline function readFloat():Float {
		return FPHelper.i32ToFloat(__take(32));
	}

	/**
	 * Skips to the next whole byte, past the padding `BitWriter.align` wrote.
	 */
	public function align():Void {
		var partial:Int = __scratchBits & 7;
		if (partial != 0) {
			__take(partial);
		}
	}

	private inline function get_bitsRemaining():Int {
		return ((__end - __wordAt) << 3) + __scratchBits;
	}

	// `__scratch` holds exactly `__scratchBits` unread bits, lowest first, with
	// zeros above them: both the shift below and a load keep it that way, so
	// the bits of the next word can simply be or-ed on above them.
	private function __take(bits:Int):Int {
		if (bits > ((__end - __wordAt) << 3) + __scratchBits) {
			throw new EOFError();
		}

		if (bits <= __scratchBits) {
			var value:Int = bits == 32 ? __scratch : __scratch & ((1 << bits) - 1);
			__scratch = bits == 32 ? 0 : __scratch >>> bits;
			__scratchBits -= bits;
			return value;
		}

		// Not enough gathered: the low part is what there is, the rest comes
		// from the next word, and whatever that word has left over is kept.
		var low:Int = __scratch;
		var have:Int = __scratchBits;
		var need:Int = bits - have;
		var loaded:Int = __load();
		var next:Int = __scratch;
		var value:Int = have == 0 ? next : low | (next << have);
		if (bits < 32) {
			value &= (1 << bits) - 1;
		}
		// `>>> 32` is `>>> 0` where the count is masked: nothing is left then.
		__scratch = need == 32 ? 0 : next >>> need;
		__scratchBits = loaded - need;
		return value;
	}

	// Loads the next word into __scratch and says how many bits it brought:
	// 32, or fewer at the very end, where the last bytes are read one at a
	// time rather than as a word that would run past them.
	private function __load():Int {
		var left:Int = __end - __wordAt;
		if (left >= 4) {
			__scratch = __bytes.getInt32(__wordAt);
			__wordAt += 4;
			return 32;
		}
		var word:Int = 0;
		for (i in 0...left) {
			word |= __bytes.get(__wordAt + i) << (i << 3);
		}
		__scratch = word;
		__wordAt += left;
		return left << 3;
	}
}
