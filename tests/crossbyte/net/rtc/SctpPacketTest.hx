package crossbyte.net.rtc;

import crossbyte.io.ByteArray;
import crossbyte.io.Endian;
import crossbyte.net.rtc._internal.sctp.Crc32c;
import crossbyte.net.rtc._internal.sctp.SctpPacket;
import crossbyte.net.rtc._internal.sctp.SctpPacket.SctpChunk;
import utest.Assert;

/**
	The framing a WebRTC data channel is written in.

	Bytes in and bytes out, so this runs on every target -- including the
	browser, where SCTP itself lives inside `RTCPeerConnection` and this code
	never will. That is the same arrangement the STUN codec has, and it is worth
	having for the same reason: the parser is the part most likely to be wrong
	and the part least in need of a socket to prove it.
**/
class SctpPacketTest extends utest.Test {
	/**
		The check value every CRC-32C implementation is measured against.

		`haxe.crypto.Crc32` is a different polynomial and disagrees on every
		input, so a checksum computed with it is one no SCTP implementation
		anywhere accepts. 0xE3069283 over "123456789" is the catalogue's value
		for Castagnoli, and the rest are RFC 3720's iSCSI vectors.
	**/
	public function testTheChecksumMatchesThePublishedVectors():Void {
		Assert.equals("E3069283", hex(Crc32c.ofString("123456789")));
		Assert.equals("00000000", hex(Crc32c.ofString("")));
		Assert.equals("C1D04330", hex(Crc32c.ofString("a")));

		Assert.equals("8A9136AA", hex(Crc32c.of(repeated(0x00, 32))));
		Assert.equals("62A8AB43", hex(Crc32c.of(repeated(0xFF, 32))));
		Assert.equals("46DD794E", hex(Crc32c.of(counting(32))));
	}

	/**
		The fast path agrees with the definition at every boundary.

		The implementation reads eight bytes a word pair at a time and finishes
		the tail a byte at a time, and the published vectors never exercise an
		odd offset -- their lengths land where they land. A slicing table built
		in the wrong order, a word read off by one, or a tail loop that starts a
		byte early would all pass the aligned vectors and corrupt some real
		packet later. So every offset up to eight and every length across two
		word boundaries is compared against the one-bit-at-a-time definition,
		computed here from the polynomial with no tables to be wrong in.
	**/
	public function testTheFastPathAgreesWithTheDefinitionAtEveryBoundary():Void {
		var bytes = counting(64);

		for (offset in 0...9) {
			for (length in 0...18) {
				Assert.equals(reference(bytes, offset, length), Crc32c.of(bytes, offset, length),
					"disagrees at offset " + offset + " length " + length);
			}
		}
	}

	/** Castagnoli, one bit at a time, straight from the polynomial. **/
	static function reference(bytes:ByteArray, offset:Int, length:Int):Int {
		var crc = 0xFFFFFFFF;

		for (i in offset...offset + length) {
			crc = crc ^ bytes[i];

			for (_ in 0...8) {
				crc = (crc & 1) != 0 ? (crc >>> 1) ^ 0x82F63B78 : crc >>> 1;
			}
		}

		return crc ^ 0xFFFFFFFF;
	}

	/**
		It is not the CRC-32 already in the standard library.

		Worth asserting rather than assuming: the two are one letter apart in
		every document that mentions them, and reaching for the wrong one
		produces a checksum that is perfectly self-consistent.
	**/
	public function testItIsNotTheOtherCrc32():Void {
		var subject = haxe.io.Bytes.ofString("123456789");

		Assert.notEquals(haxe.crypto.Crc32.make(subject), Crc32c.ofString("123456789"),
			"CRC-32C produced the same value as CRC-32, which means one of them is not what it claims");
	}

	public function testAPacketSurvivesTheRoundTrip():Void {
		var payload = new ByteArray();
		payload.writeUTFBytes("chunk value");
		payload.position = 0;

		var packet = new SctpPacket(5000, 5000, 0x12345678, [
			new SctpChunk(SctpPacket.CHUNK_DATA, 0x03, payload),
			new SctpChunk(SctpPacket.CHUNK_COOKIE_ACK, 0)
		]);

		var decoded = SctpPacket.decode(packet.encode());

		Assert.notNull(decoded, "a packet this code encoded would not decode");

		if (decoded == null) {
			// utest carries on past a failed assertion, so without this the
			// lines below report a crash where the failure above already said
			// exactly what went wrong.
			return;
		}

		Assert.equals(5000, decoded.sourcePort);
		Assert.equals(5000, decoded.destinationPort);
		Assert.equals(0x12345678, decoded.verificationTag);
		Assert.equals(2, decoded.chunks.length);

		Assert.equals(SctpPacket.CHUNK_DATA, decoded.chunks[0].type);
		Assert.equals(0x03, decoded.chunks[0].flags);
		decoded.chunks[0].value.position = 0;
		Assert.equals("chunk value", decoded.chunks[0].value.readUTFBytes(decoded.chunks[0].value.length));

		// The empty one survives too, which is the case a parser assuming every
		// chunk has a body gets wrong.
		Assert.equals(SctpPacket.CHUNK_COOKIE_ACK, decoded.chunks[1].type);
		Assert.equals(0, decoded.chunks[1].value.length);
	}

	/**
		The checksum covers the field it sits in, with that field zeroed.

		The same shape STUN's integrity has, and the same mistake available:
		checksumming the packet as it stands produces a value that verifies
		against itself and against nothing else. Pinned to arithmetic done
		outside Haxe so it cannot agree with itself into being wrong.
	**/
	public function testTheChecksumIsTakenOverTheFieldItOccupies():Void {
		var packet = new SctpPacket(5000, 5000, 0x12345678, [new SctpChunk(SctpPacket.CHUNK_INIT, 0)]);
		var encoded = packet.encode();

		Assert.equals(16, encoded.length);

		// What the packet looks like with the checksum still zero, which is
		// what is hashed.
		var zeroed = new ByteArray();
		zeroed.endian = Endian.BIG_ENDIAN;
		zeroed.writeShort(5000);
		zeroed.writeShort(5000);
		zeroed.writeInt(0x12345678);
		zeroed.writeInt(0);
		zeroed.writeByte(SctpPacket.CHUNK_INIT);
		zeroed.writeByte(0);
		zeroed.writeShort(4);
		zeroed.position = 0;

		Assert.equals("4D8B0200", hex(Crc32c.of(zeroed)), "the value being checksummed is not the packet with a zeroed field");
		Assert.isTrue(SctpPacket.verifyChecksum(encoded));
	}

	/**
		The checksum is the one field written the other way round.

		Everything else in the header is big endian; RFC 4960's reference
		implementation byte-swaps the CRC before storing it, and every
		implementation follows. Getting this backwards produces packets that
		look right and are discarded by every peer.
	**/
	public function testTheChecksumIsStoredLeastSignificantByteFirst():Void {
		var packet = new SctpPacket(5000, 5000, 0x12345678, [new SctpChunk(SctpPacket.CHUNK_INIT, 0)]);
		var encoded = packet.encode();

		encoded.position = 8;
		var onTheWire = hex(encoded.readUnsignedByte() << 24
			| encoded.readUnsignedByte() << 16
			| encoded.readUnsignedByte() << 8
			| encoded.readUnsignedByte());

		// The CRC is 0x4D8B0200; on the wire its bytes run the other way.
		Assert.equals("00028B4D", onTheWire, "the checksum was not byte-swapped, so no peer will accept these packets");
	}

	/**
		Checksumming a packet that already carries one.

		`writeChecksum` exists to be used twice: the association layer stamps a
		verification tag onto a packet built before it had one, and the checksum
		has to be recomputed over the altered bytes. That second pass is the only
		time the field holds an old value, and it is the only time zeroing it
		does anything -- `encode` writes zero there itself, so a test that only
		ever encodes cannot tell whether the zeroing is present.
	**/
	public function testRechecksummingAPacketThatAlreadyHasOne():Void {
		var encoded = new SctpPacket(5000, 5000, 0, [new SctpChunk(SctpPacket.CHUNK_INIT, 0)]).encode();

		Assert.isTrue(SctpPacket.verifyChecksum(encoded));

		// The tag an association learns only after its peer answers, stamped on
		// afterwards the way the layer above will do it.
		encoded.endian = Endian.BIG_ENDIAN;
		encoded.position = 4;
		encoded.writeInt(0x0BADF00D);

		Assert.isFalse(SctpPacket.verifyChecksum(encoded), "editing the tag did not invalidate the checksum");

		SctpPacket.writeChecksum(encoded);

		Assert.isTrue(SctpPacket.verifyChecksum(encoded), "recomputing over a packet that already had a checksum produced the wrong value");

		var decoded = SctpPacket.decode(encoded);
		Assert.notNull(decoded);

		if (decoded != null) {
			Assert.equals(0x0BADF00D, decoded.verificationTag);
		}
	}

	public function testATamperedPacketFailsItsChecksum():Void {
		var payload = new ByteArray();
		payload.writeUTFBytes("original");
		payload.position = 0;

		var encoded = new SctpPacket(5000, 5000, 0x12345678, [new SctpChunk(SctpPacket.CHUNK_DATA, 0, payload)]).encode();

		Assert.isTrue(SctpPacket.verifyChecksum(encoded));

		encoded.position = 16;
		encoded.writeByte(0x21);

		Assert.isFalse(SctpPacket.verifyChecksum(encoded), "a packet with an edited payload still passed its checksum");
		Assert.isNull(SctpPacket.decode(encoded), "a packet that failed its checksum was decoded anyway");
	}

	/**
		Verifying does not alter what it verifies.

		The field has to be zeroed to recompute the checksum, and doing that in
		place would hand the layer above a packet this code had edited -- with
		the checksum, the one field that says it was not edited, gone.
	**/
	public function testVerifyingLeavesThePacketAsItArrived():Void {
		var encoded = new SctpPacket(5000, 5000, 0x12345678, [new SctpChunk(SctpPacket.CHUNK_INIT, 0)]).encode();

		encoded.position = 8;
		var before = encoded.readInt();

		SctpPacket.verifyChecksum(encoded);

		encoded.position = 8;
		Assert.equals(before, encoded.readInt(), "verifying the checksum destroyed it");
	}

	/**
		The padding rule, which is the same one STUN attributes follow.

		A chunk's length counts its header and value and not the padding, while
		the next chunk still begins on a four byte boundary. A parser that adds
		the padding into the length, or forgets it, walks into the middle of the
		next chunk and reads nonsense with complete confidence.
	**/
	public function testChunksAreFoundAcrossThePadding():Void {
		var odd = new ByteArray();
		odd.writeUTFBytes("abc");
		odd.position = 0;

		var packet = new SctpPacket(5000, 5000, 1, [
			new SctpChunk(SctpPacket.CHUNK_DATA, 0, odd),
			new SctpChunk(SctpPacket.CHUNK_SACK, 0),
			new SctpChunk(SctpPacket.CHUNK_COOKIE_ACK, 0)
		]);

		var encoded = packet.encode();

		// 12 header + (4+3 padded to 8) + 4 + 4
		Assert.equals(28, encoded.length, "the chunks were not padded to four byte boundaries");

		var decoded = SctpPacket.decode(encoded);
		Assert.equals(3, decoded.chunks.length, "the walk lost a chunk across the padding");
		Assert.equals(SctpPacket.CHUNK_SACK, decoded.chunks[1].type);
		Assert.equals(SctpPacket.CHUNK_COOKIE_ACK, decoded.chunks[2].type);
		Assert.equals(3, decoded.chunks[0].value.length, "the padding was counted into the value");
	}

	public function testNoiseIsRefusedRatherThanParsed():Void {
		Assert.isNull(SctpPacket.decode(null));
		Assert.isNull(SctpPacket.decode(new ByteArray()));

		var short = new ByteArray();
		short.writeUTFBytes("tiny");
		short.position = 0;
		Assert.isNull(SctpPacket.decode(short));
	}

	/**
		A chunk claiming more than the packet holds ends the walk.

		Truncation is ordinary -- a datagram is whatever arrived -- and reading
		past the end would take whatever the buffer happened to contain.
	**/
	public function testAChunkLongerThanThePacketIsNotReadPast():Void {
		var packet = new ByteArray();
		packet.endian = Endian.BIG_ENDIAN;
		packet.writeShort(5000);
		packet.writeShort(5000);
		packet.writeInt(1);
		packet.writeInt(0);
		packet.writeByte(SctpPacket.CHUNK_DATA);
		packet.writeByte(0);
		packet.writeShort(400);
		packet.position = 0;

		var decoded = SctpPacket.decode(packet, false);

		Assert.notNull(decoded);
		Assert.equals(0, decoded.chunks.length, "a chunk claiming four hundred bytes in a sixteen byte packet was accepted");
	}

	/**
		What to do with a chunk type nobody here recognises.

		SCTP puts the instruction in the top two bits of the type, so a receiver
		can behave correctly toward a chunk from a later revision than it was
		written against. Two of the four cases mean carry on, which is what
		makes the protocol extensible rather than brittle.
	**/
	public function testAnUnknownChunkSaysWhatToDoWithItself():Void {
		Assert.equals(SctpUnknownActionValue.STOP, new SctpChunk(0x00, 0).unknownAction);
		Assert.equals(SctpUnknownActionValue.STOP_AND_REPORT, new SctpChunk(0x40, 0).unknownAction);
		Assert.equals(SctpUnknownActionValue.SKIP, new SctpChunk(0x80, 0).unknownAction);
		Assert.equals(SctpUnknownActionValue.SKIP_AND_REPORT, new SctpChunk(0xC0, 0).unknownAction);

		// DATA is type 0, so its instruction is the strictest one: a receiver
		// that does not understand data has no business guessing.
		Assert.equals(SctpUnknownActionValue.STOP, new SctpChunk(SctpPacket.CHUNK_DATA, 0).unknownAction);
	}

	private static function hex(value:Int):String {
		return StringTools.hex(value, 8);
	}

	private static function repeated(byte:Int, count:Int):ByteArray {
		var out = new ByteArray();

		for (_ in 0...count) {
			out.writeByte(byte);
		}

		out.position = 0;
		return out;
	}

	private static function counting(count:Int):ByteArray {
		var out = new ByteArray();

		for (i in 0...count) {
			out.writeByte(i);
		}

		out.position = 0;
		return out;
	}
}

private typedef SctpUnknownActionValue = crossbyte.net.rtc._internal.sctp.SctpPacket.SctpUnknownAction;
