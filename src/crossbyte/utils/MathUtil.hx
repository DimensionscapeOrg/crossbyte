package crossbyte.utils;

/**
 * ...
 * @author Christopher Speciale
 */
/**
 * General math helpers and low-level numeric utilities.
 */
class MathUtil {
	/**
	 * Maximum signed 32-bit integer (2^31 - 1).
	 */
	public static inline var INT32_MAX:Int = 0x7FFFFFFF;

	/**
	 * Minimum signed 32-bit integer (−2^31).
	 */
	public static inline var INT32_MIN:Int = (1 << 31);

	/**
	 * Maximum unsigned 32-bit integer (2^32 - 1).
	 */
	public static inline var UINT32_MAX:UInt = (0xFFFFFFFF : UInt);

	/**
	 * Absolute value of INT32_MIN as an unsigned integer (2^31).
	 */
	public static inline var INT32_MIN_ABS:UInt = (0x80000000 : UInt);

	/**
	 * Clamps a value between a minimum and maximum.
	 *
	 * @param v   The value to clamp.
	 * @param min The minimum allowed value.
	 * @param max The maximum allowed value.
	 * @return    `v` if between min and max, otherwise min or max.
	 */
	@:pure public static inline function clamp<T:Float>(v:T, min:T, max:T):T {
		return (v < min) ? min : (v > max ? max : v);
	}

	/**
	 * Linearly interpolates between two values.
	 *
	 * @param a The start value.
	 * @param b The end value.
	 * @param t The interpolation factor, usually in [0,1].
	 * @return  `a + (b - a) * t`.
	 */
	@:pure public static inline function lerp<T:Float>(a:T, b:T, t:T):T {
		return a + (b - a) * t;
	}

	/**
	 * Inverse linear interpolation.
	 *
	 * @param a Start value.
	 * @param b End value.
	 * @param v Value to normalize between a and b.
	 * @return  The normalized t ∈ [0,1] such that lerp(a,b,t) ≈ v.
	 */
	@:pure public static inline function invLerp(a:Float, b:Float, v:Float):Float {
		return (b != a) ? (v - a) / (b - a) : 0.0;
	}

	/**
	 * Returns the next power of two greater than or equal to `n`.
	 *
	 * @param n Input integer (must be > 0).
	 * @return  The next power of two ≥ `n`.
	 */
	@:pure public static inline function nextPow2(n:Int):Int {
		var v:Int = n - 1;
		v |= v >>> 1;
		v |= v >>> 2;
		v |= v >>> 4;
		v |= v >>> 8;
		v |= v >>> 16;
		return v + 1;
	}

	/**
	 * Tests whether a value is a power of two.
	 *
	 * @param n Input integer.
	 * @return  True if `n` is > 0 and a power of two.
	 */
	@:pure public static inline function isPowerOfTwo(n:Int):Bool {
		return (n > 0) && ((n & (n - 1)) == 0);
	}

	/**
	 * Returns the sign of a value.
	 *
	 * @param v Input value.
	 * @return -1 if v < 0, 1 if v > 0, 0 if v == 0.
	 */
	@:pure public static inline function sign(v:Float):Int {
		return (v > 0) ? 1 : (v < 0 ? -1 : 0);
	}

	/**
	 * Remaps a value from one range into another.
	 *
	 * @param inMin  Input range minimum.
	 * @param inMax  Input range maximum.
	 * @param outMin Output range minimum.
	 * @param outMax Output range maximum.
	 * @param v      The value to remap.
	 * @return       The value mapped into the new range.
	 */
	@:pure public static inline function remap(inMin:Float, inMax:Float, outMin:Float, outMax:Float, v:Float):Float {
		return outMin + (outMax - outMin) * invLerp(inMin, inMax, v);
	}

	/**
	 * Wraps a value into the range [min, max).
	 *
	 * @param v   The value to wrap.
	 * @param min The inclusive minimum.
	 * @param max The exclusive maximum.
	 * @return    A value in [min, max).
	 */
	@:pure public static inline function wrap(v:Int, min:Int, max:Int):Int {
		var range:Int = max - min;
		if (range <= 0) {
			return min;
		}
		var result:Int = (v - min) % range;
		if (result < 0) {
			result += range;
		}
		return result + min;
	}
}
