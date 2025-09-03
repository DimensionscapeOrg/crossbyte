package crossbyte;

/** 
 * @author Christopher Speciale
 */

/**
 * 32-bit wrapping serial/sequence number (RFC-1982 style ordering).
 * Intended for sequence arithmetic.
 * 
 * Usage:
 *   var a:Seq32 = 0xFFFF_FFFF;
 *   var b:Seq32 = 0;
 *   trace(a < b);        // true, because (b - a) = 1 in modulo 2^32
 * 
 */
@:transitive
abstract Seq32(Int) from Int to Int {
	public static inline var MAX_INT_32:Int = 0x7FFFFFFF; //  2147483647
	public static inline var ABS_MIN_INT_32:UInt = 0x80000000; //  2147483648
	public static inline var MAX_UINT_32:UInt = 0xFFFFFFFF; //  4294967295

	@:op(A + B) private static inline function add(a:Seq32, b:Seq32):Seq32 {
		return (a : Int) + (b : Int);
	}

	@:op(A - B) private static inline function sub(a:Seq32, b:Seq32):Seq32 {
		return (a : Int) - (b : Int);
	}

	@:op(A * B) private static inline function mul(a:Seq32, b:Seq32):Seq32 {
		return (a : Int) * (b : Int);
	}

	@:op(A / B) private static inline function div(a:Seq32, b:Seq32):Float {
		return a.toFloat() / b.toFloat();
	}

	@:op(A % B) private static inline function mod(a:Seq32, b:Seq32):Seq32 {
		var ai = (a : Int), bi = (b : Int);
		if (ai >= 0 && bi > 0)
			return ai % bi;
		return Std.int(a.toFloat() % b.toFloat());
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
		return ++this;
	}

	@:op(A++) private inline function postfixIncrement():Seq32 {
		return this
		++;
	}

	@:op(--A) private inline function prefixDecrement():Seq32 {
		return --this;
	}

	@:op(A--) private inline function postfixDecrement():Seq32 {
		return this
		--;
	}

	private inline function toString(?radix:Int):String {
		var v:Float = toFloat();
		return switch (radix) {
			case 16: StringTools.hex(Std.int(v), 8);
			case 10, null: Std.string(v);
			default: Std.string(v);
		}
	}

	private inline function toInt():Int {
		return this;
	}

	@:to private #if (!js || analyzer) inline #end function toFloat():Float {
		var i:Int = (this : Int);
		return (i < 0) ? 4294967296.0 + i : i + 0.0;
	}
}
