package crossbyte.rpc._internal;

import crossbyte.utils.Hash;
import haxe.io.Bytes;

/**
	How a compiled RPC method becomes the op that names it on the wire, and
	the check that no two methods of one surface share an op.

	An op is the 32-bit FNV-1a hash of the method's signature, its UTF-8
	bytes:

	```
	signature := name "(" [ kind ("," kind)* ] ")" [ ":" kind ]
	kind      := [ "?" ] ( "i32" | "i64" | "bool" | "f64" | "utf8" | "bytes"
	                     | "f32" | "i8" | "u8" | "i16" | "u16"
	                     | "[" kind "]"
	                     | "{" field ("," field)* "}"
	                     | "<" ctor ("," ctor)* ">" )
	field     := [ id "=" ] name ":" kind
	ctor      := name [ "(" kind ("," kind)* ")" ]
	```

	The kinds are the method's arguments in order, and after the colon its
	answer's; a one-way method has none. A `?` is a value that may be
	absent (an optional argument, a `Null<T>`), which a byte before it
	says. `f32`, `i8`, `u8`, `i16` and `u16` are the compact numbers
	(`crossbyte.rpc.Float32`, `Int8`, `UInt8`, `Int16`, `UInt16`); an
	abstract is the kind of what it abstracts. An array is its element's
	kind in brackets, and a structure (`RPCStructs`) its fields in braces,
	in their order on the wire, each with its `@:field` id if pinned:
	`{1=id:i32,name:utf8,x:f32}`; an enum its constructors in angle
	brackets, in index order, with their arguments' kinds:
	`<Stop,Walk(f32,f32)>`. `add(a:Int, b:Int):Int`
	is `add(i32,i32):i32`, `say(text:String):Void` is `say(utf8)`, and
	`grid(rows:Array<Array<Null<Int>>>):Void` is `grid([[?i32]])`.

	A kind names a layout, not a type: a typedef is the kind it names, so
	renaming one, or an argument, changes no op, and a client and a server
	still agree. Reordering arguments of different kinds, retyping one,
	adding or removing one, or making one optional changes the op: a peer
	built from the other version of the method finds no method with it,
	and is answered as for a method it does not have, rather than reading
	the bytes as its own and running on what they make. Swapping two arguments of
	the same kind changes nothing on the wire, and so not the op.

	Not the contract the method was declared in: a method keeps its op
	wherever a contract that declares it is reused. Two signatures can
	still hash alike, and on one connection they would be one method, so a
	surface with two such fails the build. `ping`, every session's own, is
	the hash of its name alone (`RPCWire.PING_OP`).

	A kind added later (a structure, an enum) names its own layout, and
	every kind above keeps its token. Compiled into the macros as well as the runtime, so
	the check the build makes is the one the tests exercise.
**/
class RPCOps {
	/** The op of `text`, a method's signature or `ping`: its FNV-1a hash. **/
	public static inline function opOf(text:String):Int {
		return Hash.fnv1a32(Bytes.ofString(text));
	}

	/**
		A method's signature: its name, the kinds of its arguments, and, for a
		method that is answered, after a colon, its answer's. `answer` is
		`null` for a one-way method.
	**/
	public static function signature(name:String, args:Array<String>, answer:Null<String>):String {
		return name + "(" + args.join(",") + ")" + (answer == null ? "" : ":" + answer);
	}

	/**
		A fingerprint of a set of methods, by their ops: FNV-1a over each op's
		four bytes, little-endian, the ops in ascending order, so the order
		methods are declared in does not matter. Two sides built from the
		same methods with the same signatures have the same fingerprint; one
		with a method more, or a signature changed, has another. Never 0,
		which a session's hello sends for a side with no methods at all.
	**/
	public static function fingerprint(ops:Array<Int>):Int {
		final sorted:Array<Int> = ops.copy();
		sorted.sort((a, b) -> a < b ? -1 : (a > b ? 1 : 0));
		var hash:Int = 0x811c9dc5;
		var last:Null<Int> = null;
		for (op in sorted) {
			// A method reached twice is one method.
			if (last != null && op == last) {
				continue;
			}
			last = op;
			for (shift in [0, 8, 16, 24]) {
				hash = Hash.mul32(hash ^ ((op >>> shift) & 0xFF), 0x01000193);
			}
		}
		return hash == 0 ? 1 : hash;
	}

	/**
		The first two of `signatures` that share an op, or `null` if none do.
		One listed twice is one method reached twice, not a clash.
	**/
	public static function firstClash(signatures:Array<String>):Null<Array<String>> {
		final byOp:Map<Int, String> = new Map();
		for (signature in signatures) {
			final op:Int = opOf(signature);
			final other:Null<String> = byOp.get(op);
			if (other == null) {
				byOp.set(op, signature);
			} else if (other != signature) {
				return [other, signature];
			}
		}
		return null;
	}
}
