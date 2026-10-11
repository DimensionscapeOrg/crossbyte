package crossbyte;

import crossbyte.utils.IntParse;

/**
 * An abstract type representing a generic primitive value.
 *
 * This abstract provides seamless conversion between `String`, `Int`, `Float`, and `Bool`,
 * allowing for flexible handling of primitive types.
 *
 * ## Supported Types:
 * - `String`
 * - `Int`
 * - `Float`
 * - `Bool`
 *
 * A null `String` stays null, as a null `Dynamic` through `fromDynamic`
 * does: `isNull()` is true, and it converts as null does, to `0`, `0.0`,
 * `false` and back to a null `String`. A `Float` that is NaN is held as
 * `0.0`. A conversion that cannot be made throws a `String`.
 *
 * ## Example:
 * ```haxe
 * var p:PrimitiveValue = 42;
 * var s:String = p; // Automatic conversion to "42"
 * var b:Bool = p.toBool(); // true
 * ```
 */
abstract PrimitiveValue(Dynamic) to Dynamic {
	public static inline function tryFromDynamic(value:Dynamic):Null<PrimitiveValue> {
		return isValid(value) ? cast value : null;
	}

	public static inline function fromDynamic(value:Dynamic):PrimitiveValue {
		if (!isValid(value)) {
			throw "Cannot convert " + Std.string(value) + " to PrimitiveValue";
		}
		return cast value;
	}

	/**
		The value's type, as `Type.typeof` gives it, except that a whole
		`Float` within `Int`'s range is `TInt` on every target, as `isInt`
		says.
	**/
	public inline function getValueType():Type.ValueType {
		var type:Type.ValueType = Type.typeof(this);
		return type == TFloat && __isWhole(this) ? TInt : type;
	}

	public inline function isString():Bool {
		return switch (Type.typeof(this)) {
			case TClass(String): true;
			default: false;
		};
	}

	/**
		Whether the value is an `Int`: one, or a `Float` with no fraction
		within `Int`'s range (`1.0`, `-0.0`), on every target. JavaScript
		cannot tell `1.0` from `1`, and natively and on the jvm `Type.typeof`
		answers `TInt` for it too; eval and neko kept it a `Float`.
	**/
	public inline function isInt():Bool {
		return switch (Type.typeof(this)) {
			case TInt: true;
			case TFloat: __isWhole(this);
			default: false;
		};
	}

	/** Whether the value is a `Float` that `isInt` does not take: one with a fraction, outside `Int`'s range, infinite or NaN. **/
	public inline function isFloat():Bool {
		return switch (Type.typeof(this)) {
			case TFloat: !__isWhole(this);
			default: false;
		};
	}

	@:noCompletion private static function __isWhole(value:Float):Bool {
		return value >= -2147483648.0 && value <= 2147483647.0 && value == Math.ffloor(value);
	}

	public inline function isBool():Bool {
		return switch (Type.typeof(this)) {
			case TBool: true;
			default: false;
		};
	}

	public inline function isNull():Bool {
		return switch (Type.typeof(this)) {
			case TNull: true;
			default: false;
		};
	}

	/**
	 * Converts the primitive to a `String`.
	 * @return The string representation of the primitive, or null for a null
	 *         value, so a null `String` comes back as it went in.
	 */
	@:to public inline function toString():String {
		return this == null ? null : Std.string(this);
	}

	/**
	 * Converts the primitive to an `Int`.
	 *
	 * - Strings are parsed as integers: surrounding spaces, then an optional
	 *   sign, then decimal digits or `0x` and hex digits, and nothing else.
	 * - Floats are truncated toward zero.
	 * - `true` becomes `1`, `false` becomes `0`.
	 * - `null` converts to `0`.
	 *
	 * A string or a Float whose value is not an `Int` (too large, too small,
	 * not a number) throws on every target, as anything else that cannot be
	 * converted does.
	 *
	 * @return The integer representation of the primitive.
	 * @throws If conversion is not possible.
	 */
	@:to public inline function toInt():Int {
		switch (Type.typeof(this)) {
			case TInt:
				return this;
			case TFloat:
				var f:Float = this;
				if (!(f > -2147483649.0 && f < 2147483648.0)) {
					throw "Cannot convert " + Std.string(this) + " to Int";
				}
				return Std.int(f);
			case TBool:
				return this ? 1 : 0;
			case TClass(String):
				return __parseInt(this);
			case TNull:
				return 0;
			default:
				throw "Cannot convert " + Std.string(this) + " to Int";
		}
	}

	/**
	 * Converts the primitive to a `Float`.
	 *
	 * - Strings are read as a number: surrounding spaces, an optional sign,
	 *   then decimal digits with an optional fraction and exponent (`1.5`,
	 *   `.5`, `2e-3`), `0x` and hex digits, or `Infinity` (or `inf`, in any
	 *   case). Anything else, `""` and `"12abc"` included, is `NaN`. Every
	 *   target reads the same text as the same number.
	 * - An `Int` becomes the same number as a `Float`, which on eval and neko
	 *   means one that adds past 2^31 without wrapping.
	 * - `true` becomes `1.0`, `false` becomes `0.0`.
	 * - `null` converts to `0.0`.
	 *
	 * @return The float representation of the primitive.
	 * @throws If the primitive holds something other than a string, a number,
	 *         a `Bool` or null.
	 */
	@:to public inline function toFloat():Float {
		switch (Type.typeof(this)) {
			case TInt:
				// On eval and neko a Float given an Int stays one, and two of
				// them add as Ints; `+ 0.0` on an Int makes it a Float there.
				var whole:Int = this;
				return whole + 0.0;
			case TFloat:
				return this;
			case TBool:
				return this ? 1.0 : 0.0;
			case TClass(String):
				return __parseFloat(this);
			case TNull:
				return 0.0;
			default:
				throw "Cannot convert " + Std.string(this) + " to Float";
		}
	}

	/**
	 * Converts the primitive to a `Bool`.
	 *
	 * - `0` or `0.0` converts to `false`, any other number (NaN, which only
	 *   `fromDynamic` can hold, included) is `true`.
	 * - A string converts to `false` when, without its surrounding spaces and
	 *   in any case, it is `""`, `"0"` or `"false"`, and to `true` otherwise.
	 * - `null` converts to `false`.
	 *
	 * @return The boolean representation of the primitive.
	 * @throws If conversion is not possible.
	 */
	@:to public inline function toBool():Bool {
		switch (Type.typeof(this)) {
			case TInt:
				return this != 0;
			case TFloat:
				return this != 0.0;
			case TBool:
				return this;
			case TClass(String):
				var s:String = StringTools.trim((this : String)).toLowerCase();
				return s != "" && s != "0" && s != "false";
			case TNull:
				return false;
			default:
				throw "Cannot convert " + Std.string(this) + " to Bool";
		}
	}

	@:from private static inline function fromNullableString(s:Null<String>):PrimitiveValue {
		return cast s;
	}

	@:from private static inline function fromInt(i:Int):PrimitiveValue {
		return cast i;
	}

	@:from private static inline function fromFloat(f:Float):PrimitiveValue {
		return cast (!Math.isNaN(f) ? f : 0.0);
	}

	@:from private static inline function fromBool(b:Bool):PrimitiveValue {
		return cast b;
	}

	// Through IntParse, which reads digits only and checks the bound before
	// each one, so every target reads the same text as the same number.
	@:noCompletion private static function __parseInt(text:String):Int {
		var s:String = StringTools.trim(text);
		var at:Int = 0;
		var negative:Bool = false;
		if (s.length > 0 && (StringTools.fastCodeAt(s, 0) == "-".code || StringTools.fastCodeAt(s, 0) == "+".code)) {
			negative = StringTools.fastCodeAt(s, 0) == "-".code;
			at = 1;
		}
		var hex:Bool = s.length > at + 2 && StringTools.fastCodeAt(s, at) == "0".code
			&& (StringTools.fastCodeAt(s, at + 1) == "x".code || StringTools.fastCodeAt(s, at + 1) == "X".code);
		var digits:String = s.substr(hex ? at + 2 : at);
		var magnitude:Int = hex ? IntParse.hex(digits) : IntParse.decimal(digits);
		if (magnitude >= 0) {
			return negative ? -magnitude : magnitude;
		}
		// The one negative number whose magnitude is not an Int.
		if (negative) {
			var significant:String = digits;
			while (significant.length > 1 && StringTools.fastCodeAt(significant, 0) == "0".code) {
				significant = significant.substr(1);
			}
			if (significant.toUpperCase() == (hex ? "80000000" : "2147483648")) {
				return 0x80000000;
			}
		}
		throw "Cannot convert \"" + text + "\" to Int";
	}

	// The text checked against one grammar before any target reads it, since
	// each reads what is outside it its own way: Std.parseFloat gave "0x10"
	// as 16 natively and on neko and 0 elsewhere, "Infinity" as NaN on eval
	// and the jvm, and "12abc" as 12. Well-formed decimal text every target
	// reads alike; hex is added up here.
	@:noCompletion private static function __parseFloat(text:String):Float {
		var s:String = StringTools.trim(text);
		var length:Int = s.length;
		var at:Int = 0;
		var negative:Bool = false;
		if (length > 0 && (StringTools.fastCodeAt(s, 0) == "-".code || StringTools.fastCodeAt(s, 0) == "+".code)) {
			negative = StringTools.fastCodeAt(s, 0) == "-".code;
			at = 1;
		}
		if (at == length) {
			return Math.NaN;
		}

		var first:Int = StringTools.fastCodeAt(s, at);
		if (first == "i".code || first == "I".code) {
			var word:String = s.substr(at).toLowerCase();
			if (word == "infinity" || word == "inf") {
				return negative ? Math.NEGATIVE_INFINITY : Math.POSITIVE_INFINITY;
			}
			return Math.NaN;
		}

		if (length - at > 2 && first == "0".code && (StringTools.fastCodeAt(s, at + 1) | 0x20) == "x".code) {
			var value:Float = 0.0;
			for (i in at + 2...length) {
				var digit:Int = __hexDigit(StringTools.fastCodeAt(s, i));
				if (digit < 0) {
					return Math.NaN;
				}
				value = value * 16.0 + digit;
			}
			return negative ? -value : value;
		}

		var i:Int = at;
		var digits:Int = 0;
		while (i < length && __isDigit(StringTools.fastCodeAt(s, i))) {
			i++;
			digits++;
		}
		if (i < length && StringTools.fastCodeAt(s, i) == ".".code) {
			i++;
			while (i < length && __isDigit(StringTools.fastCodeAt(s, i))) {
				i++;
				digits++;
			}
		}
		if (digits == 0) {
			return Math.NaN;
		}
		if (i < length && (StringTools.fastCodeAt(s, i) | 0x20) == "e".code) {
			i++;
			if (i < length && (StringTools.fastCodeAt(s, i) == "+".code || StringTools.fastCodeAt(s, i) == "-".code)) {
				i++;
			}
			var exponent:Int = 0;
			while (i < length && __isDigit(StringTools.fastCodeAt(s, i))) {
				i++;
				exponent++;
			}
			if (exponent == 0) {
				return Math.NaN;
			}
		}
		return i == length ? Std.parseFloat(s) : Math.NaN;
	}

	private static inline function __isDigit(code:Int):Bool {
		return code >= "0".code && code <= "9".code;
	}

	private static inline function __hexDigit(code:Int):Int {
		return __isDigit(code) ? code - "0".code : (code | 0x20) >= "a".code && (code | 0x20) <= "f".code ? (code | 0x20) - "a".code + 10 : -1;
	}

	private static function isValid(value:Dynamic):Bool {
		return value == null
			|| Std.isOfType(value, String)
			|| Std.isOfType(value, Int)
			|| Std.isOfType(value, Float)
			|| Std.isOfType(value, Bool);
	}
}
