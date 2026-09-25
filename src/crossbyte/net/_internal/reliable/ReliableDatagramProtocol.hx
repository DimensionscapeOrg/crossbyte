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

	/**
		On a CONNECT or a HANDSHAKE: the sender takes bundles, several frames
		to a datagram. Every CONNECT and HANDSHAKE this build sends says so.
	**/
	public var bundles(default, null):Bool;

	public function new(type:ReliableDatagramFrameType, sequence:Seq32, payload:ByteArray, resend:Bool, ?ack:Seq32, more:Bool = false,
			bundles:Bool = false) {
		this.type = type;
		this.sequence = sequence;
		this.payload = payload;
		this.resend = resend;
		this.ack = ack;
		this.more = more;
		this.bundles = bundles;
	}
}

/**
	The frame format: a two byte magic, a byte of type and flags, a four byte
	sequence, an optional four byte acknowledgement, then the payload. All of
	it big-endian.

	The flags byte holds the type in its low three bits, and above them:
	`BUNDLES_MASK` (0x10), `MORE_MASK` (0x20), `RESEND_MASK` (0x40) and
	`ACK_PRESENT_MASK` (0x80). A decoder that meets a type it does not know
	drops the frame, which is what lets a newer peer send types an older one
	has never heard of; and one that meets a flag it does not know ignores
	it, which is what lets a CONNECT say the sender takes bundles.

	A bundle is several frames in one datagram: `BUNDLE_MAGIC`, then each
	frame preceded by its length in two bytes. A session sends one only to a
	peer whose CONNECT or HANDSHAKE said it takes them, since an older peer
	would drop the whole datagram as a frame with the wrong magic.
**/
final class ReliableDatagramProtocol {
	public static inline var HEADER_SIZE:Int = 7;
	public static inline var ACK_FIELD_SIZE:Int = 4;
	public static inline var MAGIC:Int = 0xCBDA;
	public static inline var MAX_PAYLOAD_SIZE:Int = 1200;

	/** The largest frame there is: header, acknowledgement and a full payload. **/
	public static inline var MAX_FRAME_SIZE:Int = HEADER_SIZE + ACK_FIELD_SIZE + MAX_PAYLOAD_SIZE;

	/** The first two bytes of a datagram that carries several frames. **/
	public static inline var BUNDLE_MAGIC:Int = 0xCBDB;

	/** What a bundle adds: its magic once, and a length before each frame. **/
	public static inline var BUNDLE_HEADER_SIZE:Int = 2;

	public static inline var BUNDLE_ENTRY_SIZE:Int = 2;

	/**
		The most a bundle may be: the largest single frame. So bundling never
		sends a datagram larger than one frame already could, and a path that
		carries frames carries bundles.
	**/
	public static inline var BUNDLE_LIMIT:Int = MAX_FRAME_SIZE;

	/** Channels a SEQUENCED frame can name, and the counter's range within one. **/
	public static inline var SEQUENCED_COUNTER_MASK:Int = 0xFFFFFF;

	@:noCompletion private static inline var ACK_PRESENT_MASK:Int = 0x80;
	@:noCompletion private static inline var RESEND_MASK:Int = 0x40;
	@:noCompletion private static inline var MORE_MASK:Int = 0x20;
	@:noCompletion private static inline var BUNDLES_MASK:Int = 0x10;
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
		return decodeRange(packet, 0, packet.length);
	}

	/**
		The frame in `length` bytes of `packet` from `from`: a whole datagram,
		or one entry of a bundle. Null for anything that is not a frame this
		build knows.
	**/
	public static function decodeRange(packet:ByteArray, from:Int, length:Int):ReliableDatagramFrame {
		// Read off the storage rather than through the stream API: the header
		// is a handful of fixed offsets, and a datagram is decoded for every
		// packet a session receives.
		if (length < HEADER_SIZE) {
			return null;
		}

		var bytes:Bytes = packet;
		if (((bytes.get(from) << 8) | bytes.get(from + 1)) != MAGIC) {
			return null;
		}

		var meta:Int = bytes.get(from + 2);
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

		var sequence:Seq32 = __getInt(bytes, from + 3);
		var ack:Null<Seq32> = ackPresent ? __getInt(bytes, from + HEADER_SIZE) : null;

		var payloadLength:Int = length - start;
		var payload:ByteArray = new ByteArray();
		if (payloadLength > 0) {
			payload.length = payloadLength;
			(payload : Bytes).blit(0, bytes, from + start, payloadLength);
		}
		payload.position = 0;

		return new ReliableDatagramFrame(cast typeValue, sequence, payload, (meta & RESEND_MASK) != 0, ack, (meta & MORE_MASK) != 0,
			(meta & BUNDLES_MASK) != 0);
	}

	/** Whether a datagram is a bundle rather than a frame. **/
	public static function isBundle(packet:ByteArray):Bool {
		if (packet == null || packet.length < BUNDLE_HEADER_SIZE) {
			return false;
		}
		var bytes:Bytes = packet;
		return ((bytes.get(0) << 8) | bytes.get(1)) == BUNDLE_MAGIC;
	}

	/**
		The length of the bundle entry at `at`, whose frame begins
		`BUNDLE_ENTRY_SIZE` bytes later; or -1 where there is none, because
		the bundle has ended or the length runs past it. Read in a loop from
		`BUNDLE_HEADER_SIZE`, the caller keeping what came before a bad entry
		and stopping there.
	**/
	public static function bundleEntryLength(packet:ByteArray, at:Int):Int {
		var total:Int = packet.length;
		if (at < 0 || at > total - BUNDLE_ENTRY_SIZE) {
			return -1;
		}
		var bytes:Bytes = packet;
		var length:Int = (bytes.get(at) << 8) | bytes.get(at + 1);
		return length > total - at - BUNDLE_ENTRY_SIZE ? -1 : length;
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
		Writes a frame into `out` at `start`, and says how many bytes it took.
		Nothing is allocated: `out` is a buffer the caller reuses -- a
		session's pending bundle, where each frame is written in place -- which
		is safe because a send has finished with its bytes before it returns:
		natively it is a system call, and on Node `DatagramSocket.send` copies
		them first.

		A CONNECT or HANDSHAKE always says this build takes bundles.

		@param payload Whatever is to be carried, from `offset` for `length`
		       bytes; it must fit `MAX_PAYLOAD_SIZE`, which the socket checks
		       before it gets here.
	**/
	public static function encodeInto(out:ByteArray, type:ReliableDatagramFrameType, sequence:Seq32, payload:ByteArray, offset:Int, length:Int,
			resend:Bool, ack:Null<Seq32>, more:Bool, start:Int = 0):Int {
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
		if (type == CONNECT || type == HANDSHAKE) {
			meta |= BUNDLES_MASK;
		}

		bytes.set(start, MAGIC >> 8);
		bytes.set(start + 1, MAGIC & 0xFF);
		bytes.set(start + 2, meta);
		__setInt(bytes, start + 3, sequence);

		var at:Int = start + HEADER_SIZE;
		if (ack != null) {
			__setInt(bytes, at, ack);
			at += ACK_FIELD_SIZE;
		}

		if (payload != null && length > 0) {
			bytes.blit(at, payload, offset, length);
			at += length;
		}
		return at - start;
	}

	/** How many bytes `encodeInto` will write for a frame like this. **/
	public static inline function frameSize(length:Int, hasAck:Bool):Int {
		return HEADER_SIZE + (hasAck ? ACK_FIELD_SIZE : 0) + length;
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
