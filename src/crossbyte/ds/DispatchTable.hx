package crossbyte.ds;

import haxe.Constraints.Function;
#if macro
import haxe.macro.Expr;
#end

/**
	Links ids to the code that handles them, for dispatch on a hot path: an
	opcode off the wire to its handler. A macro builds it into a `switch`,
	which the compilers lower to a jump table, so a dispatch is a jump and a
	direct call: no lookup, no map, no call through a function value, and
	nothing allocated.

	A class becomes a table by implementing `DispatchTable`. Its methods
	marked `@:case` are the cases, and it gets `call`, inlined where it is
	written, so a dispatch costs what the same `switch` written out by hand
	does, and less than an `Array` of functions, which calls through a
	function value every time.

	```hx
	enum abstract Opcode(Int) from Int to Int {
		var PING = 1;
		var LOGIN = 2;
		var RELOGIN = 3;
		var QUIT = 4;
	}

	class Opcodes implements DispatchTable {
		public var pings:Int = 0;
		public var players:Array<String> = [];

		public function new() {}

		@:case(Opcode.PING) function ping(name:String):Void {
			pings++;
		}

		@:case(Opcode.LOGIN, Opcode.RELOGIN) function login(name:String):Void {
			players.push(name);
		}

		@:default function unknown(op:Opcode, name:String):Void {
			trace('$name sent $op, which nothing handles');
		}
	}
	```

	```hx
	var opcodes = new Opcodes();
	var fromTheWire:Int = 2;
	opcodes.call(fromTheWire, "ada"); // login("ada")
	opcodes.call(Opcode.QUIT, "ada"); // unknown(QUIT, "ada")
	trace(opcodes.exists(Opcode.PING)); // true
	trace(Opcodes.keys.length + " keys"); // 3 keys
	```

	Every case takes the same arguments, and every key is a constant (a
	literal, an inline variable or an enum abstract value) of one type: an
	`Int`, a `String`, or an enum abstract over either. A case that takes
	other arguments, a key of another type or one that is not a constant,
	and two keys of one value are compile errors. A method takes one key or
	several, and the cases are all instance methods, as here, keeping the
	table's state in its fields, or all static, for `Opcodes.call(...)`.

	A table makes these members:

	- `call(key, ...args)`: the case's method, or the default. Without a
	  `@:default`, a key no case names throws an `ArgumentError`, which costs
	  far more than a dispatch: give a table fed from the network a default.
	- `exists(key)`: whether a case names `key`.
	- `get(key)`: the case's method as a function value, or null.
	- `keys`: every key, in the order written, and `size`, how many.

	## A table made in place

	`Dispatch.make` builds the same `switch` into a function, from handlers
	written where it is made, which can use the variables around them. A
	handler written as a function is copied into its case rather than
	called.

	```hx
	import crossbyte.ds.DispatchTable; // Dispatch is in DispatchTable's module

	var total:Int = 0;
	var dispatch = Dispatch.make([
		{key: "ADD", handler: (amount:Int) -> total += amount},
		{key: "TAKE", handler: (amount:Int) -> total -= amount}
	], (op:String, amount:Int) -> trace('no case for $op'));

	dispatch("ADD", 5);
	dispatch("TAKE", 2); // total is 3
	```

	It is a function value, so each dispatch is a call through one: on the
	jvm and HashLink that costs about what a table of methods does, and
	natively and on Node two to three times as much (natively, such a call
	boxes its `Int` arguments). A dispatch in a hot loop wants a table of
	methods.

	A handler returns nothing unless it declares what it returns
	(`function(v:Int):Int return v * 2`), and then the table returns it: an
	arrow function's body is an expression, and `(v) -> total += v` would
	otherwise make every handler answer an `Int` nobody asked for, which
	natively is boxed.
**/
@:autoBuild(crossbyte._internal.macro.DispatchTableMacro.build())
interface DispatchTable {}

/**
	Builds a table in place: see `DispatchTable`.
**/
class Dispatch {
	/**
		A function dispatching each key to its case's handler: `(key, ...args)`,
		typed by the handlers.

		@param cases `{key, handler}` for each case. The handlers take the same
		       arguments; the keys are constants of one type.
		@param otherwise Takes the key and the arguments when no case names the
		       key. Without one, such a key throws an `ArgumentError`.
	**/
	public static macro function make(cases:ExprOf<Array<DispatchCase>>, ?otherwise:Expr):Expr {
		return crossbyte._internal.macro.DispatchTableMacro.make(cases, otherwise);
	}
}

/**
	A case of `Dispatch.make`: a key, a constant, and the handler it reaches.
**/
typedef DispatchCase = {
	var key:Any;
	var handler:Function;
}
