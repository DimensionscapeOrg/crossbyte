package crossbyte.net.rtc._internal.sctp;

import crossbyte.io.ByteArray;
import crossbyte.io.Endian;

/**
	An SCTP packet: a twelve byte common header and a list of chunks.

	SCTP is what carries a WebRTC data channel, inside the DTLS session ICE
	found a path for. It is a full transport in its own right -- association
	setup, ordered and unordered delivery, retransmission, several streams over
	one association -- and this is the bottom of it: the framing everything else
	is written in.

	```
	 0                   1                   2                   3
	 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
	+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
	|     Source Port Number        |     Destination Port Number   |
	+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
	|                      Verification Tag                         |
	+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
	|                           Checksum                            |
	+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
	```

	## Two details that decide whether anything interoperates

	The checksum is CRC-32C over the whole packet **with the checksum field set
	to zero**, which is the same shape STUN's integrity uses and the same
	mistake to make: computing it over the packet as it stands produces a value
	that verifies against itself and against nobody.

	It is then written least significant byte first, while every other field in
	the header is big endian. That is not a misreading -- RFC 4960's reference
	implementation byte-swaps the result before storing it, and every
	implementation follows suit. It looks like a bug in the code until it is
	the only thing that talks to anything.

	## Chunk padding

	A chunk's length counts its four byte header and its value and *not* the
	padding that follows, but the next chunk still begins on a four byte
	boundary. Exactly the rule STUN attributes follow, and exactly the one a
	hand-written parser gets wrong in the same way.
**/
class SctpPacket {
	public static inline var HEADER_LENGTH:Int = 12;

	// The chunk types this framing needs to name. The rest arrive as numbers.
	public static inline var CHUNK_DATA:Int = 0;

	public static inline var CHUNK_INIT:Int = 1;
	public static inline var CHUNK_INIT_ACK:Int = 2;
	public static inline var CHUNK_SACK:Int = 3;
	public static inline var CHUNK_HEARTBEAT:Int = 4;
	public static inline var CHUNK_HEARTBEAT_ACK:Int = 5;
	public static inline var CHUNK_ABORT:Int = 6;
	public static inline var CHUNK_SHUTDOWN:Int = 7;
	public static inline var CHUNK_SHUTDOWN_ACK:Int = 8;
	public static inline var CHUNK_ERROR:Int = 9;
	public static inline var CHUNK_COOKIE_ECHO:Int = 10;
	public static inline var CHUNK_COOKIE_ACK:Int = 11;
	public static inline var CHUNK_SHUTDOWN_COMPLETE:Int = 14;

	/** Sender's port. Both ends of a data channel use 5000 by convention. **/
	public var sourcePort(default, null):Int;

	public var destinationPort(default, null):Int;

	/**
		The tag the peer gave out in its INIT, echoed on everything sent to it.

		It is what stops a packet from an old association, or from somebody who
		guessed the ports, being taken for part of this one. Zero only on an
		INIT, which is the one packet sent before either side has a tag.
	**/
	public var verificationTag(default, null):Int;

	public var chunks(default, null):Array<SctpChunk>;

	public function new(sourcePort:Int, destinationPort:Int, verificationTag:Int, ?chunks:Array<SctpChunk>) {
		this.sourcePort = sourcePort;
		this.destinationPort = destinationPort;
		this.verificationTag = verificationTag;
		this.chunks = chunks != null ? chunks : [];
	}

	/**
		Serialises the packet and fills in its checksum.

		The field is zeroed, the CRC taken over everything, and only then is the
		result written back over the zeroes -- which is the only order that
		produces a checksum a peer computes the same way.
	**/
	public function encode():ByteArray {
		var out = new ByteArray();
		out.endian = Endian.BIG_ENDIAN;
		out.writeShort(sourcePort);
		out.writeShort(destinationPort);
		out.writeInt(verificationTag);
		out.writeInt(0);

		for (chunk in chunks) {
			out.writeByte(chunk.type);
			out.writeByte(chunk.flags);
			out.writeShort(SctpChunk.HEADER_LENGTH + chunk.value.length);

			if (chunk.value.length > 0) {
				out.writeBytes(chunk.value, 0, chunk.value.length);
			}

			var padding:Int = (4 - (chunk.value.length % 4)) % 4;

			for (_ in 0...padding) {
				out.writeByte(0);
			}
		}

		writeChecksum(out);
		out.position = 0;
		return out;
	}

	/**
		Computes and stores the checksum of an already serialised packet.

		Separate from `encode` because a packet altered in place -- which is how
		the association layer stamps a verification tag it did not have when it
		built the packet -- has to be checksummed again afterwards.
	**/
	public static function writeChecksum(packet:ByteArray):Void {
		if (packet == null || packet.length < HEADER_LENGTH) {
			return;
		}

		var position:Int = packet.position;

		// Zeroed first. The checksum covers the field it will occupy, so the
		// value computed over anything else is a value only this code agrees
		// with.
		packet.endian = Endian.BIG_ENDIAN;
		packet.position = 8;
		packet.writeInt(0);

		var crc:Int = Crc32c.of(packet, 0, packet.length);

		// Least significant byte first, alone among the header's fields. RFC
		// 4960's reference implementation byte-swaps the CRC before storing it,
		// and everything that speaks SCTP does the same.
		packet.position = 8;
		packet.writeByte(crc & 0xFF);
		packet.writeByte((crc >>> 8) & 0xFF);
		packet.writeByte((crc >>> 16) & 0xFF);
		packet.writeByte((crc >>> 24) & 0xFF);

		packet.position = position;
	}

	/**
		Whether a packet's checksum is the one its contents produce.

		Checked against the bytes as they arrived, with the field zeroed in a
		copy rather than in place -- a receiver that edited the packet to verify
		it would hand the layer above something it had already altered.
	**/
	public static function verifyChecksum(packet:ByteArray):Bool {
		if (packet == null || packet.length < HEADER_LENGTH) {
			return false;
		}

		var position:Int = packet.position;
		packet.position = 8;

		var found:Int = packet.readUnsignedByte()
			| (packet.readUnsignedByte() << 8)
			| (packet.readUnsignedByte() << 16)
			| (packet.readUnsignedByte() << 24);

		var copy = new ByteArray();
		packet.position = 0;
		copy.writeBytes(packet, 0, packet.length);
		copy.endian = Endian.BIG_ENDIAN;
		copy.position = 8;
		copy.writeInt(0);

		var expected:Int = Crc32c.of(copy, 0, copy.length);
		packet.position = position;

		return expected == found;
	}

	/**
		Reads a packet, or null if the bytes are not one.

		Null rather than an exception, the same as `StunMessage.decode`: this
		parses whatever came out of a DTLS record, and the layer above decides
		what to do about traffic it did not expect.

		@param verify Whether to check the checksum. A caller replaying a
		captured packet, or testing the parser, may not want to.
	**/
	public static function decode(bytes:ByteArray, verify:Bool = true):Null<SctpPacket> {
		if (bytes == null || bytes.length < HEADER_LENGTH) {
			return null;
		}

		if (verify && !verifyChecksum(bytes)) {
			return null;
		}

		bytes.endian = Endian.BIG_ENDIAN;
		bytes.position = 0;

		var sourcePort:Int = bytes.readUnsignedShort();
		var destinationPort:Int = bytes.readUnsignedShort();
		var verificationTag:Int = bytes.readInt();
		bytes.position = HEADER_LENGTH;

		var chunks:Array<SctpChunk> = [];
		var offset:Int = HEADER_LENGTH;

		while (offset + SctpChunk.HEADER_LENGTH <= bytes.length) {
			bytes.position = offset;

			var type:Int = bytes.readUnsignedByte();
			var flags:Int = bytes.readUnsignedByte();
			var length:Int = bytes.readUnsignedShort();

			// A length that does not cover its own header, or claims more than
			// the packet holds, ends the walk. What parsed so far is still
			// good; guessing past it is not.
			if (length < SctpChunk.HEADER_LENGTH || offset + length > bytes.length) {
				break;
			}

			var valueLength:Int = length - SctpChunk.HEADER_LENGTH;
			var value = new ByteArray();

			if (valueLength > 0) {
				bytes.readBytes(value, 0, valueLength);
			}

			value.position = 0;
			chunks.push(new SctpChunk(type, flags, value));

			// The padding is not counted in the length but the next chunk still
			// starts on a four byte boundary.
			offset += length + ((4 - (length % 4)) % 4);
		}

		return new SctpPacket(sourcePort, destinationPort, verificationTag, chunks);
	}

	/** The first chunk of `type`, or null. **/
	public function chunk(type:Int):Null<SctpChunk> {
		for (candidate in chunks) {
			if (candidate.type == type) {
				return candidate;
			}
		}

		return null;
	}

	public function toString():String {
		var names:Array<String> = [];

		for (candidate in chunks) {
			names.push(Std.string(candidate.type));
		}

		return "SctpPacket(" + sourcePort + " -> " + destinationPort + ", tag " + verificationTag + ", chunks [" + names.join(", ") + "])";
	}
}

/** One chunk: a type, eight bits of flags, and a value. **/
class SctpChunk {
	public static inline var HEADER_LENGTH:Int = 4;

	public var type(default, null):Int;
	public var flags(default, null):Int;
	public var value(default, null):ByteArray;

	public function new(type:Int, flags:Int, ?value:ByteArray) {
		this.type = type;
		this.flags = flags;
		this.value = value != null ? value : new ByteArray();
	}

	/**
		What an unrecognised chunk's top two type bits say to do with it.

		RFC 4960 puts the instructions for a chunk nobody understands in the
		type itself, so a receiver can act correctly on a chunk from a later
		revision of the protocol than it was written against. Two of the four
		cases mean carry on, which is what makes SCTP extensible at all.
	**/
	public var unknownAction(get, never):SctpUnknownAction;

	private function get_unknownAction():SctpUnknownAction {
		return switch ((type >> 6) & 0x03) {
			case 0: STOP;
			case 1: STOP_AND_REPORT;
			case 2: SKIP;
			default: SKIP_AND_REPORT;
		}
	}
}

/** RFC 4960 section 3.2, the top two bits of a chunk type. **/
enum abstract SctpUnknownAction(Int) {
	/** Stop processing and discard the rest of the packet. **/
	var STOP = 0;

	/** Stop, discard, and report the unrecognised type. **/
	var STOP_AND_REPORT = 1;

	/** Skip this chunk and carry on with the next. **/
	var SKIP = 2;

	/** Skip it, carry on, and report it. **/
	var SKIP_AND_REPORT = 3;
}
