package crossbyte.rpc;

/**
	A signed 8-bit integer, -128 to 127: one byte on the RPC wire, where an
	`Int` takes four. For a small signed value, a direction, a delta,
	that a signature or a field of an `RPCStruct` declares as this type.

	Held as an `Int`, and an `Int` wherever one is wanted: arithmetic on it is
	`Int` arithmetic. An `Int` assigned to one keeps its low eight bits, read
	as signed, as a cast to a byte does in C or Java, 128 is -128 and 255 is
	-1, so what a value holds is what is sent and what arrives. The narrowing
	is two shifts, the only cost. Operators and comparisons, with an Int or a
	Float on the other side, work on the `Int` it holds, so `value < 300`
	compares 300 itself. From another compact type, convert through `Int`: `var
	wide:UInt16 = (small : Int)`.

	```haxe
	import crossbyte.rpc.Int8;

	var step:Int8 = -3;
	var wrapped:Int8 = 200; // -56
	```
**/
abstract Int8(Int) to Int {
	/** The least value, -128. **/
	public static inline final MIN:Int = -128;

	/** The greatest value, 127. **/
	public static inline final MAX:Int = 127;

	inline function new(value:Int) {
		this = value;
	}

	/** `value`'s low eight bits, as a signed byte. **/
	@:from public static inline function fromInt(value:Int):Int8 {
		return new Int8((value << 24) >> 24);
	}

	// Every operator works on the Int a value holds, the other side an Int
	// or anything that is one, another compact number, an Int literal,
	// so `level < 300` compares 300, not 300 narrowed to this type.

	@:op(A + B) @:commutative static inline function add(a:Int8, b:Int):Int {
		return (a : Int) + b;
	}

	@:op(A * B) @:commutative static inline function mul(a:Int8, b:Int):Int {
		return (a : Int) * b;
	}

	@:op(A & B) @:commutative static inline function and(a:Int8, b:Int):Int {
		return (a : Int) & b;
	}

	@:op(A | B) @:commutative static inline function or(a:Int8, b:Int):Int {
		return (a : Int) | b;
	}

	@:op(A ^ B) @:commutative static inline function xor(a:Int8, b:Int):Int {
		return (a : Int) ^ b;
	}

	@:op(A == B) @:commutative static inline function eq(a:Int8, b:Int):Bool {
		return (a : Int) == b;
	}

	@:op(A != B) @:commutative static inline function neq(a:Int8, b:Int):Bool {
		return (a : Int) != b;
	}

	@:op(A - B) static inline function sub(a:Int8, b:Int):Int {
		return (a : Int) - b;
	}

	@:op(A - B) static inline function subFrom(a:Int, b:Int8):Int {
		return a - (b : Int);
	}

	@:op(A / B) static inline function div(a:Int8, b:Int):Float {
		return (a : Int) / b;
	}

	@:op(A / B) static inline function divFrom(a:Int, b:Int8):Float {
		return a / (b : Int);
	}

	@:op(A % B) static inline function mod(a:Int8, b:Int):Int {
		return (a : Int) % b;
	}

	@:op(A % B) static inline function modFrom(a:Int, b:Int8):Int {
		return a % (b : Int);
	}

	@:op(A < B) static inline function lt(a:Int8, b:Int):Bool {
		return (a : Int) < b;
	}

	@:op(A < B) static inline function ltFrom(a:Int, b:Int8):Bool {
		return a < (b : Int);
	}

	@:op(A <= B) static inline function lte(a:Int8, b:Int):Bool {
		return (a : Int) <= b;
	}

	@:op(A <= B) static inline function lteFrom(a:Int, b:Int8):Bool {
		return a <= (b : Int);
	}

	@:op(A > B) static inline function gt(a:Int8, b:Int):Bool {
		return (a : Int) > b;
	}

	@:op(A > B) static inline function gtFrom(a:Int, b:Int8):Bool {
		return a > (b : Int);
	}

	@:op(A >= B) static inline function gte(a:Int8, b:Int):Bool {
		return (a : Int) >= b;
	}

	@:op(A >= B) static inline function gteFrom(a:Int, b:Int8):Bool {
		return a >= (b : Int);
	}

	@:op(A << B) static inline function shl(a:Int8, b:Int):Int {
		return (a : Int) << b;
	}

	@:op(A << B) static inline function shlFrom(a:Int, b:Int8):Int {
		return a << (b : Int);
	}

	@:op(A >> B) static inline function shr(a:Int8, b:Int):Int {
		return (a : Int) >> b;
	}

	@:op(A >> B) static inline function shrFrom(a:Int, b:Int8):Int {
		return a >> (b : Int);
	}

	@:op(A >>> B) static inline function ushr(a:Int8, b:Int):Int {
		return (a : Int) >>> b;
	}

	@:op(A >>> B) static inline function ushrFrom(a:Int, b:Int8):Int {
		return a >>> (b : Int);
	}

	// And with a Float on the other side (a Float32 among them), as an Int is.

	@:op(A + B) @:commutative static inline function addFloat(a:Int8, b:Float):Float {
		return (a : Int) + b;
	}

	@:op(A * B) @:commutative static inline function mulFloat(a:Int8, b:Float):Float {
		return (a : Int) * b;
	}

	@:op(A == B) @:commutative static inline function eqFloat(a:Int8, b:Float):Bool {
		return (a : Int) == b;
	}

	@:op(A != B) @:commutative static inline function neqFloat(a:Int8, b:Float):Bool {
		return (a : Int) != b;
	}

	@:op(A - B) static inline function subFloat(a:Int8, b:Float):Float {
		return (a : Int) - b;
	}

	@:op(A - B) static inline function subFloatFrom(a:Float, b:Int8):Float {
		return a - (b : Int);
	}

	@:op(A / B) static inline function divFloat(a:Int8, b:Float):Float {
		return (a : Int) / b;
	}

	@:op(A / B) static inline function divFloatFrom(a:Float, b:Int8):Float {
		return a / (b : Int);
	}

	@:op(A < B) static inline function ltFloat(a:Int8, b:Float):Bool {
		return (a : Int) < b;
	}

	@:op(A < B) static inline function ltFloatFrom(a:Float, b:Int8):Bool {
		return a < (b : Int);
	}

	@:op(A <= B) static inline function lteFloat(a:Int8, b:Float):Bool {
		return (a : Int) <= b;
	}

	@:op(A <= B) static inline function lteFloatFrom(a:Float, b:Int8):Bool {
		return a <= (b : Int);
	}

	@:op(A > B) static inline function gtFloat(a:Int8, b:Float):Bool {
		return (a : Int) > b;
	}

	@:op(A > B) static inline function gtFloatFrom(a:Float, b:Int8):Bool {
		return a > (b : Int);
	}

	@:op(A >= B) static inline function gteFloat(a:Int8, b:Float):Bool {
		return (a : Int) >= b;
	}

	@:op(A >= B) static inline function gteFloatFrom(a:Float, b:Int8):Bool {
		return a >= (b : Int);
	}
}
