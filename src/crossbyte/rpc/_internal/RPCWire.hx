package crossbyte.rpc._internal;

import crossbyte.io.ByteArrayInput;

class RPCWire {
	public static inline final FLAG_REQUEST:Int = 0x01;
	public static inline final FLAG_RESPONSE:Int = 0x02;
	public static inline final FLAG_ERROR:Int = 0x04;
	public static inline final FLAG_RUNTIME:Int = 0x08;
	public static inline final MIN_PAYLOAD_LEN:Int = 5;

	/** Where a frame being read ends when nothing has said: nowhere. **/
	public static inline final NO_FRAME_END:Int = 0x7FFFFFFF;

	/**
		Throws unless `count` more bytes fit in what is left of a frame ending
		at `end` -- or `count` values, none of which is shorter than a byte.

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
		Throws if reading a frame went past its end, into whatever follows it.

		A frame's length says where the next begins, and each was read to its
		end and then skipped to it -- but nothing stopped a frame too short
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
