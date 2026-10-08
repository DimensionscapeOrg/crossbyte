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

	public inline function getValueType():Type.ValueType {
		return Type.typeof(this);
	}

	public inline function isString():Bool {
		return switch (Type.typeof(this)) {
			case TClass(String): true;
			default: false;
		};
	}

	public inline function isInt():Bool {
		return switch (Type.typeof(this)) {
			case TInt: true;
			default: false;
		};
	}

	public inline function isFloat():Bool {
		return switch (Type.typeof(this)) {
			case TFloat: true;
			default: false;
		};
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
	 * @return The string representation of the primitive.
	 */
	@:to public inline function toString():String {
		return Std.string(this);
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
	 * - Strings are parsed as floats.
	 * - `true` becomes `1.0`, `false` becomes `0.0`.
	 * - `null` converts to `0.0`.
	 *
	 * @return The float representation of the primitive.
	 * @throws If conversion is not possible.
	 */
	@:to public inline function toFloat():Float {
		switch (Type.typeof(this)) {
			case TInt, TFloat:
				return this;
			case TBool:
				return this ? 1.0 : 0.0;
			case TClass(String):
				return Std.parseFloat(this);
			case TNull:
				return 0.0;
			default:
				throw "Cannot convert " + Std.string(this) + " to Float";
		}
	}

	/**
	 * Converts the primitive to a `Bool`.
	 * 
	 * - `0` or `0.0` converts to `false`, anything else is `true`.
	 * - Strings convert to `true` unless they are `"false"`.
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
		return cast (s != null ? s : "");
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

	private static function isValid(value:Dynamic):Bool {
		return value == null
			|| Std.isOfType(value, String)
			|| Std.isOfType(value, Int)
			|| Std.isOfType(value, Float)
			|| Std.isOfType(value, Bool);
	}
}
