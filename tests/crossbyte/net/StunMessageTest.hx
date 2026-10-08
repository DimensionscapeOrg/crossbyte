package crossbyte.net;

import crossbyte.net._internal.stun.StunMessage;
import crossbyte.net._internal.stun.StunMessage.StunAttribute;
import crossbyte.io.ByteArray;
import crossbyte.io.Endian;
import haxe.Int64;
import utest.Assert;
import crossbyte.test.Require;

/**
	The STUN wire format.

	Needs no socket (these are bytes in and bytes out), so it runs wherever
	CrossByte does, including the browser, even though the client that uses it
	needs UDP and does not.

	The XOR cases matter more than they look. `XOR-MAPPED-ADDRESS` exists
	because NATs were built that rewrote anything in a packet resembling an
	address, so an unobscured reflexive address could arrive already "corrected"
	to the private one it was sent to report on. A decoder that quietly skipped
	the XOR would still return a plausible address, and the failure would show
	up as peers unable to reach each other rather than as anything here.
**/
@:access(crossbyte.net._internal.stun.StunMessage)
class StunMessageTest extends utest.Test {
	/**
		RFC 5769 section 2.1, byte for byte.

		A sample request carrying SOFTWARE, PRIORITY, ICE-CONTROLLED, USERNAME,
		MESSAGE-INTEGRITY and FINGERPRINT, produced by an implementation that is
		not this one. That is the entire value of it: an integrity scheme can be
		perfectly self-consistent and still interoperate with nothing, and a
		round-trip test cannot tell the two apart.
	**/
	private static inline var RFC5769_REQUEST:String = "000100582112a442"
		+ "b7e7a701bc34d686fa87dfae"
		+ "80220010" + "5354554e207465737420636c69656e74"
		+ "00240004" + "6e0001ff"
		+ "80290008" + "932ff9b151263b36"
		+ "00060009" + "6576746a3a683676" + "59202020"
		+ "00080014" + "9aeaa70cbfd8cb56781ef2b5b2d3f249c1b571a2"
		+ "80280004" + "e57a3bcf";

	/** RFC 5769 section 2.2, the matching IPv4 response. **/
	private static inline var RFC5769_RESPONSE:String = "0101003c2112a442"
		+ "b7e7a701bc34d686fa87dfae"
		+ "8022000b" + "7465737420766563746f7220"
		+ "00200008" + "0001a147e112a643"
		+ "00080014" + "2b91f599fd9e90c38c7489f92af9ba53f06be7d7"
		+ "80280004" + "c07d4c96";

	/** The credential both of those were signed with. **/
	private static inline var RFC5769_PASSWORD:String = "VOkJxbRl1RmTxUk/WvJxBt";

	/**
		RFC 5769 section 2.4, the long-term credential sample.

		A different scheme from the two above, and the one TURN uses. Short-term
		credentials key the HMAC with the password itself; long-term ones key it
		with MD5 of username, realm and password joined by colons, so an
		implementation can have the integrity exactly right and still get every
		long-term exchange wrong.

		Worth pinning here rather than against a relay: the suite's TURN server is
		one this repository wrote, and it verifies a request with the very code
		that produced it, so the two would agree about a key derived wrongly. This
		is the same request produced by an implementation that is not this one.
	**/
	private static inline var RFC5769_LONG_TERM_REQUEST:String = "000100602112a442"
		+ "78ad3433c6ad72c029da412e"
		+ "00060012" + "e3839ee38388e383aae38383e382afe382b9" + "0000"
		+ "0015001c" + "662f2f3439396b39353464364f4c33346f4c39465354767936347341"
		+ "0014000b" + "6578616d706c652e6f726700"
		+ "00080014" + "f67024656dd64a3e02b8e0712e85c9a28ca89666";

	/** Six characters of Japanese, which SASLprep leaves alone. **/
	private static inline var RFC5769_LONG_TERM_USERNAME:String = "\u30DE\u30C8\u30EA\u30C3\u30AF\u30B9";

	private static inline var RFC5769_LONG_TERM_REALM:String = "example.org";

	private static inline var RFC5769_LONG_TERM_NONCE:String = "f//499k954d6OL34oL9FSTvy64sA";

	/**
		The password *after* SASLprep, which is what the key is derived from.

		The RFC writes it with a soft hyphen, a feminine ordinal and a Roman
		numeral nine, and SASLprep maps those to nothing, "a" and "IX", so an
		implementation that prepares its inputs and one that does not derive
		different keys from the same password. Nothing here prepares anything, so
		the prepared form is what is passed; see `longTermKey`.
	**/
	private static inline var RFC5769_LONG_TERM_PASSWORD:String = "TheMatrIX";

	private static function fromHex(hex:String):ByteArray {
		var bytes = new ByteArray();
		bytes.endian = Endian.BIG_ENDIAN;

		var i = 0;
		while (i < hex.length) {
			bytes.writeByte(Std.parseInt("0x" + hex.substr(i, 2)));
			i += 2;
		}

		bytes.position = 0;
		return bytes;
	}

	private static function toHex(bytes:ByteArray, from:Int, length:Int):String {
		var out = new StringBuf();
		var position = bytes.position;
		bytes.position = from;

		for (_ in 0...length) {
			var byte = bytes.readUnsignedByte();
			out.add(StringTools.hex(byte, 2).toLowerCase());
		}

		bytes.position = position;
		return out.toString();
	}

	// Fixed, so a test does not depend on a random transaction id.
	private static function transaction():ByteArray {
		var id = new ByteArray();

		for (i in 0...12) {
			id.writeByte(i + 1);
		}

		id.position = 0;
		return id;
	}

	public function testABindingRequestRoundTrips():Void {
		var request = new StunMessage(StunMessage.BINDING_REQUEST, transaction());
		var decoded = StunMessage.decode(request.encode());

		Require.notNull(decoded);
		Assert.equals(StunMessage.BINDING_REQUEST, decoded.type);
		Assert.isTrue(request.matches(decoded), "the transaction did not survive the round trip");
	}

	public function testTheHeaderIsTwentyBytesAndCarriesTheCookie():Void {
		var encoded = new StunMessage(StunMessage.BINDING_REQUEST, transaction()).encode();

		// No attributes, so the whole message is the header.
		Assert.equals(20, encoded.length);

		encoded.endian = Endian.BIG_ENDIAN;
		encoded.position = 4;
		Assert.equals(StunMessage.MAGIC_COOKIE, encoded.readInt());
	}

	public function testAXorMappedAddressDecodesToWhatWasEncoded():Void {
		var attribute = StunMessage.xorMappedAddress("192.168.1.100", 54321);
		var response = new StunMessage(StunMessage.BINDING_SUCCESS, transaction(), [attribute]);

		var decoded = StunMessage.decode(response.encode());
		Require.notNull(decoded);

		var address = decoded.mappedAddress();
		Require.notNull(address, "a success response carrying an address reported none");
		Assert.equals("192.168.1.100", address.address);
		Assert.equals(54321, address.port);
	}

	/**
		An address is written only when it is an IPv4 one, and then exactly as
		written.

		The octets must be checked, not read with `Std.parseInt` and written
		modulo 256: 1.2.3.999 would go out as 1.2.3.231; an IPv6 address as
		whatever its first group read as, which on the jvm is an exception
		rather than a number; and 010 as ten, where `inet_addr` reads it as
		octal eight.
	**/
	public function testOnlyAnIPv4AddressIsWrittenAsOne():Void {
		for (address in ["1.2.3.999", "256.0.0.1", "1.2.3.4294967296", "010.1.1.1", "1.2.3.00", "1.2.3", "1.2.3.4.5", "1.2.3.-4",
			" 1.2.3.4", "1.2.3.4 ", "1..3.4", "fe80::1", "::ffff:1.2.3.4", "", null]) {
			Assert.equals("null", octets(address), "\"" + address + "\" was read as an IPv4 address");
			Assert.raises(() -> StunMessage.xorMappedAddress(address, 1), crossbyte.errors.ArgumentError,
				"\"" + address + "\" was written as an IPv4 address");
		}

		Assert.equals("0,0,0,0", octets("0.0.0.0"));
		Assert.equals("255,255,255,255", octets("255.255.255.255"));
		Assert.equals("10,0,0,1", octets("10.0.0.1"));

		for (address in ["0.0.0.0", "255.255.255.255", "10.0.0.1"]) {
			var response = new StunMessage(StunMessage.BINDING_SUCCESS, transaction(), [StunMessage.xorMappedAddress(address, 65535)]);
			var decoded = StunMessage.decode(response.encode());
			Require.notNull(decoded);

			var mapped = decoded.mappedAddress();
			Require.notNull(mapped);
			Assert.equals(address, mapped.address);
			Assert.equals(65535, mapped.port);
		}
	}

	private static function octets(address:String):String {
		var read = StunMessage.ipv4Octets(address);
		return read == null ? "null" : read.join(",");
	}

	public function testTheAddressIsActuallyObscuredOnTheWire():Void {
		// Computed from RFC 5389 rather than from the encoder: X-Port is the
		// port XOR the top half of the cookie, and each address octet is XORed
		// with the cookie byte at its own position. If the encoder ever stopped
		// XORing, the round-trip case above would still pass (decode would
		// simply undo nothing twice), and only this one would notice.
		var attribute = StunMessage.xorMappedAddress("192.168.1.100", 54321);

		attribute.value.endian = Endian.BIG_ENDIAN;
		attribute.value.position = 2;

		Assert.equals(54321 ^ 0x2112, attribute.value.readUnsignedShort());
		Assert.equals(192 ^ 0x21, attribute.value.readUnsignedByte());
		Assert.equals(168 ^ 0x12, attribute.value.readUnsignedByte());
		Assert.equals(1 ^ 0xA4, attribute.value.readUnsignedByte());
		Assert.equals(100 ^ 0x42, attribute.value.readUnsignedByte());
	}

	public function testAPlainMappedAddressIsReadWhenItIsAllThereIs():Void {
		// The pre-RFC-5389 attribute, which some servers still send alongside
		// the XOR form. Read as a fallback so an older server is usable, but
		// only as a fallback.
		var value = new ByteArray();
		value.endian = Endian.BIG_ENDIAN;
		value.writeByte(0);
		value.writeByte(0x01);
		value.writeShort(3478);
		value.writeByte(203);
		value.writeByte(0);
		value.writeByte(113);
		value.writeByte(7);
		value.position = 0;

		var response = new StunMessage(StunMessage.BINDING_SUCCESS, transaction(), [new StunAttribute(StunMessage.ATTR_MAPPED_ADDRESS, value)]);
		var address = StunMessage.decode(response.encode()).mappedAddress();

		Require.notNull(address);
		Assert.equals("203.0.113.7", address.address);
		Assert.equals(3478, address.port);
	}

	public function testTheXorFormWinsOverThePlainOne():Void {
		var plain = new ByteArray();
		plain.endian = Endian.BIG_ENDIAN;
		plain.writeByte(0);
		plain.writeByte(0x01);
		plain.writeShort(1111);
		plain.writeByte(10);
		plain.writeByte(0);
		plain.writeByte(0);
		plain.writeByte(1);
		plain.position = 0;

		// A NAT that rewrote the plain attribute would leave the private
		// address there. The XOR form is the one to believe.
		var response = new StunMessage(StunMessage.BINDING_SUCCESS, transaction(), [
			new StunAttribute(StunMessage.ATTR_MAPPED_ADDRESS, plain),
			StunMessage.xorMappedAddress("198.51.100.9", 2222)
		]);

		var address = StunMessage.decode(response.encode()).mappedAddress();

		Assert.equals("198.51.100.9", address.address);
		Assert.equals(2222, address.port);
	}

	public function testAttributesSurviveThePaddingRules():Void {
		// Three bytes of value, so one byte of padding that is not counted in
		// the attribute's length. Getting that wrong shifts every attribute
		// after it, which is why a message with two of them is used here.
		var odd = new ByteArray();
		odd.writeByte(0xAA);
		odd.writeByte(0xBB);
		odd.writeByte(0xCC);
		odd.position = 0;

		var response = new StunMessage(StunMessage.BINDING_SUCCESS, transaction(), [
			new StunAttribute(0x8022, odd),
			StunMessage.xorMappedAddress("203.0.113.42", 40404)
		]);

		var decoded = StunMessage.decode(response.encode());
		Require.notNull(decoded);
		Assert.equals(2, decoded.attributes.length);

		var address = decoded.mappedAddress();
		Require.notNull(address, "the attribute after an odd-length one was lost to padding");
		Assert.equals("203.0.113.42", address.address);
		Assert.equals(40404, address.port);
	}

	public function testARepliesTransactionIsCheckedRatherThanAssumed():Void {
		var mine = new StunMessage(StunMessage.BINDING_REQUEST, transaction());

		var theirs = new ByteArray();
		for (i in 0...12) {
			theirs.writeByte(0xF0 + i);
		}
		theirs.position = 0;

		// A datagram socket accepts from anyone. A response carrying somebody
		// else's transaction is a stray at best, and at worst an attempt to
		// hand this peer an address of the sender's choosing, which the mesh
		// would then publish and every other peer would dial.
		Assert.isFalse(mine.matches(new StunMessage(StunMessage.BINDING_SUCCESS, theirs)));
	}

	public function testNoiseIsRejectedRatherThanParsed():Void {
		Assert.isNull(StunMessage.decode(null));
		Assert.isNull(StunMessage.decode(new ByteArray()), "an empty buffer parsed as a message");

		var tooShort = new ByteArray();
		for (i in 0...12) {
			tooShort.writeByte(i);
		}
		Assert.isNull(StunMessage.decode(tooShort), "a buffer shorter than the header parsed as a message");

		// Right length, wrong cookie: this is how unrelated UDP traffic on a
		// bound port is told from a STUN message.
		var wrongCookie = new ByteArray();
		wrongCookie.endian = Endian.BIG_ENDIAN;
		wrongCookie.writeShort(StunMessage.BINDING_SUCCESS);
		wrongCookie.writeShort(0);
		wrongCookie.writeInt(0xDEADBEEF);
		for (i in 0...12) {
			wrongCookie.writeByte(i);
		}
		Assert.isNull(StunMessage.decode(wrongCookie), "a message without the magic cookie was accepted");
	}

	public function testATruncatedBodyIsNotReadPast():Void {
		// The header promises forty bytes of attributes and the datagram holds
		// none. Reading on would return whatever the buffer happened to have.
		var truncated = new ByteArray();
		truncated.endian = Endian.BIG_ENDIAN;
		truncated.writeShort(StunMessage.BINDING_SUCCESS);
		truncated.writeShort(40);
		truncated.writeInt(StunMessage.MAGIC_COOKIE);
		for (i in 0...12) {
			truncated.writeByte(i);
		}

		Assert.isNull(StunMessage.decode(truncated), "a message claiming more body than it carried was accepted");
	}

	public function testAnErrorResponseReportsItsCode():Void {
		var value = new ByteArray();
		value.endian = Endian.BIG_ENDIAN;
		value.writeShort(0);
		value.writeByte(4);
		value.writeByte(1);
		value.writeUTFBytes("Unauthorized");
		value.position = 0;

		var response = new StunMessage(StunMessage.BINDING_ERROR, transaction(), [new StunAttribute(StunMessage.ATTR_ERROR_CODE, value)]);
		var reported = StunMessage.decode(response.encode()).errorMessage();

		Require.notNull(reported);
		Assert.isTrue(reported.indexOf("401") == 0, "got " + reported);
		Assert.isTrue(reported.indexOf("Unauthorized") > 0, "got " + reported);
	}

	// ------------------------------------------------------------------
	/**
		The key a long-term credential produces, against the published sample.

		MD5 of "username:realm:password", and every part of that is a decision
		something else has to have made the same way: the order, the colons, and
		that it is the raw digest rather than its hex.
	**/
	public function testTheLongTermKeyMatchesThePublishedSample():Void {
		var key = StunMessage.longTermKey(RFC5769_LONG_TERM_USERNAME, RFC5769_LONG_TERM_REALM, RFC5769_LONG_TERM_PASSWORD);

		Require.notNull(key);
		Assert.equals(16, key.length);
		Assert.equals("e8ca7ad59d5eb0518e312911d2dab2a9", key.toHex());
	}

	/** And a message signed with it verifies. **/
	public function testTheLongTermSampleVerifies():Void {
		var message = StunMessage.decode(fromHex(RFC5769_LONG_TERM_REQUEST));

		Assert.notNull(message);

		if (message == null) {
			return;
		}

		var key = StunMessage.longTermKey(RFC5769_LONG_TERM_USERNAME, RFC5769_LONG_TERM_REALM, RFC5769_LONG_TERM_PASSWORD);

		Assert.isTrue(message.verifyIntegrityWithKey(key),
			"the RFC 5769 long-term sample did not verify, so no relay would accept anything signed here");

		Assert.equals(RFC5769_LONG_TERM_USERNAME, message.textOf(StunMessage.ATTR_USERNAME));
		Assert.equals(RFC5769_LONG_TERM_REALM, message.textOf(StunMessage.ATTR_REALM));
		Assert.equals(RFC5769_LONG_TERM_NONCE, message.textOf(StunMessage.ATTR_NONCE));
	}

	/**
		And building one from its parts reproduces the sample byte for byte.

		The stronger direction. Verifying proves this can read what somebody else
		wrote; reproducing proves a relay reading what this writes sees what it
		expects: the attribute encoding, the padding, and the length field
		counting the integrity attribute that has not been appended yet.
	**/
	public function testALongTermRequestIsBuiltByteForByte():Void {
		var key = StunMessage.longTermKey(RFC5769_LONG_TERM_USERNAME, RFC5769_LONG_TERM_REALM, RFC5769_LONG_TERM_PASSWORD);
		var transaction = fromHex("78ad3433c6ad72c029da412e");

		var message = new StunMessage(StunMessage.BINDING_REQUEST, transaction, [
			StunMessage.text(StunMessage.ATTR_USERNAME, RFC5769_LONG_TERM_USERNAME),
			StunMessage.text(StunMessage.ATTR_NONCE, RFC5769_LONG_TERM_NONCE),
			StunMessage.text(StunMessage.ATTR_REALM, RFC5769_LONG_TERM_REALM)
		]);

		var encoded = message.encodeSignedWithKey(key, false);

		Assert.equals(RFC5769_LONG_TERM_REQUEST, toHex(encoded, 0, encoded.length));
	}

	// Integrity, against RFC 5769
	// ------------------------------------------------------------------

	/**
		A real implementation's message verifies here.

		This is the receive direction, and it is checked against the bytes as
		they arrived rather than a re-encoding, which is the only way it can
		pass, because this encoder pads a username with zeros and the RFC's
		sample pads it with spaces. Both are legal and they hash differently.
	**/
	public function testTheRfcSampleRequestVerifies():Void {
		var message = StunMessage.decode(fromHex(RFC5769_REQUEST));

		Require.notNull(message);
		Assert.isTrue(message.verifyIntegrity(RFC5769_PASSWORD), "the RFC 5769 sample request did not verify, so this would interoperate with nothing");
		Assert.isTrue(message.verifyFingerprint());
	}

	public function testTheRfcSampleResponseVerifies():Void {
		var message = StunMessage.decode(fromHex(RFC5769_RESPONSE));

		Require.notNull(message);
		Assert.isTrue(message.verifyIntegrity(RFC5769_PASSWORD));
		Assert.isTrue(message.verifyFingerprint());

		// And it still decodes as what it is, with the integrity attributes
		// sitting alongside the address rather than confusing the parser.
		var mapped = message.mappedAddress();
		Require.notNull(mapped);
		Assert.equals("192.0.2.1", mapped.address);
		Assert.equals(32853, mapped.port);
	}

	/**
		The send direction, pinned to the same vector.

		Everything up to MESSAGE-INTEGRITY is taken from the RFC and the
		attribute is computed onto it, so what is being checked is this
		implementation's arithmetic rather than its formatting. That separation
		matters: the padding difference makes a whole-message byte comparison
		impossible, and without this the producing path would be tested only
		against itself.
	**/
	public function testSigningReproducesTheRfcIntegrityValue():Void {
		// Up to but not including the MESSAGE-INTEGRITY attribute header.
		var upToIntegrity = RFC5769_REQUEST.substr(0, 76 * 2);
		var partial = fromHex(upToIntegrity);

		var message = new StunMessage(StunMessage.BINDING_REQUEST, transaction());
		message.__appendIntegrity(partial, haxe.io.Bytes.ofString(RFC5769_PASSWORD));

		Assert.equals("9aeaa70cbfd8cb56781ef2b5b2d3f249c1b571a2", toHex(partial, 80, 20));

		// And the header length now says what it must for the next attribute to
		// be appended after it.
		message.__appendFingerprint(partial);
		Assert.equals("e57a3bcf", toHex(partial, 104, 4));

		// Which means the whole thing is now the RFC's message.
		Assert.equals(RFC5769_REQUEST, toHex(partial, 0, partial.length));
	}

	/**
		One flipped byte and it stops verifying.

		The byte chosen is inside the username, so what is being proved is that
		the hash covers the attributes and not merely the header.
	**/
	public function testATamperedMessageDoesNotVerify():Void {
		var bytes = fromHex(RFC5769_REQUEST);
		bytes.position = 68;
		bytes.writeByte(0x66);

		var message = StunMessage.decode(bytes);

		Require.notNull(message);
		Assert.isFalse(message.verifyIntegrity(RFC5769_PASSWORD), "a message with an edited username still verified");
	}

	public function testTheWrongPasswordDoesNotVerify():Void {
		var message = StunMessage.decode(fromHex(RFC5769_REQUEST));

		Assert.isFalse(message.verifyIntegrity("not the password"));
		Assert.isFalse(message.verifyIntegrity(""));
	}

	public function testATamperedFingerprintIsCaught():Void {
		var bytes = fromHex(RFC5769_REQUEST);
		bytes.position = 104;
		bytes.writeByte(0x00);

		var message = StunMessage.decode(bytes);

		Assert.isFalse(message.verifyFingerprint());
	}

	/**
		An unsigned message is refused, not crashed on.

		A plain binding request from a public STUN server carries neither
		attribute, and arriving at a verifier is ordinary rather than
		exceptional.
	**/
	public function testAMessageWithoutIntegrityIsRefusedRatherThanThrowing():Void {
		var plain = StunMessage.decode(new StunMessage(StunMessage.BINDING_REQUEST, transaction()).encode());

		Require.notNull(plain);
		Assert.isFalse(plain.verifyIntegrity("anything"));
		Assert.isFalse(plain.verifyFingerprint());

		// And a message that was never decoded has nothing to check against.
		Assert.isFalse(new StunMessage(StunMessage.BINDING_REQUEST, transaction()).verifyIntegrity("anything"));
	}

	/**
		The attribute list is walked, not searched.

		A software name here contains the four bytes of a MESSAGE-INTEGRITY
		header. An implementation that scanned for the tag would find it inside
		this value, hash the wrong span, and reject a message that is perfectly
		good, or accept one that is not.
	**/
	public function testAnAttributeValueCannotImpersonateAnAttributeHeader():Void {
		var decoy = new ByteArray();
		decoy.endian = Endian.BIG_ENDIAN;
		decoy.writeShort(StunMessage.ATTR_MESSAGE_INTEGRITY);
		decoy.writeShort(20);
		decoy.writeUTFBytes("xxxx");
		decoy.position = 0;

		var message = new StunMessage(StunMessage.BINDING_REQUEST, transaction(), [
			new StunAttribute(StunMessage.ATTR_SOFTWARE, decoy)
		]);

		var signed = StunMessage.decode(message.encodeSigned("secret"));

		Require.notNull(signed);
		Assert.isTrue(signed.verifyIntegrity("secret"), "a decoy attribute header inside a value confused the span that gets hashed");
		Assert.isTrue(signed.verifyFingerprint());
	}

	public function testASignedMessageSurvivesTheRoundTrip():Void {
		var message = new StunMessage(StunMessage.BINDING_REQUEST, transaction(), [
			StunMessage.username("theirfrag:myfrag"),
			StunMessage.priority(1845494015),
			StunMessage.iceRole(true, Int64.make(0x932ff9b1, 0x51263b36)),
			StunMessage.useCandidate()
		]);

		var decoded = StunMessage.decode(message.encodeSigned("shared secret"));

		Require.notNull(decoded);
		Assert.isTrue(decoded.verifyIntegrity("shared secret"));
		Assert.isTrue(decoded.verifyFingerprint());
		Assert.isTrue(decoded.hasUseCandidate());

		var username = decoded.attribute(StunMessage.ATTR_USERNAME);
		Require.notNull(username);
		username.position = 0;
		Assert.equals("theirfrag:myfrag", username.readUTFBytes(username.length));

		var priority = decoded.attribute(StunMessage.ATTR_PRIORITY);
		Require.notNull(priority);
		priority.endian = Endian.BIG_ENDIAN;
		priority.position = 0;
		Assert.equals(1845494015, priority.readInt());
	}

	/**
		The tiebreaker is 64 bits and has to survive as 64 bits.

		Two peers that both claim the controlling role settle it by comparing
		these, so a value truncated to 32 would make collisions vastly more
		likely, and a collision is two peers that both defer, or neither.
	**/
	public function testTheIceTiebreakerSurvivesAsSixtyFourBits():Void {
		var tiebreaker = Int64.make(0x932ff9b1, 0x51263b36);
		var attribute = StunMessage.iceRole(true, tiebreaker);

		Assert.equals(StunMessage.ATTR_ICE_CONTROLLING, attribute.type);
		Assert.equals(8, attribute.value.length);

		attribute.value.endian = Endian.BIG_ENDIAN;
		attribute.value.position = 0;

		var high = attribute.value.readInt();
		var low = attribute.value.readInt();

		Assert.isTrue(Int64.eq(tiebreaker, Int64.make(high, low)));
		Assert.equals(StunMessage.ATTR_ICE_CONTROLLED, StunMessage.iceRole(false, tiebreaker).type);
	}

	/**
		An attribute whose entire meaning is that it is present.

		USE-CANDIDATE has no value, so it is the case a parser assuming every
		attribute has a body gets wrong, and it is the one that decides which
		pair a session actually uses.
	**/
	public function testAnEmptyAttributeSurvivesEncoding():Void {
		var message = new StunMessage(StunMessage.BINDING_REQUEST, transaction(), [StunMessage.useCandidate()]);
		var decoded = StunMessage.decode(message.encode());

		Require.notNull(decoded);
		Assert.isTrue(decoded.hasUseCandidate());
		Assert.equals(0, decoded.attribute(StunMessage.ATTR_USE_CANDIDATE).length);
	}

	/**
		A message of more attributes than anything sends is not read.

		The count is the sender's to choose: one unauthenticated 64 KB datagram
		of empty attributes is sixteen thousand of them, each an allocation and
		a copy (527 microseconds a decode on cpp, 4.4 ms on Node, twenty to a
		hundred times an ordinary datagram of the same size). Up to
		`MAX_ATTRIBUTES` is read as usual.
	**/
	public function testAMessageOfTooManyAttributesIsNotRead():Void {
		Assert.isNull(StunMessage.decode(emptyAttributes(16000)), "sixteen thousand empty attributes were read");
		Assert.isNull(StunMessage.decode(emptyAttributes(StunMessage.MAX_ATTRIBUTES + 1)), "one attribute past the limit was read");

		var most = StunMessage.decode(emptyAttributes(StunMessage.MAX_ATTRIBUTES));
		Require.notNull(most, "a message at the limit was refused");
		Assert.equals(StunMessage.MAX_ATTRIBUTES, most.attributes.length);
	}

	// ------------------------------------------------------------------
	// IPv6, and RFC 8489's credentials
	// ------------------------------------------------------------------

	/** RFC 5769 section 2.3: the sample response again, reporting an IPv6 address. **/
	private static inline var RFC5769_IPV6_RESPONSE:String = "010100482112a442"
		+ "b7e7a701bc34d686fa87dfae"
		+ "8022000b" + "7465737420766563746f7220"
		+ "00200014" + "0002a1470113a9faa5d3f179bc25f4b5bed2b9d9"
		+ "00080014" + "a382954e4be67bf11784c97c8292c275bfe3ed41"
		+ "80280004" + "c8fb0b4c";

	/**
		An IPv6 mapped address is read, pinned to RFC 5769's sample.

		The family byte is 2 for IPv6, and a decoder that understands only 1
		reads no address at all: a STUN server answering over IPv6 would report
		"no mapped address", and a TURN relay granting an IPv6 allocation
		"allocated nothing". An IPv6 address is XORed with the transaction id
		as well as the cookie, which is the part a decoder that only knows IPv4
		gets wrong.
	**/
	public function testTheRfcSampleIPv6ResponseVerifies():Void {
		var message = StunMessage.decode(fromHex(RFC5769_IPV6_RESPONSE));

		Require.notNull(message);
		Assert.isTrue(message.verifyIntegrity(RFC5769_PASSWORD));
		Assert.isTrue(message.verifyFingerprint());

		var mapped = Require.notNull(message.mappedAddress(), "the IPv6 mapped address was read as none");
		Assert.equals("2001:db8:1234:5678:11:2233:4455:6677", mapped.address);
		Assert.equals(32853, mapped.port);
	}

	/**
		An IPv6 address written with a transaction reads back as it was, in the
		canonical form a socket reports; without the transaction it cannot be
		written at all, since the XOR needs it.
	**/
	public function testAnIPv6AddressIsWrittenWithItsTransaction():Void {
		var id = transaction();
		var message = new StunMessage(StunMessage.SEND_INDICATION, id, [StunMessage.xorPeerAddress("2001:0DB8:0:0:0:0:0:7", 5000, id)]);
		var decoded = Require.notNull(StunMessage.decode(message.encode()));
		var peer = Require.notNull(decoded.addressOf(StunMessage.ATTR_XOR_PEER_ADDRESS));

		Assert.equals("2001:db8::7", peer.address);
		Assert.equals(5000, peer.port);

		Assert.raises(() -> StunMessage.xorPeerAddress("2001:db8::7", 5000), crossbyte.errors.ArgumentError);
	}

	/** What reads as an IPv6 address, and what does not. **/
	public function testIPv6AddressesAreReadStrictly():Void {
		for (address in ["::", "::1", "2001:db8::7", "1:2:3:4:5:6:7:8", "1::", "::ffff:192.0.2.1", "fe80::1:2:3:4"]) {
			Assert.notNull(StunMessage.ipv6Bytes(address), "\"" + address + "\" was refused");
		}

		for (address in ["1:2:3:4:5:6:7", "1:2:3:4:5:6:7:8:9", "1::2::3", ":1:2:3:4:5:6:7", "12345::", "fe80::1%eth0", "[::1]", "::g",
			"192.0.2.1", "::ffff:192.0.2.999", "", null]) {
			Assert.isNull(StunMessage.ipv6Bytes(address), "\"" + address + "\" was read as an IPv6 address");
		}

		Assert.equals("::ffff:c000:201", StunMessage.canonicalIPv6("::ffff:192.0.2.1"));
		Assert.equals("2001:db8::7", StunMessage.canonicalIPv6("2001:0DB8:0000:0000:0000:0000:0000:0007"));
		Assert.equals("1::", StunMessage.canonicalIPv6("1:0:0:0:0:0:0:0"));
	}

	/**
		RFC 8489's SHA-256 long-term credentials, pinned to arithmetic done
		outside Haxe: the key, the USERHASH, and a whole signed request, each
		computed with Node's crypto over the same attributes. Nothing here would
		otherwise check the SHA-256 path against anything but itself: the
		suite's relay verifies with the code that signs.
	**/
	public function testSha256CredentialsMatchArithmeticDoneElsewhere():Void {
		var key = StunMessage.longTermKeySha256("user", "example.org", "secret");
		Assert.equals("bf9f8cc2da128fcb78077f794a818f9d3ccf550dab291cb21c82f29a153b3355", key.toHex());

		var hash = StunMessage.userHash("user", "example.org");
		Assert.equals("cf9fa894dfc9b7680968aec1efb3a6b8b2a1cac25c0461cab3b0c2f87c25eeaf", hash.toHex());

		var algorithms = new ByteArray();
		for (byte in [0, 2, 0, 0, 0, 1, 0, 0]) {
			algorithms.writeByte(byte);
		}

		var request = new StunMessage(StunMessage.ALLOCATE_REQUEST, transaction(), [
			StunMessage.requestedTransport(),
			StunMessage.bytesAttribute(StunMessage.ATTR_USERHASH, hash),
			StunMessage.text(StunMessage.ATTR_REALM, "example.org"),
			StunMessage.text(StunMessage.ATTR_NONCE, "obMatJos2gAAAnonce-one"),
			StunMessage.passwordAlgorithm(StunMessage.PASSWORD_ALGORITHM_SHA256),
			StunMessage.bytesAttribute(StunMessage.ATTR_PASSWORD_ALGORITHMS, algorithms)
		]);

		var signed = request.encodeSignedSha256WithKey(key, false);
		Assert.equals("000300902112a4420102030405060708090a0b0c0019000411000000001e0020cf9fa894dfc9b7680968aec1efb3a6b8b2a1cac25c0461cab3b0c2f87c25eeaf"
			+ "0014000b6578616d706c652e6f726700001500166f624d61744a6f7332674141416e6f6e63652d6f6e650000001d000400020000800200080002000000010000"
			+ "001c002096e0543436ff8a3e47cd6726e304d2a8517fb2ebb9b8512b11649f9109a63e24", toHex(signed, 0, signed.length));

		var decoded = Require.notNull(StunMessage.decode(signed));
		Assert.isTrue(decoded.verifyIntegritySha256WithKey(key));
		Assert.isTrue(decoded.verifyAnyIntegrityWithKey(key));
		Assert.isFalse(decoded.verifyIntegritySha256WithKey(StunMessage.longTermKeySha256("user", "example.org", "guess")));
		Assert.equals("2,1", decoded.passwordAlgorithms().join(","));
	}

	/** RFC 8489's nonce cookie: the features it declares, and none without it. **/
	public function testANonceSaysWhatTheServerOffers():Void {
		Assert.equals(StunMessage.FEATURE_PASSWORD_ALGORITHMS, StunMessage.nonceFeatures("obMatJos2gAAAxyz"));
		Assert.equals(StunMessage.FEATURE_USERNAME_ANONYMITY, StunMessage.nonceFeatures("obMatJos2QAAAxyz"));
		Assert.equals(StunMessage.FEATURE_PASSWORD_ALGORITHMS | StunMessage.FEATURE_USERNAME_ANONYMITY, StunMessage.nonceFeatures("obMatJos2wAAA"));
		Assert.equals(0, StunMessage.nonceFeatures("f//499k954d6OL34oL9FSTvy64sA"));
		Assert.equals(0, StunMessage.nonceFeatures("obMatJos2"));
		Assert.equals(0, StunMessage.nonceFeatures(null));
	}

	/** A binding success of `count` empty SOFTWARE attributes. **/
	private static function emptyAttributes(count:Int):ByteArray {
		var out = new ByteArray();
		out.endian = Endian.BIG_ENDIAN;
		out.writeShort(StunMessage.BINDING_SUCCESS);
		out.writeShort(count * 4);
		out.writeInt(StunMessage.MAGIC_COOKIE);
		out.writeBytes(transaction(), 0, 12);

		for (_ in 0...count) {
			out.writeShort(StunMessage.ATTR_SOFTWARE);
			out.writeShort(0);
		}

		out.position = 0;
		return out;
	}
}
