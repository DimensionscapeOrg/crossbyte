package crossbyte;

/** 
 * @author Christopher Speciale
 */

/**
 * 32-bit wrapping serial/sequence number (RFC-1982 style ordering).
 * Intended for sequence arithmetic.
 * 
 * Usage:
 *   var a:Seq32 = 0xFFFFFFFF;
 *   var b:Seq32 = 0;
 *   trace(a < b);        // true, because (b - a) = 1 in modulo 2^32
 * 
 */
@:transitive
abstract Seq32(Int) from Int to Int {
	// Arithmetic goes through haxe.Int32, which wraps it at 32 bits where
	// the target does not: JavaScript, PHP, Python and Lua. Elsewhere it is
	// plain Int arithmetic, as it always was. On JavaScript it was left to
	// run past 2^31 - 1, so a sequence counted up past it no longer equalled
	// the same sequence read off the wire, and a reliable session that got
	// there stopped delivering.
	public static inline var MAX_INT_32:Int = 0x7FFFFFFF; //  2147483647
	public static inline var ABS_MIN_INT_32:UInt = 0x80000000; //  2147483648
	public static inline var MAX_UINT_32:UInt = 0xFFFFFFFF; //  4294967295

	@:op(A + B) private static inline function add(a:Seq32, b:Seq32):Seq32 {
		return (((a : Int) : haxe.Int32) + ((b : Int) : haxe.Int32) : Int);
	}

	@:op(A - B) private static inline function sub(a:Seq32, b:Seq32):Seq32 {
		return (((a : Int) : haxe.Int32) - ((b : Int) : haxe.Int32) : Int);
	}

	@:op(A * B) private static inline function mul(a:Seq32, b:Seq32):Seq32 {
		return (((a : Int) : haxe.Int32) * ((b : Int) : haxe.Int32) : Int);
	}

	@:op(A / B) private static inline function div(a:Seq32, b:Seq32):Float {
		return a.toFloat() / b.toFloat();
	}

	// Unsigned, as the rest of the type is. Past the first case the operands
	// go through Float, where every 32-bit value and the remainder of two are
	// exact, and the remainder comes back through `__fromUnsigned`: `Std.int`
	// of one of 2^31 or more saturated at 2147483647 on the jvm.
	@:op(A % B) private static inline function mod(a:Seq32, b:Seq32):Seq32 {
		var ai = (a : Int), bi = (b : Int);
		if (ai >= 0 && bi > 0)
			return ai % bi;
		return __fromUnsigned(a.toFloat() % b.toFloat());
	}

	@:op(A & B) private static inline function and(a:Seq32, b:Seq32):Seq32 {
		return (a : Int) & (b : Int);
	}

	@:op(A | B) private static inline function or(a:Seq32, b:Seq32):Seq32 {
		return (a : Int) | (b : Int);
	}

	@:op(A ^ B) private static inline function xor(a:Seq32, b:Seq32):Seq32 {
		return (a : Int) ^ (b : Int);
	}

	@:op(A << B) private static inline function shl(a:Seq32, b:Int):Seq32 {
		return (a : Int) << b;
	}

	@:op(A >> B) private static inline function shr(a:Seq32, b:Int):Seq32 {
		return (a : Int) >> b;
	}

	@:op(A >>> B) private static inline function ushr(a:Seq32, b:Int):Seq32 {
		return (a : Int) >>> b;
	}

	private static inline function ugt(a:Seq32, b:Seq32):Bool {
		var d:Int = (a : Int) - (b : Int);
		return d != 0 && ((d ^ 0x80000000) < 0);
	}

	@:op(A > B) private static inline function gt(a:Seq32, b:Seq32):Bool {
		return ugt(a, b);
	}

	@:op(A < B) private static inline function lt(a:Seq32, b:Seq32):Bool {
		return ugt(b, a);
	}

	@:op(A >= B) private static inline function gte(a:Seq32, b:Seq32):Bool {
		return ((a : Int) == (b : Int)) || ugt(a, b);
	}

	@:op(A <= B) private static inline function lte(a:Seq32, b:Seq32):Bool {
		return ((a : Int) == (b : Int)) || ugt(b, a);
	}

	@:commutative @:op(A + B) private static inline function addWithFloat(a:Seq32, b:Float):Float {
		return a.toFloat() + b;
	}

	@:commutative @:op(A * B) private static inline function mulWithFloat(a:Seq32, b:Float):Float {
		return a.toFloat() * b;
	}

	@:op(A / B) private static inline function divFloat(a:Seq32, b:Float):Float {
		return a.toFloat() / b;
	}

	@:op(A / B) private static inline function floatDiv(a:Float, b:Seq32):Float {
		return a / b.toFloat();
	}

	@:op(A - B) private static inline function subFloat(a:Seq32, b:Float):Float {
		return a.toFloat() - b;
	}

	@:op(A - B) private static inline function floatSub(a:Float, b:Seq32):Float {
		return a - b.toFloat();
	}

	@:op(A % B) private static inline function modFloat(a:Seq32, b:Float):Float {
		return a.toFloat() % b;
	}

	@:op(A % B) private static inline function floatMod(a:Float, b:Seq32):Float {
		return a % b.toFloat();
	}

	@:op(~A) private inline function negBits():Seq32 {
		return ~this;
	}

	@:op(++A) private inline function prefixIncrement():Seq32 {
		return this = (((this : haxe.Int32) + 1) : Int);
	}

	@:op(A++) private inline function postfixIncrement():Seq32 {
		final before:Int = this;
		this = (((this : haxe.Int32) + 1) : Int);
		return before;
	}

	@:op(--A) private inline function prefixDecrement():Seq32 {
		return this = (((this : haxe.Int32) - 1) : Int);
	}

	@:op(A--) private inline function postfixDecrement():Seq32 {
		final before:Int = this;
		this = (((this : haxe.Int32) - 1) : Int);
		return before;
	}

	/**
		The value as an unsigned number: decimal, or eight hex digits for a
		radix of 16. Both went through `toFloat`, so on the jvm a value of
		2^31 or more printed as "4.294967295E9" and in hex as 7FFFFFFF.
	**/
	private inline function toString(?radix:Int):String {
		return radix == 16 ? StringTools.hex(this, 8) : __unsignedDecimal(this);
	}

	// The last digit apart from the rest: the rest, below 2^29, is an Int,
	// and u / 10 lands exactly on it since u is a whole number below 2^53.
	private static function __unsignedDecimal(i:Int):String {
		if (i >= 0) {
			return Std.string(i);
		}
		var u:Float = i + 4294967296.0;
		var rest:Int = Std.int(u / 10.0);
		return Std.string(rest) + Std.string(Std.int(u - rest * 10.0));
	}

	// A remainder in [0, 2^32) back to the Int that holds it. A NaN, from a
	// remainder by zero, is 0 here on every target.
	private static inline function __fromUnsigned(r:Float):Int {
		return !(r >= 0) ? 0 : (r >= 2147483648.0 ? Std.int(r - 4294967296.0) : Std.int(r));
	}

	private inline function toInt():Int {
		return this;
	}

	@:to private #if (!js || analyzer) inline #end function toFloat():Float {
		var i:Int = (this : Int);
		return (i < 0) ? 4294967296.0 + i : i + 0.0;
	}
}
