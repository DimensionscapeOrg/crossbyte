package crossbyte.net;

import crossbyte.errors.IOError;
import crossbyte.io.ByteArray;
import crossbyte.io.Endian;

/**
	Message boundaries over a transport that does not keep them.

	TCP and a binary WebSocket deliver bytes, not messages: what one `send`
	wrote can arrive as three reads, or share a read with the message after
	it. Anything sending whole values over those -- a serialized object, a
	command, a snapshot -- has to say where each one ends, and every caller
	writing that itself gets the same three things wrong: they scan the buffer
	again on every read, they take the front off it, and they believe the
	length a peer declared before checking it.

	The datagram transports already keep boundaries -- `DatagramSocket`,
	`ReliableDatagramSocket` in its datagram mode, a WebRTC `DataChannel` --
	so none of them need this.

	```haxe
	socket.writeBytes(FrameCodec.encode(payload));

	frames.feed(incoming);
	var message = frames.next();
	while (message != null) {
		handle(message);
		message = frames.next();
	}
	```

	## On the prefix

	Four bytes, big endian, counting the payload only. A variable length
	prefix would save three bytes on small messages, at the cost of a decoder
	that can stall part way through the prefix itself; anything small enough
	for that to matter is better carried on a transport that keeps its own
	boundaries.
**/
class FrameCodec {
	/** The header this writes and expects: one big endian unsigned 32 bit length. **/
	public static inline var HEADER_SIZE:Int = 4;

	/**
		The largest payload accepted by default.

		A peer declares the length before sending it, so the figure is a
		claim, not a measurement. Checked the moment the header is readable
		and refused there, because a reader that waits for the bytes first
		has already agreed to hold as many as the peer asked for -- four
		bytes claiming two gigabytes is otherwise all it takes.
	**/
	public static inline var DEFAULT_MAX_FRAME:Int = 8 * 1024 * 1024;

	/** The largest payload this reader will accept. **/
	public var maxFrameSize(default, null):Int;

	/** Bytes held that are not yet a whole message. **/
	public var buffered(get, never):Int;

	private var __buffer:ByteArray;

	/** How far `__buffer` has been consumed; see `__compact`. **/
	private var __at:Int = 0;

	public function new(maxFrameSize:Int = DEFAULT_MAX_FRAME) {
		if (maxFrameSize <= 0) {
			throw new IOError("FrameCodec needs a positive maxFrameSize");
		}

		this.maxFrameSize = maxFrameSize;
		this.__buffer = new ByteArray();
		this.__buffer.endian = Endian.BIG_ENDIAN;
	}

	/** One payload with its length in front, ready to write to a transport. **/
	public static function encode(payload:ByteArray):ByteArray {
		var length:Int = payload == null ? 0 : payload.length;
		var out = new ByteArray();
		out.endian = Endian.BIG_ENDIAN;
		out.writeUnsignedInt(length);

		if (length > 0) {
			out.writeBytes(payload, 0, length);
		}

		out.position = 0;
		return out;
	}

	/** Takes whatever arrived, whole messages or parts of them. **/
	public function feed(bytes:ByteArray):Void {
		if (bytes == null || bytes.length == 0) {
			return;
		}

		__buffer.position = __buffer.length;
		__buffer.writeBytes(bytes, 0, bytes.length);
	}

	/**
		The next whole message, or null while one is still arriving.

		@throws IOError When a peer declares a payload larger than
		        `maxFrameSize`. The reader cannot continue after that: the
		        stream is no longer at a boundary it can find, so the caller
		        should drop the connection.
	**/
	public function next():Null<ByteArray> {
		var available:Int = __buffer.length - __at;

		if (available < HEADER_SIZE) {
			__compact();
			return null;
		}

		__buffer.position = __at;
		var declared:Int = __buffer.readUnsignedInt();

		// Before anything is held for it. A reader that waits for the bytes
		// first has already agreed to hold however many were asked for.
		if (declared < 0 || declared > maxFrameSize) {
			throw new IOError("A peer declared a " + declared + " byte frame against a limit of " + maxFrameSize + ".");
		}

		if (available - HEADER_SIZE < declared) {
			__compact();
			return null;
		}

		var payload = new ByteArray();

		if (declared > 0) {
			__buffer.position = __at + HEADER_SIZE;
			__buffer.readBytes(payload, 0, declared);
			payload.position = 0;
		}

		__at += HEADER_SIZE + declared;
		__compact();
		return payload;
	}

	/** Forgets everything part-read, for a connection starting over. **/
	public function reset():Void {
		__buffer = new ByteArray();
		__buffer.endian = Endian.BIG_ENDIAN;
		__at = 0;
	}

	private function get_buffered():Int {
		return __buffer.length - __at;
	}

	/**
		Drops the consumed front of the buffer.

		A cursor rather than taking bytes off the front, which is a pass over
		everything still buffered for each message that leaves. Compacted
		once the consumed part is the larger half, so it amortises to nothing.
	**/
	private function __compact():Void {
		if (__at == 0) {
			return;
		}

		if (__at >= __buffer.length) {
			__buffer.length = 0;
			__at = 0;
			return;
		}

		if (__at * 2 < __buffer.length) {
			return;
		}

		var keep = new ByteArray();
		keep.endian = Endian.BIG_ENDIAN;
		__buffer.position = __at;
		__buffer.readBytes(keep, 0, __buffer.length - __at);
		keep.position = keep.length;
		__buffer = keep;
		__at = 0;
	}
}
