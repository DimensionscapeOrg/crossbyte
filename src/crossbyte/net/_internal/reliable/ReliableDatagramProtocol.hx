package crossbyte.net._internal.reliable;

import crossbyte.Seq32;
import crossbyte.io.ByteArray;
import crossbyte.io.Endian;

enum abstract ReliableDatagramFrameType(Int) from Int to Int {
	var CONNECT = 0;
	var HANDSHAKE = 1;
	var PACKET = 2;
	var ACK = 3;
	var FIN = 4;
}

final class ReliableDatagramFrame {
	public var resend(default, null):Bool;
	public var sequence(default, null):Seq32;
	public var type(default, null):ReliableDatagramFrameType;
	public var payload(default, null):ByteArray;
	public var ack(default, null):Null<Seq32>;

	public function new(type:ReliableDatagramFrameType, sequence:Seq32, payload:ByteArray, resend:Bool, ?ack:Seq32) {
		this.type = type;
		this.sequence = sequence;
		this.payload = payload;
		this.resend = resend;
		this.ack = ack;
	}
}

final class ReliableDatagramProtocol {
	public static inline var HEADER_SIZE:Int = 7;
	public static inline var ACK_FIELD_SIZE:Int = 4;
	public static inline var MAGIC:Int = 0xCBDA;
	public static inline var MAX_PAYLOAD_SIZE:Int = 1200;

	@:noCompletion private static inline var ACK_PRESENT_MASK:Int = 0x80;
	@:noCompletion private static inline var RESEND_MASK:Int = 0x40;
	@:noCompletion private static inline var TYPE_SHIFT:Int = 0;
	@:noCompletion private static inline var TYPE_MASK:Int = 0x07;

	public static function decode(packet:ByteArray):ReliableDatagramFrame {
		if (packet == null || packet.length < HEADER_SIZE) {
			return null;
		}

		packet.position = 0;
		packet.endian = Endian.BIG_ENDIAN;

		if (packet.readUnsignedShort() != MAGIC) {
			return null;
		}

		var meta:Int = packet.readUnsignedByte();
		var typeValue:Int = (meta & TYPE_MASK) >> TYPE_SHIFT;
		var resend:Bool = (meta & RESEND_MASK) != 0;
		var ackPresent:Bool = (meta & ACK_PRESENT_MASK) != 0;
		if (ackPresent && packet.length < HEADER_SIZE + ACK_FIELD_SIZE) {
			return null;
		}

		var sequence:Seq32 = packet.readUnsignedInt();
		var ack:Null<Seq32> = null;
		if (ackPresent) {
			ack = packet.readUnsignedInt();
		}

		var payload:ByteArray = new ByteArray();
		if (packet.bytesAvailable > 0) {
			packet.readBytes(payload, 0, packet.bytesAvailable);
			payload.position = 0;
		}

		return new ReliableDatagramFrame(cast typeValue, sequence, payload, resend, ack);
	}

	public static function encode(type:ReliableDatagramFrameType, sequence:Seq32, ?payload:ByteArray, resend:Bool = false, ?ack:Seq32):ByteArray {
		var frame:ByteArray = new ByteArray();
		frame.endian = Endian.BIG_ENDIAN;
		frame.writeShort(MAGIC);
		var meta:Int = (type << TYPE_SHIFT);
		if (resend) {
			meta |= RESEND_MASK;
		}
		if (ack != null) {
			meta |= ACK_PRESENT_MASK;
		}
		frame.writeByte(meta);
		frame.writeUnsignedInt(sequence);
		if (ack != null) {
			frame.writeUnsignedInt(ack);
		}

		var payloadLength:Int = payload != null ? payload.length : 0;
		if (payloadLength > 0) {
			var sourcePosition:UInt = payload.position;
			payload.position = 0;
			frame.writeBytes(payload, 0, payloadLength);
			payload.position = sourcePosition;
		}
		frame.position = 0;
		return frame;
	}
}
