package crossbyte.utils;

/**
 * Parses integers from text the same way on every target.
 *
 * `Std.parseInt` has no single answer for a number too big for an `Int`:
 * 4294967296 is 0 on Linux and macOS native (hxcpp's `strtol` result is cast
 * to `int`, keeping the low 32 bits), 2147483647 on Windows native, a thrown
 * `NumberFormatException` on the jvm, `null` on eval, and on JavaScript a
 * number wider than `Int` that is neither null nor negative. Code shaped like
 * `n == null || n < 0` is right on no target: on Linux a `Content-Length` of
 * 4294967296 read as 0. It also accepts signs, spaces and trailing text.
 *
 * These read digits only, check the bound before each digit so nothing ever
 * overflows, and answer `-1` for anything that is not a plain non-negative
 * number within the bound, which no valid result can be. An `Int` rather
 * than `Null<Int>` keeps the result unboxed on hxcpp and the jvm.
 *
 * ```haxe
 * var length:Int = IntParse.decimal(header, MAX_BODY);
 * if (length < 0) {
 *     reject();
 * }
 * ```
 */
class IntParse {
	/**
	 * Reads `text` as a non-negative decimal integer no greater than `max`.
	 *
	 * Leading zeros are allowed. Signs, spaces, a `0x` prefix and any other
	 * character are not.
	 *
	 * @param text The digits.
	 * @param max The largest value to accept. Defaults to the largest `Int`.
	 * @return The value, or `-1` when `text` is null, empty, not all digits,
	 *         or greater than `max` (or `max` is negative).
	 */
	public static function decimal(text:String, max:Int = 0x7FFFFFFF):Int {
		if (text == null || text.length == 0 || max < 0) {
			return -1;
		}

		// The classic strtol bound: past `cutoff`, or at it with a digit past
		// `cutlim`, the next step would exceed `max`. One division, before the
		// loop, and no intermediate ever leaves the range of an Int.
		final cutoff:Int = Std.int(max / 10);
		final cutlim:Int = max - cutoff * 10;
		var value:Int = 0;
		for (i in 0...text.length) {
			final digit:Int = StringTools.fastCodeAt(text, i) - 48;
			if (digit < 0 || digit > 9) {
				return -1;
			}
			if (value > cutoff || (value == cutoff && digit > cutlim)) {
				return -1;
			}
			value = value * 10 + digit;
		}
		return value;
	}

	/**
	 * Reads `text` as a non-negative hexadecimal integer no greater than
	 * `max`, in either letter case.
	 *
	 * Leading zeros are allowed, as they are in wire formats such as an HTTP
	 * chunk size. A `0x` prefix, signs and spaces are not.
	 *
	 * @param text The hex digits.
	 * @param max The largest value to accept. Defaults to the largest `Int`.
	 * @return The value, or `-1` when `text` is null, empty, not all hex
	 *         digits, or greater than `max` (or `max` is negative).
	 */
	public static function hex(text:String, max:Int = 0x7FFFFFFF):Int {
		if (text == null || text.length == 0 || max < 0) {
			return -1;
		}

		final cutoff:Int = max >> 4;
		final cutlim:Int = max & 15;
		var value:Int = 0;
		for (i in 0...text.length) {
			final code:Int = StringTools.fastCodeAt(text, i);
			final digit:Int = if (code >= 48 && code <= 57) {
				code - 48;
			} else if (code >= 97 && code <= 102) {
				code - 87;
			} else if (code >= 65 && code <= 70) {
				code - 55;
			} else {
				return -1;
			}
			if (value > cutoff || (value == cutoff && digit > cutlim)) {
				return -1;
			}
			value = (value << 4) | digit;
		}
		return value;
	}
}
