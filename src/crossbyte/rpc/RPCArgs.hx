package crossbyte.rpc;

import crossbyte.io.ByteArray;
import crossbyte.io.ByteArrayInput;
import crossbyte.rpc._internal.RPCBytes;
import crossbyte.rpc._internal.RPCRuntimeCodec;
import crossbyte.rpc._internal.RPCWire;
import haxe.io.Bytes;

/**
	A runtime-lane call's arguments, read where they lie in the frame: what
	a handler registered with `RPCSession.registerArgs` is handed, in place
	of the `Array<Dynamic>` that `register` builds.

	```haxe
	// Given session:RPCSession<Dynamic, Dynamic>.
	final MOVE = 102;
	session.registerArgs(MOVE, args -> {
		trace(args.float(0) + args.float(1), args.string(2));
		return null;
	});
	```

	Each getter takes the value's index and checks its tag: `int(i)` of a
	value sent as an `Int`, `float(i)` of a `Float` or an `Int` (which a
	`Float` holds exactly), `bool(i)`, `string(i)` and `bytes(i)` of their
	kinds or of the lane's null, `isNull(i)`, and `value(i)` of anything, as
	`register`'s array holds it. A value of another kind, or an index past
	`count`, throws an `RPCError` saying which, so the caller of a request
	is answered with that message, as for any `RPCError` its handler throws.
	A number read is not boxed; a string or `Bytes` read is made for the
	handler, and is its to keep.

	The frame is read once before the handler runs, to find where each
	value begins and to check that every one of them lies within it: a call
	that does not read is answered `RPCError.UNREADABLE_MESSAGE`, as on
	`register`'s side, and its handler does not run.

	**Valid only during the call.** It is the session's, handed to the next
	call too, and reads the frame the call came in: read what the handler
	needs before it returns (a handler answering later with a `Future`
	reads its arguments first). Re-entered (a handler whose call delivers
	another to this session at once), the inner call is handed one of its
	own.
**/
@:access(crossbyte.io.ByteArrayData)
class RPCArgs {
	/** How many values the call carries. **/
	public var count(default, null):Int = 0;

	@:noCompletion private var __input:Null<ByteArrayInput> = null;
	@:noCompletion private var __data:Null<ByteArrayData> = null;
	// Where each value's tag is, in the frame.
	@:noCompletion private var __at:Array<Int> = [];
	@:noCompletion private var __busy:Bool = false;

	@:noCompletion private function new() {}

	/**
		Finds each of the values `input` holds from its position, none past
		`end`, and leaves `input` past them.

		@throws String For a frame that does not read: a count or a length
		        past what it holds, a value of a kind this lane does not know.
	**/
	@:noCompletion private function __read(input:ByteArrayInput, end:Int):Void {
		final total:Int = input.readVarUInt();
		RPCWire.requireRoom(input, end, total);
		final data:ByteArrayData = cast input;
		var at:Int = input.position;
		final offsets:Array<Int> = __at;
		if (offsets.length < total) {
			offsets.resize(total);
		}
		for (i in 0...total) {
			if (at >= end) {
				throw "RPC frame names more than it holds";
			}
			offsets[i] = at;
			final tag:Int = data.get(at);
			at += 1;
			switch (tag) {
				case RPCRuntimeCodec.TAG_NULL | RPCRuntimeCodec.TAG_FALSE | RPCRuntimeCodec.TAG_TRUE:
				case RPCRuntimeCodec.TAG_INT:
					at += 4;
				case RPCRuntimeCodec.TAG_FLOAT:
					at += 8;
				case RPCRuntimeCodec.TAG_STRING | RPCRuntimeCodec.TAG_BYTES:
					input.position = at;
					final length:Int = input.readVarUInt();
					RPCWire.requireRoom(input, end, length);
					at = input.position + length;
				case _:
					throw "Unsupported runtime RPC tag: " + tag;
			}
			if (at > end) {
				throw "RPC frame names more than it holds";
			}
		}
		input.position = at;
		count = total;
		__input = input;
		__data = data;
	}

	/** Lets go of the frame once the call is over. **/
	@:noCompletion private inline function __done():Void {
		__input = null;
		__data = null;
		count = 0;
		__busy = false;
	}

	/** The tag of value `index`; see `RPCRuntimeCodec`. **/
	@:noCompletion private inline function __tag(index:Int):Int {
		if (index < 0 || index >= count || __data == null) {
			throw new RPCError('RPC argument $index was asked for, and the call carries $count');
		}
		return __data.get(__at[index]);
	}

	/** Whether value `index` is the lane's null. **/
	public inline function isNull(index:Int):Bool {
		return __tag(index) == RPCRuntimeCodec.TAG_NULL;
	}

	/** Value `index`, an `Int`. **/
	public inline function int(index:Int):Int {
		final tag:Int = __tag(index);
		if (tag != RPCRuntimeCodec.TAG_INT) {
			throw __wrongKind(index, tag, "an Int");
		}
		return RPCBytes.getI32(__data, __at[index] + 1);
	}

	/** Value `index`, a `Float`, or an `Int` as a `Float`. **/
	public inline function float(index:Int):Float {
		final tag:Int = __tag(index);
		return if (tag == RPCRuntimeCodec.TAG_FLOAT) {
			RPCBytes.getF64(__data, __at[index] + 1);
		} else if (tag == RPCRuntimeCodec.TAG_INT) {
			RPCBytes.getI32(__data, __at[index] + 1);
		} else {
			throw __wrongKind(index, tag, "a Float");
		}
	}

	/** Value `index`, a `Bool`. **/
	public inline function bool(index:Int):Bool {
		final tag:Int = __tag(index);
		return if (tag == RPCRuntimeCodec.TAG_TRUE) {
			true;
		} else if (tag == RPCRuntimeCodec.TAG_FALSE) {
			false;
		} else {
			throw __wrongKind(index, tag, "a Bool");
		}
	}

	/** Value `index`, a `String` made for the handler, or `null` for the lane's null. **/
	public function string(index:Int):Null<String> {
		final tag:Int = __tag(index);
		if (tag == RPCRuntimeCodec.TAG_NULL) {
			return null;
		}
		if (tag != RPCRuntimeCodec.TAG_STRING) {
			throw __wrongKind(index, tag, "a String");
		}
		final input:ByteArrayInput = __input;
		final back:Int = input.position;
		input.position = __at[index] + 1;
		final text:String = input.readVarUTF();
		input.position = back;
		return text;
	}

	/** Value `index`, `Bytes` made for the handler, or `null` for the lane's null. **/
	public function bytes(index:Int):Null<Bytes> {
		final tag:Int = __tag(index);
		if (tag == RPCRuntimeCodec.TAG_NULL) {
			return null;
		}
		if (tag != RPCRuntimeCodec.TAG_BYTES) {
			throw __wrongKind(index, tag, "Bytes");
		}
		final input:ByteArrayInput = __input;
		final back:Int = input.position;
		input.position = __at[index] + 1;
		final length:Int = input.readVarUInt();
		final made:Bytes = Bytes.alloc(length);
		input.readBytes(made, 0, length);
		input.position = back;
		return made;
	}

	/** Value `index` as `register`'s array holds it: `null`, a `Bool`, an `Int`, a `Float`, a `String` or `Bytes`. **/
	public function value(index:Int):Dynamic {
		return switch (__tag(index)) {
			case RPCRuntimeCodec.TAG_NULL: null;
			case RPCRuntimeCodec.TAG_FALSE: false;
			case RPCRuntimeCodec.TAG_TRUE: true;
			case RPCRuntimeCodec.TAG_INT: int(index);
			case RPCRuntimeCodec.TAG_FLOAT: float(index);
			case RPCRuntimeCodec.TAG_STRING: string(index);
			case _: bytes(index);
		}
	}

	/**
		The kind of value `index`, as the name of a Haxe type: `"Null"`,
		`"Bool"`, `"Int"`, `"Float"`, `"String"` or `"Bytes"`, for a handler
		that takes more than one.
	**/
	public function kind(index:Int):String {
		return kindName(__tag(index));
	}

	static function kindName(tag:Int):String {
		return switch (tag) {
			case RPCRuntimeCodec.TAG_NULL: "Null";
			case RPCRuntimeCodec.TAG_FALSE | RPCRuntimeCodec.TAG_TRUE: "Bool";
			case RPCRuntimeCodec.TAG_INT: "Int";
			case RPCRuntimeCodec.TAG_FLOAT: "Float";
			case RPCRuntimeCodec.TAG_STRING: "String";
			case _: "Bytes";
		}
	}

	@:noCompletion private static function __wrongKind(index:Int, tag:Int, wanted:String):RPCError {
		final kind:String = kindName(tag);
		final what:String = tag == RPCRuntimeCodec.TAG_NULL ? "null" : (kind == "Int" ? "an Int" : (kind == "Bytes" ? "Bytes" : "a " + kind));
		return new RPCError('RPC argument $index is $what, where $wanted was asked for');
	}
}
