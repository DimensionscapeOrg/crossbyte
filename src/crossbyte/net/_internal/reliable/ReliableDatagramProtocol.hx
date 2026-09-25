package crossbyte.net._internal.reliable;

import crossbyte.Seq32;
import crossbyte.io.ByteArray;
import haxe.io.Bytes;

enum abstract ReliableDatagramFrameType(Int) from Int to Int {
	var CONNECT = 0;
	var HANDSHAKE = 1;
	var PACKET = 2;
	var ACK = 3;
	var FIN = 4;

	/** Sent once, never acknowledged or resent. **/
	var UNRELIABLE = 5;

	/**
		Unreliable, and dropped by the receiver when something newer has
		arrived on the same channel. The sequence field carries the channel in
		its top byte and a 24-bit counter below it; see `sequencedField`.
	**/
	var SEQUENCED = 6;
}

final class ReliableDatagramFrame {
	public var resend(default, null):Bool;
	public var sequence(default, null):Seq32;
	public var type(default, null):ReliableDatagramFrameType;
	public var payload(default, null):ByteArray;
	public var ack(default, null):Null<Seq32>;

	/**
		Whether more of this message follows in the next PACKET. Set on every
		fragment of a reliable message but the last.
	**/
	public var more(default, null):Bool;

	public function new(type:ReliableDatagramFrameType, sequence:Seq32, payload:ByteArray, resend:Bool, ?ack:Seq32, more:Bool = false) {
		this.type = type;
		this.sequence = sequence;
		this.payload = payload;
		this.resend = resend;
		this.ack = ack;
		this.more = more;
	}
}

/**
	The frame format: a two byte magic, a byte of type and flags, a four byte
	sequence, an optional four byte acknowledgement, then the payload. All of
	it big-endian.

	The flags byte holds the type in its low three bits, and above them:
	`MORE_MASK` (0x20), `RESEND_MASK` (0x40) and `ACK_PRESENT_MASK` (0x80).
	A decoder that meets a type it does not know drops the frame, which is
	what lets a newer peer send types an older one has never heard of.
**/
final class ReliableDatagramProtocol {
	public static inline var HEADER_SIZE:Int = 7;
	public static inline var ACK_FIELD_SIZE:Int = 4;
	public static inline var MAGIC:Int = 0xCBDA;
	public static inline var MAX_PAYLOAD_SIZE:Int = 1200;

	/** The largest frame there is: header, acknowledgement and a full payload. **/
	public static inline var MAX_FRAME_SIZE:Int = HEADER_SIZE + ACK_FIELD_SIZE + MAX_PAYLOAD_SIZE;

	/** Channels a SEQUENCED frame can name, and the counter's range within one. **/
	public static inline var SEQUENCED_COUNTER_MASK:Int = 0xFFFFFF;

	@:noCompletion private static inline var ACK_PRESENT_MASK:Int = 0x80;
	@:noCompletion private static inline var RESEND_MASK:Int = 0x40;
	@:noCompletion private static inline var MORE_MASK:Int = 0x20;
	@:noCompletion private static inline var TYPE_MASK:Int = 0x07;

	/**
		A SEQUENCED frame's sequence field: the channel in the top byte and the
		counter, which wraps at 2^24, below it. One field rather than a byte of
		its own, so the frame is the same size as any other.
	**/
	public static inline function sequencedField(channel:Int, counter:Int):Seq32 {
		return (channel << 24) | (counter & SEQUENCED_COUNTER_MASK);
	}

	public static inline function channelOf(field:Seq32):Int {
		return ((field : Int) >>> 24) & 0xFF;
	}

	public static inline function counterOf(field:Seq32):Int {
		return (field : Int) & SEQUENCED_COUNTER_MASK;
	}

	/**
		Whether counter `a` is newer than `b` on a 24-bit wrapping scale: it is
		ahead by less than half the range. The same rule `Seq32` applies at 32
		bits, so a channel keeps its order across the wrap.
	**/
	public static inline function counterIsNewer(a:Int, b:Int):Bool {
		var ahead:Int = (a - b) & SEQUENCED_COUNTER_MASK;
		return ahead != 0 && ahead < 0x800000;
	}

	public static function decode(packet:ByteArray):ReliableDatagramFrame {
		if (packet == null) {
			return null;
		}

		// Read off the storage rather than through the stream API: the header
		// is a handful of fixed offsets, and a datagram is decoded for every
		// packet a session receives.
		var length:Int = packet.length;
		if (length < HEADER_SIZE) {
			return null;
		}

		var bytes:Bytes = packet;
		if (((bytes.get(0) << 8) | bytes.get(1)) != MAGIC) {
			return null;
		}

		var meta:Int = bytes.get(2);
		var typeValue:Int = meta & TYPE_MASK;
		if (typeValue > (SEQUENCED : Int)) {
			return null;
		}

		var ackPresent:Bool = (meta & ACK_PRESENT_MASK) != 0;
		var start:Int = HEADER_SIZE;
		if (ackPresent) {
			if (length < HEADER_SIZE + ACK_FIELD_SIZE) {
				return null;
			}
			start += ACK_FIELD_SIZE;
		}

		var sequence:Seq32 = __getInt(bytes, 3);
		var ack:Null<Seq32> = ackPresent ? __getInt(bytes, HEADER_SIZE) : null;

		var payloadLength:Int = length - start;
		var payload:ByteArray = new ByteArray();
		if (payloadLength > 0) {
			payload.length = payloadLength;
			(payload : Bytes).blit(0, bytes, start, payloadLength);
		}
		payload.position = 0;

		return new ReliableDatagramFrame(cast typeValue, sequence, payload, (meta & RESEND_MASK) != 0, ack, (meta & MORE_MASK) != 0);
	}

	/**
		A frame in a buffer of its own. `encodeInto` is the one to use per
		packet; this is kept for callers that want the frame to keep.
	**/
	public static function encode(type:ReliableDatagramFrameType, sequence:Seq32, ?payload:ByteArray, resend:Bool = false, ?ack:Seq32,
			more:Bool = false):ByteArray {
		var payloadLength:Int = payload != null ? payload.length : 0;
		var frame:ByteArray = new ByteArray();
		frame.length = HEADER_SIZE + ACK_FIELD_SIZE + payloadLength;
		var written:Int = encodeInto(frame, type, sequence, payload, 0, payloadLength, resend, ack, more);
		frame.length = written;
		frame.position = 0;
		return frame;
	}

	/**
		Writes a frame into `out` from its first byte, and says how many bytes
		it took. Nothing is allocated: `out` is a buffer the caller reuses,
		`MAX_FRAME_SIZE` long, which is safe because a send has finished with
		its bytes before it returns -- natively it is a system call, and on
		Node `DatagramSocket.send` copies them first.

		@param payload Whatever is to be carried, from `offset` for `length`
		       bytes; it must fit `MAX_PAYLOAD_SIZE`, which the socket checks
		       before it gets here.
	**/
	public static function encodeInto(out:ByteArray, type:ReliableDatagramFrameType, sequence:Seq32, payload:ByteArray, offset:Int, length:Int,
			resend:Bool, ack:Null<Seq32>, more:Bool):Int {
		var bytes:Bytes = out;
		var meta:Int = (type : Int);
		if (resend) {
			meta |= RESEND_MASK;
		}
		if (more) {
			meta |= MORE_MASK;
		}
		if (ack != null) {
			meta |= ACK_PRESENT_MASK;
		}

		bytes.set(0, MAGIC >> 8);
		bytes.set(1, MAGIC & 0xFF);
		bytes.set(2, meta);
		__setInt(bytes, 3, sequence);

		var at:Int = HEADER_SIZE;
		if (ack != null) {
			__setInt(bytes, at, ack);
			at += ACK_FIELD_SIZE;
		}

		if (payload != null && length > 0) {
			bytes.blit(at, payload, offset, length);
			at += length;
		}
		return at;
	}

	private static inline function __setInt(bytes:Bytes, at:Int, value:Int):Void {
		bytes.set(at, value >>> 24);
		bytes.set(at + 1, (value >>> 16) & 0xFF);
		bytes.set(at + 2, (value >>> 8) & 0xFF);
		bytes.set(at + 3, value & 0xFF);
	}

	// Assembled with `|`, which leaves a 32-bit signed Int on every target:
	// the top byte shifted into the sign is the wrap Seq32 already expects.
	private static inline function __getInt(bytes:Bytes, at:Int):Int {
		return (bytes.get(at) << 24) | (bytes.get(at + 1) << 16) | (bytes.get(at + 2) << 8) | bytes.get(at + 3);
	}
}
