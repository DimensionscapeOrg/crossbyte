package crossbyte.db.mongodb._internal;

import haxe.Int64;

/**
	`haxe.Int64` to `Float`, which the standard library does not offer:
	exact below 2^53 in magnitude, and the nearest double above.
**/
class Int64Float {
	public static inline function toFloat(value:Int64):Float {
		var low:Int = value.low;
		return value.high * 4294967296.0 + (low < 0 ? low + 4294967296.0 : low);
	}
}
