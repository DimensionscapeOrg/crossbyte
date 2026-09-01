package crossbyte.net._internal.stun;

import crossbyte.io.ByteArray;
import crossbyte.net.ReflexiveAddress;

/**
	One question to a STUN server: its transaction, its schedule, and what an
	answer to it means.

	Three places here ask a server what address it sees -- `StunClient` on a
	socket of its own, `ReliableDatagramServerSocket` through the port it
	listens on, and `PeerConnection` through the socket ICE and DTLS already
	share. The transport differs in each, genuinely and irreducibly. Everything
	else was the same three times over: a transaction to match a reply against,
	a doubling retransmission schedule, a deadline, and the handful of ways a
	reply can be unhelpful.

	Keeping one copy is not tidiness. The retransmission this schedule
	implements had to be added to two of those by hand, and the second was
	nearly missed; the class of bug this session has met repeatedly is one place
	knowing something another does not.

	No socket, no clock, no events -- times arrive as arguments and datagrams as
	bytes -- so the interpretation can be tested directly on every target rather
	than only through three socket-bound paths.
**/
class StunQuery {
	/**
		The first gap before asking again, doubling after each, from RFC 5389.

		A question asked once over UDP is a question lost to one dropped
		datagram, and the loss is reported as a server that is not there --
		which sends whoever reads it looking at their configuration for a fault
		that is not in it.
	**/
	public static inline var RETRANSMIT_FIRST:Float = 0.5;

	/** The request, whose transaction is what a reply is believed by. **/
	public var request(default, null):StunMessage;

	@:noCompletion private var __deadline:Float;
	@:noCompletion private var __nextAttempt:Float;
	@:noCompletion private var __interval:Float;

	/**
		@param now The caller's clock, whatever it consistently uses.
		@param timeoutMs How long to keep asking. Non-positive means three
		seconds, which is what every caller here passed for it.
	**/
	public function new(now:Float, timeoutMs:Int) {
		request = StunMessage.bindingRequest();
		__deadline = now + (timeoutMs > 0 ? timeoutMs / 1000 : 3.0);
		__interval = RETRANSMIT_FIRST;
		__nextAttempt = now + __interval;
	}

	/** Whether the time allowed has run out. **/
	public inline function expired(now:Float):Bool {
		return now >= __deadline;
	}

	/**
		Whether it is time to ask again, and books the next attempt if so.

		Asking again means resending the *same* request: a reply to any attempt
		answers the question, and a fresh transaction each time would leave
		earlier answers unrecognisable.
	**/
	public function shouldRetransmit(now:Float):Bool {
		if (now < __nextAttempt) {
			return false;
		}

		__interval *= 2;
		__nextAttempt = now + __interval;
		return true;
	}

	/**
		What an inbound datagram means for this question.

		`NOT_OURS` for anything that is not a reply to this exact request --
		another peer's connectivity check, a relay's answer, a stray packet.
		The transaction is ninety-six bits chosen at random per request and is
		the whole of what stops a third party who can reach the port from
		handing this host an address of their choosing, which it would then
		advertise to peers as its own.
	**/
	public function interpret(payload:ByteArray):StunQueryOutcome {
		var response = StunMessage.decode(payload);

		if (response == null || !request.matches(response)) {
			return NOT_OURS;
		}

		if (response.type == StunMessage.BINDING_ERROR) {
			return REFUSED(response.errorMessage());
		}

		if (response.type != StunMessage.BINDING_SUCCESS) {
			// Some other reply carrying this transaction. Not an answer, and
			// not somebody else's either, so there is nothing to do but wait.
			return NOT_OURS;
		}

		var address = response.mappedAddress();

		// A success with no address is a server that answered without
		// answering. Saying so beats waiting out the deadline and then blaming
		// the network for a server that replied promptly and unhelpfully.
		return address != null ? ANSWERED(address) : ANSWERED_WITHOUT_ADDRESS;
	}
}

/** What a datagram turned out to be. **/
enum StunQueryOutcome {
	/** Not a reply to this question; keep waiting. **/
	NOT_OURS;

	/** The address this host appears at. **/
	ANSWERED(address:ReflexiveAddress);

	/** The server refused, with its reason where it gave one. **/
	REFUSED(reason:Null<String>);

	/** A success carrying no mapped address. **/
	ANSWERED_WITHOUT_ADDRESS;
}
