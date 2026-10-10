package crossbyte.rpc._internal;

import crossbyte.io.ByteArray;
import crossbyte.io.ByteArrayInput;

class RPCWire {
	public static inline final FLAG_REQUEST:Int = 0x01;
	public static inline final FLAG_RESPONSE:Int = 0x02;
	public static inline final FLAG_ERROR:Int = 0x04;
	public static inline final FLAG_RUNTIME:Int = 0x08;

	/**
		On a request: the caller's deadline follows the request id, a varuint
		of the milliseconds the caller will wait from when it sent the call.
		Sent only to a peer whose hello declared `CAPABILITY_CALL_CONTROL`.
	**/
	public static inline final FLAG_DEADLINE:Int = 0x10;

	/**
		A frame of its own, with the op and the varuint request id of a call
		the caller has stopped waiting for: it cancelled it, or its deadline
		passed. With `FLAG_RUNTIME` for a runtime-lane call. Sent only to a
		peer whose hello declared `CAPABILITY_CALL_CONTROL`; a peer without
		it would pass it over.
	**/
	public static inline final FLAG_CANCEL:Int = 0x20;

	/**
		The capability, in a hello, of reading `FLAG_DEADLINE` on a request
		and `FLAG_CANCEL` frames: a peer that declares it is told each call's
		deadline and each call it need no longer answer.
	**/
	public static inline final CAPABILITY_CALL_CONTROL:Int = 0x01;

	/**
		A frame of its own carrying a piece of an answer too long to send at
		once, so that the frames sent while it goes are not held up behind
		it, as HTTP/2's DATA frames are:

		```
		u32      length        5 + the rest
		u8       flags         FLAG_CHUNK, with FLAG_CHUNK_END on the last piece
		i32      stream        which answer it is a piece of, in the op's place
		varuint  total         on the first piece only: the answer's frame
		                       length, what its own length would have said
		...      the piece     the answer's frame after its length, in order
		```

		The pieces of one answer, joined, are its frame after its length: the
		first carries its flags and op, and the rest follow, `total` bytes in
		all. A reader holds them until the last, then reads the frame as if
		it had come whole. At most
		`MAX_CHUNK_STREAMS` answers go in pieces at once, and each counts
		toward `RPCSession.maxFrameLength`. Only answers are sent so, and only
		to a peer whose hello declared `CAPABILITY_CHUNKS`.
	**/
	public static inline final FLAG_CHUNK:Int = 0x40;

	/** On the last piece of a `FLAG_CHUNK` stream. **/
	public static inline final FLAG_CHUNK_END:Int = 0x80;

	/** The bytes before a piece's own: its length, flags and stream. **/
	public static inline final CHUNK_HEAD:Int = 9;

	/** The most answers that go in pieces at once, one way on a connection; the rest wait their turn. **/
	public static inline final MAX_CHUNK_STREAMS:Int = 4;

	/** The capability, in a hello, of reading `FLAG_CHUNK` frames. **/
	public static inline final CAPABILITY_CHUNKS:Int = 0x02;
	public static inline final MIN_PAYLOAD_LEN:Int = 5;

	// What refused a call, after an error answer's message: a varuint, left
	// out for REFUSED_BY_HANDLER, so a handler's refusal is framed as before.
	// A reader takes an answer with none, as one from before 1.0 has, and one
	// it does not know, as a later version's could be, as the handler's own.
	//
	//   varuint request id
	//   varuint length, UTF-8   the message
	//   varuint code            absent for REFUSED_BY_HANDLER

	/** An `RPCError` the handler meant its caller to see: `RPCFailure.Refused`. **/
	public static inline final REFUSED_BY_HANDLER:Int = 0;

	/** The handler failed with something else: `RPCFailure.HandlerFailed`, `RPCError.INTERNAL_MESSAGE`. **/
	public static inline final REFUSED_HANDLER_FAILED:Int = 1;

	/** No method answers the call: `RPCFailure.UnknownMethod`. **/
	public static inline final REFUSED_UNKNOWN_METHOD:Int = 2;

	/** Its arguments did not read: `RPCFailure.UnreadableArguments`. **/
	public static inline final REFUSED_UNREADABLE:Int = 3;

	/** Too many calls were waiting: `RPCFailure.Busy`. **/
	public static inline final REFUSED_BUSY:Int = 4;

	/** Nothing answers calls on that session: `RPCFailure.NoHandler`. **/
	public static inline final REFUSED_NO_HANDLER:Int = 5;

	/** The handler did not answer in time: `RPCFailure.HandlerTimedOut`. **/
	public static inline final REFUSED_HANDLER_TIMEOUT:Int = 6;

	/** The frame was larger than its receiver takes: `RPCFailure.TooLarge`. **/
	public static inline final REFUSED_TOO_LARGE:Int = 7;

	/** The message a refusal of `code` is framed with, or `null` for one whose message is the handler's. **/
	public static function refusalMessage(code:Int):Null<String> {
		return switch (code) {
			case REFUSED_HANDLER_FAILED: crossbyte.rpc.RPCError.INTERNAL_MESSAGE;
			case REFUSED_UNKNOWN_METHOD: crossbyte.rpc.RPCError.UNKNOWN_METHOD_MESSAGE;
			case REFUSED_UNREADABLE: crossbyte.rpc.RPCError.UNREADABLE_MESSAGE;
			case REFUSED_BUSY: crossbyte.rpc.RPCError.BUSY_MESSAGE;
			case REFUSED_NO_HANDLER: crossbyte.rpc.RPCError.NO_HANDLER_MESSAGE;
			case REFUSED_HANDLER_TIMEOUT: crossbyte.rpc.RPCError.TIMEOUT_MESSAGE;
			case REFUSED_TOO_LARGE: crossbyte.rpc.RPCError.TOO_LARGE_MESSAGE;
			case _: null;
		}
	}

	/**
		The message of an error answer refused as `code`, `input` at it: the
		session's own words for the code (read without a string made for them)
		when the answer carries them, as a session's own refusal does, and
		otherwise what it carries, as a handler refusing with a code
		(`RPCError.refusal`) words it.
	**/
	public static function refusalText(input:ByteArrayInput, code:Int):String {
		final words:Null<String> = refusalMessage(code);
		if (words == null) {
			return input.readVarUTF();
		}
		final start:Int = input.position;
		final length:Int = input.readVarUInt();
		var same:Bool = length == words.length && length <= input.bytesAvailable;
		if (same) {
			final data:ByteArrayData = cast input;
			final at:Int = input.position;
			for (i in 0...length) {
				if (data.get(at + i) != StringTools.fastCodeAt(words, i)) {
					same = false;
					break;
				}
			}
		}
		if (same) {
			input.position += length;
			return words;
		}
		input.position = start;
		return input.readVarUTF();
	}

	/**
		The code of the error answer whose message `input` is at, in a frame
		ending at `end`: what follows the message, or `REFUSED_BY_HANDLER`
		when nothing does. `input` is left at the message, which is read only
		when the code does not say it: a refusal the session made costs no
		string to read.
	**/
	public static function refusalCode(input:ByteArrayInput, end:Int):Int {
		final start:Int = input.position;
		final length:Int = input.readVarUInt();
		requireRoom(input, end, length);
		input.position += length;
		var code:Int = REFUSED_BY_HANDLER;
		if (input.position < end) {
			code = input.readVarUInt();
		}
		input.position = start;
		return code > REFUSED_BY_HANDLER && code <= REFUSED_TOO_LARGE ? code : REFUSED_BY_HANDLER;
	}

	/**
		The op of `ping`, `RPCOps.opOf("ping")`, written out so that the check
		every one-way frame gets for it is against a constant.

		A ping is a one-way frame with this op and no arguments. Every session
		answers one with a pong: a response frame with this op and request id
		0, which answers no call (ids start at 1), so a session of an
		earlier version passes over it.
	**/
	public static inline final PING_OP:Int = 0x165DF089;

	/**
		The op of the hello, `RPCOps.opOf("rpc:hello")`: a response frame
		under request id 0 (which answers no call, so a session from before
		1.0 passes over it, as it does a pong) that each session sends as
		its connection starts:

		```
		varuint version        VERSION
		varuint capabilities   CAPABILITIES
		i32     calls          the fingerprint of the methods its commands call
		i32     answers        the fingerprint of the methods its handler answers
		```

		A later version appends to it and changes none of it, and a reader
		takes what it knows and passes over the rest, as the frame's length
		lets it.
	**/
	public static inline final HELLO_OP:Int = 0xADD0D102;

	/** The protocol a session of this build speaks, in its hello: 1 for 1.0. **/
	public static inline final VERSION:Int = 1;

	/**
		The capabilities a session of this build declares in its hello, a bit
		each: in 1.0, `CAPABILITY_CALL_CONTROL` and `CAPABILITY_CHUNKS`. A release that adds a flag, a
		kind of frame, a kind of runtime value or compression gives it a bit,
		sets the bit in its own hello, and uses the feature towards a peer
		only once that peer's hello has set it; a peer that sent no hello has
		none.
	**/
	public static inline final CAPABILITIES:Int = CAPABILITY_CALL_CONTROL | CAPABILITY_CHUNKS;

	/** Where a frame being read ends when nothing has said: nowhere. **/
	public static inline final NO_FRAME_END:Int = 0x7FFFFFFF;

	/**
		Throws unless `count` more bytes fit in what is left of a frame ending
		at `end`, or `count` values, none of which is shorter than a byte.

		For a length or a count the peer chose, checked before anything is
		allocated for it, so twenty bytes cannot ask for two gigabytes.
	**/
	public static inline function requireRoom(input:ByteArrayInput, end:Int, count:Int):Void {
		if (count < 0 || count > end - input.position) {
			throw "RPC frame names more than it holds";
		}
	}

	/**
		Throws unless `count` values of at least `least` bytes each fit in
		what is left of a frame ending at `end`: an array's count, which the
		peer chose, checked before the array is made. Divided rather than
		multiplied, which a count near 2^31 would overflow.
	**/
	public static inline function requireCount(input:ByteArrayInput, end:Int, count:Int, least:Int):Void {
		if (count < 0 || count > Std.int((end - input.position) / least)) {
			throw "RPC frame names more than it holds";
		}
	}

	/**
		Throws if reading a frame went past its end, into whatever follows it.

		A frame's length says where the next begins, and each is read to its
		end and then skipped to it, but that alone would not stop a frame too
		short for its arguments from taking the rest of them from the next
		one, and the handler running on them. Checked before a handler runs or a
		response resolves: past the end, the frame is not sound.
	**/
	public static inline function requireWithin(input:ByteArrayInput, end:Int):Void {
		if (input.position > end) {
			throw "RPC frame read past its end";
		}
	}

	// -------------------------------------------------- numbers, read whole

	/**
		The compiled lane's readers of a number: checked against what the
		input holds, in every build (a frame is the peer's) and then one
		load natively (`RPCBytes`), where `ByteArrayInput.readInt` was four
		bounds-checked byte reads, and no check at all in `final`.
	**/
	public static inline function readI32(input:ByteArrayInput):Int {
		final data:ByteArrayData = cast input;
		final at:Int = data.position;
		need(data, at, 4);
		data.position = at + 4;
		return RPCBytes.getI32(data, at);
	}

	public static inline function readI64(input:ByteArrayInput):haxe.Int64 {
		final data:ByteArrayData = cast input;
		final at:Int = data.position;
		need(data, at, 8);
		data.position = at + 8;
		return RPCBytes.getI64(data, at);
	}

	public static inline function readF64(input:ByteArrayInput):Float {
		final data:ByteArrayData = cast input;
		final at:Int = data.position;
		need(data, at, 8);
		data.position = at + 8;
		return RPCBytes.getF64(data, at);
	}

	public static inline function readF32(input:ByteArrayInput):Float {
		final data:ByteArrayData = cast input;
		final at:Int = data.position;
		need(data, at, 4);
		data.position = at + 4;
		return RPCBytes.getF32(data, at);
	}

	/** An unsigned 16-bit integer. **/
	public static inline function readU16(input:ByteArrayInput):Int {
		final data:ByteArrayData = cast input;
		final at:Int = data.position;
		need(data, at, 2);
		data.position = at + 2;
		return RPCBytes.getU16(data, at);
	}

	/** A signed 16-bit integer. **/
	public static inline function readI16(input:ByteArrayInput):Int {
		final data:ByteArrayData = cast input;
		final at:Int = data.position;
		need(data, at, 2);
		data.position = at + 2;
		return RPCBytes.getI16(data, at);
	}

	static inline function need(data:ByteArrayData, at:Int, count:Int):Void {
		if (count > data.length - at) {
			throw "ByteArrayInput underflow";
		}
	}
}
