package crossbyte.rpc;

/**
	An `Int` sent as an unsigned LEB128 varint: one byte up to 127, two up to
	16,383, three up to 2,097,151, four up to 268,435,455 and five at most,
	where an `Int` always takes four. For a tick, an acknowledgement, an input
	sequence: numbers that grow without bound but stay small for a long time.
	Protobuf's `uint32` is the same encoding.

	It is an `Int` wherever one is wanted, and holds all 32 bits: a negative
	value is sent as the unsigned number its bits make, in five bytes, and
	arrives as the same negative `Int`. So a tick counter that has wrapped past
	2^31 - 1 (as `crossbyte.Seq32` and `SequenceRing` order them) carries on.
	Operators and comparisons work on the `Int` it holds.

	```haxe
	import crossbyte.rpc.VarUInt;

	interface MatchContract {
		// 3 bytes for a tick of 36,000, where an Int is 4.
		function ack(tick:VarUInt):Void;
	}
	```
**/
abstract VarUInt(Int) from Int to Int {
	// Every operator works on the Int a value holds, the other side an Int
	// or anything that is one (another compact number, an Int literal).

	@:op(A + B) @:commutative static inline function add(a:VarUInt, b:Int):Int {
		return (a : Int) + b;
	}

	@:op(A * B) @:commutative static inline function mul(a:VarUInt, b:Int):Int {
		return (a : Int) * b;
	}

	@:op(A & B) @:commutative static inline function and(a:VarUInt, b:Int):Int {
		return (a : Int) & b;
	}

	@:op(A | B) @:commutative static inline function or(a:VarUInt, b:Int):Int {
		return (a : Int) | b;
	}

	@:op(A ^ B) @:commutative static inline function xor(a:VarUInt, b:Int):Int {
		return (a : Int) ^ b;
	}

	@:op(A == B) @:commutative static inline function eq(a:VarUInt, b:Int):Bool {
		return (a : Int) == b;
	}

	@:op(A != B) @:commutative static inline function neq(a:VarUInt, b:Int):Bool {
		return (a : Int) != b;
	}

	@:op(A - B) static inline function sub(a:VarUInt, b:Int):Int {
		return (a : Int) - b;
	}

	@:op(A - B) static inline function subFrom(a:Int, b:VarUInt):Int {
		return a - (b : Int);
	}

	@:op(A / B) static inline function div(a:VarUInt, b:Int):Float {
		return (a : Int) / b;
	}

	@:op(A / B) static inline function divFrom(a:Int, b:VarUInt):Float {
		return a / (b : Int);
	}

	@:op(A % B) static inline function mod(a:VarUInt, b:Int):Int {
		return (a : Int) % b;
	}

	@:op(A % B) static inline function modFrom(a:Int, b:VarUInt):Int {
		return a % (b : Int);
	}

	@:op(A < B) static inline function lt(a:VarUInt, b:Int):Bool {
		return (a : Int) < b;
	}

	@:op(A < B) static inline function ltFrom(a:Int, b:VarUInt):Bool {
		return a < (b : Int);
	}

	@:op(A <= B) static inline function lte(a:VarUInt, b:Int):Bool {
		return (a : Int) <= b;
	}

	@:op(A <= B) static inline function lteFrom(a:Int, b:VarUInt):Bool {
		return a <= (b : Int);
	}

	@:op(A > B) static inline function gt(a:VarUInt, b:Int):Bool {
		return (a : Int) > b;
	}

	@:op(A > B) static inline function gtFrom(a:Int, b:VarUInt):Bool {
		return a > (b : Int);
	}

	@:op(A >= B) static inline function gte(a:VarUInt, b:Int):Bool {
		return (a : Int) >= b;
	}

	@:op(A >= B) static inline function gteFrom(a:Int, b:VarUInt):Bool {
		return a >= (b : Int);
	}

	@:op(A << B) static inline function shl(a:VarUInt, b:Int):Int {
		return (a : Int) << b;
	}

	@:op(A << B) static inline function shlFrom(a:Int, b:VarUInt):Int {
		return a << (b : Int);
	}

	@:op(A >> B) static inline function shr(a:VarUInt, b:Int):Int {
		return (a : Int) >> b;
	}

	@:op(A >> B) static inline function shrFrom(a:Int, b:VarUInt):Int {
		return a >> (b : Int);
	}

	@:op(A >>> B) static inline function ushr(a:VarUInt, b:Int):Int {
		return (a : Int) >>> b;
	}

	@:op(A >>> B) static inline function ushrFrom(a:Int, b:VarUInt):Int {
		return a >>> (b : Int);
	}

	// And with a Float on the other side (a Float32 among them), as an Int is.

	@:op(A + B) @:commutative static inline function addFloat(a:VarUInt, b:Float):Float {
		return (a : Int) + b;
	}

	@:op(A * B) @:commutative static inline function mulFloat(a:VarUInt, b:Float):Float {
		return (a : Int) * b;
	}

	@:op(A == B) @:commutative static inline function eqFloat(a:VarUInt, b:Float):Bool {
		return (a : Int) == b;
	}

	@:op(A != B) @:commutative static inline function neqFloat(a:VarUInt, b:Float):Bool {
		return (a : Int) != b;
	}

	@:op(A - B) static inline function subFloat(a:VarUInt, b:Float):Float {
		return (a : Int) - b;
	}

	@:op(A - B) static inline function subFloatFrom(a:Float, b:VarUInt):Float {
		return a - (b : Int);
	}

	@:op(A / B) static inline function divFloat(a:VarUInt, b:Float):Float {
		return (a : Int) / b;
	}

	@:op(A / B) static inline function divFloatFrom(a:Float, b:VarUInt):Float {
		return a / (b : Int);
	}

	@:op(A < B) static inline function ltFloat(a:VarUInt, b:Float):Bool {
		return (a : Int) < b;
	}

	@:op(A < B) static inline function ltFloatFrom(a:Float, b:VarUInt):Bool {
		return a < (b : Int);
	}

	@:op(A <= B) static inline function lteFloat(a:VarUInt, b:Float):Bool {
		return (a : Int) <= b;
	}

	@:op(A <= B) static inline function lteFloatFrom(a:Float, b:VarUInt):Bool {
		return a <= (b : Int);
	}

	@:op(A > B) static inline function gtFloat(a:VarUInt, b:Float):Bool {
		return (a : Int) > b;
	}

	@:op(A > B) static inline function gtFloatFrom(a:Float, b:VarUInt):Bool {
		return a > (b : Int);
	}

	@:op(A >= B) static inline function gteFloat(a:VarUInt, b:Float):Bool {
		return (a : Int) >= b;
	}

	@:op(A >= B) static inline function gteFloatFrom(a:Float, b:VarUInt):Bool {
		return a >= (b : Int);
	}
}
