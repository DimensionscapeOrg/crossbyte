package crossbyte.rpc;

import crossbyte.errors.ArgumentError;
import crossbyte.io.ByteArray;
import crossbyte.io.ByteArrayInput;
import crossbyte.rpc._internal.RPCFrame;
import crossbyte.rpc._internal.RPCKeys;

/**
	A structure sent as what changed since a base both ends hold: a bit for
	each of its fields, then the fields that differ, each whole. An argument
	or an answer of a contract method, for a class that implements
	`RPCStruct`.

	```haxe
	import crossbyte.rpc.RPCCommands;
	import crossbyte.rpc.RPCPatch;
	import crossbyte.rpc.RPCStruct;
	import crossbyte.rpc.VarUInt;

	class Hero implements RPCStruct {
		public var x:Float = 0;
		public var y:Float = 0;
		public var health:Int = 100;

		public function new() {}
	}

	interface HeroContract {
		function hero(tick:VarUInt, base:VarUInt, state:RPCPatch<Hero>):Void;
	}

	@:rpcContract(HeroContract)
	class HeroCommands extends RPCCommands {
		public function new() {}
	}
	```

	**Sending.** `diff(base, current)` works out which fields differ, at the
	precision they are sent, and answers the patch, which is then passed as
	the argument. Nothing is copied: the patch holds the two values until it
	is sent, and is used again for the next. The base is what the receiver
	holds: the value last sent over a reliable connection, or the one it last
	acknowledged over an unreliable one. A `null` base sends the patch from
	the structure as its constructor makes it (`isFull`), which a receiver
	applies whatever it holds: what a joining client, or one whose base has
	aged out, is sent.

	```haxe
	// Given commands:HeroCommands, patch:RPCPatch<Hero>, hero:Hero, acked:Null<Hero>.
	commands.hero(36000, 35998, patch.diff(acked, hero));
	```

	**Received**, it is valid only during the call, as a socket's event is:
	the session reads every call's into the same one. `apply(base, into)`
	makes the value the sender had, from the base it named:

	```haxe
	// Given state:RPCPatch<Hero>, frames:crossbyte.ds.SequenceRing<Hero>, base:Int, tick:Int.
	final from:Null<Hero> = state.isFull ? null : frames.get(base);
	if (from != null || state.isFull) {
		final slot:Null<Hero> = frames.get(tick - frames.capacity);
		frames.put(tick, state.apply(from, slot != null ? slot : new Hero()));
	}
	```

	Values are absolute, never arithmetic differences, so a patch applied to
	the right base gives the sender's value exactly, whatever was lost in
	between. A nested structure field is patched field by field against the
	base's; any other field that differs (a `String`, an array, a map, an
	enum) goes whole. A structure of up to 64 fields can be patched.

	Writing allocates nothing, nor does reading once the session has made the
	patch it reads into; applying allocates only what `into` lacks (a nested
	structure it does not hold, an array it has not got).

	**Threading.** None: one patch is used by one thread at a time.
**/
final class RPCPatch<T> {
	/** The structure's codec. **/
	public final codec:RPCCodec<T>;

	/** How many fields differ (sending), or arrived (received). **/
	public var changedCount(default, null):Int = 0;

	/**
		Whether it is the patch from the structure as its constructor makes
		it: its base was `null`. A receiver applies it whatever base it holds.
	**/
	public var isFull(default, null):Bool = true;

	/** Whether nothing differs from a base: no field changed, and not `isFull`. **/
	public var isEmpty(get, never):Bool;

	@:noCompletion public var __base:Null<T> = null;
	@:noCompletion public var __current:Null<T> = null;
	@:noCompletion public var __mask:Int = 0;
	@:noCompletion public var __maskHigh:Int = 0;
	// What a read put the values in: the generated state of the structure.
	@:noCompletion public var __state:Any = null;
	@:noCompletion public var __received:Bool = false;
	@:noCompletion private var __frame:Null<RPCFrame> = null;
	@:noCompletion private var __wide:Bool;

	/**
		@param codec The structure's codec: `RPCCodecs.of(Hero)`.
		@throws ArgumentError For a `null` codec.
	**/
	public function new(codec:RPCCodec<T>) {
		if (codec == null) {
			throw new ArgumentError("An RPCPatch needs its structure's codec: RPCCodecs.of(Type).");
		}
		this.codec = codec;
		__wide = codec.fieldCount > 32;
	}

	/**
		Works out which fields of `current` differ from `base`, at the
		precision they are sent (a `Float32` at single precision, a quantized
		field by its step), and answers this patch, to pass as the argument.
		The two are held, not copied, until the patch is sent: change neither
		before then.

		@param base What the receiver holds, or `null` for the patch from the
		       structure as its constructor makes it.
		@throws ArgumentError For a `null` `current`.
	**/
	public function diff(base:Null<T>, current:T):RPCPatch<T> {
		if (current == null) {
			throw new ArgumentError("RPCPatch.diff needs the current value.");
		}
		__base = base;
		__current = current;
		__received = false;
		isFull = base == null;
		final from:T = base == null ? codec.__default() : base;
		__mask = codec.__mask(from, current);
		__maskHigh = __wide ? codec.__maskHigh(from, current) : 0;
		changedCount = RPCKeys.bitCount(__mask) + RPCKeys.bitCount(__maskHigh);
		return this;
	}

	/**
		Sets `into` to `base` patched, and answers it: the value the sender
		had. `base` is ignored when `isFull`, and may be `null` then; `into`
		may be `base`, patched in place. Fields that did not change are copied
		from `base` (nested structures and arrays into those `into` holds), so
		`into` shares nothing with either.

		On a patch made by `diff`, it copies the current value into `into`.

		@throws ArgumentError When `into` is `null`, or the patch is not from
		        the default and `base` is `null`.
	**/
	public function apply(base:Null<T>, into:T):T {
		if (into == null) {
			throw new ArgumentError("RPCPatch.apply needs a value to set: pass the one to patch, or a new one.");
		}
		if (!isFull && base == null) {
			throw new ArgumentError("This patch is against a base, and none was given: keep the value it names, or wait for a full one.");
		}
		if (!__received) {
			if (__current == null) {
				throw new ArgumentError("This patch has not been diffed or received.");
			}
			return codec.copy(__current, into);
		}
		return codec.__apply(__state, isFull ? null : base, into);
	}

	/**
		Writes the patch at `out.position` (as it goes on the wire, after a bit
		saying whether it is full) and moves `position` past it: for a test, a
		recording, a resync frame kept for later, or a patch carried in a
		`Bytes` argument. `read` reads it back.
	**/
	public function write(out:ByteArray):Void {
		if (out == null) {
			throw new ArgumentError("RPCPatch.write needs a ByteArray to write into.");
		}
		final frame:RPCFrame = __scratch();
		codec.__writePatch(frame, this);
		out.writeBytes(frame, 0, frame.position);
	}

	/**
		Reads a patch `write` wrote at `input.position` into this one, moving
		`position` past it, and answers this patch, to `apply` as one that
		arrived in a call.

		@throws String When the bytes are not a whole patch of this structure.
	**/
	public function read(input:ByteArray):RPCPatch<T> {
		if (input == null) {
			throw new ArgumentError("RPCPatch.read needs a ByteArray to read.");
		}
		final from:ByteArrayInput = input;
		codec.__readPatch(from, input.length, this);
		if (from.position > input.length) {
			throw "RPC patch read past its end";
		}
		return this;
	}

	@:noCompletion public inline function __receive(mask:Int, maskHigh:Int, full:Bool):Void {
		__mask = mask;
		__maskHigh = maskHigh;
		isFull = full;
		changedCount = RPCKeys.bitCount(mask) + RPCKeys.bitCount(maskHigh);
		__received = true;
		__base = null;
		__current = null;
	}

	@:noCompletion private function __scratch():RPCFrame {
		var frame:Null<RPCFrame> = __frame;
		if (frame == null) {
			frame = __frame = new RPCFrame(64);
		}
		frame.beginScratch();
		return frame;
	}

	private inline function get_isEmpty():Bool {
		return !isFull && changedCount == 0;
	}
}
