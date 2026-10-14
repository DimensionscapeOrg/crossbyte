package crossbyte.rpc;

/**
	An `Int` sent zigzagged and then as a varint, as protobuf's `sint32` is:
	small magnitudes of either sign take one byte (-64 to 63), two up to
	±8,191, and five at most, where an `Int` always takes four. For a signed
	offset, a small delta, a key that may be negative.

	It is an `Int` wherever one is wanted, and holds all 32 bits; operators and
	comparisons work on the `Int` it holds.

	```haxe
	import crossbyte.rpc.VarInt;

	interface ScrollContract {
		function scroll(lines:VarInt):Void;
	}
	```
**/
abstract VarInt(Int) from Int to Int {
	// Every operator works on the Int a value holds, the other side an Int
	// or anything that is one (another compact number, an Int literal).

	@:op(A + B) @:commutative static inline function add(a:VarInt, b:Int):Int {
		return (a : Int) + b;
	}

	@:op(A * B) @:commutative static inline function mul(a:VarInt, b:Int):Int {
		return (a : Int) * b;
	}

	@:op(A & B) @:commutative static inline function and(a:VarInt, b:Int):Int {
		return (a : Int) & b;
	}

	@:op(A | B) @:commutative static inline function or(a:VarInt, b:Int):Int {
		return (a : Int) | b;
	}

	@:op(A ^ B) @:commutative static inline function xor(a:VarInt, b:Int):Int {
		return (a : Int) ^ b;
	}

	@:op(A == B) @:commutative static inline function eq(a:VarInt, b:Int):Bool {
		return (a : Int) == b;
	}

	@:op(A != B) @:commutative static inline function neq(a:VarInt, b:Int):Bool {
		return (a : Int) != b;
	}

	@:op(A - B) static inline function sub(a:VarInt, b:Int):Int {
		return (a : Int) - b;
	}

	@:op(A - B) static inline function subFrom(a:Int, b:VarInt):Int {
		return a - (b : Int);
	}

	@:op(A / B) static inline function div(a:VarInt, b:Int):Float {
		return (a : Int) / b;
	}

	@:op(A / B) static inline function divFrom(a:Int, b:VarInt):Float {
		return a / (b : Int);
	}

	@:op(A % B) static inline function mod(a:VarInt, b:Int):Int {
		return (a : Int) % b;
	}

	@:op(A % B) static inline function modFrom(a:Int, b:VarInt):Int {
		return a % (b : Int);
	}

	@:op(A < B) static inline function lt(a:VarInt, b:Int):Bool {
		return (a : Int) < b;
	}

	@:op(A < B) static inline function ltFrom(a:Int, b:VarInt):Bool {
		return a < (b : Int);
	}

	@:op(A <= B) static inline function lte(a:VarInt, b:Int):Bool {
		return (a : Int) <= b;
	}

	@:op(A <= B) static inline function lteFrom(a:Int, b:VarInt):Bool {
		return a <= (b : Int);
	}

	@:op(A > B) static inline function gt(a:VarInt, b:Int):Bool {
		return (a : Int) > b;
	}

	@:op(A > B) static inline function gtFrom(a:Int, b:VarInt):Bool {
		return a > (b : Int);
	}

	@:op(A >= B) static inline function gte(a:VarInt, b:Int):Bool {
		return (a : Int) >= b;
	}

	@:op(A >= B) static inline function gteFrom(a:Int, b:VarInt):Bool {
		return a >= (b : Int);
	}

	@:op(A << B) static inline function shl(a:VarInt, b:Int):Int {
		return (a : Int) << b;
	}

	@:op(A << B) static inline function shlFrom(a:Int, b:VarInt):Int {
		return a << (b : Int);
	}

	@:op(A >> B) static inline function shr(a:VarInt, b:Int):Int {
		return (a : Int) >> b;
	}

	@:op(A >> B) static inline function shrFrom(a:Int, b:VarInt):Int {
		return a >> (b : Int);
	}

	@:op(A >>> B) static inline function ushr(a:VarInt, b:Int):Int {
		return (a : Int) >>> b;
	}

	@:op(A >>> B) static inline function ushrFrom(a:Int, b:VarInt):Int {
		return a >>> (b : Int);
	}

	// And with a Float on the other side (a Float32 among them), as an Int is.

	@:op(A + B) @:commutative static inline function addFloat(a:VarInt, b:Float):Float {
		return (a : Int) + b;
	}

	@:op(A * B) @:commutative static inline function mulFloat(a:VarInt, b:Float):Float {
		return (a : Int) * b;
	}

	@:op(A == B) @:commutative static inline function eqFloat(a:VarInt, b:Float):Bool {
		return (a : Int) == b;
	}

	@:op(A != B) @:commutative static inline function neqFloat(a:VarInt, b:Float):Bool {
		return (a : Int) != b;
	}

	@:op(A - B) static inline function subFloat(a:VarInt, b:Float):Float {
		return (a : Int) - b;
	}

	@:op(A - B) static inline function subFloatFrom(a:Float, b:VarInt):Float {
		return a - (b : Int);
	}

	@:op(A / B) static inline function divFloat(a:VarInt, b:Float):Float {
		return (a : Int) / b;
	}

	@:op(A / B) static inline function divFloatFrom(a:Float, b:VarInt):Float {
		return a / (b : Int);
	}

	@:op(A < B) static inline function ltFloat(a:VarInt, b:Float):Bool {
		return (a : Int) < b;
	}

	@:op(A < B) static inline function ltFloatFrom(a:Float, b:VarInt):Bool {
		return a < (b : Int);
	}

	@:op(A <= B) static inline function lteFloat(a:VarInt, b:Float):Bool {
		return (a : Int) <= b;
	}

	@:op(A <= B) static inline function lteFloatFrom(a:Float, b:VarInt):Bool {
		return a <= (b : Int);
	}

	@:op(A > B) static inline function gtFloat(a:VarInt, b:Float):Bool {
		return (a : Int) > b;
	}

	@:op(A > B) static inline function gtFloatFrom(a:Float, b:VarInt):Bool {
		return a > (b : Int);
	}

	@:op(A >= B) static inline function gteFloat(a:VarInt, b:Float):Bool {
		return (a : Int) >= b;
	}

	@:op(A >= B) static inline function gteFloatFrom(a:Float, b:VarInt):Bool {
		return a >= (b : Int);
	}
}
