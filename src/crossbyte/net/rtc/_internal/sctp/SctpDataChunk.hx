package crossbyte.net.rtc._internal.sctp;

import crossbyte.io.ByteArray;
import crossbyte.io.Endian;
import crossbyte.net.rtc._internal.sctp.SctpPacket.SctpChunk;

/**
	One DATA chunk: a fragment of a message on a stream.

	```
	|   Type = 0    | Reserved|U|B|E|    Length                     |
	|                              TSN                              |
	|      Stream Identifier S      |   Stream Sequence Number n    |
	|                  Payload Protocol Identifier                  |
	|                 User Data (seq n of Stream S)                 |
	```

	## Three numbers doing three different jobs

	The **TSN** orders and acknowledges every fragment on the association,
	whatever stream it belongs to. It is what a SACK talks about, and what
	decides whether something needs sending again.

	The **stream sequence number** orders whole messages within one stream, and
	only within it. Two streams advance independently -- which is the point of
	having them: a large message on one channel does not delay a small one on
	another, the head-of-line blocking that made a data channel over TCP
	unattractive in the first place.

	The **payload protocol identifier** says what the bytes are. WebRTC uses it
	to separate a channel's control messages from its contents, and to tell a
	string from a binary blob, which is why an empty message needs a PPID of its
	own: a zero-length payload would otherwise be indistinguishable from no
	payload.

	## Begin and end

	A message too large for one packet is cut into fragments carrying the same
	stream sequence number, the first flagged B and the last flagged E. A
	message that fits carries both. A receiver holds fragments until it has the
	pair, which is why an E that never arrives holds a message open rather than
	delivering half of one.
**/
class SctpDataChunk {
	/** The chunk header is four bytes; this is what DATA adds before the payload. **/
	public static inline var HEADER_LENGTH:Int = 12;

	/** Delivered without waiting for anything ahead of it on its stream. **/
	public static inline var FLAG_UNORDERED:Int = 0x04;

	/** First fragment of a message. **/
	public static inline var FLAG_BEGINNING:Int = 0x02;

	/** Last fragment of a message. **/
	public static inline var FLAG_ENDING:Int = 0x01;

	// RFC 8831's identifiers, which is how WebRTC says what a message holds.
	/** A data channel control message: open, or acknowledge an open. **/
	public static inline var PPID_CONTROL:Int = 50;

	public static inline var PPID_STRING:Int = 51;
	public static inline var PPID_BINARY:Int = 53;

	/** An empty binary message, which needs its own identifier to exist at all. **/
	public static inline var PPID_BINARY_EMPTY:Int = 57;

	/** An empty string message, for the same reason. **/
	public static inline var PPID_STRING_EMPTY:Int = 56;

	public var tsn(default, null):Int;
	public var streamId(default, null):Int;
	public var streamSequence(default, null):Int;
	public var protocolId(default, null):Int;
	public var payload(default, null):ByteArray;
	public var flags(default, null):Int;

	public function new(tsn:Int, streamId:Int, streamSequence:Int, protocolId:Int, payload:ByteArray, flags:Int) {
		this.tsn = tsn;
		this.streamId = streamId;
		this.streamSequence = streamSequence;
		this.protocolId = protocolId;
		this.payload = payload != null ? payload : new ByteArray();
		this.flags = flags;
	}

	public var unordered(get, never):Bool;

	private function get_unordered():Bool {
		return (flags & FLAG_UNORDERED) != 0;
	}

	public var beginning(get, never):Bool;

	private function get_beginning():Bool {
		return (flags & FLAG_BEGINNING) != 0;
	}

	public var ending(get, never):Bool;

	private function get_ending():Bool {
		return (flags & FLAG_ENDING) != 0;
	}

	/** Wraps this as a chunk the packet layer can write. **/
	public function toChunk():SctpChunk {
		var value = new ByteArray();
		value.endian = Endian.BIG_ENDIAN;
		value.writeInt(tsn);
		value.writeShort(streamId);
		value.writeShort(streamSequence);
		value.writeInt(protocolId);

		if (payload.length > 0) {
			value.writeBytes(payload, 0, payload.length);
		}

		value.position = 0;
		return new SctpChunk(SctpPacket.CHUNK_DATA, flags, value);
	}

	/** Reads one, or null when the chunk is too short to be a DATA chunk. **/
	public static function fromChunk(chunk:SctpChunk):Null<SctpDataChunk> {
		if (chunk == null || chunk.type != SctpPacket.CHUNK_DATA || chunk.value.length < HEADER_LENGTH) {
			return null;
		}

		chunk.value.endian = Endian.BIG_ENDIAN;
		chunk.value.position = 0;

		var tsn:Int = chunk.value.readInt();
		var streamId:Int = chunk.value.readUnsignedShort();
		var streamSequence:Int = chunk.value.readUnsignedShort();
		var protocolId:Int = chunk.value.readInt();

		var payload = new ByteArray();
		var remaining:Int = chunk.value.length - HEADER_LENGTH;

		if (remaining > 0) {
			chunk.value.readBytes(payload, 0, remaining);
		}

		payload.position = 0;
		return new SctpDataChunk(tsn, streamId, streamSequence, protocolId, payload, chunk.flags);
	}

	/**
		Whether `a` comes before `b` in a sequence that wraps.

		TSNs and stream sequence numbers both run out and start again, so the
		comparison cannot be a subtraction. RFC 1982's rule: a is earlier when
		the distance forward to b is less than half the space. Getting this
		wrong looks like nothing for hours and then reorders every message at
		the moment the counter wraps.
	**/
	public static function isEarlier(a:Int, b:Int):Bool {
		if (a == b) {
			return false;
		}

		// The distance forward from a to b, wrapped into thirty-two bits and
		// read as signed. Positive means b is ahead of a by less than half the
		// space, which is RFC 1982's rule and the only comparison that survives
		// the counter rolling over.
		//
		// `| 0` is what forces the wrap on a target whose Int is a double. It
		// is not decoration: without it the subtraction stays exact, and two
		// values either side of the boundary compare as though the sequence ran
		// forever in a straight line.
		return ((b - a) | 0) > 0;
	}

	public function toString():String {
		return "DATA(tsn " + tsn + ", stream " + streamId + ", seq " + streamSequence + ", ppid " + protocolId + ", " + payload.length
			+ " bytes" + (beginning ? ", B" : "") + (ending ? ", E" : "") + (unordered ? ", U" : "") + ")";
	}
}
