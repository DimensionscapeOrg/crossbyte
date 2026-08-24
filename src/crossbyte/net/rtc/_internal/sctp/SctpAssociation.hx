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
		How much unacknowledged data this end is willing to hold, in bytes.

		Advertised in the INIT so the peer knows when to stop sending. A modest
		figure: a data channel is messages, not bulk transfer.
	**/
	public static inline var RECEIVE_WINDOW:Int = 262144;

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

	/** Streams the peer offered inbound and outbound. **/
	public var peerOutboundStreams(default, null):Int = 0;

	public var peerInboundStreams(default, null):Int = 0;

	/** Resolves when the association is open, fails when it cannot be. **/
	public var established(default, null):Future<SctpAssociation>;

	/** Called with a packet to hand to the DTLS transport below. **/
	public dynamic function onSend(payload:ByteArray):Void {}

	/** Chunks this handshake does not handle, passed up for the data layer. **/
	public dynamic function onChunk(chunk:SctpChunk, packet:SctpPacket):Void {}

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
		if (__closed || now < __retryAt) {
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
					__fail("The peer aborted the association.");
					return true;
				default:
					// Everything else -- DATA, SACK, HEARTBEAT -- is for the
					// layer above, which is where it goes once established.
					if (state == ESTABLISHED && __tagMatches(packet)) {
						onChunk(chunk, packet);
					}
			}
		}

		return true;
	}

	public function close():Void {
		__closed = true;
		state = CLOSED;
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

		var value = __initBody(localTag, localTsn);
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
		if (__closed) {
			return;
		}

		var wasOpen = state == ESTABLISHED;
		close();

		if (!wasOpen) {
			@:privateAccess established.__fail(reason, null);
		}
	}

	@:noCompletion private function __tagMatches(packet:SctpPacket):Bool {
		return packet.verificationTag == localTag;
	}

	/** The twenty byte fixed part every INIT and INIT ACK begins with. **/
	@:noCompletion private function __initBody(tag:Int, tsn:Int):ByteArray {
		var value = new ByteArray();
		value.endian = Endian.BIG_ENDIAN;
		value.writeInt(tag);
		value.writeInt(RECEIVE_WINDOW);
		value.writeShort(STREAM_COUNT);
		value.writeShort(STREAM_COUNT);
		value.writeInt(tsn);
		return value;
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
