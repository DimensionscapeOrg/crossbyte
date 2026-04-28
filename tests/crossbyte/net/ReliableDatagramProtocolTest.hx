package crossbyte.net;

import crossbyte.io.ByteArray;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol.ReliableDatagramFrameType;
import utest.Assert;

class ReliableDatagramProtocolTest extends utest.Test {
	public function testEncodeDecodeRoundTripWithAckAndPayload():Void {
		var payload = bytesOf("hello");
		payload.position = 2;

		var encoded = ReliableDatagramProtocol.encode(PACKET, 42, payload, true, 17);
		var decoded = ReliableDatagramProtocol.decode(encoded);

		Assert.notNull(decoded);
		Assert.equals(ReliableDatagramFrameType.PACKET, decoded.type);
		Assert.equals(42, decoded.sequence);
		Assert.equals(17, decoded.ack);
		Assert.isTrue(decoded.resend);
		Assert.equals("hello", readBytes(decoded.payload));
		Assert.equals(2, payload.position);
	}

	public function testControlFrameWithoutPayload():Void {
		var decoded = ReliableDatagramProtocol.decode(ReliableDatagramProtocol.encode(ACK, 99));

		Assert.notNull(decoded);
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
