package crossbyte.rpc;

/**
	Marks a class as one the compiled RPC lane carries: a class that
	implements it can be an argument or an answer of a contract method, an
	element of an `Array`, or a field of another structure, as an `Int` or
	a `String` can.

	```haxe
	import crossbyte.rpc.Float32;
	import crossbyte.rpc.RPCStruct;
	import crossbyte.rpc.UInt8;

	class Spawn implements RPCStruct {
		public var id:Int = 0;
		public var x:Float32 = 0;
		public var y:Float32 = 0;
		public var flags:UInt8 = 0;
		@:rpcSkip public var sprite:Null<Dynamic> = null; // not sent

		public function new() {}
	}
	```

	What goes on the wire is every `var` the class declares, and every one
	the classes it extends declare, except those marked `@:rpcSkip`: their
	values one after another, with no names, tags or lengths, a `Float32`
	four bytes, a `UInt8` one. The fields go in the order of their names, so
	moving a declaration changes nothing; `@:field(n)`, n from 0 to 65535,
	pins a field ahead of the named ones, in the order of n, as the `hxwire`
	library orders its fields. A field the lane does not carry, a `final`
	field, or a property fails the build, naming it, unless it is marked
	`@:rpcSkip`.

	A class is read by calling its constructor with no arguments and then
	setting each field, so it must have one that takes none (or only
	optional ones); it may set defaults for `@:rpcSkip` fields there. It
	cannot have type parameters, and it cannot contain itself, directly or
	through the structures it holds.

	The layout, each field's pinned id, name and kind, in order, is part
	of the op of every method that carries the class (see "What names a
	call" in the RPC guide), so a peer built from another version of it
	answers as for a method it does not have, rather than reading the
	bytes as its own. The class's name is not: a class and a typedef'd
	anonymous structure with the same fields have the same layout, and the
	two ends of a call may use one each.

	Nothing to implement: the reader and writer are generated at compile
	time, once for each class, with no reflection. A class whose fields are
	all numbers and `Bool`s is written and read as one run of bytes, and an
	array of them as one run.

	Prefer a class to a typedef'd anonymous structure for hot calls:
	natively an anonymous structure's fields are looked up by name and its
	numbers boxed. A one-way call carrying five numbers took 50 ns and 40
	bytes as a class, 74 ns and 232 bytes as a typedef.
**/
interface RPCStruct {}
