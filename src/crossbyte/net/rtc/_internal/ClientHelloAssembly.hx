package crossbyte.net.rtc._internal;

import haxe.io.Bytes;

/**
	Puts a ClientHello back together when a peer sent it in pieces.

	## Why this exists

	DTLS runs over datagrams, so a handshake message larger than the path MTU
	has to be split by the handshake layer itself rather than by IP -- RFC 6347
	gives every handshake message a fragment offset and length for exactly that
	reason. A ClientHello carrying a modern cipher suite list and its extensions
	is comfortably over a kilobyte, and Chrome fragments it at around 1175
	bytes.

	mbedtls reassembles fragmented handshake messages in general, but not the
	ClientHello: reassembly needs handshake state, and the ClientHello is what
	creates it. Its parser says so in as many words -- "We don't support
	fragmentation of ClientHello" -- and rejects a first fragment because the
	record is shorter than the message length it declares.

	So a browser offering a data channel to CrossByte cannot complete a
	handshake, while a browser answering one connects immediately: the answering
	direction has CrossByte as the DTLS client, and a client never reads a
	ClientHello. The two directions fail and pass for that one reason.

	Reassembling here is the natural place. This stack already owns every
	datagram between the socket and the DTLS implementation, and the alternative
	-- carrying a patch against a vendored mbedtls -- buys nothing that this
	does not.

	## What it does and does not touch

	Only a handshake record whose message is a ClientHello *and* is genuinely
	fragmented. A datagram with nothing of that shape in it is returned
	unchanged and not even copied, which keeps every other record on the
	untouched path: encrypted records at a later epoch, alerts, and the whole of
	the client direction never reach the rebuilding code at all.

	The message is rebuilt as though it had been sent in one piece -- fragment
	offset zero, fragment length equal to the message length. That is not a
	convenience: RFC 6347 requires the handshake hash to be computed over that
	form, so a reassembly that preserved the original fragment headers would
	produce a transcript the peer's Finished disagrees with.
**/
class ClientHelloAssembly {
	/** ContentType, version, epoch, sequence number, length. **/
	public static inline var RECORD_HEADER:Int = 13;

	/** Type, length, message sequence, fragment offset, fragment length. **/
	public static inline var HANDSHAKE_HEADER:Int = 12;

	/** RFC 7983 puts DTLS between 20 and 63; 22 is the handshake protocol. **/
	private static inline var TYPE_HANDSHAKE:Int = 22;

	private static inline var CLIENT_HELLO:Int = 1;

	/**
		The largest message worth assembling.

		A fragment declares its message length in three bytes, so a peer can
		claim sixteen megabytes before a single one has been read. mbedtls will
		not accept a record over its input content length however it arrives, so
		anything above that is a message no handshake could use and an
		allocation nobody asked for.
	**/
	public static inline var MAX_MESSAGE:Int = 16384 - HANDSHAKE_HEADER;

	/** The message being assembled, or null when nothing is in progress. **/
	@:noCompletion private var __body:Bytes;

	@:noCompletion private var __messageSequence:Int = -1;

	@:noCompletion private var __length:Int = 0;

	/**
		Which bytes have arrived, as merged ranges.

		Ranges rather than a count, because a peer retransmitting its flight
		sends fragments already held, and counting bytes would call the message
		complete once enough duplicates had arrived.
	**/
	@:noCompletion private var __covered:Array<{start:Int, end:Int}> = [];

	/**
		How many bytes are held for a message still being assembled.

		Zero between messages. Worth being able to see: the difference between
		refusing an impossible length and believing it is not in what `accept`
		returns -- both hold the fragment -- but in whether sixteen megabytes
		were set aside on the strength of one unauthenticated packet.
	**/
	public var pending(get, never):Int;

	public function new() {}

	@:noCompletion private function get_pending():Int {
		return __body == null ? 0 : __length;
	}

	/**
		Takes a datagram on its way to the DTLS implementation.

		@return What to hand over: the datagram itself when there was nothing to
		reassemble, a rebuilt one when a ClientHello was completed, or `null`
		when everything in it is being held for fragments still to come.
	**/
	public function accept(datagram:Bytes):Null<Bytes> {
		if (datagram == null || !__hasFragment(datagram)) {
			return datagram;
		}

		var pieces:Array<Bytes> = [];
		var at:Int = 0;

		while (at + RECORD_HEADER <= datagram.length) {
			var length:Int = (datagram.get(at + 11) << 8) | datagram.get(at + 12);
			var stop:Int = at + RECORD_HEADER + length;

			if (stop > datagram.length) {
				break;
			}

			if (__isFragment(datagram, at, length)) {
				var completed = __absorb(datagram, at, length);

				if (completed != null) {
					pieces.push(completed);
				}
			} else {
				pieces.push(datagram.sub(at, stop - at));
			}

			at = stop;
		}

		if (pieces.length == 0) {
			return null;
		}

		var total:Int = 0;

		for (piece in pieces) {
			total += piece.length;
		}

		var out = Bytes.alloc(total);
		var written:Int = 0;

		for (piece in pieces) {
			out.blit(written, piece, 0, piece.length);
			written += piece.length;
		}

		return out;
	}

	/** Forgets a partial message. **/
	public function reset():Void {
		__body = null;
		__messageSequence = -1;
		__length = 0;
		__covered = [];
	}

	// ------------------------------------------------------------------

	/** Whether anything in this datagram is a piece of a ClientHello. **/
	@:noCompletion private function __hasFragment(datagram:Bytes):Bool {
		var at:Int = 0;

		while (at + RECORD_HEADER <= datagram.length) {
			var length:Int = (datagram.get(at + 11) << 8) | datagram.get(at + 12);
			var stop:Int = at + RECORD_HEADER + length;

			if (stop > datagram.length) {
				return false;
			}

			if (__isFragment(datagram, at, length)) {
				return true;
			}

			at = stop;
		}

		return false;
	}

	/**
		A ClientHello record carrying less than the whole message.

		Epoch zero as well: a record at a later epoch is encrypted, and its
		bytes at these offsets are ciphertext that would parse as anything at
		all.
	**/
	@:noCompletion private function __isFragment(datagram:Bytes, at:Int, length:Int):Bool {
		if (datagram.get(at) != TYPE_HANDSHAKE || length < HANDSHAKE_HEADER) {
			return false;
		}

		if (datagram.get(at + 3) != 0 || datagram.get(at + 4) != 0) {
			return false;
		}

		var body:Int = at + RECORD_HEADER;

		if (datagram.get(body) != CLIENT_HELLO) {
			return false;
		}

		var declared:Int = __uint24(datagram, body + 1);
		var offset:Int = __uint24(datagram, body + 6);
		var carried:Int = __uint24(datagram, body + 9);

		// The unfragmented case, which is every ClientHello small enough to fit
		// and the only one mbedtls would have accepted on its own.
		if (offset == 0 && carried == declared) {
			return false;
		}

		return carried == length - HANDSHAKE_HEADER && offset + carried <= declared;
	}

	/**
		Files one fragment.

		@return The whole message as a record once the last gap closes, or null
		while any remains.
	**/
	@:noCompletion private function __absorb(datagram:Bytes, at:Int, length:Int):Null<Bytes> {
		var body:Int = at + RECORD_HEADER;
		var declared:Int = __uint24(datagram, body + 1);
		var sequence:Int = (datagram.get(body + 4) << 8) | datagram.get(body + 5);
		var offset:Int = __uint24(datagram, body + 6);
		var carried:Int = __uint24(datagram, body + 9);

		if (declared > MAX_MESSAGE) {
			return null;
		}

		// A different message, or the same one at a different size, means the
		// peer started over -- so does the assembly. Retransmitted fragments of
		// the message in hand land on top of what is already there.
		if (sequence != __messageSequence || declared != __length || __body == null) {
			__body = Bytes.alloc(declared);
			__messageSequence = sequence;
			__length = declared;
			__covered = [];
		}

		__body.blit(offset, datagram, body + HANDSHAKE_HEADER, carried);
		__cover(offset, offset + carried);

		if (__covered.length != 1 || __covered[0].start != 0 || __covered[0].end != declared) {
			return null;
		}

		var record = Bytes.alloc(RECORD_HEADER + HANDSHAKE_HEADER + declared);

		// The header of whichever fragment finished the message, so the record
		// carries a sequence number the peer has actually used and one no
		// earlier than any already seen.
		record.blit(0, datagram, at, RECORD_HEADER);
		record.set(11, ((HANDSHAKE_HEADER + declared) >> 8) & 0xFF);
		record.set(12, (HANDSHAKE_HEADER + declared) & 0xFF);

		record.set(RECORD_HEADER, CLIENT_HELLO);
		__writeUint24(record, RECORD_HEADER + 1, declared);
		record.set(RECORD_HEADER + 4, (sequence >> 8) & 0xFF);
		record.set(RECORD_HEADER + 5, sequence & 0xFF);
		__writeUint24(record, RECORD_HEADER + 6, 0);
		__writeUint24(record, RECORD_HEADER + 9, declared);
		record.blit(RECORD_HEADER + HANDSHAKE_HEADER, __body, 0, declared);

		reset();
		return record;
	}

	/** Adds a range, merging it with anything it meets or overlaps. **/
	@:noCompletion private function __cover(start:Int, end:Int):Void {
		if (end <= start) {
			return;
		}

		var merged:Array<{start:Int, end:Int}> = [];
		var low:Int = start;
		var high:Int = end;

		for (range in __covered) {
			if (range.end < low || range.start > high) {
				merged.push(range);
			} else {
				low = range.start < low ? range.start : low;
				high = range.end > high ? range.end : high;
			}
		}

		merged.push({start: low, end: high});
		merged.sort(function(a, b):Int return a.start - b.start);
		__covered = merged;
	}

	@:noCompletion private static inline function __uint24(bytes:Bytes, at:Int):Int {
		return (bytes.get(at) << 16) | (bytes.get(at + 1) << 8) | bytes.get(at + 2);
	}

	@:noCompletion private static inline function __writeUint24(bytes:Bytes, at:Int, value:Int):Void {
		bytes.set(at, (value >> 16) & 0xFF);
		bytes.set(at + 1, (value >> 8) & 0xFF);
		bytes.set(at + 2, value & 0xFF);
	}
}
