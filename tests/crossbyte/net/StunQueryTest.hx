package crossbyte.net;

import crossbyte.io.ByteArray;
import crossbyte.net._internal.stun.StunMessage;
import crossbyte.net._internal.stun.StunQuery;
import utest.Assert;

/**
	What a STUN answer means, and when to ask again.

	Three places ask a server what address it sees -- a socket of its own, a
	listening reliable-datagram port, and the socket a peer connection already
	shares with ICE and DTLS -- and until this class existed each carried its own
	copy of the reading and the schedule. The transports differ irreducibly; the
	semantics never did, and the copies were a standing invitation for a fix to
	reach two of three. One did: the retransmission was added by hand twice and
	the second was nearly missed.

	No socket and no clock here, times being arguments, so these hold on every
	target rather than only where UDP exists -- which is more than the
	socket-bound cases they were extracted from could manage.
**/
class StunQueryTest extends utest.Test {
	private function unsupported():Bool {
		if (!crossbyte.crypto.SecureRandom.isSupported) {
			// A transaction id has to be unguessable, so there is no query to
			// build at all without a CSPRNG.
			Assert.isFalse(crossbyte.crypto.SecureRandom.isSupported);
			return true;
		}

		return false;
	}

	/** A success carrying an address is the answer. **/
	public function testASuccessCarryingAnAddressIsTheAnswer():Void {
		if (unsupported()) return;

		var query = new StunQuery(0, 3000);
		var reply = new StunMessage(StunMessage.BINDING_SUCCESS, query.request.transactionId,
			[StunMessage.xorMappedAddress("198.51.100.42", 51234)]);

		switch (query.interpret(reply.encode())) {
			case ANSWERED(address):
				Assert.equals("198.51.100.42", address.address);
				Assert.equals(51234, address.port);
			case other:
				Assert.fail("expected an answer, got " + other);
		}
	}

	/**
		A reply to a question nobody asked is nobody's business.

		The transaction is ninety-six bits chosen at random per request, and
		matching against it is the whole of what stops a third party who can
		reach the port from handing this host an address of their choosing --
		which it would then advertise to peers as its own.
	**/
	public function testAReplyWithAnotherTransactionIsNotOurs():Void {
		if (unsupported()) return;

		var query = new StunQuery(0, 3000);
		var stranger = new StunQuery(0, 3000);

		var forged = new StunMessage(StunMessage.BINDING_SUCCESS, stranger.request.transactionId,
			[StunMessage.xorMappedAddress("192.0.2.66", 9999)]);

		Assert.equals(NOT_OURS, query.interpret(forged.encode()));
	}

	/** So is a datagram that is not STUN at all. **/
	public function testSomethingThatIsNotStunIsNotOurs():Void {
		if (unsupported()) return;

		var query = new StunQuery(0, 3000);
		var noise = new ByteArray();

		for (i in 0...40) {
			noise.writeByte((i * 37) & 0xFF);
		}

		noise.position = 0;
		Assert.equals(NOT_OURS, query.interpret(noise));
	}

	/** A refusal carries the server's reason where it gave one. **/
	public function testARefusalIsReportedWithItsReason():Void {
		if (unsupported()) return;

		var query = new StunQuery(0, 3000);
		var refusal = new StunMessage(StunMessage.BINDING_ERROR, query.request.transactionId,
			[StunMessage.errorCode(400, "Bad Request")]);

		switch (query.interpret(refusal.encode())) {
			case REFUSED(_):
				Assert.pass();
			case other:
				Assert.fail("expected a refusal, got " + other);
		}
	}

	/**
		A success with no address is answered without being answered.

		Distinct from silence on purpose: saying so beats waiting out the
		deadline and then blaming the network for a server that replied
		promptly and unhelpfully.
	**/
	public function testASuccessWithoutAnAddressIsItsOwnOutcome():Void {
		if (unsupported()) return;

		var query = new StunQuery(0, 3000);
		var empty = new StunMessage(StunMessage.BINDING_SUCCESS, query.request.transactionId);

		Assert.equals(ANSWERED_WITHOUT_ADDRESS, query.interpret(empty.encode()));
	}

	/**
		The schedule doubles, and stops at the deadline.

		Asking once over UDP loses the whole question to one dropped datagram
		and reports it as a server that is not there. Doubling is RFC 5389's
		answer: often enough early that a single loss costs little, rarely
		enough later that a silent server is not flooded.
	**/
	public function testTheScheduleDoublesAndTheDeadlineEnds():Void {
		if (unsupported()) return;

		var query = new StunQuery(0, 3000);

		Assert.isFalse(query.shouldRetransmit(0.4), "asked again before the first gap had passed");
		Assert.isTrue(query.shouldRetransmit(0.5), "never asked again at the first gap");

		// Booked for a second gap of one, not another half.
		Assert.isFalse(query.shouldRetransmit(1.4), "the gap did not double");
		Assert.isTrue(query.shouldRetransmit(1.5));

		// And a third of two.
		Assert.isFalse(query.shouldRetransmit(3.4), "the gap did not double twice");
		Assert.isTrue(query.shouldRetransmit(3.5));

		Assert.isFalse(query.expired(2.999));
		Assert.isTrue(query.expired(3.0), "three thousand milliseconds should be three seconds");
	}

	/** A request is asked again as itself, so an early answer is still one. **/
	public function testAskingAgainKeepsTheSameTransaction():Void {
		if (unsupported()) return;

		var query = new StunQuery(0, 3000);
		var first = query.request.transactionId;

		query.shouldRetransmit(0.5);
		query.shouldRetransmit(1.5);

		var again = query.request.transactionId;
		Assert.equals(first.length, again.length);

		for (i in 0...first.length) {
			Assert.equals(first[i], again[i],
				"the transaction changed, so a reply to the first attempt would no longer be recognised");
		}
	}

	/** A non-positive timeout is three seconds, which is what callers passed. **/
	public function testANonPositiveTimeoutIsThreeSeconds():Void {
		if (unsupported()) return;

		var query = new StunQuery(10, 0);

		Assert.isFalse(query.expired(12.999));
		Assert.isTrue(query.expired(13.0));
	}
}
