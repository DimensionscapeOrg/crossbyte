package crossbyte.net;

import crossbyte.net._internal.stun.StunMessage;
import crossbyte.net._internal.stun.StunMessage.StunAttribute;
import crossbyte.io.ByteArray;
import crossbyte.io.Endian;
import haxe.Int64;
import utest.Assert;

/**
	The STUN wire format.

	Needs no socket -- these are bytes in and bytes out -- so it runs wherever
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

		Assert.notNull(decoded);
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
		Assert.notNull(decoded);

		var address = decoded.mappedAddress();
		Assert.notNull(address, "a success response carrying an address reported none");
		Assert.equals("192.168.1.100", address.address);
		Assert.equals(54321, address.port);
	}

	public function testTheAddressIsActuallyObscuredOnTheWire():Void {
		// Computed from RFC 5389 rather than from the encoder: X-Port is the
		// port XOR the top half of the cookie, and each address octet is XORed
		// with the cookie byte at its own position. If the encoder ever stopped
		// XORing, the round-trip case above would still pass -- decode would
		// simply undo nothing twice -- and only this one would notice.
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

		Assert.notNull(address);
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
		Assert.notNull(decoded);
		Assert.equals(2, decoded.attributes.length);

		var address = decoded.mappedAddress();
		Assert.notNull(address, "the attribute after an odd-length one was lost to padding");
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
		// hand this peer an address of the sender's choosing -- which the mesh
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

		Assert.notNull(reported);
		Assert.isTrue(reported.indexOf("401") == 0, "got " + reported);
		Assert.isTrue(reported.indexOf("Unauthorized") > 0, "got " + reported);
	}

	// ------------------------------------------------------------------
	// Integrity, against RFC 5769
	// ------------------------------------------------------------------

	/**
		A real implementation's message verifies here.

		This is the receive direction, and it is checked against the bytes as
		they arrived rather than a re-encoding -- which is the only way it can
		pass, because this encoder pads a username with zeros and the RFC's
		sample pads it with spaces. Both are legal and they hash differently.
	**/
	public function testTheRfcSampleRequestVerifies():Void {
		var message = StunMessage.decode(fromHex(RFC5769_REQUEST));

		Assert.notNull(message);
		Assert.isTrue(message.verifyIntegrity(RFC5769_PASSWORD), "the RFC 5769 sample request did not verify, so this would interoperate with nothing");
		Assert.isTrue(message.verifyFingerprint());
	}

	public function testTheRfcSampleResponseVerifies():Void {
		var message = StunMessage.decode(fromHex(RFC5769_RESPONSE));

		Assert.notNull(message);
		Assert.isTrue(message.verifyIntegrity(RFC5769_PASSWORD));
		Assert.isTrue(message.verifyFingerprint());

		// And it still decodes as what it is, with the integrity attributes
		// sitting alongside the address rather than confusing the parser.
		var mapped = message.mappedAddress();
		Assert.notNull(mapped);
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
		message.__appendIntegrity(partial, RFC5769_PASSWORD);

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

		Assert.notNull(message);
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

		Assert.notNull(plain);
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
		good -- or accept one that is not.
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

		Assert.notNull(signed);
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

		Assert.notNull(decoded);
		Assert.isTrue(decoded.verifyIntegrity("shared secret"));
		Assert.isTrue(decoded.verifyFingerprint());
		Assert.isTrue(decoded.hasUseCandidate());

		var username = decoded.attribute(StunMessage.ATTR_USERNAME);
		Assert.notNull(username);
		username.position = 0;
		Assert.equals("theirfrag:myfrag", username.readUTFBytes(username.length));

		var priority = decoded.attribute(StunMessage.ATTR_PRIORITY);
		Assert.notNull(priority);
		priority.endian = Endian.BIG_ENDIAN;
		priority.position = 0;
		Assert.equals(1845494015, priority.readInt());
	}

	/**
		The tiebreaker is 64 bits and has to survive as 64 bits.

		Two peers that both claim the controlling role settle it by comparing
		these, so a value truncated to 32 would make collisions vastly more
		likely -- and a collision is two peers that both defer, or neither.
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
		attribute has a body gets wrong -- and it is the one that decides which
		pair a session actually uses.
	**/
	public function testAnEmptyAttributeSurvivesEncoding():Void {
		var message = new StunMessage(StunMessage.BINDING_REQUEST, transaction(), [StunMessage.useCandidate()]);
		var decoded = StunMessage.decode(message.encode());

		Assert.notNull(decoded);
		Assert.isTrue(decoded.hasUseCandidate());
		Assert.equals(0, decoded.attribute(StunMessage.ATTR_USE_CANDIDATE).length);
	}
}
