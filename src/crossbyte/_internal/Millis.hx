package crossbyte._internal;

/**
	Whole milliseconds for a duration in seconds, where a system call or a
	native helper takes milliseconds and CrossByte's own member is seconds.
**/
class Millis {
	/**
		`seconds` as whole milliseconds, rounded up so a short wait is never
		made shorter (and never to 0, which means no deadline); 0 for 0,
		less, or NaN; at most `Int`'s largest.
	**/
	public static function of(seconds:Float):Int {
		// A Float literal, so eval and neko multiply as floats even when
		// `seconds` holds an Int, which would wrap past 2^31 there.
		var ms:Float = seconds * 1000.0;
		if (!(ms > 0)) {
			return 0;
		}
		if (ms >= 2147483647.0) {
			return 2147483647;
		}
		// Less a hair, so that 0.3 s, which is 300.00000000000006 ms as a
		// double, is 300 rather than 301.
		var whole:Int = Math.ceil(ms - 0.000001);
		return whole < 1 ? 1 : whole;
	}
}
