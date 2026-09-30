package crossbyte.net;

import crossbyte.io.ByteArray;
import crossbyte.net._internal.stun.StunMessage;
import crossbyte.net._internal.stun.StunMessage.StunAttribute;
import crossbyte.net._internal.stun.StunQuery;
import utest.Assert;

/**
	What a STUN answer means, and when to ask again.

	Three places ask a server what address it sees, a socket of its own, a
	listening reliable-datagram port, and the socket a peer connection already
	shares with ICE and DTLS, and until this class existed each carried its own
	copy of the reading and the schedule. The transports differ irreducibly; the
	semantics never did, and the copies were a standing invitation for a fix to
	reach two of three. One did: the retransmission was added by hand twice and
	the second was nearly missed.

	No socket and no clock here, times being arguments, so these hold on every
	target rather than only where UDP exists, which is more than the
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
		reach the port from handing this host an address of their choosing,
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

	/**
		An answer whose FINGERPRINT does not match is not an answer.

		RFC 8489 section 7.3 has such a message dropped: damaged on the way, or
		not STUN at all however it looks. It was believed, transaction and
		all, so a mangled datagram could settle the question with whatever
		address it now carried. Dropped, it leaves the question open for the
		sound answer behind it.
	**/
	public function testAnAnswerWithABadFingerprintIsNotBelieved():Void {
		if (unsupported()) return;

		var query = new StunQuery(0, 3000);
		var damaged = fingerprinted(new StunMessage(StunMessage.BINDING_SUCCESS, query.request.transactionId,
			[StunMessage.xorMappedAddress("192.0.2.66", 9999)]), true);

		Assert.equals(NOT_OURS, query.interpret(damaged), "an answer with a bad FINGERPRINT was taken");
		Assert.isNull(query.answer, "an answer with a bad FINGERPRINT was kept");

		// And counted, so a deadline passing can say the answers came damaged
		// rather than that none came.
		Assert.equals(1, query.damaged);
		var damage = query.damage();
		Assert.isTrue(damage != null && damage.indexOf("FINGERPRINT") >= 0, "the damage should be named: " + damage);

		var sound = fingerprinted(new StunMessage(StunMessage.BINDING_SUCCESS, query.request.transactionId,
			[StunMessage.xorMappedAddress("198.51.100.42", 51234)]), false);

		switch (query.interpret(sound)) {
			case ANSWERED(address):
				Assert.equals("198.51.100.42", address.address);
				Assert.notNull(query.answer, "the answer taken was not kept for its other attributes");
			case other:
				Assert.fail("a sound answer after a damaged one was not taken: " + other);
		}
	}

	/**
		An answer carrying an attribute the server requires understood, and
		this client does not, cannot be used: whatever it changes about the
		answer is exactly what cannot be seen. RFC 8489 section 7.3.3. It was
		used, address and all.

		One the server marks optional is ignored, as the same section says, so
		the check is on the range and not on strangeness.
	**/
	public function testAnAnswerRequiringAnUnknownAttributeCannotBeUsed():Void {
		if (unsupported()) return;

		var query = new StunQuery(0, 3000);
		var reply = new StunMessage(StunMessage.BINDING_SUCCESS, query.request.transactionId,
			[StunMessage.xorMappedAddress("198.51.100.42", 51234), unknownAttribute(0x7FAA)]);

		switch (query.interpret(reply.encode())) {
			case UNUSABLE(reason):
				Assert.isTrue(reason.indexOf("7FAA") >= 0, "the reason should name the attribute: " + reason);
			case other:
				Assert.fail("an answer requiring an attribute nobody here understands was taken: " + other);
		}

		var optional = new StunQuery(0, 3000);
		var tolerable = new StunMessage(StunMessage.BINDING_SUCCESS, optional.request.transactionId,
			[StunMessage.xorMappedAddress("198.51.100.42", 51234), unknownAttribute(0xFFAA)]);

		switch (optional.interpret(tolerable.encode())) {
			case ANSWERED(address):
				Assert.equals(51234, address.port);
			case other:
				Assert.fail("an answer with an optional attribute nobody here understands was refused: " + other);
		}
	}

	/**
		An IPv6 answer is an answer. The address is XORed with the
		transaction as well as the cookie, and it used to read as no address
		at all, a server that answered promptly reported as one that had
		answered without answering.
	**/
	public function testAnIPv6AnswerIsAnAnswer():Void {
		if (unsupported()) return;

		var query = new StunQuery(0, 3000);
		var reply = new StunMessage(StunMessage.BINDING_SUCCESS, query.request.transactionId,
			[StunMessage.xorMappedAddress("2001:db8::42", 51234, query.request.transactionId)]);

		switch (query.interpret(reply.encode())) {
			case ANSWERED(address):
				Assert.equals("2001:db8::42", address.address);
				Assert.equals(51234, address.port);
			case other:
				Assert.fail("an IPv6 answer was not read: " + other);
		}
	}

	/** A request can carry more: a CHANGE-REQUEST, for RFC 5780's questions. **/
	public function testARequestCarriesWhatItIsGiven():Void {
		if (unsupported()) return;

		var query = new StunQuery(0, 3000, [StunMessage.changeRequest(true, false)]);
		var sent = StunMessage.decode(query.request.encode());

		Assert.notNull(sent);
		if (sent == null) {
			return;
		}

		var change = sent.attribute(StunMessage.ATTR_CHANGE_REQUEST);
		Assert.notNull(change, "the CHANGE-REQUEST given was not sent");
		if (change != null) {
			Assert.equals(4, change.length);
			change.position = 3;
			Assert.equals(0x04, change.readUnsignedByte(), "asked to change the address and not the port");
		}
	}

	// ------------------------------------------------------------------

	/** `message` with a FINGERPRINT, or with one a bit off when `damage` is set. **/
	private static function fingerprinted(message:StunMessage, damage:Bool):ByteArray {
		var bytes = message.encode();
		@:privateAccess message.__appendFingerprint(bytes);

		if (damage) {
			bytes[bytes.length - 1] = bytes[bytes.length - 1] ^ 0x01;
		}

		bytes.position = 0;
		return bytes;
	}

	private static function unknownAttribute(type:Int):StunAttribute {
		var value = new ByteArray();

		for (_ in 0...4) {
			value.writeByte(0);
		}

		value.position = 0;
		return new StunAttribute(type, value);
	}
}
