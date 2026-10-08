package crossbyte.rpc;

/**
	A signed 16-bit integer, -32,768 to 32,767: two bytes on the RPC wire,
	little-endian, where an `Int` takes four. For a coordinate on a grid, a
	small signed delta, that a signature or a field of an `RPCStruct`
	declares as this type.

	Held as an `Int`, and an `Int` wherever one is wanted: arithmetic on it is
	`Int` arithmetic. An `Int` assigned to one keeps its low sixteen bits, read
	as signed, as a cast to a short does in C or Java, 32,768 is -32,768,
	so what a value holds is what is sent and what arrives. The narrowing is
	two shifts, the only cost. Operators and comparisons, with an Int or a
	Float on the other side, work on the `Int` it holds, so `value < 300`
	compares 300 itself. From another compact type, convert through `Int`: `var
	wide:UInt16 = (small : Int)`.

	```haxe
	import crossbyte.rpc.Int16;

	var x:Int16 = -1200;
	var wrapped:Int16 = 40000; // -25536
	```
**/
abstract Int16(Int) to Int {
	/** The least value, -32,768. **/
	public static inline final MIN:Int = -32768;

	/** The greatest value, 32,767. **/
	public static inline final MAX:Int = 32767;

	inline function new(value:Int) {
		this = value;
	}

	/** `value`'s low sixteen bits, as a signed short. **/
	@:from public static inline function fromInt(value:Int):Int16 {
		return new Int16((value << 16) >> 16);
	}

	// Every operator works on the Int a value holds, the other side an Int
	// or anything that is one, another compact number, an Int literal,
	// so `level < 300` compares 300, not 300 narrowed to this type.

	@:op(A + B) @:commutative static inline function add(a:Int16, b:Int):Int {
		return (a : Int) + b;
	}

	@:op(A * B) @:commutative static inline function mul(a:Int16, b:Int):Int {
		return (a : Int) * b;
	}

	@:op(A & B) @:commutative static inline function and(a:Int16, b:Int):Int {
		return (a : Int) & b;
	}

	@:op(A | B) @:commutative static inline function or(a:Int16, b:Int):Int {
		return (a : Int) | b;
	}

	@:op(A ^ B) @:commutative static inline function xor(a:Int16, b:Int):Int {
		return (a : Int) ^ b;
	}

	@:op(A == B) @:commutative static inline function eq(a:Int16, b:Int):Bool {
		return (a : Int) == b;
	}

	@:op(A != B) @:commutative static inline function neq(a:Int16, b:Int):Bool {
		return (a : Int) != b;
	}

	@:op(A - B) static inline function sub(a:Int16, b:Int):Int {
		return (a : Int) - b;
	}

	@:op(A - B) static inline function subFrom(a:Int, b:Int16):Int {
		return a - (b : Int);
	}

	@:op(A / B) static inline function div(a:Int16, b:Int):Float {
		return (a : Int) / b;
	}

	@:op(A / B) static inline function divFrom(a:Int, b:Int16):Float {
		return a / (b : Int);
	}

	@:op(A % B) static inline function mod(a:Int16, b:Int):Int {
		return (a : Int) % b;
	}

	@:op(A % B) static inline function modFrom(a:Int, b:Int16):Int {
		return a % (b : Int);
	}

	@:op(A < B) static inline function lt(a:Int16, b:Int):Bool {
		return (a : Int) < b;
	}

	@:op(A < B) static inline function ltFrom(a:Int, b:Int16):Bool {
		return a < (b : Int);
	}

	@:op(A <= B) static inline function lte(a:Int16, b:Int):Bool {
		return (a : Int) <= b;
	}

	@:op(A <= B) static inline function lteFrom(a:Int, b:Int16):Bool {
		return a <= (b : Int);
	}

	@:op(A > B) static inline function gt(a:Int16, b:Int):Bool {
		return (a : Int) > b;
	}

	@:op(A > B) static inline function gtFrom(a:Int, b:Int16):Bool {
		return a > (b : Int);
	}

	@:op(A >= B) static inline function gte(a:Int16, b:Int):Bool {
		return (a : Int) >= b;
	}

	@:op(A >= B) static inline function gteFrom(a:Int, b:Int16):Bool {
		return a >= (b : Int);
	}

	@:op(A << B) static inline function shl(a:Int16, b:Int):Int {
		return (a : Int) << b;
	}

	@:op(A << B) static inline function shlFrom(a:Int, b:Int16):Int {
		return a << (b : Int);
	}

	@:op(A >> B) static inline function shr(a:Int16, b:Int):Int {
		return (a : Int) >> b;
	}

	@:op(A >> B) static inline function shrFrom(a:Int, b:Int16):Int {
		return a >> (b : Int);
	}

	@:op(A >>> B) static inline function ushr(a:Int16, b:Int):Int {
		return (a : Int) >>> b;
	}

	@:op(A >>> B) static inline function ushrFrom(a:Int, b:Int16):Int {
		return a >>> (b : Int);
	}

	// And with a Float on the other side (a Float32 among them), as an Int is.

	@:op(A + B) @:commutative static inline function addFloat(a:Int16, b:Float):Float {
		return (a : Int) + b;
	}

	@:op(A * B) @:commutative static inline function mulFloat(a:Int16, b:Float):Float {
		return (a : Int) * b;
	}

	@:op(A == B) @:commutative static inline function eqFloat(a:Int16, b:Float):Bool {
		return (a : Int) == b;
	}

	@:op(A != B) @:commutative static inline function neqFloat(a:Int16, b:Float):Bool {
		return (a : Int) != b;
	}

	@:op(A - B) static inline function subFloat(a:Int16, b:Float):Float {
		return (a : Int) - b;
	}

	@:op(A - B) static inline function subFloatFrom(a:Float, b:Int16):Float {
		return a - (b : Int);
	}

	@:op(A / B) static inline function divFloat(a:Int16, b:Float):Float {
		return (a : Int) / b;
	}

	@:op(A / B) static inline function divFloatFrom(a:Float, b:Int16):Float {
		return a / (b : Int);
	}

	@:op(A < B) static inline function ltFloat(a:Int16, b:Float):Bool {
		return (a : Int) < b;
	}

	@:op(A < B) static inline function ltFloatFrom(a:Float, b:Int16):Bool {
		return a < (b : Int);
	}

	@:op(A <= B) static inline function lteFloat(a:Int16, b:Float):Bool {
		return (a : Int) <= b;
	}

	@:op(A <= B) static inline function lteFloatFrom(a:Float, b:Int16):Bool {
		return a <= (b : Int);
	}

	@:op(A > B) static inline function gtFloat(a:Int16, b:Float):Bool {
		return (a : Int) > b;
	}

	@:op(A > B) static inline function gtFloatFrom(a:Float, b:Int16):Bool {
		return a > (b : Int);
	}

	@:op(A >= B) static inline function gteFloat(a:Int16, b:Float):Bool {
		return (a : Int) >= b;
	}

	@:op(A >= B) static inline function gteFloatFrom(a:Float, b:Int16):Bool {
		return a >= (b : Int);
	}
}
