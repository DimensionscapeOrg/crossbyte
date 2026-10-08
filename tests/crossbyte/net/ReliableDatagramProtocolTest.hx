package crossbyte.net;

import crossbyte.io.ByteArray;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol.ReliableDatagramFrameType;
import crossbyte.net._internal.reliable.SipHash;
import utest.Assert;
import crossbyte.test.Require;

class ReliableDatagramProtocolTest extends utest.Test {
	public function testEncodeDecodeRoundTripWithAckAndPayload():Void {
		var payload = bytesOf("hello");
		payload.position = 2;

		var encoded = ReliableDatagramProtocol.encode(PACKET, 42, payload, true, 17);
		var decoded = ReliableDatagramProtocol.decode(encoded);

		Require.notNull(decoded);
		Assert.equals(ReliableDatagramFrameType.PACKET, decoded.type);
		Assert.equals(42, decoded.sequence);
		Assert.equals(17, decoded.ack);
		Assert.isTrue(decoded.resend);
		Assert.equals("hello", readBytes(decoded.payload));
		Assert.equals(2, payload.position);
	}

	public function testControlFrameWithoutPayload():Void {
		var decoded = ReliableDatagramProtocol.decode(ReliableDatagramProtocol.encode(ACK, 99));

		Require.notNull(decoded);
		Assert.equals(ReliableDatagramFrameType.ACK, decoded.type);
		Assert.equals(99, decoded.sequence);
		Assert.isNull(decoded.ack);
		Assert.isFalse(decoded.resend);
		Assert.equals(0, decoded.payload.length);
	}

	public function testDecodeRejectsShortOrInvalidPackets():Void {
		Assert.isNull(ReliableDatagramProtocol.decode(null));
		Assert.isNull(ReliableDatagramProtocol.decode(new ByteArray()));
		Assert.isNull(ReliableDatagramProtocol.decode(bytesWithMagic(0x1234)));
		Assert.isNull(ReliableDatagramProtocol.decode(ackHeaderWithoutAck()));
		Assert.isNull(ReliableDatagramProtocol.decode(headerWithType(7)));
	}

	/**
		SipHash-2-4, which join cookies, rebind challenges and rebind proofs
		are made with, against the reference's 64 vectors: the key 00..0f,
		and the messages 00..n-1 for n from 0 to 63 (every length of last
		block, and one, two and seven whole blocks). Printed by libsodium's
		`crypto_shorthash_siphash24` reference, vendored in this repository.
	**/
	public function testSipHashGivesTheReferencesAnswers():Void {
		var key = haxe.io.Bytes.alloc(16);
		for (i in 0...16) {
			key.set(i, i);
		}
		var message = haxe.io.Bytes.alloc(64 + 3);
		for (i in 0...message.length) {
			message.set(i, (i - 3) & 0xFF);
		}
		var hasher = new SipHash(key);
		var wrong:Array<String> = [];
		for (n in 0...64) {
			// From 3 in, so an offset is read as one.
			hasher.hash(message, 3, n);
			if (hasher.high != SIP_VECTORS[n * 2] || hasher.low != SIP_VECTORS[n * 2 + 1]) {
				wrong.push('$n: ${StringTools.hex(hasher.high, 8)}${StringTools.hex(hasher.low, 8)}');
			}
		}
		Assert.same([], wrong, "SipHash differs from the reference for these lengths");

		// Another key, read from an offset, gives another answer.
		var other = haxe.io.Bytes.alloc(20);
		other.blit(4, key, 0, 16);
		other.set(4, 1);
		var second = new SipHash(other, 4);
		second.hash(message, 3, 15);
		Assert.isFalse(second.high == SIP_VECTORS[30] && second.low == SIP_VECTORS[31], "a different key gave the same answer");
	}

	// libsodium's crypto_shorthash_siphash24 for key 00..0f and messages
	// 00..n-1: each answer's high word, then its low word.
	private static final SIP_VECTORS:Array<Int> = [
		0x726fdb47, 0xdd0e0e31, 0x74f839c5, 0x93dc67fd, 0x0d6c8009, 0xd9a94f5a, 0x85676696, 0xd7fb7e2d, 0xcf2794e0, 0x277187b7, 0x18765564,
		0xcd99a68d, 0xcbc9466e, 0x58fee3ce, 0xab0200f5, 0x8b01d137, 0x93f5f579, 0x9a932462, 0x9e0082df, 0x0ba9e4b0, 0x7a5dbbc5, 0x94ddb9f3,
		0xf4b32f46, 0x226bada7, 0x751e8fbc, 0x860ee5fb, 0x14ea5627, 0xc0843d90, 0xf723ca90, 0x8e7af2ee, 0xa129ca61, 0x49be45e5, 0x3f2acc7f,
		0x57c29bdb, 0x699ae9f5, 0x2cbe4794, 0x4bc1b3f0, 0x968dd39c, 0xbb6dc91d, 0xa77961bd, 0xbed65cf2, 0x1aa2ee98, 0xd0f2cbb0, 0x2e3b67c7,
		0x93536795, 0xe3a33e88, 0xa80c038c, 0xcd5ccec8, 0xb8ad50c6, 0xf649af94, 0xbce192de, 0x8a85b8ea, 0x17d835b8, 0x5bbb15f3, 0x2f2e6163,
		0x076bcfad, 0xde4daaac, 0xa71dc9a5, 0xa6a25066, 0x87956571, 0xad87a353, 0x5c49ef28, 0x32d892fa, 0xd841c342, 0x7127512f, 0x72f27cce,
		0xa7f32346, 0xf95978e3, 0x12e0b01a, 0xbb051238, 0x15e034d4, 0x0fa197ae, 0x314dffbe, 0x0815a3b4, 0x027990f0, 0x29623981, 0xcadcd4e5,
		0x9ef40c4d, 0x9abfd876, 0x6a33735c, 0x0e3ea96b, 0x5304a7d0, 0xad0c42d6, 0xfc585992, 0x187306c8, 0x9bc215a9, 0xd4a60abc, 0xf3792b95,
		0xf935451d, 0xe4f21df2, 0xa9538f04, 0x19755787, 0xdb9acddf, 0xf56ca510, 0xd06c98cd, 0x5c0975eb, 0xe612a3cb, 0x9ecba951, 0xc766e62c,
		0xfcadaf96, 0xee64435a, 0x9752fe72, 0xa192d576, 0xb245165a, 0x0a8787bf, 0x8ecb74b2, 0x81b3e73d, 0x20b49b6f, 0x7fa8220b, 0xa3b2ecea,
		0x245731c1, 0x3ca42499, 0xb78dbfaf, 0x3a8d83bd, 0xea1ad565, 0x322a1a0b, 0x60e61c23, 0xa3795013, 0x6606d7e4, 0x46282b93, 0x6ca4ecb1,
		0x5c5f91e1, 0x9f626da1, 0x5c9625f3, 0xe51b3860, 0x8ef25f57, 0x958a324c, 0xeb064572
	];

	/**
		A 1.0 CONNECT puts its extension (features, a cookie, padding) ahead
		of what `connect` passed, and the decoder hands the two over apart: the
		payload is exactly what was passed.
	**/
	public function testAnExtendedConnectCarriesItsExtensionApartFromThePayload():Void {
		var encoded = ReliableDatagramProtocol.encodeConnect(77, bytesOf("token"), ReliableDatagramProtocol.FEATURE_REBIND);
		Assert.equals(ReliableDatagramProtocol.MIN_CONNECT_SIZE, encoded.length, "a short CONNECT was not padded to what may answer it");
		var frame = Require.notNull(ReliableDatagramProtocol.decode(encoded));
		Assert.equals(ReliableDatagramFrameType.CONNECT, frame.type);
		Assert.equals(77, frame.sequence);
		Assert.isTrue(frame.extended);
		Assert.isTrue(frame.bundles);
		Assert.equals(ReliableDatagramProtocol.FEATURE_REBIND, frame.features);
		Assert.isFalse(frame.hasCookie);
		Assert.equals("token", readBytes(frame.payload));

		var withCookie = Require.notNull(ReliableDatagramProtocol.decode(ReliableDatagramProtocol.encodeConnect(78, bytesOf("token"), 0, true, 0x81234567,
			0x7EDCBA98)));
		Assert.isTrue(withCookie.hasCookie);
		Assert.equals(ReliableDatagramProtocol.FEATURE_COOKIE, withCookie.features);
		Assert.equals(0x81234567, withCookie.cookieHigh);
		Assert.equals(0x7EDCBA98, withCookie.cookieLow);
		Assert.equals("token", readBytes(withCookie.payload));

		// Nothing passed: an empty payload, the frame padded.
		var empty = Require.notNull(ReliableDatagramProtocol.decode(ReliableDatagramProtocol.encodeConnect(79)));
		Assert.equals(0, empty.payload.length);

		// A whole frame's worth needs no padding: the extension's two bytes,
		// and the cookie's eight.
		var full = new ByteArray();
		full.length = ReliableDatagramProtocol.MAX_PAYLOAD_SIZE;
		var big = ReliableDatagramProtocol.encodeConnect(80, full, 0, true, 1, 2);
		Assert.equals(ReliableDatagramProtocol.HEADER_SIZE + ReliableDatagramProtocol.CONNECT_EXTENSION_MAX + ReliableDatagramProtocol.MAX_PAYLOAD_SIZE,
			big.length);
		Assert.equals(ReliableDatagramProtocol.MAX_PAYLOAD_SIZE, Require.notNull(ReliableDatagramProtocol.decode(big)).payload.length);

		// From before 1.0: no extension, and the payload whole.
		var older = Require.notNull(ReliableDatagramProtocol.decode(ReliableDatagramProtocol.encode(CONNECT, 81, bytesOf("x"))));
		Assert.isFalse(older.extended);
		Assert.isFalse(older.hasCookie);
		Assert.equals("x", readBytes(older.payload));
	}

	/** An extended CONNECT that is short, or whose extension runs past its end, is not a frame. **/
	public function testAMalformedExtendedConnectIsNotAFrame():Void {
		var good = ReliableDatagramProtocol.encodeConnect(5, bytesOf("abc"));

		// Shorter than what may be sent back to it.
		var short = new ByteArray();
		short.writeBytes(good, 0, ReliableDatagramProtocol.MIN_CONNECT_SIZE - 1);
		Assert.isNull(ReliableDatagramProtocol.decode(short), "a CONNECT shorter than its answers was taken");

		// An extension running past the end, and one of no length.
		var past = copy(good);
		(past : haxe.io.Bytes).set(ReliableDatagramProtocol.HEADER_SIZE, 250);
		Assert.isNull(ReliableDatagramProtocol.decode(past), "an extension past the frame's end was taken");
		var none = copy(good);
		(none : haxe.io.Bytes).set(ReliableDatagramProtocol.HEADER_SIZE, 0);
		Assert.isNull(ReliableDatagramProtocol.decode(none), "an extension of no length was taken");

		// A cookie the extension has no room for.
		var noRoom = ReliableDatagramProtocol.encodeConnect(5, zeros(40));
		(noRoom : haxe.io.Bytes).set(ReliableDatagramProtocol.HEADER_SIZE + 1, ReliableDatagramProtocol.FEATURE_COOKIE);
		Assert.isNull(ReliableDatagramProtocol.decode(noRoom), "a cookie flagged in an extension too short for one was taken");

		// A PATH frame names its kind.
		Assert.isNull(ReliableDatagramProtocol.decode(ReliableDatagramProtocol.encode(PATH, 1)), "a PATH frame with no kind was taken");
		var path = Require.notNull(ReliableDatagramProtocol.decode(ReliableDatagramProtocol.encode(PATH, 1, zeros(1))));
		Assert.equals(ReliableDatagramFrameType.PATH, path.type);
	}

	public function testTheNewFrameTypesAndTheMoreFlagSurviveARoundTrip():Void {
		for (type in [ReliableDatagramFrameType.UNRELIABLE, ReliableDatagramFrameType.SEQUENCED]) {
			var decoded = ReliableDatagramProtocol.decode(ReliableDatagramProtocol.encode(type, 1234, bytesOf("state")));
			Require.notNull(decoded);
			Assert.equals(type, decoded.type);
			Assert.equals(1234, decoded.sequence);
			Assert.equals("state", readBytes(decoded.payload));
			Assert.isFalse(decoded.more);
		}

		var fragment = ReliableDatagramProtocol.decode(ReliableDatagramProtocol.encode(PACKET, 7, bytesOf("part"), true, 3, true));
		Require.notNull(fragment);
		Assert.isTrue(fragment.more);
		Assert.isTrue(fragment.resend, "the more flag disturbed its neighbour");
		Assert.equals(3, fragment.ack);
	}

	public function testAFinSaysWhetherItIsGraceful():Void {
		var graceful = ReliableDatagramProtocol.decode(ReliableDatagramProtocol.encode(FIN, 77, null, false, 5, false, true));
		Require.notNull(graceful);
		Assert.equals(ReliableDatagramFrameType.FIN, graceful.type);
		Assert.isTrue(graceful.graceful);
		Assert.equals(77, graceful.sequence);
		Assert.equals(5, graceful.ack);

		// The abortive FIN, which is what a peer from before 1.0 sends.
		var abortive = ReliableDatagramProtocol.decode(ReliableDatagramProtocol.encode(FIN, 0));
		Require.notNull(abortive);
		Assert.isFalse(abortive.graceful);

		// A bit of its own, disturbing neither the type nor the other flags.
		var bytes:haxe.io.Bytes = ReliableDatagramProtocol.encode(FIN, 77, null, true, 5, true, true);
		Assert.equals(0x80 | 0x40 | 0x20 | 0x08 | 4, bytes.get(2));
	}

	public function testASequenceFieldCarriesTheChannelAndCounter():Void {
		for (channel in [0, 1, 127, 128, 255]) {
			for (counter in [0, 1, 0x7FFFFF, 0x800000, 0xFFFFFF]) {
				var field = ReliableDatagramProtocol.sequencedField(channel, counter);
				// Through the wire as well, where the top byte becomes the sign.
				var decoded = ReliableDatagramProtocol.decode(ReliableDatagramProtocol.encode(SEQUENCED, field, null));
				Assert.equals(channel, ReliableDatagramProtocol.channelOf(decoded.sequence), 'channel $channel counter $counter');
				Assert.equals(counter, ReliableDatagramProtocol.counterOf(decoded.sequence), 'channel $channel counter $counter');
			}
		}
		// A counter past 24 bits wraps rather than spilling into the channel.
		Assert.equals(9, ReliableDatagramProtocol.channelOf(ReliableDatagramProtocol.sequencedField(9, 0x1000005)));
		Assert.equals(5, ReliableDatagramProtocol.counterOf(ReliableDatagramProtocol.sequencedField(9, 0x1000005)));
	}

	public function testACounterIsNewerByLessThanHalfTheRange():Void {
		Assert.isTrue(ReliableDatagramProtocol.counterIsNewer(1, 0));
		Assert.isFalse(ReliableDatagramProtocol.counterIsNewer(0, 1));
		Assert.isFalse(ReliableDatagramProtocol.counterIsNewer(5, 5), "the same counter is a duplicate, not newer");
		Assert.isTrue(ReliableDatagramProtocol.counterIsNewer(0, 0xFFFFFF), "across the wrap");
		Assert.isFalse(ReliableDatagramProtocol.counterIsNewer(0xFFFFFF, 0), "backwards across the wrap");
		Assert.isTrue(ReliableDatagramProtocol.counterIsNewer(0x7FFFFF, 0), "just under half the range ahead");
		Assert.isFalse(ReliableDatagramProtocol.counterIsNewer(0x800000, 0), "half the range ahead is not newer");
	}

	public function testEncodingIntoABufferWritesTheSameFrame():Void {
		var payload = bytesOf("0123456789");
		var expected = ReliableDatagramProtocol.encode(PACKET, 0x80000001, bytesOf("3456"), true, 0xFFFFFFFE, true);

		var scratch = new ByteArray();
		scratch.length = ReliableDatagramProtocol.MAX_FRAME_SIZE;
		// Something already there, which the frame must not depend on.
		for (i in 0...scratch.length) {
			scratch[i] = 0xAA;
		}
		var written = ReliableDatagramProtocol.encodeInto(scratch, PACKET, 0x80000001, payload, 3, 4, true, 0xFFFFFFFE, true, true);

		Assert.equals(expected.length, written);
		var same = true;
		for (i in 0...written) {
			if (scratch[i] != expected[i]) {
				same = false;
			}
		}
		Assert.isTrue(same, "encodeInto and encode disagree about the bytes of one frame");
		Assert.equals(0, payload.position, "the payload's position moved");
	}

	public function testALargePayloadStillEncodesWhole():Void {
		// encode takes any size, which encodeInto leaves to the socket to have
		// checked.
		var big = new ByteArray();
		for (i in 0...5000) {
			big.writeByte(i & 0xFF);
		}
		var decoded = ReliableDatagramProtocol.decode(ReliableDatagramProtocol.encode(PACKET, 1, big));
		Require.notNull(decoded);
		Assert.equals(5000, decoded.payload.length);
	}

	private static function bytesOf(value:String):ByteArray {
		var bytes = new ByteArray();
		bytes.writeUTFBytes(value);
		bytes.position = 0;
		return bytes;
	}

	private static function readBytes(bytes:ByteArray):String {
		bytes.position = 0;
		return bytes.readUTFBytes(bytes.length);
	}

	private static function copy(bytes:ByteArray):ByteArray {
		var out = new ByteArray();
		out.writeBytes(bytes, 0, bytes.length);
		out.position = 0;
		return out;
	}

	private static function zeros(length:Int):ByteArray {
		var bytes = new ByteArray();
		bytes.length = length;
		return bytes;
	}

	private static function bytesWithMagic(magic:Int):ByteArray {
		var bytes = new ByteArray();
		bytes.endian = BIG_ENDIAN;
		bytes.writeShort(magic);
		bytes.writeByte(0);
		bytes.writeUnsignedInt(0);
		bytes.position = 0;
		return bytes;
	}

	private static function ackHeaderWithoutAck():ByteArray {
		var bytes = bytesWithMagic(ReliableDatagramProtocol.MAGIC);
		bytes.position = 2;
		bytes.writeByte(0x80);
		bytes.position = 0;
		return bytes;
	}

	private static function headerWithType(type:Int):ByteArray {
		var bytes = bytesWithMagic(ReliableDatagramProtocol.MAGIC);
		bytes.position = 2;
		bytes.writeByte(type);
		bytes.position = 0;
		return bytes;
	}
}
