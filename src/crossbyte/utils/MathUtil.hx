package crossbyte.utils;

/**
 * ...
 * @author Christopher Speciale
 */
class MathUtil {
	public static inline var MAX_INT_32:Int = 0x7FFFFFFF;
	public static inline var MIN_INT_32:Int = -MAX_INT_32;
	public static inline var MAX_UINT_32:UInt = MAX_INT_32 + MAX_INT_32 + 1;
	public static inline var ABS_MIN_INT_32:UInt = MAX_INT_32 + 1;
}
