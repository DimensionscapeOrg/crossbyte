package crossbyte.rpc._internal;

import haxe.io.Bytes;

/**
	The comparisons and copies generated patch code calls for values that
	are not a number compared with `==`: whether two would go as the same
	bytes, and a copy that shares nothing that can change.
**/
@:noCompletion
class RPCSame {
	/** Two `Float`s as they go: NaN the same as NaN. **/
	public static inline function floats(a:Float, b:Float):Bool {
		return a == b || (a != a && b != b);
	}

	/** Two `Float32`s as they go: at single precision, NaN the same as NaN. **/
	public static inline function singles(a:Float, b:Float):Bool {
		#if (cpp || jvm || java || hl || cs)
		// Held as Single there: rounded already.
		return a == b || (a != a && b != b);
		#else
		return floats(round(a), round(b));
		#end
	}

	#if !(cpp || jvm || java || hl || cs)
	/** `value` rounded to single precision, as it is sent. **/
	public static inline function round(value:Float):Float {
		#if js
		return js.Syntax.code("Math.fround({0})", value);
		#else
		return haxe.io.FPHelper.i32ToFloat(haxe.io.FPHelper.floatToI32(value));
		#end
	}
	#end

	public static function bytes(a:Null<Bytes>, b:Null<Bytes>):Bool {
		if (a == b) {
			return true;
		}
		if (a == null || b == null || a.length != b.length) {
			return false;
		}
		return a.compare(b) == 0;
	}

	/**
		Two enum values: by reference, then constructor and arguments. An
		argument that is an object (a structure) is compared by reference,
		which may say two equal values differ: only ever a field sent again.
	**/
	public static function enums<E:EnumValue>(a:Null<E>, b:Null<E>):Bool {
		if (a == b) {
			return true;
		}
		if (a == null || b == null) {
			return false;
		}
		return Type.enumEq(a, b);
	}

	/** `from`'s bytes in `into` when it has their length, else in bytes of their own. **/
	public static function copyBytes(from:Null<Bytes>, into:Null<Bytes>):Null<Bytes> {
		if (from == null) {
			return null;
		}
		if (into == from) {
			return from;
		}
		if (into != null && into.length == from.length) {
			into.blit(0, from, 0, from.length);
			return into;
		}
		return from.sub(0, from.length);
	}
}
