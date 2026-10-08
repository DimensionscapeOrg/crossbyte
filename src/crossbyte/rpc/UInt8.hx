package crossbyte.rpc;

/**
	An unsigned 8-bit integer, 0 to 255: one byte on the RPC wire, where an
	`Int` takes four. For a count, a level, a set of flags that a signature
	or a field of an `RPCStruct` declares as this type.

	Held as an `Int`, and an `Int` wherever one is wanted: arithmetic on it is
	`Int` arithmetic. An `Int` assigned to one keeps its low eight bits, as a
	cast to a byte does in C or Java (256 is 0 and -1 is 255), so what a
	value holds is what is sent and what arrives. The narrowing is a mask, the
	only cost. Operators and comparisons (with an Int or a Float on the other
	side) work on the `Int` it holds, so `value < 300` compares 300 itself.
	From another compact type, convert through `Int`: `var wide:UInt16 = (small
	: Int)`.

	```haxe
	import crossbyte.rpc.UInt8;

	var flags:UInt8 = 0x81;
	var fromInt:UInt8 = 257; // 1
	var sum:Int = flags + 1; // 130, an Int
	```
**/
abstract UInt8(Int) to Int {
	/** The least value, 0. **/
	public static inline final MIN:Int = 0;

	/** The greatest value, 255. **/
	public static inline final MAX:Int = 0xFF;

	inline function new(value:Int) {
		this = value;
	}

	/** `value`'s low eight bits. **/
	@:from public static inline function fromInt(value:Int):UInt8 {
		return new UInt8(value & 0xFF);
	}

	// Every operator works on the Int a value holds, the other side an Int
	// or anything that is one (another compact number, an Int literal),
	// so `level < 300` compares 300, not 300 narrowed to this type.

	@:op(A + B) @:commutative static inline function add(a:UInt8, b:Int):Int {
		return (a : Int) + b;
	}

	@:op(A * B) @:commutative static inline function mul(a:UInt8, b:Int):Int {
		return (a : Int) * b;
	}

	@:op(A & B) @:commutative static inline function and(a:UInt8, b:Int):Int {
		return (a : Int) & b;
	}

	@:op(A | B) @:commutative static inline function or(a:UInt8, b:Int):Int {
		return (a : Int) | b;
	}

	@:op(A ^ B) @:commutative static inline function xor(a:UInt8, b:Int):Int {
		return (a : Int) ^ b;
	}

	@:op(A == B) @:commutative static inline function eq(a:UInt8, b:Int):Bool {
		return (a : Int) == b;
	}

	@:op(A != B) @:commutative static inline function neq(a:UInt8, b:Int):Bool {
		return (a : Int) != b;
	}

	@:op(A - B) static inline function sub(a:UInt8, b:Int):Int {
		return (a : Int) - b;
	}

	@:op(A - B) static inline function subFrom(a:Int, b:UInt8):Int {
		return a - (b : Int);
	}

	@:op(A / B) static inline function div(a:UInt8, b:Int):Float {
		return (a : Int) / b;
	}

	@:op(A / B) static inline function divFrom(a:Int, b:UInt8):Float {
		return a / (b : Int);
	}

	@:op(A % B) static inline function mod(a:UInt8, b:Int):Int {
		return (a : Int) % b;
	}

	@:op(A % B) static inline function modFrom(a:Int, b:UInt8):Int {
		return a % (b : Int);
	}

	@:op(A < B) static inline function lt(a:UInt8, b:Int):Bool {
		return (a : Int) < b;
	}

	@:op(A < B) static inline function ltFrom(a:Int, b:UInt8):Bool {
		return a < (b : Int);
	}

	@:op(A <= B) static inline function lte(a:UInt8, b:Int):Bool {
		return (a : Int) <= b;
	}

	@:op(A <= B) static inline function lteFrom(a:Int, b:UInt8):Bool {
		return a <= (b : Int);
	}

	@:op(A > B) static inline function gt(a:UInt8, b:Int):Bool {
		return (a : Int) > b;
	}

	@:op(A > B) static inline function gtFrom(a:Int, b:UInt8):Bool {
		return a > (b : Int);
	}

	@:op(A >= B) static inline function gte(a:UInt8, b:Int):Bool {
		return (a : Int) >= b;
	}

	@:op(A >= B) static inline function gteFrom(a:Int, b:UInt8):Bool {
		return a >= (b : Int);
	}

	@:op(A << B) static inline function shl(a:UInt8, b:Int):Int {
		return (a : Int) << b;
	}

	@:op(A << B) static inline function shlFrom(a:Int, b:UInt8):Int {
		return a << (b : Int);
	}

	@:op(A >> B) static inline function shr(a:UInt8, b:Int):Int {
		return (a : Int) >> b;
	}

	@:op(A >> B) static inline function shrFrom(a:Int, b:UInt8):Int {
		return a >> (b : Int);
	}

	@:op(A >>> B) static inline function ushr(a:UInt8, b:Int):Int {
		return (a : Int) >>> b;
	}

	@:op(A >>> B) static inline function ushrFrom(a:Int, b:UInt8):Int {
		return a >>> (b : Int);
	}

	// And with a Float on the other side (a Float32 among them), as an Int is.

	@:op(A + B) @:commutative static inline function addFloat(a:UInt8, b:Float):Float {
		return (a : Int) + b;
	}

	@:op(A * B) @:commutative static inline function mulFloat(a:UInt8, b:Float):Float {
		return (a : Int) * b;
	}

	@:op(A == B) @:commutative static inline function eqFloat(a:UInt8, b:Float):Bool {
		return (a : Int) == b;
	}

	@:op(A != B) @:commutative static inline function neqFloat(a:UInt8, b:Float):Bool {
		return (a : Int) != b;
	}

	@:op(A - B) static inline function subFloat(a:UInt8, b:Float):Float {
		return (a : Int) - b;
	}

	@:op(A - B) static inline function subFloatFrom(a:Float, b:UInt8):Float {
		return a - (b : Int);
	}

	@:op(A / B) static inline function divFloat(a:UInt8, b:Float):Float {
		return (a : Int) / b;
	}

	@:op(A / B) static inline function divFloatFrom(a:Float, b:UInt8):Float {
		return a / (b : Int);
	}

	@:op(A < B) static inline function ltFloat(a:UInt8, b:Float):Bool {
		return (a : Int) < b;
	}

	@:op(A < B) static inline function ltFloatFrom(a:Float, b:UInt8):Bool {
		return a < (b : Int);
	}

	@:op(A <= B) static inline function lteFloat(a:UInt8, b:Float):Bool {
		return (a : Int) <= b;
	}

	@:op(A <= B) static inline function lteFloatFrom(a:Float, b:UInt8):Bool {
		return a <= (b : Int);
	}

	@:op(A > B) static inline function gtFloat(a:UInt8, b:Float):Bool {
		return (a : Int) > b;
	}

	@:op(A > B) static inline function gtFloatFrom(a:Float, b:UInt8):Bool {
		return a > (b : Int);
	}

	@:op(A >= B) static inline function gteFloat(a:UInt8, b:Float):Bool {
		return (a : Int) >= b;
	}

	@:op(A >= B) static inline function gteFloatFrom(a:Float, b:UInt8):Bool {
		return a >= (b : Int);
	}
}
