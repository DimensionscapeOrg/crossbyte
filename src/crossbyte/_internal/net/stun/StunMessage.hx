package crossbyte._internal.net.stun;

import crossbyte.io.ByteArray;
import crossbyte.io.Endian;

/**
	A STUN message, per RFC 5389.

	The point of STUN, for CrossByte, is one question: what address does the
	rest of the world see this socket as? A peer behind NAT cannot answer that
	from anything local -- `localAddress` is the private side of the mapping --
	and it has to be able to, because the address it tells other peers to dial
	is the public one. That answer is the first thing ICE needs, and ICE is the
	first thing a peer-to-peer transport needs.

	The wire format is deliberately small: a twenty byte header and a list of
	type/length/value attributes. What follows is that and nothing more -- no
	authentication, no fingerprint, no TURN. Those are separate RFCs and are not
	needed to ask a public STUN server for a reflexive address.

	```
	 0                   1                   2                   3
	 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
	+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
	|0 0|     STUN Message Type     |         Message Length        |
	+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
	|                         Magic Cookie                          |
	+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
	|                     Transaction ID (96 bits)                  |
	+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
	```
**/
class StunMessage {
	/** Fixed value in every STUN message, and how one is told from noise. */
	public static inline var MAGIC_COOKIE:Int = 0x2112A442;

	public static inline var BINDING_REQUEST:Int = 0x0001;
	public static inline var BINDING_SUCCESS:Int = 0x0101;
	public static inline var BINDING_ERROR:Int = 0x0111;

	public static inline var ATTR_MAPPED_ADDRESS:Int = 0x0001;
	public static inline var ATTR_ERROR_CODE:Int = 0x0009;
	public static inline var ATTR_XOR_MAPPED_ADDRESS:Int = 0x0020;

	private static inline var HEADER_LENGTH:Int = 20;
	private static inline var TRANSACTION_LENGTH:Int = 12;
	private static inline var FAMILY_IPV4:Int = 0x01;

	public var type(default, null):Int;

	/**
		Ninety-six bits identifying this exchange.

		Checked on every reply. A datagram socket accepts from anyone, so a
		response carrying somebody else's transaction is either a stray from an
		earlier attempt or an attempt to hand this peer a forged address -- and
		a forged reflexive address is a peer telling the mesh to dial an
		attacker.
	**/
	public var transactionId(default, null):ByteArray;

	public var attributes(default, null):Array<StunAttribute>;

	public function new(type:Int, transactionId:ByteArray, ?attributes:Array<StunAttribute>) {
		this.type = type;
		this.transactionId = transactionId;
		this.attributes = attributes != null ? attributes : [];
	}

	/** A binding request with a fresh transaction, ready to send. */
	public static function bindingRequest():StunMessage {
		return new StunMessage(BINDING_REQUEST, crossbyte.crypto.SecureRandom.getSecureRandomBytes(TRANSACTION_LENGTH));
	}

	public function encode():ByteArray {
		var body = new ByteArray();
		body.endian = Endian.BIG_ENDIAN;

		for (attribute in attributes) {
			body.writeShort(attribute.type);
			body.writeShort(attribute.value.length);
			body.writeBytes(attribute.value, 0, attribute.value.length);

			// Every attribute starts on a four byte boundary. The padding is
			// not counted in the attribute's own length, which is the detail a
			// hand-rolled parser gets wrong.
			var padding:Int = (4 - (attribute.value.length % 4)) % 4;

			for (_ in 0...padding) {
				body.writeByte(0);
			}
		}

		var out = new ByteArray();
		out.endian = Endian.BIG_ENDIAN;
		out.writeShort(type);
		out.writeShort(body.length);
		out.writeInt(MAGIC_COOKIE);
		out.writeBytes(transactionId, 0, TRANSACTION_LENGTH);
		out.writeBytes(body, 0, body.length);
		out.position = 0;
		return out;
	}

	/**
		Reads a message, or returns null if the bytes are not one.

		Null rather than an exception: this parses whatever arrives on a bound
		UDP socket, and unrelated traffic reaching that port is ordinary rather
		than exceptional.
	**/
	public static function decode(bytes:ByteArray):Null<StunMessage> {
		if (bytes == null || bytes.length < HEADER_LENGTH) {
			return null;
		}

		bytes.endian = Endian.BIG_ENDIAN;
		bytes.position = 0;

		var type:Int = bytes.readUnsignedShort();
		var length:Int = bytes.readUnsignedShort();

		if (bytes.readInt() != MAGIC_COOKIE) {
			return null;
		}

		// The advertised body must actually be present. A short read here is
		// what a truncated datagram looks like, and reading past it would take
		// whatever the buffer happened to hold.
		if (HEADER_LENGTH + length > bytes.length) {
			return null;
		}

		var transactionId = new ByteArray();
		bytes.readBytes(transactionId, 0, TRANSACTION_LENGTH);

		var attributes:Array<StunAttribute> = [];
		var read:Int = 0;

		while (read + 4 <= length) {
			var attributeType:Int = bytes.readUnsignedShort();
			var attributeLength:Int = bytes.readUnsignedShort();
			read += 4;

			if (read + attributeLength > length) {
				// An attribute claiming more than the message holds. Everything
				// parsed so far is still good; the remainder is not.
				break;
			}

			var value = new ByteArray();

			if (attributeLength > 0) {
				bytes.readBytes(value, 0, attributeLength);
			}

			attributes.push(new StunAttribute(attributeType, value));
			read += attributeLength;

			var padding:Int = (4 - (attributeLength % 4)) % 4;

			if (padding > 0 && read + padding <= length) {
				bytes.position += padding;
				read += padding;
			}
		}

		return new StunMessage(type, transactionId, attributes);
	}

	/** Whether `other` answers this exchange and not somebody else's. */
	public function matches(other:StunMessage):Bool {
		if (other == null || other.transactionId == null || transactionId == null) {
			return false;
		}

		if (other.transactionId.length != TRANSACTION_LENGTH || transactionId.length != TRANSACTION_LENGTH) {
			return false;
		}

		// Compared byte for byte rather than by any shortcut: this is the only
		// thing standing between a peer and an address an attacker chose.
		for (i in 0...TRANSACTION_LENGTH) {
			if (transactionId[i] != other.transactionId[i]) {
				return false;
			}
		}

		return true;
	}

	/**
		The reflexive address this message reports, or null if it reports none.

		Prefers `XOR-MAPPED-ADDRESS` over the older `MAPPED-ADDRESS`, and the
		reason is not cosmetic. A plain address appears verbatim in the payload,
		and NATs were built that rewrote anything in a packet that looked like
		one -- so the unXORed form could arrive already "helpfully" corrected to
		the private address it was sent to report on. XOR against a constant the
		NAT does not know about is what stops that.
	**/
	public function mappedAddress():Null<StunAddress> {
		var fallback:Null<StunAddress> = null;

		for (attribute in attributes) {
			if (attribute.type == ATTR_XOR_MAPPED_ADDRESS) {
				var decoded = __readAddress(attribute.value, true);

				if (decoded != null) {
					return decoded;
				}
			} else if (attribute.type == ATTR_MAPPED_ADDRESS && fallback == null) {
				fallback = __readAddress(attribute.value, false);
			}
		}

		return fallback;
	}

	/** The error a binding error response carries, or null. */
	public function errorMessage():Null<String> {
		for (attribute in attributes) {
			if (attribute.type != ATTR_ERROR_CODE || attribute.value.length < 4) {
				continue;
			}

			attribute.value.position = 0;
			attribute.value.readUnsignedShort();
			var codeClass:Int = attribute.value.readUnsignedByte() & 0x07;
			var codeNumber:Int = attribute.value.readUnsignedByte();
			var reason:String = attribute.value.length > 4 ? attribute.value.readUTFBytes(attribute.value.length - 4) : "";

			return (codeClass * 100 + codeNumber) + (reason != "" ? " " + reason : "");
		}

		return null;
	}

	private function __readAddress(value:ByteArray, xored:Bool):Null<StunAddress> {
		if (value == null || value.length < 8) {
			return null;
		}

		value.endian = Endian.BIG_ENDIAN;
		value.position = 0;
		value.readUnsignedByte();
		var family:Int = value.readUnsignedByte();

		// IPv4 only, and said rather than guessed at. An IPv6 reflexive address
		// is decoded against the transaction id as well as the cookie, and
		// there is nothing in CrossByte yet that would dial one.
		if (family != FAMILY_IPV4) {
			return null;
		}

		var port:Int = value.readUnsignedShort();
		var octets:Array<Int> = [];

		for (_ in 0...4) {
			octets.push(value.readUnsignedByte());
		}

		if (xored) {
			port = port ^ (MAGIC_COOKIE >>> 16);
			octets[0] = octets[0] ^ ((MAGIC_COOKIE >>> 24) & 0xFF);
			octets[1] = octets[1] ^ ((MAGIC_COOKIE >>> 16) & 0xFF);
			octets[2] = octets[2] ^ ((MAGIC_COOKIE >>> 8) & 0xFF);
			octets[3] = octets[3] ^ (MAGIC_COOKIE & 0xFF);
		}

		return {address: octets.join("."), port: port & 0xFFFF};
	}

	/**
		An `XOR-MAPPED-ADDRESS` attribute for an IPv4 endpoint.

		Only a server needs to write one. It is here so the parser can be tested
		against something other than itself.
	**/
	public static function xorMappedAddress(address:String, port:Int):StunAttribute {
		var parts:Array<String> = address.split(".");
		var value = new ByteArray();
		value.endian = Endian.BIG_ENDIAN;
		value.writeByte(0);
		value.writeByte(FAMILY_IPV4);
		value.writeShort(port ^ (MAGIC_COOKIE >>> 16));

		var shifts:Array<Int> = [24, 16, 8, 0];

		for (i in 0...4) {
			var octet:Int = parts.length > i ? Std.parseInt(parts[i]) : 0;
			value.writeByte(octet ^ ((MAGIC_COOKIE >>> shifts[i]) & 0xFF));
		}

		value.position = 0;
		return new StunAttribute(ATTR_XOR_MAPPED_ADDRESS, value);
	}
}

/** One type/length/value attribute. */
class StunAttribute {
	public var type(default, null):Int;
	public var value(default, null):ByteArray;

	public function new(type:Int, value:ByteArray) {
		this.type = type;
		this.value = value;
	}
}

/** An address as somebody else sees it. */
typedef StunAddress = {
	var address:String;
	var port:Int;
}
