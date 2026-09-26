package crossbyte.net.rtc._internal.sctp;

import crossbyte.io.ByteArray;
import crossbyte.io.Endian;

/**
	The two messages that open a data channel, RFC 8832.

	SCTP gives an association with streams numbered but anonymous. DCEP is what
	turns a stream number into a *channel*: one peer sends an OPEN on the stream
	it has chosen, naming it and saying how it should behave, and the other
	answers with an ACK on the same stream.

	```
	|  Message Type |  Channel Type |            Priority           |
	|                    Reliability Parameter                      |
	|         Label Length          |       Protocol Length         |
	|                             Label                             |
	|                            Protocol                           |
	```

	It travels as an ordinary message on the stream it is about, marked with
	payload protocol identifier 50 -- which is the whole reason that identifier
	exists. Control and content share a stream and are told apart by it, so a
	channel needs no second stream to be negotiated on.

	## Who picks the stream number

	The DTLS client uses even numbers and the server odd ones. That is the whole
	of the collision avoidance: two peers opening channels at the same instant
	cannot choose the same stream, so no negotiation is needed and no round trip
	is spent discovering a clash.
**/
class DcepMessage {
	/** A peer asking to open a channel on this stream. **/
	public static inline var OPEN:Int = 0x03;

	/** The answer, which carries nothing but its own type. **/
	public static inline var ACK:Int = 0x02;

	// Channel types. The high bit is the ordering flag, so the unordered form of
	// each is its value with 0x80 set.
	/** Every message arrives, in the order it was sent. **/
	public static inline var RELIABLE:Int = 0x00;

	/** Every message arrives, in whatever order it lands. **/
	public static inline var RELIABLE_UNORDERED:Int = 0x80;

	/** Given up on after a number of retransmissions, ordered. **/
	public static inline var PARTIAL_RETRANSMIT:Int = 0x01;

	/** Given up on after a time, ordered. **/
	public static inline var PARTIAL_TIMED:Int = 0x02;

	/** Given up on after a number of retransmissions, in whatever order it lands: a browser's `{ordered: false, maxRetransmits: n}`. **/
	public static inline var PARTIAL_RETRANSMIT_UNORDERED:Int = 0x81;

	/** Given up on after a time, in whatever order it lands. **/
	public static inline var PARTIAL_TIMED_UNORDERED:Int = 0x82;

	private static inline var UNORDERED_FLAG:Int = 0x80;
	private static inline var OPEN_HEADER_LENGTH:Int = 12;

	public var messageType(default, null):Int;
	public var channelType(default, null):Int;
	public var priority(default, null):Int;
	public var reliability(default, null):Int;
	public var label(default, null):String;
	public var protocol(default, null):String;

	public function new(messageType:Int, channelType:Int = RELIABLE, priority:Int = 0, reliability:Int = 0, label:String = "",
			protocol:String = "") {
		this.messageType = messageType;
		this.channelType = channelType;
		this.priority = priority;
		this.reliability = reliability;
		this.label = label != null ? label : "";
		this.protocol = protocol != null ? protocol : "";
	}

	/** Whether this channel type delivers without waiting for what came before. **/
	public var unordered(get, never):Bool;

	private function get_unordered():Bool {
		return (channelType & UNORDERED_FLAG) != 0;
	}

	/**
		How many times a message may be sent again before it is given up on,
		for a channel of that type; null for one that is not.
	**/
	public var maxRetransmits(get, never):Null<Int>;

	private function get_maxRetransmits():Null<Int> {
		return (channelType & ~UNORDERED_FLAG) == PARTIAL_RETRANSMIT ? __parameter() : null;
	}

	/** How long, in milliseconds, a message is tried for, for a channel of that type; null otherwise. **/
	public var maxPacketLifeTime(get, never):Null<Int>;

	private function get_maxPacketLifeTime():Null<Int> {
		return (channelType & ~UNORDERED_FLAG) == PARTIAL_TIMED ? __parameter() : null;
	}

	/** The reliability parameter, which is unsigned on the wire: past an Int's range is as good as no limit. **/
	private inline function __parameter():Int {
		return reliability < 0 ? 0x7FFFFFFF : reliability;
	}

	/**
		An OPEN for a channel, ordered unless told otherwise, and reliable
		unless given one of the two limits -- RFC 8832's partially reliable
		types, which is what a channel for game state wants: a position that
		arrives late is worth less than the next one.
	**/
	public static function open(label:String, ordered:Bool = true, protocol:String = "", ?maxRetransmits:Int,
			?maxPacketLifeTime:Int):DcepMessage {
		var type:Int = RELIABLE;
		var reliability:Int = 0;

		if (maxRetransmits != null) {
			type = PARTIAL_RETRANSMIT;
			reliability = maxRetransmits;
		} else if (maxPacketLifeTime != null) {
			type = PARTIAL_TIMED;
			reliability = maxPacketLifeTime;
		}

		return new DcepMessage(OPEN, ordered ? type : type | UNORDERED_FLAG, 0, reliability, label, protocol);
	}

	public static function acknowledge():DcepMessage {
		return new DcepMessage(ACK);
	}

	public function encode():ByteArray {
		var out = new ByteArray();
		out.endian = Endian.BIG_ENDIAN;
		out.writeByte(messageType);

		if (messageType == ACK) {
			// One byte and nothing else. A parser expecting a fixed header
			// everywhere reads past the end of it.
			out.position = 0;
			return out;
		}

		out.writeByte(channelType);
		out.writeShort(priority);
		out.writeInt(reliability);

		var labelBytes = new ByteArray();
		labelBytes.writeUTFBytes(label);

		var protocolBytes = new ByteArray();
		protocolBytes.writeUTFBytes(protocol);

		// Lengths in bytes rather than characters, because the label is UTF-8
		// and a peer counting characters would truncate every label containing
		// anything outside ASCII.
		out.writeShort(labelBytes.length);
		out.writeShort(protocolBytes.length);

		if (labelBytes.length > 0) {
			out.writeBytes(labelBytes, 0, labelBytes.length);
		}

		if (protocolBytes.length > 0) {
			out.writeBytes(protocolBytes, 0, protocolBytes.length);
		}

		out.position = 0;
		return out;
	}

	/** Reads one, or null when the bytes are not a DCEP message. **/
	public static function decode(bytes:ByteArray):Null<DcepMessage> {
		if (bytes == null || bytes.length < 1) {
			return null;
		}

		bytes.endian = Endian.BIG_ENDIAN;
		bytes.position = 0;

		var messageType:Int = bytes.readUnsignedByte();

		if (messageType == ACK) {
			return new DcepMessage(ACK);
		}

		if (messageType != OPEN || bytes.length < OPEN_HEADER_LENGTH) {
			return null;
		}

		var channelType:Int = bytes.readUnsignedByte();
		var priority:Int = bytes.readUnsignedShort();
		var reliability:Int = bytes.readInt();
		var labelLength:Int = bytes.readUnsignedShort();
		var protocolLength:Int = bytes.readUnsignedShort();

		// A length claiming more than arrived is a truncated message, not a
		// long label. Reading it would take whatever followed in the buffer.
		if (OPEN_HEADER_LENGTH + labelLength + protocolLength > bytes.length) {
			return null;
		}

		var label:String = labelLength > 0 ? bytes.readUTFBytes(labelLength) : "";
		var protocol:String = protocolLength > 0 ? bytes.readUTFBytes(protocolLength) : "";

		return new DcepMessage(OPEN, channelType, priority, reliability, label, protocol);
	}

	public function toString():String {
		return messageType == ACK ? "DCEP(ack)" : "DCEP(open \"" + label + "\", type " + channelType + ")";
	}
}
