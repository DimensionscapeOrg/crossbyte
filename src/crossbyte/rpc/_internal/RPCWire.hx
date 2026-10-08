package crossbyte.rpc._internal;

import crossbyte.io.ByteArrayInput;

class RPCWire {
	public static inline final FLAG_REQUEST:Int = 0x01;
	public static inline final FLAG_RESPONSE:Int = 0x02;
	public static inline final FLAG_ERROR:Int = 0x04;
	public static inline final FLAG_RUNTIME:Int = 0x08;
	public static inline final MIN_PAYLOAD_LEN:Int = 5;

	/**
		The op of `ping`, `RPCOps.opOf("ping")`, written out so that the check
		every one-way frame gets for it is against a constant.

		A ping is a one-way frame with this op and no arguments. Every session
		answers one with a pong: a response frame with this op and request id
		0, which answers no call, ids start at 1, so a session of an
		earlier version passes over it.
	**/
	public static inline final PING_OP:Int = 0x165DF089;

	/**
		The op of the hello, `RPCOps.opOf("rpc:hello")`: a response frame
		under request id 0, which answers no call, so a session from before
		1.0 passes over it, as it does a pong, that each session sends as
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
		each: none, in 1.0. A later release that adds a flag, a kind of frame,
		a kind of runtime value or compression gives it a bit, sets the bit in
		its own hello, and uses the feature towards a peer only once that
		peer's hello has set it; a peer that sent no hello, from before 1.0,
		has none.
	**/
	public static inline final CAPABILITIES:Int = 0;

	/** Where a frame being read ends when nothing has said: nowhere. **/
	public static inline final NO_FRAME_END:Int = 0x7FFFFFFF;

	/**
		Throws unless `count` more bytes fit in what is left of a frame ending
		at `end`, or `count` values, none of which is shorter than a byte.

		For a length or a count the peer chose, checked before anything is
		allocated for it. The runtime lane made an array of whatever count a
		frame named, and a `Bytes` of whatever length, before reading a byte
		of either, so twenty bytes could ask for two gigabytes in any build.
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

		A frame's length says where the next begins, and each was read to its
		end and then skipped to it, but nothing stopped a frame too short
		for its arguments from taking the rest of them from the next one, and
		the handler then ran on them. Checked before a handler runs or a
		response resolves: past the end, the frame is not sound.
	**/
	public static inline function requireWithin(input:ByteArrayInput, end:Int):Void {
		if (input.position > end) {
			throw "RPC frame read past its end";
		}
	}
}
