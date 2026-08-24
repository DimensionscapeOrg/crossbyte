package crossbyte._internal.http.h2;

import haxe.io.Bytes;
import haxe.io.BytesBuffer;

/**
 * One HTTP/2 frame.
 *
 * The 9-octet header is length (24 bits), type (8), flags (8), then a reserved
 * bit and a 31-bit stream identifier. `payload` excludes that header.
 */
class H2Frame {
	/** Every frame carries a 9-octet header (§4.1). */
	public static inline var HEADER_SIZE:Int = 9;

	/** The smallest SETTINGS_MAX_FRAME_SIZE a peer may advertise (§6.5.2). */
	public static inline var MIN_MAX_FRAME_SIZE:Int = 16384;

	/** The largest, which is also the widest a 24-bit length can express. */
	public static inline var MAX_MAX_FRAME_SIZE:Int = 16777215;

	public final type:H2FrameType;
	public final flags:Int;
	public final streamId:Int;
	public final payload:Bytes;

	public function new(type:H2FrameType, flags:Int, streamId:Int, payload:Bytes) {
		this.type = type;
		this.flags = flags;
		this.streamId = streamId;
		this.payload = payload;
	}

	public inline function has(flag:Int):Bool {
		return (flags & flag) != 0;
	}

	/**
	 * Writes the 9-octet header for a payload of `length` bytes.
	 *
	 * The stream identifier is masked to 31 bits: §4.1 reserves the high bit
	 * and requires senders to leave it clear, and masking rather than
	 * rejecting keeps a caller from having to pre-validate an id it derived
	 * arithmetically.
	 */
	public static function writeHeader(out:BytesBuffer, length:Int, type:H2FrameType, flags:Int, streamId:Int):Void {
		out.addByte((length >> 16) & 0xff);
		out.addByte((length >> 8) & 0xff);
		out.addByte(length & 0xff);
		out.addByte((cast type : Int) & 0xff);
		out.addByte(flags & 0xff);
		out.addByte((streamId >> 24) & 0x7f);
		out.addByte((streamId >> 16) & 0xff);
		out.addByte((streamId >> 8) & 0xff);
		out.addByte(streamId & 0xff);
	}

	public function write(out:BytesBuffer):Void {
		var length:Int = payload == null ? 0 : payload.length;
		writeHeader(out, length, type, flags, streamId);
		if (length > 0) {
			out.addBytes(payload, 0, length);
		}
	}

	public function toBytes():Bytes {
		var out:BytesBuffer = new BytesBuffer();
		write(out);
		return out.getBytes();
	}

	/** Payload length declared by a header sitting at `offset`. */
	public static inline function lengthOf(header:Bytes, offset:Int = 0):Int {
		return (header.get(offset) << 16) | (header.get(offset + 1) << 8) | header.get(offset + 2);
	}

	/**
	 * Parses a frame whose 9-octet header starts at `offset` and whose payload
	 * follows it. The caller must already have `HEADER_SIZE + lengthOf(...)`
	 * bytes available.
	 */
	public static function read(source:Bytes, offset:Int = 0):H2Frame {
		var length:Int = lengthOf(source, offset);
		var type:Int = source.get(offset + 3);
		var flags:Int = source.get(offset + 4);

		// The reserved bit is masked off rather than checked: §4.1 says a
		// receiver must ignore it, and some senders do set it.
		var streamId:Int = ((source.get(offset + 5) & 0x7f) << 24)
			| (source.get(offset + 6) << 16)
			| (source.get(offset + 7) << 8)
			| source.get(offset + 8);

		var payload:Bytes = length == 0 ? Bytes.alloc(0) : source.sub(offset + HEADER_SIZE, length);
		return new H2Frame(type, flags, streamId, payload);
	}

	/**
	 * Strips the padding from a DATA or HEADERS payload (§6.1, §6.2).
	 *
	 * The first octet is the pad length, and it is counted against the frame
	 * size but not against flow control's view of the content. A pad length
	 * that meets or exceeds the remaining payload is a connection error --
	 * §6.1 is explicit that it must not be treated as an empty frame, because
	 * the arithmetic would otherwise underflow into a huge length.
	 */
	public static function stripPadding(payload:Bytes, streamId:Int):Bytes {
		if (payload.length < 1) {
			throw new H2ConnectionError(H2ErrorCode.PROTOCOL_ERROR, "Padded frame has no pad length octet");
		}

		var padLength:Int = payload.get(0);
		var contentLength:Int = payload.length - 1 - padLength;

		if (contentLength < 0) {
			throw new H2ConnectionError(H2ErrorCode.PROTOCOL_ERROR, 'Pad length $padLength exceeds the payload of stream $streamId');
		}

		return payload.sub(1, contentLength);
	}

	public function toString():String {
		var length:Int = payload == null ? 0 : payload.length;
		return '$type(stream=$streamId, flags=0x${StringTools.hex(flags, 2)}, length=$length)';
	}
}
