package crossbyte.net.rtc._internal.sctp;

import crossbyte.Future;
import crossbyte.crypto.SecureRandom;
import crossbyte.io.ByteArray;
import crossbyte.io.Endian;
import crossbyte.net.rtc._internal.sctp.SctpPacket.SctpChunk;

/**
	The four-way handshake that opens an SCTP association.

	INIT, INIT ACK, COOKIE ECHO, COOKIE ACK. Four messages where TCP uses three,
	and the extra one is the whole point: the peer that is asked to open an
	association commits no memory to it until the requester has proved it can
	receive at the address it claimed. The state that would have been held sits
	in a cookie the requester carries and hands back.

	That is a defence against a flood of forged INITs from addresses that cannot
	answer -- the attack that made SYN cookies necessary for TCP, designed into
	SCTP from the start rather than retrofitted.

	## Verification tags

	Each side invents a tag, sends it in its INIT or INIT ACK, and from then on
	stamps every packet with the *other* side's. A packet carrying the wrong tag
	belongs to an association that has ended, or to somebody who guessed the
	ports, and is discarded. It is the reason an association survives a peer
	restarting on the same port without silently accepting its new traffic as
	the old session.

	## No socket

	`onSend` out, `receive` in, `poll` for time -- the fourth component in this
	stack built that way, and here it is doubly forced: an association runs
	inside a DTLS session which itself runs over a socket already carrying ICE.
	Nothing at this level has any business knowing what a socket is.
**/
class SctpAssociation {
	/** The port both ends of a WebRTC data channel use, by convention. **/
	public static inline var DEFAULT_PORT:Int = 5000;

	/**
		How much undelivered data this end is willing to hold, in bytes.

		Advertised in the INIT and, now that `SctpDataTransfer` subtracts what
		it is holding, in every SACK as well. It was 256 KB and meant nothing:
		the figure went out unchanged however much had piled up, so the peer
		was told the whole window was free right up to the point where nothing
		was.

		It has to clear `MAX_REASSEMBLY` plus `MAX_HELD`, and that is what set
		it. Those are the most one stream may have part-assembled and the most
		it may have waiting its turn, so a peer sending a message of the
		largest size this accepts would otherwise watch the window reach zero
		partway through and stop -- holding a message that can never complete,
		by obeying a limit this end published. `SctpDataTransferTest` asserts
		the relationship rather than leaving it to whoever edits one of the
		three next.
	**/
	public static inline var RECEIVE_WINDOW:Int = 2 * 1024 * 1024;

	/**
		Streams offered in each direction.

		WebRTC opens a data channel per stream pair and browsers ask for the
		full range, so a peer that offered a handful would quietly cap how many
		channels an application could open.
	**/
	public static inline var STREAM_COUNT:Int = 65535;

	/** How long before an unanswered INIT or COOKIE ECHO is sent again. **/
	public static inline var RETRY_AFTER:Float = 1.0;

	/** Attempts before the association is abandoned, RFC 4960's Max.Init.Retransmits. **/
	public static inline var MAX_ATTEMPTS:Int = 8;

	private static inline var COOKIE_LENGTH:Int = 32;
	private static inline var INIT_FIXED_LENGTH:Int = 16;

	/**
		Whether an association can be opened here.

		Tags and cookies both have to be unguessable, so this is `SecureRandom`
		under another name: a predictable verification tag is one an off-path
		attacker can stamp on its own packets.
	**/
	public static var isSupported(default, null):Bool = SecureRandom.isSupported;

	public var state(default, null):SctpAssociationState = CLOSED;

	/** This end's tag, which the peer stamps on everything it sends here. **/
	public var localTag(default, null):Int = 0;

	/** The peer's tag, stamped on everything sent to it. **/
	public var remoteTag(default, null):Int = 0;

	/** The first TSN this end will use for data. **/
	public var localTsn(default, null):Int = 0;

	/** The first TSN the peer said it would use. **/
	public var remoteTsn(default, null):Int = 0;

	/** How much unacknowledged data the peer is willing to hold. **/
	public var peerReceiveWindow(default, null):Int = 0;

	/**
		Whether the peer said it understands FORWARD TSN, RFC 3758: partial
		reliability. Until both ends have, nothing may be abandoned, and a
		channel asked to be unreliable is carried reliably instead.
	**/
	public var peerSupportsForwardTsn(default, null):Bool = false;

	/**
		Whether the peer listed RE-CONFIG among the chunks it understands,
		RFC 6525: stream reset, which is how a data channel is closed at both
		ends. Without it nothing is asked of the peer, and a channel closed here
		closes here only -- what a CrossByte peer from before 1.0 gets.
	**/
	public var peerSupportsReconfig(default, null):Bool = false;

	/** Streams the peer offered inbound and outbound. **/
	public var peerOutboundStreams(default, null):Int = 0;

	public var peerInboundStreams(default, null):Int = 0;

	/** Resolves when the association is open, fails when it cannot be. **/
	public var established(default, null):Future<SctpAssociation>;

	/** Called with a packet to hand to the DTLS transport below. **/
	public dynamic function onSend(payload:ByteArray):Void {}

	/** Chunks this handshake does not handle, passed up for the data layer. **/
	public dynamic function onChunk(chunk:SctpChunk, packet:SctpPacket):Void {}

	/**
		Called once a packet whose chunks went to `onChunk` has been read to
		the end.

		For the data layer, which decides what to send back once per packet
		rather than once per chunk: an acknowledgement for several DATA chunks
		is one SACK, and data the acknowledgement made room for goes out in the
		same packet as the next one owed.
	**/
	public dynamic function onPacketEnd():Void {}

	/**
		The time the most recent `receive` or `poll` was given.

		What the layer above measures an arriving acknowledgement against. It
		reaches that layer through `onChunk`, which is not handed a time, and a
		round trip measured from the previous poll instead would be off by up
		to a whole tick.
	**/
	public var clock(default, null):Float = 0;

	/**
		Called once when an association that was established ends from the far
		side or from a fault: the peer's ABORT, or the peer no longer answering.
		Not called for `close()` or `abort()`, which the caller already knows
		about.

		An ABORT used to close the association without a word to anyone above
		it. The channels on top went on reporting themselves open, and the
		first sign anything had happened was a `send` that threw.
	**/
	public dynamic function onClose(reason:String):Void {}

	/**
		Whether everything the layer above was given has been sent and
		acknowledged.

		A peer's SHUTDOWN is answered only once it has: RFC 4960 section 9.2
		has what is outstanding delivered first, so a graceful close does not
		lose the last messages. The data layer answers; with none attached
		there is nothing to wait for.
	**/
	public dynamic function drained():Bool {
		return true;
	}

	/** The ABORT flag saying its tag is the sender's own, reflected. **/
	@:noCompletion private static inline var FLAG_TAG_REFLECTED:Int = 0x01;

	/** RFC 4960 section 3.3.10.12: the reason an upper layer gave for aborting. **/
	@:noCompletion private static inline var CAUSE_USER_ABORT:Int = 12;

	@:noCompletion private static inline var MAX_ABORT_REASON:Int = 256;

	@:noCompletion private var __attempts:Int = 0;
	@:noCompletion private var __retryAt:Float = 0;
	@:noCompletion private var __cookie:ByteArray;
	@:noCompletion private var __issuedCookie:ByteArray;
	@:noCompletion private var __closed:Bool = false;

	public function new() {
		established = new Future<SctpAssociation>();
	}

	/**
		Opens the association, as the side that asks.

		Exactly one peer does this. In WebRTC the DTLS client takes the role,
		which follows the controlling ICE agent, so the choice has already been
		made twice before it reaches here.
	**/
	public function associate(now:Float):Void {
		if (__closed || state != CLOSED) {
			return;
		}

		localTag = __tag();
		localTsn = __tag();
		state = COOKIE_WAIT;
		__attempts = 0;
		__sendInit(now);
	}

	/**
		Waits for a peer to open the association, as the side that is asked.

		Nothing is sent until an INIT arrives -- which is the arrangement that
		lets this side hold no state for an association that was never really
		requested.
	**/
	public function listen():Void {
		if (__closed || state != CLOSED) {
			return;
		}

		localTag = __tag();
		localTsn = __tag();
		state = LISTENING;
	}

	public function poll(now:Float):Void {
		clock = now;

		if (__closed) {
			return;
		}

		// Data still going out when the peer asked to shut down: answered the
		// moment the last of it is acknowledged.
		if (state == SHUTDOWN_RECEIVED) {
			__answerShutdownIfDrained(now);
			return;
		}

		if (now < __retryAt) {
			return;
		}

		if (state == SHUTDOWN_ACK_SENT) {
			// The peer asked to go and never confirmed the answer. It is gone
			// either way.
			if (__attempts >= MAX_ATTEMPTS) {
				__end("The peer shut the association down.", false);
				return;
			}

			__sendShutdownAck(now);
			return;
		}

		if (state != COOKIE_WAIT && state != COOKIE_ECHOED) {
			return;
		}

		if (__attempts >= MAX_ATTEMPTS) {
			__fail("The peer did not answer after " + MAX_ATTEMPTS + " attempts, so no association was opened.");
			return;
		}

		if (state == COOKIE_WAIT) {
			__sendInit(now);
		} else {
			__sendCookieEcho(now);
		}
	}

	/**
		Offers an arriving packet to the association.

		@return Whether it was SCTP for this association. A packet whose tag
		does not match belongs to something else and is refused rather than
		acted on.
	**/
	public function receive(payload:ByteArray, now:Float):Bool {
		if (__closed) {
			return false;
		}

		var packet = SctpPacket.decode(payload);

		if (packet == null) {
			return false;
		}

		clock = now;

		var passedUp:Bool = false;

		for (chunk in packet.chunks) {
			switch (chunk.type) {
				case SctpPacket.CHUNK_INIT:
					__onInit(chunk, packet, now);
				case SctpPacket.CHUNK_INIT_ACK:
					__onInitAck(chunk, packet, now);
				case SctpPacket.CHUNK_COOKIE_ECHO:
					__onCookieEcho(chunk, packet, now);
				case SctpPacket.CHUNK_COOKIE_ACK:
					__onCookieAck(packet);
				case SctpPacket.CHUNK_ABORT:
					// RFC 4960 section 8.5.1: this association's own tag, or the
					// peer's reflected back with the T bit saying so. Anything
					// else is an ABORT for an association that is not this one.
					if (__tagOrReflected(chunk, packet)) {
						__end("The peer aborted the association" + __abortReason(chunk) + ".", false);
					}

					return true;
				case SctpPacket.CHUNK_HEARTBEAT:
					// RFC 4960 section 8.3: answered at once, with what it
					// carried copied back unchanged. It never was, and a peer
					// that hears no answer counts a failed path -- so a channel
					// that only received, from a browser whose stack probes idle
					// paths, was torn down after a few minutes of quiet.
					if (__up() && __tagMatches(packet)) {
						onSend(packetFor([new SctpChunk(SctpPacket.CHUNK_HEARTBEAT_ACK, 0, chunk.value)]));
					}
				case SctpPacket.CHUNK_SHUTDOWN:
					// RFC 4960 section 9.2: the peer has finished sending and
					// wants to go. Its cumulative acknowledgement goes to the
					// layer above like a SACK's, and the answer waits for what
					// this end still has outstanding.
					if ((state == ESTABLISHED || state == SHUTDOWN_RECEIVED) && __tagMatches(packet)) {
						state = SHUTDOWN_RECEIVED;
						passedUp = true;
						onChunk(chunk, packet);
					} else if (state == SHUTDOWN_ACK_SENT && __tagMatches(packet)) {
						// The answer was lost, and the peer is asking again.
						__sendShutdownAck(now);
					}
				case SctpPacket.CHUNK_SHUTDOWN_COMPLETE:
					if (state == SHUTDOWN_ACK_SENT && __tagOrReflected(chunk, packet)) {
						__end("The peer shut the association down.", false);
						return true;
					}
				default:
					// Everything else -- DATA and SACK -- is for the layer above,
					// which is where it goes once established, and while a
					// shutdown the peer asked for is finishing what was sent.
					if ((state == ESTABLISHED || state == SHUTDOWN_RECEIVED) && __tagMatches(packet)) {
						passedUp = true;
						onChunk(chunk, packet);
					}
			}
		}

		// A chunk handed up may have ended the association -- a SACK can tell
		// the layer above the peer is gone -- and then nothing is owed.
		if (passedUp && !__closed) {
			onPacketEnd();
		}

		// The acknowledgement that just arrived may have been of the last of it.
		if (state == SHUTDOWN_RECEIVED) {
			__answerShutdownIfDrained(now);
		}

		return true;
	}

	public function close():Void {
		__closed = true;
		state = CLOSED;

		// Nothing settled `established` on a close. Every other path that does
		// runs from the handshake, and closing is what stops it.
		@:privateAccess established.__cancel("The association was closed before it was established.");
	}

	/**
		Ends the association and tells the peer, with an ABORT.

		What `close()` does, plus the one packet that saves the peer from
		finding out on its own -- which, for a peer relying on retransmission
		limits, takes the better part of a minute. Sent only once the peer's
		tag is known: an ABORT stamped with anything else is discarded.

		@param reason Carried to the peer as an upper-layer abort reason, which
		is what a browser logs.
	**/
	public function abort(?reason:String):Void {
		if (__closed) {
			return;
		}

		__sendAbort(reason);
		close();
	}

	/**
		Ends the association because it cannot go on, telling the peer when
		`notifyPeer` and whoever is above through `onClose`.

		For the layer above, which is where the faults an established
		association dies of are noticed -- data the peer stopped acknowledging.
	**/
	@:allow(crossbyte.net.rtc._internal.sctp)
	@:noCompletion private function __end(reason:String, notifyPeer:Bool):Void {
		if (__closed) {
			return;
		}

		var wasEstablished:Bool = __up();

		if (notifyPeer) {
			__sendAbort(reason);
		}

		// Before close(), for the same reason as DtlsTransport: close() settles
		// this future too, Future.__fail is idempotent, and the specific reason
		// should be the one that survives.
		if (!wasEstablished) {
			@:privateAccess established.__fail(reason, null);
		}

		close();

		if (wasEstablished) {
			onClose(reason);
		}
	}

	/** Builds a packet addressed to the peer, with the right tag already on it. **/
	public function packetFor(chunks:Array<SctpChunk>):ByteArray {
		return new SctpPacket(DEFAULT_PORT, DEFAULT_PORT, remoteTag, chunks).encode();
	}

	// ------------------------------------------------------------------

	@:noCompletion private function __sendInit(now:Float):Void {
		__attempts++;
		__retryAt = now + RETRY_AFTER * __attempts;

		var value = __initBody(localTag, localTsn);

		// The one packet sent with a zero verification tag, because this side
		// has not been told the peer's yet and there is nothing else to put
		// there.
		var packet = new SctpPacket(DEFAULT_PORT, DEFAULT_PORT, 0, [new SctpChunk(SctpPacket.CHUNK_INIT, 0, value)]);
		onSend(packet.encode());
	}

	@:noCompletion private function __sendCookieEcho(now:Float):Void {
		if (__cookie == null) {
			return;
		}

		__attempts++;
		__retryAt = now + RETRY_AFTER * __attempts;

		onSend(packetFor([new SctpChunk(SctpPacket.CHUNK_COOKIE_ECHO, 0, __cookie)]));
	}

	@:noCompletion private function __onInit(chunk:SctpChunk, packet:SctpPacket, now:Float):Void {
		if (state != LISTENING && state != ESTABLISHED) {
			return;
		}

		var init = __readInit(chunk);

		if (init == null || init.tag == 0) {
			// A zero initiate tag is malformed: it is the value that means "no
			// association yet", so a peer claiming it as its own would make
			// every later packet unverifiable.
			return;
		}

		remoteTag = init.tag;
		remoteTsn = init.tsn;
		peerReceiveWindow = init.window;
		peerOutboundStreams = init.outbound;
		peerInboundStreams = init.inbound;

		// The state this side would otherwise have to hold, handed to the peer
		// to carry instead. Random and remembered rather than signed, because
		// there is exactly one association per DTLS session here and the
		// session already proved who the peer is.
		__issuedCookie = __random(COOKIE_LENGTH);

		peerSupportsForwardTsn = __offersForwardTsn(chunk);
		peerSupportsReconfig = __offersExtension(chunk, SctpPacket.CHUNK_RECONFIG);

		var value = __initBody(localTag, localTsn);
		value.position = value.length;
		SctpParameter.writeAll(value, [new SctpParameter(SctpParameter.STATE_COOKIE, __issuedCookie)]);
		value.position = 0;

		onSend(packetFor([new SctpChunk(SctpPacket.CHUNK_INIT_ACK, 0, value)]));
	}

	@:noCompletion private function __onInitAck(chunk:SctpChunk, packet:SctpPacket, now:Float):Void {
		if (state != COOKIE_WAIT) {
			return;
		}

		// Addressed to the tag this side sent in its INIT, which is what makes
		// it an answer to that INIT and not to somebody else's.
		if (packet.verificationTag != localTag) {
			return;
		}

		var init = __readInit(chunk);

		if (init == null || init.tag == 0) {
			return;
		}

		var parameters = SctpParameter.readAll(chunk.value, INIT_FIXED_LENGTH, chunk.value.length);
		var cookie = SctpParameter.find(parameters, SctpParameter.STATE_COOKIE);

		if (cookie == null) {
			__fail("The peer's INIT ACK carried no state cookie, so there is nothing to echo back.");
			return;
		}

		remoteTag = init.tag;
		remoteTsn = init.tsn;
		peerReceiveWindow = init.window;
		peerOutboundStreams = init.outbound;
		peerInboundStreams = init.inbound;
		peerSupportsForwardTsn = __offersForwardTsn(chunk);
		peerSupportsReconfig = __offersExtension(chunk, SctpPacket.CHUNK_RECONFIG);
		__cookie = cookie.value;

		state = COOKIE_ECHOED;
		__attempts = 0;
		__sendCookieEcho(now);
	}

	@:noCompletion private function __onCookieEcho(chunk:SctpChunk, packet:SctpPacket, now:Float):Void {
		if (__issuedCookie == null || packet.verificationTag != localTag) {
			return;
		}

		// Compared without a short circuit: a cookie is a secret the peer had
		// to be given, and returning as soon as two bytes differ reports in its
		// timing how much of a guess was right.
		if (!__sameBytes(chunk.value, __issuedCookie)) {
			return;
		}

		onSend(packetFor([new SctpChunk(SctpPacket.CHUNK_COOKIE_ACK, 0)]));
		__establish();
	}

	@:noCompletion private function __onCookieAck(packet:SctpPacket):Void {
		if (state != COOKIE_ECHOED || packet.verificationTag != localTag) {
			return;
		}

		__establish();
	}

	@:noCompletion private function __establish():Void {
		if (state == ESTABLISHED) {
			return;
		}

		state = ESTABLISHED;
		__retryAt = 0;
		@:privateAccess established.__resolve(this);
	}

	@:noCompletion private function __fail(reason:String):Void {
		__end(reason, false);
	}

	@:noCompletion private function __tagMatches(packet:SctpPacket):Bool {
		return packet.verificationTag == localTag;
	}

	/**
		The rule RFC 4960 section 8.5.1 gives an ABORT and a SHUTDOWN COMPLETE:
		this association's own tag, or the peer's reflected with the T bit set.
	**/
	@:noCompletion private function __tagOrReflected(chunk:SctpChunk, packet:SctpPacket):Bool {
		if ((chunk.flags & FLAG_TAG_REFLECTED) != 0) {
			return remoteTag != 0 && packet.verificationTag == remoteTag;
		}

		return localTag != 0 && packet.verificationTag == localTag;
	}

	/** Established, or finishing a shutdown the peer asked for. **/
	@:noCompletion private inline function __up():Bool {
		return state == ESTABLISHED || state == SHUTDOWN_RECEIVED || state == SHUTDOWN_ACK_SENT;
	}

	@:noCompletion private function __answerShutdownIfDrained(now:Float):Void {
		if (!drained()) {
			return;
		}

		state = SHUTDOWN_ACK_SENT;
		__attempts = 0;
		__sendShutdownAck(now);
	}

	@:noCompletion private function __sendShutdownAck(now:Float):Void {
		__attempts++;
		__retryAt = now + RETRY_AFTER * __attempts;
		onSend(packetFor([new SctpChunk(SctpPacket.CHUNK_SHUTDOWN_ACK, 0)]));
	}

	/**
		The reason inside an ABORT, when the peer gave one, as the tail of a
		sentence. A browser closing a connection says so, and passing that on
		costs a few bytes and saves a guess.
	**/
	@:noCompletion private function __abortReason(chunk:SctpChunk):String {
		var value = chunk.value;

		if (value == null || value.length < 4) {
			return "";
		}

		value.endian = Endian.BIG_ENDIAN;
		value.position = 0;

		var code:Int = value.readUnsignedShort();
		var length:Int = value.readUnsignedShort();

		if (code != CAUSE_USER_ABORT || length <= 4 || length > value.length) {
			return " (cause " + code + ")";
		}

		// Printable ASCII only. It is the peer's text, and a NUL in it would
		// hide whatever follows it in a report.
		var text = new StringBuf();

		for (_ in 0...(length - 4)) {
			var byte:Int = value.readUnsignedByte();
			text.addChar(byte >= 0x20 && byte < 0x7F ? byte : "?".code);
		}

		return ": " + text.toString();
	}

	@:noCompletion private function __sendAbort(reason:Null<String>):Void {
		// Without the peer's tag there is nothing to stamp this with that it
		// would accept.
		if (remoteTag == 0) {
			return;
		}

		var value = new ByteArray();
		value.endian = Endian.BIG_ENDIAN;

		if (reason != null && reason.length > 0) {
			var text = new ByteArray();
			text.writeUTFBytes(reason);

			// A reason is for a log line, and the packet has to fit a datagram.
			var length:Int = text.length > MAX_ABORT_REASON ? MAX_ABORT_REASON : text.length;

			value.writeShort(CAUSE_USER_ABORT);
			value.writeShort(4 + length);
			value.writeBytes(text, 0, length);
			value.position = 0;
		}

		onSend(packetFor([new SctpChunk(SctpPacket.CHUNK_ABORT, 0, value)]));
	}

	/**
		The fixed part every INIT and INIT ACK begins with, and the extensions
		this end supports after it.

		Partial reliability, RFC 3758, said twice over: the parameter that
		says so, and the chunk type listed as a supported extension, which is
		how RFC 5061 has a sender name the chunks it understands. A browser
		looks for both. Without them it may not abandon anything it sends here
		-- a channel opened with `maxRetransmits: 0` was silently made
		reliable -- and nothing sent from here may be abandoned either.

		And RE-CONFIG, RFC 6525, listed beside it: stream reset, which is how a
		data channel closes at both ends. A peer that does not see it listed
		resets nothing toward this end, so a browser closing a channel had no
		way to say so.
	**/
	@:noCompletion private function __initBody(tag:Int, tsn:Int):ByteArray {
		var value = new ByteArray();
		value.endian = Endian.BIG_ENDIAN;
		value.writeInt(tag);
		value.writeInt(RECEIVE_WINDOW);
		value.writeShort(STREAM_COUNT);
		value.writeShort(STREAM_COUNT);
		value.writeInt(tsn);

		var extensions = new ByteArray();
		extensions.writeByte(SctpPacket.CHUNK_FORWARD_TSN);
		extensions.writeByte(SctpPacket.CHUNK_RECONFIG);

		SctpParameter.writeAll(value, [
			new SctpParameter(SctpParameter.FORWARD_TSN_SUPPORTED),
			new SctpParameter(SctpParameter.SUPPORTED_EXTENSIONS, extensions)
		]);

		return value;
	}

	/** Whether an INIT or INIT ACK says its sender understands FORWARD TSN, either way RFC 3758 and RFC 5061 allow. **/
	@:noCompletion private function __offersForwardTsn(chunk:SctpChunk):Bool {
		var parameters = SctpParameter.readAll(chunk.value, INIT_FIXED_LENGTH, chunk.value.length);

		if (SctpParameter.find(parameters, SctpParameter.FORWARD_TSN_SUPPORTED) != null) {
			return true;
		}

		return __offersExtension(chunk, SctpPacket.CHUNK_FORWARD_TSN);
	}

	/** Whether an INIT or INIT ACK lists `chunkType` among its Supported Extensions, RFC 5061's way of saying so. **/
	@:noCompletion private function __offersExtension(chunk:SctpChunk, chunkType:Int):Bool {
		var parameters = SctpParameter.readAll(chunk.value, INIT_FIXED_LENGTH, chunk.value.length);
		var extensions = SctpParameter.find(parameters, SctpParameter.SUPPORTED_EXTENSIONS);

		if (extensions != null) {
			extensions.value.position = 0;

			for (_ in 0...extensions.value.length) {
				if (extensions.value.readUnsignedByte() == chunkType) {
					return true;
				}
			}
		}

		return false;
	}

	@:noCompletion private function __readInit(chunk:SctpChunk):Null<{tag:Int, window:Int, outbound:Int, inbound:Int, tsn:Int}> {
		if (chunk == null || chunk.value.length < INIT_FIXED_LENGTH) {
			return null;
		}

		chunk.value.endian = Endian.BIG_ENDIAN;
		chunk.value.position = 0;

		return {
			tag: chunk.value.readInt(),
			window: chunk.value.readInt(),
			outbound: chunk.value.readUnsignedShort(),
			inbound: chunk.value.readUnsignedShort(),
			tsn: chunk.value.readInt()
		};
	}

	@:noCompletion private static function __sameBytes(a:ByteArray, b:ByteArray):Bool {
		if (a == null || b == null || a.length != b.length) {
			return false;
		}

		a.position = 0;
		b.position = 0;

		var difference:Int = 0;

		for (_ in 0...a.length) {
			difference = difference | (a.readUnsignedByte() ^ b.readUnsignedByte());
		}

		return difference == 0;
	}

	@:noCompletion private static function __random(length:Int):ByteArray {
		return SecureRandom.getSecureRandomBytes(length);
	}

	/**
		A verification tag, which must not be zero.

		Zero is the value that means "no association yet", so a tag of zero
		would make every packet stamped with it unverifiable.
	**/
	@:noCompletion private static function __tag():Int {
		var bytes:ByteArray = SecureRandom.getSecureRandomBytes(4);
		bytes.endian = Endian.BIG_ENDIAN;
		bytes.position = 0;

		var tag:Int = bytes.readInt();

		return tag == 0 ? 1 : tag;
	}
}
