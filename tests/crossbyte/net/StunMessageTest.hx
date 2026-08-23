package crossbyte.net;

import crossbyte.net._internal.stun.StunMessage;
import crossbyte.net._internal.stun.StunMessage.StunAttribute;
import crossbyte.io.ByteArray;
import crossbyte.io.Endian;
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
class StunMessageTest extends utest.Test {
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
}
