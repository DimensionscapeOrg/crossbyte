package crossbyte.db.mongodb.bson;

import crossbyte.errors.ArgumentError;
import haxe.io.Bytes;

/**
	A BSON Decimal128: an IEEE 754-2008 decimal floating point number of up to
	34 significant digits, held exactly.

	Money, and anything else that must not pass through a binary `Float`,
	belongs in one. Nothing here converts through `Float`: the value is its 16
	bytes, `toString` gives the exact decimal text by the BSON specification's
	rules, and `fromString` parses text to exactly those bytes -- or refuses
	it, where the text cannot be held without rounding.

	```haxe
	import crossbyte.db.mongodb.MongoConnection;

	// Given connection:MongoConnection.
	var price = Decimal128.fromString("19.99");
	connection.insert("orders", [{price: price}]);
	```
**/
final class Decimal128 {
	/** The 16 bytes, little-endian, as BSON stores them. Not to be modified. **/
	public var bytes(default, null):Bytes;

	@:noCompletion private static inline var EXPONENT_BIAS:Int = 6176;
	@:noCompletion private static inline var EXPONENT_MAX:Int = 6111;
	@:noCompletion private static inline var EXPONENT_MIN:Int = -6176;
	@:noCompletion private static inline var MAX_DIGITS:Int = 34;

	/** Wraps 16 bytes, little-endian, as they are stored. **/
	public function new(bytes:Bytes) {
		if (bytes == null || bytes.length != 16) {
			throw new ArgumentError("A Decimal128 is 16 bytes.");
		}

		this.bytes = bytes;
	}

	/**
		Parses decimal text: an optional sign, digits with an optional point,
		and an optional exponent -- `-12.50`, `1E+3`, `0.000001` -- or
		`Infinity`, `Inf` or `NaN` in either case.

		@throws ArgumentError When `text` is not a number, has more significant
		digits than 34 that are not trailing zeros, or has an exponent out of
		range: anything that could only be stored rounded.
	**/
	public static function fromString(text:String):Decimal128 {
		if (text == null || text.length == 0) {
			throw new ArgumentError("Not a decimal number: empty text.");
		}

		var i:Int = 0;
		var negative:Bool = false;
		var first:Int = StringTools.fastCodeAt(text, 0);

		if (first == "+".code || first == "-".code) {
			negative = first == "-".code;
			i = 1;
		}

		var rest:String = text.substr(i).toLowerCase();

		if (rest == "infinity" || rest == "inf") {
			return __special(negative ? 0xF8 : 0x78);
		}

		if (rest == "nan") {
			return __special(negative ? 0xFC : 0x7C);
		}

		// The significand's digits, and where the point fell among them.
		var digits:StringBuf = new StringBuf();
		var digitCount:Int = 0;
		var afterPoint:Int = 0;
		var sawPoint:Bool = false;
		var sawDigit:Bool = false;

		while (i < text.length) {
			var c:Int = StringTools.fastCodeAt(text, i);

			if (c >= "0".code && c <= "9".code) {
				sawDigit = true;

				// Leading zeros carry no information, and dropping them here
				// keeps the count honest.
				if (digitCount > 0 || c != "0".code) {
					digits.addChar(c);
					digitCount++;
				}

				if (sawPoint) {
					afterPoint++;
				}
			} else if (c == ".".code && !sawPoint) {
				sawPoint = true;
			} else {
				break;
			}

			i++;
		}

		if (!sawDigit) {
			throw new ArgumentError('Not a decimal number: "$text".');
		}

		var exponent:Int = 0;

		if (i < text.length) {
			var e:Int = StringTools.fastCodeAt(text, i);

			if (e != "e".code && e != "E".code) {
				throw new ArgumentError('Not a decimal number: "$text".');
			}

			i++;
			var exponentNegative:Bool = false;

			if (i < text.length && (StringTools.fastCodeAt(text, i) == "+".code || StringTools.fastCodeAt(text, i) == "-".code)) {
				exponentNegative = StringTools.fastCodeAt(text, i) == "-".code;
				i++;
			}

			if (i >= text.length) {
				throw new ArgumentError('Not a decimal number: "$text".');
			}

			while (i < text.length) {
				var d:Int = StringTools.fastCodeAt(text, i);

				if (d < "0".code || d > "9".code) {
					throw new ArgumentError('Not a decimal number: "$text".');
				}

				// Capped well past any exponent that could be clamped into
				// range, so a thousand-digit exponent cannot overflow the Int.
				if (exponent < 100000000) {
					exponent = exponent * 10 + (d - "0".code);
				}

				i++;
			}

			if (exponentNegative) {
				exponent = -exponent;
			}
		}

		var significand:String = digitCount == 0 ? "0" : digits.toString();
		exponent -= afterPoint;

		// More digits than fit: only trailing zeros may go, since dropping
		// anything else would round, and a driver must not round silently.
		if (significand.length > MAX_DIGITS) {
			var cut:Int = significand.length - MAX_DIGITS;

			for (k in MAX_DIGITS...significand.length) {
				if (StringTools.fastCodeAt(significand, k) != "0".code) {
					throw new ArgumentError('"$text" has more than $MAX_DIGITS significant digits and cannot be held exactly.');
				}
			}

			significand = significand.substr(0, MAX_DIGITS);
			exponent += cut;
		}

		var zero:Bool = significand == "0";

		if (exponent > EXPONENT_MAX) {
			if (zero) {
				exponent = EXPONENT_MAX;
			} else {
				// Clamped: the same value with trailing zeros in the
				// significand, while there is room for them.
				while (exponent > EXPONENT_MAX && significand.length < MAX_DIGITS) {
					significand += "0";
					exponent--;
				}

				if (exponent > EXPONENT_MAX) {
					throw new ArgumentError('"$text" is too large for a Decimal128.');
				}
			}
		}

		if (exponent < EXPONENT_MIN) {
			if (zero) {
				exponent = EXPONENT_MIN;
			} else {
				while (exponent < EXPONENT_MIN && significand.length > 1 && StringTools.fastCodeAt(significand, significand.length - 1) == "0".code) {
					significand = significand.substr(0, significand.length - 1);
					exponent++;
				}

				if (exponent < EXPONENT_MIN) {
					throw new ArgumentError('"$text" is too small for a Decimal128 to hold exactly.');
				}
			}
		}

		// The significand into eight 16-bit limbs, least significant first.
		var limbs:Array<Int> = [0, 0, 0, 0, 0, 0, 0, 0];

		for (k in 0...significand.length) {
			var carry:Int = StringTools.fastCodeAt(significand, k) - "0".code;

			for (l in 0...8) {
				var v:Int = limbs[l] * 10 + carry;
				limbs[l] = v & 0xFFFF;
				carry = v >>> 16;
			}
		}

		var biased:Int = exponent + EXPONENT_BIAS;
		var out:Bytes = Bytes.alloc(16);

		// The low 112 bits of the significand, then its 113th bit beside the
		// exponent in the top two bytes' neighbours.
		for (l in 0...7) {
			out.set(l * 2, limbs[l] & 0xFF);
			out.set(l * 2 + 1, (limbs[l] >> 8) & 0xFF);
		}

		// Byte 14 holds the significand's bit 112 and the exponent's low 7
		// bits; byte 15 the sign and the exponent's high 7 bits.
		out.set(14, (limbs[7] & 0x01) | ((biased & 0x7F) << 1));
		out.set(15, ((biased >> 7) & 0x7F) | (negative ? 0x80 : 0));
		return new Decimal128(out);
	}

	/**
		The exact decimal text, by the BSON specification's rules: plain
		notation (`12.50`, `0.000001`) for moderate exponents and scientific
		(`1.0E+3`, `1.234E-7`) otherwise, so text parsed and printed again
		comes back the same.
	**/
	public function toString():String {
		var top:Int = bytes.get(15);
		var negative:Bool = (top & 0x80) != 0;
		// The five bits after the sign.
		var combination:Int = (top >> 2) & 0x1F;

		if ((combination >> 3) == 3) {
			if (combination == 0x1E) {
				return negative ? "-Infinity" : "Infinity";
			}

			if (combination == 0x1F) {
				return "NaN";
			}
		}

		var biased:Int;
		var limbs:Array<Int> = [0, 0, 0, 0, 0, 0, 0, 0];

		if ((combination >> 3) == 3) {
			// The form whose significand starts 100 in binary: always more
			// than 34 digits, so non-canonical, and read as zero.
			biased = ((top & 0x1F) << 9) | (bytes.get(14) << 1) | (bytes.get(13) >> 7);
		} else {
			biased = ((top & 0x7F) << 7) | (bytes.get(14) >> 1);

			for (l in 0...7) {
				limbs[l] = bytes.get(l * 2) | (bytes.get(l * 2 + 1) << 8);
			}

			limbs[7] = bytes.get(14) & 0x01;
		}

		var digits:String = __digits(limbs);

		// A significand past 34 digits is non-canonical, and read as zero.
		if (digits.length > MAX_DIGITS) {
			digits = "0";
		}

		var exponent:Int = biased - EXPONENT_BIAS;
		var adjusted:Int = exponent + digits.length - 1;
		var out:StringBuf = new StringBuf();

		if (negative) {
			out.add("-");
		}

		if (exponent > 0 || adjusted < -6) {
			out.add(digits.charAt(0));

			if (digits.length > 1) {
				out.add(".");
				out.add(digits.substr(1));
			}

			out.add("E");
			out.add(adjusted >= 0 ? "+" : "-");
			out.add(Std.string(adjusted >= 0 ? adjusted : -adjusted));
		} else if (exponent == 0) {
			out.add(digits);
		} else {
			var fraction:Int = -exponent;

			if (digits.length > fraction) {
				out.add(digits.substr(0, digits.length - fraction));
				out.add(".");
				out.add(digits.substr(digits.length - fraction));
			} else {
				out.add("0.");

				for (_ in 0...(fraction - digits.length)) {
					out.add("0");
				}

				out.add(digits);
			}
		}

		return out.toString();
	}

	/** Whether this is NaN. **/
	public function isNaN():Bool {
		return ((bytes.get(15) >> 2) & 0x1F) == 0x1F;
	}

	/** Whether this is positive or negative infinity. **/
	public function isInfinite():Bool {
		return ((bytes.get(15) >> 2) & 0x1F) == 0x1E;
	}

	/**
		The nearest `Float`. Lossy by nature -- the reason to hold a
		Decimal128 at all is that most decimals have no exact binary form.
	**/
	public function toFloat():Float {
		var text:String = toString();

		if (text == "NaN") {
			return Math.NaN;
		}

		if (text == "Infinity") {
			return Math.POSITIVE_INFINITY;
		}

		if (text == "-Infinity") {
			return Math.NEGATIVE_INFINITY;
		}

		return Std.parseFloat(text);
	}

	/** Whether `other` holds the same 16 bytes: `1.0` and `1.00` differ. **/
	public function equals(other:Decimal128):Bool {
		return other != null && other.bytes.compare(bytes) == 0;
	}

	@:noCompletion private static function __special(top:Int):Decimal128 {
		var out:Bytes = Bytes.alloc(16);
		out.fill(0, 16, 0);
		out.set(15, top);
		return new Decimal128(out);
	}

	/** The limbs' value in decimal, with no leading zeros. **/
	@:noCompletion private static function __digits(limbs:Array<Int>):String {
		var work:Array<Int> = limbs.copy();
		var chunks:Array<Int> = [];

		while (true) {
			var nonzero:Bool = false;

			for (l in work) {
				if (l != 0) {
					nonzero = true;
					break;
				}
			}

			if (!nonzero) {
				break;
			}

			// Divided by 10000 a limb at a time, most significant first; the
			// running value stays below 10000 * 65536, well inside an Int.
			var remainder:Int = 0;
			var l:Int = 7;

			while (l >= 0) {
				var current:Int = remainder * 65536 + work[l];
				work[l] = Std.int(current / 10000);
				remainder = current - work[l] * 10000;
				l--;
			}

			chunks.push(remainder);
		}

		if (chunks.length == 0) {
			return "0";
		}

		var out:StringBuf = new StringBuf();
		var c:Int = chunks.length - 1;
		out.add(Std.string(chunks[c]));

		while (--c >= 0) {
			var part:String = Std.string(chunks[c]);

			for (_ in part.length...4) {
				out.add("0");
			}

			out.add(part);
		}

		return out.toString();
	}
}
