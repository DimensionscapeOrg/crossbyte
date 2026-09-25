package crossbyte.net;

import crossbyte.io.ByteArray;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol.ReliableDatagramFrameType;
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
		var written = ReliableDatagramProtocol.encodeInto(scratch, PACKET, 0x80000001, payload, 3, 4, true, 0xFFFFFFFE, true);

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
		// encode keeps its old promise: any size, which encodeInto leaves to
		// the socket to have checked.
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
