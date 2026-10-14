package crossbyte.rpc;

import crossbyte.io.ByteArray;
import crossbyte.io.ByteArrayInput;

/**
	What generic code holds to work with a structure it does not name: the
	reader, writer, copier and differ the RPC macros generate for a class
	that implements `RPCStruct`. `RPCCodecs.of(Ship)` is an `RPCCodec<Ship>`,
	one for each class, made once.

	A replication layer that knows nothing of the game's types is handed
	the codec by the game, as Go code is handed a protobuf message's
	descriptor and Rust code a serde implementation. One value per observer, sent
	as patches against what it acknowledged:

	```haxe
	import crossbyte.ds.SequenceRing;
	import crossbyte.rpc.RPCCodec;
	import crossbyte.rpc.RPCPatch;

	class ReplicatedValue<T> {
		final codec:RPCCodec<T>;
		final sent:SequenceRing<T>;
		final patch:RPCPatch<T>;

		public function new(codec:RPCCodec<T>, window:Int) {
			this.codec = codec;
			sent = new SequenceRing(window);
			patch = new RPCPatch(codec);
		}

		public function next(tick:Int, acked:Int, current:T):RPCPatch<T> {
			patch.diff(sent.get(acked), current); // aged out or never acknowledged: a full patch
			final slot:Null<T> = sent.get(tick - sent.capacity); // about to age out: reused
			sent.put(tick, codec.copy(current, slot != null ? slot : codec.make()));
			return patch;
		}
	}
	```

	A contract that carries the structure calls the generated code directly,
	never through this interface, so a typed call pays no virtual call. The
	`ByteArray` methods are for code outside a call (a baseline kept as bytes,
	a test, a recording) and make a scratch buffer each time; a hot path keeps
	an `RPCPatch` and uses its `write` and `read`.

	**Threading.** A codec holds nothing of its own: any thread may use it.
**/
interface RPCCodec<T> {
	/** The structure's name, for logs. **/
	var name(get, never):String;

	/**
		Its layout's fingerprint: the FNV-1a hash of its layout as a signature
		names it (each field's id, name and kind, in order). Two builds have
		the same one exactly when they write the same bytes, so a stored
		baseline can be kept with it and refused under another.
	**/
	var layout(get, never):Int;

	/** How many fields go on the wire. **/
	var fieldCount(get, never):Int;

	/** The most bytes a whole value takes, or -1 when that depends on the value (a `String`, an array). **/
	var maxSize(get, never):Int;

	/** A new value, as a reader makes one: its constructor with no arguments. **/
	function make():T;

	/**
		Copies every field that goes on the wire from `from` onto `into`, a
		nested structure into the one `into` holds and an array into its
		array, so `into` shares nothing `from` can change. Answers `into`.
	**/
	function copy(from:T, into:T):T;

	/**
		Whether the two would go as the same bytes: a `Float32` compared at
		single precision, a quantized field by its step, NaN equal to NaN.
	**/
	function equals(a:T, b:T):Bool;

	/** Writes `value` at `out.position`, as an argument of its type is written, and moves `position` past it. **/
	function write(value:T, out:ByteArray):Void;

	/**
		Reads a value at `input.position`, as an argument of its type is read:
		into `into` when given (its nested structures read in place), or into
		a new one. Answers the value.

		@throws String When the bytes are not a whole value.
	**/
	function read(input:ByteArray, ?into:T):T;

	/**
		Writes the patch from `base` (`null`: the structure as its constructor
		makes it) to `current` at `out.position`, as an `RPCPatch` writes it.
	**/
	function writePatch(base:Null<T>, current:T, out:ByteArray):Void;

	/**
		Reads a patch at `input.position` and applies it to `base` (`null`: the
		structure as its constructor makes it), the result in `into`, which may
		be `base`. Answers `into`.

		@throws String When the bytes are not a whole patch.
	**/
	function readPatch(input:ByteArray, base:Null<T>, into:T):T;

	@:noCompletion function __default():T;
	@:noCompletion function __mask(base:T, current:T):Int;
	@:noCompletion function __maskHigh(base:T, current:T):Int;
	@:noCompletion function __patchBound():Int;
	@:noCompletion function __newState():Any;
	@:noCompletion function __apply(state:Any, base:Null<T>, into:T):T;
	@:noCompletion function __writePatch(frame:crossbyte.rpc._internal.RPCFrame, patch:RPCPatch<T>):Void;
	@:noCompletion function __readPatch(input:ByteArrayInput, end:Int, patch:RPCPatch<T>):Void;
	@:noCompletion function __writeMapPatch(frame:crossbyte.rpc._internal.RPCFrame, patch:RPCMapPatch<T>):Void;
	@:noCompletion function __readMapPatch(input:ByteArrayInput, end:Int, patch:RPCMapPatch<T>):Void;
	@:noCompletion function __writeStringMapPatch(frame:crossbyte.rpc._internal.RPCFrame, patch:RPCStringMapPatch<T>):Void;
	@:noCompletion function __readStringMapPatch(input:ByteArrayInput, end:Int, patch:RPCStringMapPatch<T>):Void;
}
