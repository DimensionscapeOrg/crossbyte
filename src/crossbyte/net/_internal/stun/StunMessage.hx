package crossbyte.net._internal.stun;

import crossbyte._internal.net.IPv6;
import crossbyte.errors.ArgumentError;
import crossbyte.io.ByteArray;
import crossbyte.io.Endian;
import crossbyte.net.ReflexiveAddress;
import crossbyte.utils.IntParse;
import haxe.Int64;
import haxe.crypto.Crc32;
import haxe.crypto.Hmac;
import haxe.crypto.Hmac.HashMethod;
import haxe.crypto.Md5;
import haxe.crypto.Sha256;
import haxe.io.Bytes;

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
	public static inline var ATTR_USERNAME:Int = 0x0006;
	public static inline var ATTR_MESSAGE_INTEGRITY:Int = 0x0008;
	public static inline var ATTR_ERROR_CODE:Int = 0x0009;
	public static inline var ATTR_XOR_MAPPED_ADDRESS:Int = 0x0020;
	public static inline var ATTR_PRIORITY:Int = 0x0024;
	public static inline var ATTR_USE_CANDIDATE:Int = 0x0025;
	public static inline var ATTR_SOFTWARE:Int = 0x8022;
	public static inline var ATTR_FINGERPRINT:Int = 0x8028;
	public static inline var ATTR_ICE_CONTROLLED:Int = 0x8029;
	public static inline var ATTR_ICE_CONTROLLING:Int = 0x802A;

	// TURN, RFC 8656. The same framing with different methods: the low twelve
	// bits of the type are the method and the two class bits say request,
	// indication, success or error -- which is why an allocate request is
	// 0x0003 and its success response 0x0103.
	public static inline var ALLOCATE_REQUEST:Int = 0x0003;

	public static inline var ALLOCATE_SUCCESS:Int = 0x0103;
	public static inline var ALLOCATE_ERROR:Int = 0x0113;
	public static inline var REFRESH_REQUEST:Int = 0x0004;
	public static inline var REFRESH_SUCCESS:Int = 0x0104;
	public static inline var REFRESH_ERROR:Int = 0x0114;
	public static inline var SEND_INDICATION:Int = 0x0016;
	public static inline var DATA_INDICATION:Int = 0x0017;
	public static inline var CHANNEL_BIND_REQUEST:Int = 0x0009;
	public static inline var CHANNEL_BIND_SUCCESS:Int = 0x0109;
	public static inline var CHANNEL_BIND_ERROR:Int = 0x0119;
	public static inline var CREATE_PERMISSION_REQUEST:Int = 0x0008;
	public static inline var CREATE_PERMISSION_SUCCESS:Int = 0x0108;
	public static inline var CREATE_PERMISSION_ERROR:Int = 0x0118;

	public static inline var ATTR_CHANNEL_NUMBER:Int = 0x000C;
	public static inline var ATTR_LIFETIME:Int = 0x000D;
	public static inline var ATTR_XOR_PEER_ADDRESS:Int = 0x0012;
	public static inline var ATTR_DATA:Int = 0x0013;
	public static inline var ATTR_REALM:Int = 0x0014;
	public static inline var ATTR_NONCE:Int = 0x0015;
	public static inline var ATTR_XOR_RELAYED_ADDRESS:Int = 0x0016;
	public static inline var ATTR_REQUESTED_ADDRESS_FAMILY:Int = 0x0017;
	public static inline var ATTR_REQUESTED_TRANSPORT:Int = 0x0019;

	// RFC 8489's long-term credential mechanism, section 9.2: a stronger
	// integrity, a choice of password hash, and a username the relay need not
	// see in the clear.
	public static inline var ATTR_MESSAGE_INTEGRITY_SHA256:Int = 0x001C;
	public static inline var ATTR_PASSWORD_ALGORITHM:Int = 0x001D;
	public static inline var ATTR_USERHASH:Int = 0x001E;
	public static inline var ATTR_PASSWORD_ALGORITHMS:Int = 0x8002;

	/** The password algorithms RFC 8489 section 18.5 registers. **/
	public static inline var PASSWORD_ALGORITHM_MD5:Int = 0x0001;

	public static inline var PASSWORD_ALGORITHM_SHA256:Int = 0x0002;

	/**
		What a NONCE starting with `NONCE_COOKIE` says a server supports: the
		first two of the 24 bits after it, the first the most significant --
		PASSWORD-ALGORITHMS, and USERHASH in place of USERNAME.
	**/
	public static inline var FEATURE_PASSWORD_ALGORITHMS:Int = 0x800000;

	public static inline var FEATURE_USERNAME_ANONYMITY:Int = 0x400000;

	/** RFC 8489 section 9.2's "nonce cookie", followed by the features in four characters of base64. **/
	public static inline var NONCE_COOKIE:String = "obMatJos2";

	/** The IANA protocol number for UDP, which is the only transport TURN relays here. **/
	public static inline var TRANSPORT_UDP:Int = 17;

	/** Sent when the server wants credentials it has not been given yet. **/
	public static inline var UNAUTHORIZED:Int = 401;

	/** Sent when the nonce a request was signed against has expired. **/
	public static inline var STALE_NONCE:Int = 438;

	/**
		A relay's answer for an allocation it does not hold: the 5-tuple has
		none, or has another. Whatever the request was, the allocation it was
		about is gone.
	**/
	public static inline var ALLOCATION_MISMATCH:Int = 437;

	/** Ask the server named in ALTERNATE-SERVER instead. RFC 8489 section 10. **/
	public static inline var TRY_ALTERNATE:Int = 300;

	/**
		`ALTERNATE-SERVER`: where a 300 points. An address in the MAPPED-ADDRESS
		format, not XORed -- RFC 8489 section 14.15.
	**/
	public static inline var ATTR_ALTERNATE_SERVER:Int = 0x8023;

	/**
		XORed into the CRC so a STUN fingerprint cannot be mistaken for the
		start of some other protocol that also begins with a checksum. RFC 5389
		section 15.5 picks the ASCII of "STUN" for it.
	**/
	private static inline var FINGERPRINT_XOR:Int = 0x5354554E;

	/** SHA-1 output, and so the length of every MESSAGE-INTEGRITY value. **/
	private static inline var INTEGRITY_LENGTH:Int = 20;

	/** SHA-256 output: a MESSAGE-INTEGRITY-SHA256 value, untruncated. **/
	private static inline var INTEGRITY_SHA256_LENGTH:Int = 32;

	/** Type, length, cookie and transaction id: what every message begins with. **/
	public static inline var HEADER_LENGTH:Int = 20;

	/**
		The most attributes a message may carry and still be read.

		Every attribute read costs an allocation and a copy, and the count was
		the sender's to choose: a 64 KB datagram of empty attributes is sixteen
		thousand of them, 527 microseconds to decode on cpp and 4.4 ms on Node
		against 24 and 39 for the same bytes as one attribute -- sent by anyone,
		before anything is authenticated. Nothing any STUN, TURN or ICE peer
		sends comes near this; a message past it is not read.
	**/
	public static inline var MAX_ATTRIBUTES:Int = 32;

	/**
		How many messages have been decoded, counted without a lock: how a
		caller that should decode a datagram once can be seen to.
	**/
	@:noCompletion public static var __decoded:Int = 0;

	private static inline var TRANSACTION_LENGTH:Int = 12;
	private static inline var FAMILY_IPV4:Int = 0x01;
	private static inline var FAMILY_IPV6:Int = 0x02;

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

	/**
		Exactly the bytes this was decoded from, kept because integrity cannot
		be checked against a re-encoding.

		Attribute padding is not specified: RFC 5389 says the padding bytes are
		ignored, and implementations differ on what they put there -- the test
		vectors in RFC 5769 pad a username with spaces where this encoder writes
		zeros. Both are correct on the wire and they hash differently, so a
		receiver that re-encodes a message to verify it would reject perfectly
		valid traffic from anyone whose padding it did not happen to match.
		Null for a message built locally, which has no received bytes to check.
	**/
	public var raw(default, null):Null<ByteArray>;

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

		__decoded++;

		var transactionId = new ByteArray();
		bytes.readBytes(transactionId, 0, TRANSACTION_LENGTH);

		var attributes:Array<StunAttribute> = [];
		var read:Int = 0;

		while (read + 4 <= length) {
			// Bounded before the work, not after: see MAX_ATTRIBUTES.
			if (attributes.length >= MAX_ATTRIBUTES) {
				return null;
			}

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

		var message = new StunMessage(type, transactionId, attributes);
		message.raw = bytes;
		return message;
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
	public function mappedAddress():Null<ReflexiveAddress> {
		var fallback:Null<ReflexiveAddress> = null;

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

	/**
		A named address attribute, XOR-decoded, or null.

		`mappedAddress` answers the one question a binding response is asked;
		TURN carries three more of the same shape -- the relayed address an
		allocation was granted, and the peer an indication came from or is bound
		for -- and they are read identically.
	**/
	public function addressOf(attributeType:Int):Null<ReflexiveAddress> {
		for (attribute in attributes) {
			if (attribute.type == attributeType) {
				return __readAddress(attribute.value, true);
			}
		}

		return null;
	}

	/** The server a 300 Try Alternate names, or null. Plain, not XORed. **/
	public function alternateServerAddress():Null<ReflexiveAddress> {
		var value = attribute(ATTR_ALTERNATE_SERVER);
		return value != null ? __readAddress(value, false) : null;
	}

	/** The value of a text attribute such as `REALM` or `NONCE`, or null. **/
	public function textOf(attributeType:Int):Null<String> {
		var value = attribute(attributeType);

		if (value == null) {
			return null;
		}

		value.position = 0;
		return value.length > 0 ? value.readUTFBytes(value.length) : "";
	}

	/** A 32-bit attribute such as `LIFETIME`, or a default when absent. **/
	public function uintOf(attributeType:Int, orElse:Int = 0):Int {
		var value = attribute(attributeType);

		if (value == null || value.length < 4) {
			return orElse;
		}

		value.endian = Endian.BIG_ENDIAN;
		value.position = 0;
		return value.readInt();
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

	private function __readAddress(value:ByteArray, xored:Bool):Null<ReflexiveAddress> {
		if (value == null || value.length < 8) {
			return null;
		}

		value.endian = Endian.BIG_ENDIAN;
		value.position = 0;
		value.readUnsignedByte();
		var family:Int = value.readUnsignedByte();

		// IPv6: sixteen bytes, XORed against the cookie and then the
		// transaction id. It was read as no address at all, so a server
		// answering over IPv6 reported "no mapped address" and a relay that
		// allocated an IPv6 address "allocated nothing".
		if (family == FAMILY_IPV6) {
			return __readIPv6(value, xored);
		}

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

	@:noCompletion private function __readIPv6(value:ByteArray, xored:Bool):Null<ReflexiveAddress> {
		if (value.length < 20 || (xored && (transactionId == null || transactionId.length < TRANSACTION_LENGTH))) {
			return null;
		}

		var port:Int = ((value[2] << 8) | value[3]) ^ (xored ? (MAGIC_COOKIE >>> 16) & 0xFFFF : 0);
		var groups:Array<String> = [];

		for (group in 0...8) {
			var high:Int = value[4 + group * 2];
			var low:Int = value[5 + group * 2];

			if (xored) {
				high = high ^ __xorMask(group * 2);
				low = low ^ __xorMask(group * 2 + 1);
			}

			groups.push(StringTools.hex((high << 8) | low).toLowerCase());
		}

		return {address: IPv6.compress(groups.join(":")), port: port & 0xFFFF};
	}

	/**
		The byte an IPv6 address's byte `index` is XORed with: the four bytes of
		the cookie, then the twelve of this message's transaction.
	**/
	@:noCompletion private inline function __xorMask(index:Int):Int {
		return index < 4 ? (MAGIC_COOKIE >>> (24 - index * 8)) & 0xFF : transactionId[index - 4];
	}

	/**
		The sixteen bytes of an IPv6 address written the usual way -- up to
		eight groups of up to four hex digits, one `::` for a run of zeros, an
		IPv4 tail allowed -- or null for anything else: a name, a zone suffix,
		brackets, an IPv4 address.
	**/
	public static function ipv6Bytes(address:String):Null<Bytes> {
		if (address == null || address.indexOf(":") < 0 || address.indexOf("%") >= 0 || address.indexOf("[") >= 0) {
			return null;
		}

		var gap:Int = address.indexOf("::");

		if (gap >= 0 && address.indexOf("::", gap + 1) >= 0) {
			return null;
		}

		var head:Array<String> = gap >= 0 ? (gap == 0 ? [] : address.substr(0, gap).split(":")) : address.split(":");
		var tail:Array<String> = gap >= 0 ? (gap + 2 >= address.length ? [] : address.substr(gap + 2).split(":")) : [];
		var values:Array<Int> = [];
		var tailValues:Array<Int> = [];

		if (!__ipv6Groups(head, values, tail.length == 0 && gap < 0) || !__ipv6Groups(tail, tailValues, true)) {
			return null;
		}

		var count:Int = values.length + tailValues.length;

		if ((gap < 0 && count != 8) || (gap >= 0 && count > 7)) {
			return null;
		}

		var bytes = Bytes.alloc(16);
		bytes.fill(0, 16, 0);

		for (i in 0...values.length) {
			bytes.set(i * 2, values[i] >> 8);
			bytes.set(i * 2 + 1, values[i] & 0xFF);
		}

		var from:Int = 8 - tailValues.length;

		for (i in 0...tailValues.length) {
			bytes.set((from + i) * 2, tailValues[i] >> 8);
			bytes.set((from + i) * 2 + 1, tailValues[i] & 0xFF);
		}

		return bytes;
	}

	/**
		An IPv6 address in RFC 5952's canonical form -- lowercase, no leading
		zeros, the longest run of zero groups as `::` -- or null when it is not
		one. The form a socket and a relay report an address in, so one peer
		is one string however it was written.
	**/
	public static function canonicalIPv6(address:String):Null<String> {
		var bytes = ipv6Bytes(address);

		if (bytes == null) {
			return null;
		}

		var groups:Array<String> = [];

		for (group in 0...8) {
			groups.push(StringTools.hex((bytes.get(group * 2) << 8) | bytes.get(group * 2 + 1)).toLowerCase());
		}

		return IPv6.compress(groups.join(":"));
	}

	/**
		Reads groups of an IPv6 address into 16-bit values; the last may be an
		IPv4 address, which is two.

		@return Whether every group was one.
	**/
	@:noCompletion private static function __ipv6Groups(groups:Array<String>, into:Array<Int>, last:Bool):Bool {
		for (i in 0...groups.length) {
			var group:String = groups[i];

			if (last && i == groups.length - 1 && group.indexOf(".") >= 0) {
				var octets = ipv4Octets(group);

				if (octets == null) {
					return false;
				}

				into.push((octets[0] << 8) | octets[1]);
				into.push((octets[2] << 8) | octets[3]);
				continue;
			}

			if (group.length == 0 || group.length > 4) {
				return false;
			}

			var value:Int = 0;

			for (j in 0...group.length) {
				var c:Int = StringTools.fastCodeAt(group, j);
				var digit:Int = c >= "0".code && c <= "9".code ? c - "0".code : (c >= "a".code && c <= "f".code ? c - "a".code + 10 : (c >= "A".code
					&& c <= "F".code ? c - "A".code + 10 : -1));

				if (digit < 0) {
					return false;
				}

				value = (value << 4) | digit;
			}

			into.push(value);
		}

		return true;
	}

	/**
		An `XOR-MAPPED-ADDRESS` attribute: what an ICE agent answers a check
		with, and what a STUN server sends.

		@param transactionId The message's, which an IPv6 address is XORed
		with as well as the cookie; an IPv4 address needs none.
		@throws ArgumentError When `address` is not an IPv4 address (see
		`ipv4Octets`), nor an IPv6 one (see `ipv6Bytes`) with a transaction id
		to write it with.
	**/
	public static function xorMappedAddress(address:String, port:Int, ?transactionId:ByteArray):StunAttribute {
		return new StunAttribute(ATTR_XOR_MAPPED_ADDRESS, __writeXorAddress(address, port, transactionId));
	}

	/**
		The four octets of an IPv4 address written the one way every reader
		agrees on -- four decimal numbers up to 255, dot-separated, none with
		a leading zero -- or null for anything else: an IPv6 address, a name,
		or something that only looks like an address.

		The octets were read with `Std.parseInt`, which answers four different
		ways past 32 bits by target and throws on the jvm, and written modulo
		256, so a peer naming 1.2.3.999 had a relay permit 1.2.3.231. The
		leading zero matters because `inet_addr` reads 010 as octal: that is
		8.1.1.1 to the socket and would be 10.1.1.1 here.
	**/
	public static function ipv4Octets(address:String):Null<Array<Int>> {
		if (address == null) {
			return null;
		}

		var parts:Array<String> = address.split(".");

		if (parts.length != 4) {
			return null;
		}

		var octets:Array<Int> = [];

		for (part in parts) {
			var octet:Int = IntParse.decimal(part, 255);

			if (octet < 0 || (part.length > 1 && StringTools.fastCodeAt(part, 0) == "0".code)) {
				return null;
			}

			octets.push(octet);
		}

		return octets;
	}

	@:noCompletion private static function __writeXorAddress(address:String, port:Int, ?transactionId:ByteArray):ByteArray {
		var octets = ipv4Octets(address);

		if (octets == null) {
			var bytes = ipv6Bytes(address);

			if (bytes == null) {
				throw new ArgumentError("\"" + address + "\" is neither an IPv4 nor an IPv6 address.");
			}

			if (transactionId == null || transactionId.length < TRANSACTION_LENGTH) {
				throw new ArgumentError("\"" + address + "\" is an IPv6 address, which is XORed with the message's transaction as well as the cookie, "
					+ "so writing one needs the transaction id.");
			}

			var value = new ByteArray();
			value.endian = Endian.BIG_ENDIAN;
			value.writeByte(0);
			value.writeByte(FAMILY_IPV6);
			value.writeShort(port ^ (MAGIC_COOKIE >>> 16));

			for (i in 0...16) {
				value.writeByte(bytes.get(i) ^ (i < 4 ? (MAGIC_COOKIE >>> (24 - i * 8)) & 0xFF : transactionId[i - 4]));
			}

			value.position = 0;
			return value;
		}

		var value = new ByteArray();
		value.endian = Endian.BIG_ENDIAN;
		value.writeByte(0);
		value.writeByte(FAMILY_IPV4);
		value.writeShort(port ^ (MAGIC_COOKIE >>> 16));
		value.writeByte(octets[0] ^ ((MAGIC_COOKIE >>> 24) & 0xFF));
		value.writeByte(octets[1] ^ ((MAGIC_COOKIE >>> 16) & 0xFF));
		value.writeByte(octets[2] ^ ((MAGIC_COOKIE >>> 8) & 0xFF));
		value.writeByte(octets[3] ^ (MAGIC_COOKIE & 0xFF));
		value.position = 0;
		return value;
	}

	// ------------------------------------------------------------------
	// Attributes a connectivity check needs
	// ------------------------------------------------------------------

	/**
		`USERNAME`, which for ICE is the peer's fragment and then ours, joined
		by a colon.

		Not decoration: it is what tells a receiver which of possibly several
		ongoing sessions a check belongs to, and it is covered by
		MESSAGE-INTEGRITY, so an attacker cannot retarget a check by editing it.
	**/
	public static function username(value:String):StunAttribute {
		var bytes = new ByteArray();
		bytes.writeUTFBytes(value);
		bytes.position = 0;
		return new StunAttribute(ATTR_USERNAME, bytes);
	}

	/**
		`PRIORITY`: what the sender would give a peer-reflexive candidate learned
		from this check.

		A check can arrive from a mapping neither peer knew about, because a NAT
		allocated one for this particular destination. The receiver turns that
		into a peer-reflexive candidate, and this is the priority it gets --
		sent rather than guessed, so both sides still agree on the ordering.
	**/
	public static function priority(value:Int):StunAttribute {
		var bytes = new ByteArray();
		bytes.endian = Endian.BIG_ENDIAN;
		bytes.writeInt(value);
		bytes.position = 0;
		return new StunAttribute(ATTR_PRIORITY, bytes);
	}

	/**
		`USE-CANDIDATE`, which carries no value at all.

		The controlling peer sets it to say "this is the pair we are using".
		Its presence is the whole message, which is why the value is empty --
		and why a parser that assumes every attribute has a body mishandles it.
	**/
	public static function useCandidate():StunAttribute {
		return new StunAttribute(ATTR_USE_CANDIDATE, new ByteArray());
	}

	/**
		`ICE-CONTROLLING` or `ICE-CONTROLLED`, carrying the 64-bit tiebreaker.

		Both peers pick a random tiebreaker and state their role. If they turn
		out to have claimed the same role, the one with the larger tiebreaker
		keeps it -- which is why this is 64 bits of randomness rather than a
		flag: two peers must not collide.
	**/
	public static function iceRole(controlling:Bool, tiebreaker:Int64):StunAttribute {
		var bytes = new ByteArray();
		bytes.endian = Endian.BIG_ENDIAN;
		bytes.writeInt(tiebreaker.high);
		bytes.writeInt(tiebreaker.low);
		bytes.position = 0;
		return new StunAttribute(controlling ? ATTR_ICE_CONTROLLING : ATTR_ICE_CONTROLLED, bytes);
	}

	/**
		`ERROR-CODE`, split into a class and a number the way RFC 5389 stores it.

		The wire format is not the integer: the hundreds digit goes in three bits
		of one byte and the remainder in the next, so 487 travels as a 4 and an
		87. Reassembling it is what `errorCodeValue` does, and writing it is
		what a peer refusing a check has to do.
	**/
	public static function errorCode(code:Int, reason:String):StunAttribute {
		var bytes = new ByteArray();
		bytes.endian = Endian.BIG_ENDIAN;
		bytes.writeShort(0);
		bytes.writeByte(Std.int(code / 100) & 0x07);
		bytes.writeByte(code % 100);

		if (reason != null && reason.length > 0) {
			bytes.writeUTFBytes(reason);
		}

		bytes.position = 0;
		return new StunAttribute(ATTR_ERROR_CODE, bytes);
	}

	/**
		The reason phrase of an error response alone, without its code: empty
		when the server gave none, null when there is no ERROR-CODE at all.
	**/
	public function errorReason():Null<String> {
		for (attribute in attributes) {
			if (attribute.type != ATTR_ERROR_CODE || attribute.value.length < 4) {
				continue;
			}

			attribute.value.position = 4;
			return attribute.value.length > 4 ? attribute.value.readUTFBytes(attribute.value.length - 4) : "";
		}

		return null;
	}

	/**
		The numeric code of an error response, or zero.

		`errorMessage` renders the code and reason together for a human;
		anything deciding what to *do* about a refusal needs the number, and
		parsing it back out of that string would be a way to get it wrong.
	**/
	public function errorCodeValue():Int {
		for (attribute in attributes) {
			if (attribute.type != ATTR_ERROR_CODE || attribute.value.length < 4) {
				continue;
			}

			attribute.value.endian = Endian.BIG_ENDIAN;
			attribute.value.position = 0;
			attribute.value.readUnsignedShort();

			var codeClass:Int = attribute.value.readUnsignedByte() & 0x07;
			var codeNumber:Int = attribute.value.readUnsignedByte();

			return codeClass * 100 + codeNumber;
		}

		return 0;
	}

	/**
		The tiebreaker from whichever role attribute is present, or null.

		Returned alongside which role the sender claimed, because the two are
		only meaningful together: the same number means "switch" or "refuse"
		depending on which side of the conflict it arrived from.
	**/
	public function iceRoleClaim():Null<{controlling:Bool, tiebreaker:Int64}> {
		for (attribute in attributes) {
			var controlling = attribute.type == ATTR_ICE_CONTROLLING;

			if (!controlling && attribute.type != ATTR_ICE_CONTROLLED) {
				continue;
			}

			if (attribute.value.length < 8) {
				continue;
			}

			attribute.value.endian = Endian.BIG_ENDIAN;
			attribute.value.position = 0;

			var high = attribute.value.readInt();
			var low = attribute.value.readInt();

			return {controlling: controlling, tiebreaker: Int64.make(high, low)};
		}

		return null;
	}

	/**
		`XOR-PEER-ADDRESS`, naming the far peer in a TURN exchange.

		The same obscuring as a mapped address and for the same reason: a NAT
		that rewrote anything resembling an address in a passing packet would
		otherwise corrupt the very field that says who to relay to.

		@param transactionId The message's, needed for an IPv6 address.
		@throws ArgumentError When `address` is not an address that can be
		written with what was given: see `xorMappedAddress`.
	**/
	public static function xorPeerAddress(address:String, port:Int, ?transactionId:ByteArray):StunAttribute {
		return new StunAttribute(ATTR_XOR_PEER_ADDRESS, __writeXorAddress(address, port, transactionId));
	}

	/**
		`XOR-RELAYED-ADDRESS`, the address an allocation was granted.

		Only a relay writes one. It is here for the same reason
		`xorMappedAddress` is: so the parser can be tested against something
		other than itself.
	**/
	public static function xorRelayed(address:String, port:Int, ?transactionId:ByteArray):StunAttribute {
		return new StunAttribute(ATTR_XOR_RELAYED_ADDRESS, __writeXorAddress(address, port, transactionId));
	}

	/** `DATA`, the payload a relay carries in either direction. **/
	public static function data(payload:ByteArray):StunAttribute {
		var bytes = new ByteArray();

		if (payload != null && payload.length > 0) {
			bytes.writeBytes(payload, 0, payload.length);
		}

		bytes.position = 0;
		return new StunAttribute(ATTR_DATA, bytes);
	}

	/** `REQUESTED-TRANSPORT`, which for a data relay is always UDP. **/
	public static function requestedTransport(protocol:Int = TRANSPORT_UDP):StunAttribute {
		var bytes = new ByteArray();
		bytes.endian = Endian.BIG_ENDIAN;
		bytes.writeByte(protocol);
		bytes.writeByte(0);
		bytes.writeShort(0);
		bytes.position = 0;
		return new StunAttribute(ATTR_REQUESTED_TRANSPORT, bytes);
	}

	/** `LIFETIME`, in seconds: how long an allocation should outlive this request. **/
	/**
		`CHANNEL-NUMBER`: two bytes of channel, then two reserved and zero.

		Four bytes for a two-byte value, which is RFC 8656 leaving room it never
		used. Writing the number alone would make an attribute the length field
		says is two and every relay reads as malformed.
	**/
	public static function channelNumber(number:Int):StunAttribute {
		var bytes = new ByteArray();
		bytes.writeByte((number >> 8) & 0xFF);
		bytes.writeByte(number & 0xFF);
		bytes.writeByte(0);
		bytes.writeByte(0);
		bytes.position = 0;
		return new StunAttribute(ATTR_CHANNEL_NUMBER, bytes);
	}

	public static function lifetime(seconds:Int):StunAttribute {
		var bytes = new ByteArray();
		bytes.endian = Endian.BIG_ENDIAN;
		bytes.writeInt(seconds);
		bytes.position = 0;
		return new StunAttribute(ATTR_LIFETIME, bytes);
	}

	/** A text attribute, which is how `REALM` and `NONCE` are echoed back. **/
	public static function text(attributeType:Int, value:String):StunAttribute {
		var bytes = new ByteArray();

		if (value != null) {
			bytes.writeUTFBytes(value);
		}

		bytes.position = 0;
		return new StunAttribute(attributeType, bytes);
	}

	/**
		The key a long-term credential signs with.

		Not the password. TURN hashes the username, realm and password together,
		so a server can hold the digest rather than the password itself and a
		credential is bound to the realm it was issued for. MD5 is what RFC 8656
		specifies here, and it is specified for exactly this -- the digest is a
		key derivation over values the server already knows, not a signature
		anybody is asked to trust on its own; the signature over the message is
		HMAC-SHA1, the same as everywhere else.

		## The three strings are used exactly as given

		RFC 8489 says to run the username and password through SASLprep first, and
		this does not. SASLprep maps a soft hyphen to nothing, a feminine ordinal
		to "a" and a Roman numeral nine to "IX", among much else -- so for any
		credential outside printable ASCII, an implementation that prepares its
		inputs and one that does not derive different keys from the same password,
		and every request signed with the wrong one is refused with nothing said
		about why.

		For ASCII credentials, which is what a relay hands out in practice, the
		preparation is the identity and there is nothing between the two. Pass an
		already-prepared password if a server ever issues one that is not.

		Pinned to RFC 5769 section 2.4, whose sample is signed with a long-term
		credential -- against the prepared form of its password, since that is the
		part this can answer for.
	**/
	public static function longTermKey(username:String, realm:String, password:String):Bytes {
		return Md5.make(Bytes.ofString(username + ":" + realm + ":" + password));
	}

	/**
		The key a long-term credential signs with under RFC 8489's SHA-256
		password algorithm: SHA-256 of username, realm and password, the same
		three strings `longTermKey` takes MD5 of, and used exactly as given
		for the same reason.
	**/
	public static function longTermKeySha256(username:String, realm:String, password:String):Bytes {
		return Sha256.make(Bytes.ofString(username + ":" + realm + ":" + password));
	}

	/**
		`USERHASH`'s value: SHA-256 of username and realm, which a server that
		offers username anonymity takes in place of `USERNAME`, so the name
		never crosses the network in the clear. RFC 8489 section 14.4.
	**/
	public static function userHash(username:String, realm:String):Bytes {
		return Sha256.make(Bytes.ofString(username + ":" + realm));
	}

	/**
		The security features a NONCE declares, as 24 bits with the first the
		most significant, or 0 when it does not start with `NONCE_COOKIE` --
		which is a server from before RFC 8489, offering none.
	**/
	public static function nonceFeatures(nonce:String):Int {
		if (nonce == null || !StringTools.startsWith(nonce, NONCE_COOKIE) || nonce.length < NONCE_COOKIE.length + 4) {
			return 0;
		}

		try {
			var bits = haxe.crypto.Base64.decode(nonce.substr(NONCE_COOKIE.length, 4), false);

			if (bits.length < 3) {
				return 0;
			}

			return (bits.get(0) << 16) | (bits.get(1) << 8) | bits.get(2);
		} catch (_:Dynamic) {
			return 0;
		}
	}

	/**
		The algorithms a `PASSWORD-ALGORITHMS` attribute offers, in the order
		offered, or null when there is none. Each entry is an algorithm number
		and parameters padded to four bytes, which neither registered
		algorithm has.
	**/
	public function passwordAlgorithms():Null<Array<Int>> {
		var value = attribute(ATTR_PASSWORD_ALGORITHMS);

		if (value == null) {
			return null;
		}

		var offered:Array<Int> = [];
		var at:Int = 0;

		while (at + 4 <= value.length) {
			offered.push((value[at] << 8) | value[at + 1]);
			var parameters:Int = (value[at + 2] << 8) | value[at + 3];
			at += 4 + parameters + ((4 - (parameters % 4)) % 4);
		}

		return offered;
	}

	/** `PASSWORD-ALGORITHM`: the one a request's key was derived with, and no parameters. **/
	public static function passwordAlgorithm(algorithm:Int):StunAttribute {
		var bytes = new ByteArray();
		bytes.endian = Endian.BIG_ENDIAN;
		bytes.writeShort(algorithm);
		bytes.writeShort(0);
		bytes.position = 0;
		return new StunAttribute(ATTR_PASSWORD_ALGORITHM, bytes);
	}

	/** An attribute holding exactly `value`: a USERHASH, or a PASSWORD-ALGORITHMS echoed as it came. **/
	public static function bytesAttribute(type:Int, value:Bytes):StunAttribute {
		var bytes = new ByteArray();

		if (value.length > 0) {
			bytes.writeBytes(value, 0, value.length);
		}

		bytes.position = 0;
		return new StunAttribute(type, bytes);
	}

	/**
		`REQUESTED-ADDRESS-FAMILY`: which family of relayed address an Allocate
		asks for. Left out, a relay allocates IPv4. RFC 8656 section 18.8.
	**/
	public static function requestedAddressFamily(ipv6:Bool):StunAttribute {
		var bytes = new ByteArray();
		bytes.writeByte(ipv6 ? FAMILY_IPV6 : FAMILY_IPV4);
		bytes.writeByte(0);
		bytes.writeByte(0);
		bytes.writeByte(0);
		bytes.position = 0;
		return new StunAttribute(ATTR_REQUESTED_ADDRESS_FAMILY, bytes);
	}

	/** `SOFTWARE`, which is advisory and never covered by anything. **/
	public static function software(name:String):StunAttribute {
		var bytes = new ByteArray();
		bytes.writeUTFBytes(name);
		bytes.position = 0;
		return new StunAttribute(ATTR_SOFTWARE, bytes);
	}

	/** The value of the first attribute of `type`, or null. **/
	public function attribute(type:Int):Null<ByteArray> {
		for (candidate in attributes) {
			if (candidate.type == type) {
				return candidate.value;
			}
		}

		return null;
	}

	/**
		The first attribute here that a receiver must understand and this code
		does not, or -1 when there is none.

		RFC 8489 section 14: a type below 0x8000 is comprehension-required. A
		success carrying one the receiver does not know is discarded and its
		transaction taken as failed (section 7.3.3), since whatever it changes
		about the answer is exactly what the receiver cannot see. Types from
		0x8000 up may be ignored, and are.

		Known means known to this stack: the STUN, TURN, ICE and RFC 5780
		attributes, and the five RFC 3489 ones old servers still send beside
		the rest.
	**/
	public function unknownRequiredAttribute():Int {
		for (attribute in attributes) {
			if (attribute.type < 0x8000 && !__understood(attribute.type)) {
				return attribute.type;
			}
		}

		return -1;
	}

	@:noCompletion private static function __understood(type:Int):Bool {
		return switch (type) {
			// MAPPED-ADDRESS, RFC 3489's RESPONSE-ADDRESS, CHANGE-REQUEST, RFC
			// 3489's SOURCE-ADDRESS and CHANGED-ADDRESS, USERNAME, RFC 3489's
			// PASSWORD, MESSAGE-INTEGRITY, ERROR-CODE, UNKNOWN-ATTRIBUTES, RFC
			// 3489's REFLECTED-FROM.
			case 0x0001, 0x0002, 0x0003, 0x0004, 0x0005, 0x0006, 0x0007, 0x0008, 0x0009, 0x000A, 0x000B: true;
			// CHANNEL-NUMBER, LIFETIME, XOR-PEER-ADDRESS, DATA, REALM, NONCE,
			// XOR-RELAYED-ADDRESS, REQUESTED-ADDRESS-FAMILY, EVEN-PORT,
			// REQUESTED-TRANSPORT, DONT-FRAGMENT.
			case 0x000C, 0x000D, 0x0012, 0x0013, 0x0014, 0x0015, 0x0016, 0x0017, 0x0018, 0x0019, 0x001A: true;
			// MESSAGE-INTEGRITY-SHA256, PASSWORD-ALGORITHM, USERHASH,
			// XOR-MAPPED-ADDRESS, RESERVATION-TOKEN, PRIORITY, USE-CANDIDATE,
			// PADDING, RESPONSE-PORT, CONNECTION-ID.
			case 0x001C, 0x001D, 0x001E, 0x0020, 0x0022, 0x0024, 0x0025, 0x0026, 0x0027, 0x002A: true;
			default: false;
		}
	}

	/** Whether the controlling peer marked this check as the chosen pair. **/
	public function hasUseCandidate():Bool {
		for (candidate in attributes) {
			if (candidate.type == ATTR_USE_CANDIDATE) {
				return true;
			}
		}

		return false;
	}

	// ------------------------------------------------------------------
	// Integrity
	// ------------------------------------------------------------------

	/**
		Encodes, appending `MESSAGE-INTEGRITY` and optionally `FINGERPRINT`.

		Both are computed over the message *as if they were already in it*: the
		header's length field is rewritten to cover the attribute about to be
		appended, and only then is the hash taken over everything before it.
		That is not an implementation quirk to work around -- it is what RFC
		5389 sections 15.4 and 15.5 specify, and getting it wrong produces a
		message that verifies perfectly against your own code and against
		nobody else's. It is the reason the tests here are pinned to RFC 5769's
		vectors rather than to a round trip.

		For ICE these use short-term credentials, where the key is the peer's
		password with nothing derived from it.

		@param password The credential the receiver will verify against.
		@param withFingerprint Whether to append `FINGERPRINT`. ICE requires it;
		a plain binding request to a public STUN server does not need it.
	**/
	public function encodeSigned(password:String, withFingerprint:Bool = true):ByteArray {
		return encodeSignedWithKey(Bytes.ofString(password), withFingerprint);
	}

	/**
		The same, keyed with bytes rather than a password.

		Short-term credentials use the password directly; long-term ones use a
		digest of the username, realm and password. The message layer does not
		care which, and taking the key rather than deriving it is what keeps
		that decision with the caller who knows the credential's kind.
	**/
	public function encodeSignedWithKey(key:Bytes, withFingerprint:Bool = true):ByteArray {
		var out = encode();

		__appendIntegrity(out, key);

		if (withFingerprint) {
			__appendFingerprint(out);
		}

		out.position = 0;
		return out;
	}

	/**
		Encodes, appending `MESSAGE-INTEGRITY-SHA256` and optionally
		`FINGERPRINT`: RFC 8489's HMAC-SHA256 in place of HMAC-SHA1, all
		thirty-two bytes of it, computed over the message as if it were
		already there -- the same rule `encodeSignedWithKey` follows.

		What a request carries once a server has offered PASSWORD-ALGORITHMS,
		which RFC 8489 section 9.2.5 has sign "using MESSAGE-INTEGRITY-SHA256
		only".
	**/
	public function encodeSignedSha256WithKey(key:Bytes, withFingerprint:Bool = true):ByteArray {
		var out = encode();

		__setLength(out, (out.length - HEADER_LENGTH) + 4 + INTEGRITY_SHA256_LENGTH);

		var mac = new Hmac(HashMethod.SHA256).make(key, __copy(out, out.length));

		out.endian = Endian.BIG_ENDIAN;
		out.position = out.length;
		out.writeShort(ATTR_MESSAGE_INTEGRITY_SHA256);
		out.writeShort(INTEGRITY_SHA256_LENGTH);

		for (i in 0...INTEGRITY_SHA256_LENGTH) {
			out.writeByte(mac.get(i));
		}

		if (withFingerprint) {
			__appendFingerprint(out);
		}

		out.position = 0;
		return out;
	}

	/**
		Whether this message carries a `MESSAGE-INTEGRITY-SHA256` that `key`
		produces. A value truncated to no fewer than sixteen bytes, a multiple
		of four, is checked as far as it goes, which RFC 8489 section 14.6
		allows; anything shorter is not believed.
	**/
	public function verifyIntegritySha256WithKey(key:Bytes):Bool {
		if (raw == null) {
			return false;
		}

		var at = __attributeOffset(raw, ATTR_MESSAGE_INTEGRITY_SHA256);

		if (at < 0 || at + 4 > raw.length) {
			return false;
		}

		var length:Int = (raw[at + 2] << 8) | raw[at + 3];

		if (length < 16 || length > INTEGRITY_SHA256_LENGTH || length % 4 != 0 || at + 4 + length > raw.length) {
			return false;
		}

		var covered = __covered(raw, at, (at - HEADER_LENGTH) + 4 + length);
		var expected = new Hmac(HashMethod.SHA256).make(key, covered);
		var difference:Int = 0;

		for (i in 0...length) {
			difference = difference | (expected.get(i) ^ raw[at + 4 + i]);
		}

		return difference == 0;
	}

	/**
		Whether this message's integrity checks out against `key`: the SHA-256
		form when it carries one, the SHA-1 form otherwise. What an answer to a
		signed request is believed by, whichever of the two its server writes.
	**/
	public function verifyAnyIntegrityWithKey(key:Bytes):Bool {
		return attribute(ATTR_MESSAGE_INTEGRITY_SHA256) != null ? verifyIntegritySha256WithKey(key) : verifyIntegrityWithKey(key);
	}

	/**
		Whether this message carries a `MESSAGE-INTEGRITY` that `password`
		produces.

		Checked against `raw` -- the bytes that actually arrived -- for the
		reason that field exists. Returns false rather than throwing when there
		is no integrity attribute at all, because an unauthenticated message is
		not a malformed one; it is simply not one this can accept.
	**/
	public function verifyIntegrity(password:String):Bool {
		return verifyIntegrityWithKey(Bytes.ofString(password));
	}

	/** The same, keyed with bytes: see `encodeSignedWithKey`. **/
	public function verifyIntegrityWithKey(key:Bytes):Bool {
		if (raw == null) {
			return false;
		}

		var at = __attributeOffset(raw, ATTR_MESSAGE_INTEGRITY);

		if (at < 0 || at + 4 + INTEGRITY_LENGTH > raw.length) {
			return false;
		}

		var covered = __covered(raw, at, (at - HEADER_LENGTH) + 4 + INTEGRITY_LENGTH);
		var expected = new Hmac(HashMethod.SHA1).make(key, covered);
		var difference:Int = 0;

		// Compared without a short circuit. A verifier that returns as soon as
		// two bytes differ leaks, in its timing, how much of a forged tag was
		// right -- which is enough to build the rest of one a byte at a time.
		for (i in 0...INTEGRITY_LENGTH) {
			difference = difference | (expected.get(i) ^ raw[at + 4 + i]);
		}

		return difference == 0;
	}

	/**
		Whether the `FINGERPRINT` matches, when there is one.

		This is not a security check and cannot be: anyone able to alter a
		message can recompute a CRC. It exists to tell STUN traffic apart from
		whatever else shares a port -- which is exactly the problem a peer using
		one socket for both STUN and its own protocol has.
	**/
	public function verifyFingerprint():Bool {
		if (raw == null) {
			return false;
		}

		var at = __attributeOffset(raw, ATTR_FINGERPRINT);

		if (at < 0 || at + 8 > raw.length) {
			return false;
		}

		var covered = __covered(raw, at, (at - HEADER_LENGTH) + 8);
		var expected:Int = Crc32.make(covered) ^ FINGERPRINT_XOR;

		raw.endian = Endian.BIG_ENDIAN;
		raw.position = at + 4;
		var found:Int = raw.readInt();

		return expected == found;
	}

	@:noCompletion private function __appendIntegrity(out:ByteArray, key:Bytes):Void {
		__setLength(out, (out.length - HEADER_LENGTH) + 4 + INTEGRITY_LENGTH);

		var mac = new Hmac(HashMethod.SHA1).make(key, __copy(out, out.length));

		out.endian = Endian.BIG_ENDIAN;
		out.position = out.length;
		out.writeShort(ATTR_MESSAGE_INTEGRITY);
		out.writeShort(INTEGRITY_LENGTH);

		for (i in 0...INTEGRITY_LENGTH) {
			out.writeByte(mac.get(i));
		}
	}

	@:noCompletion private function __appendFingerprint(out:ByteArray):Void {
		__setLength(out, (out.length - HEADER_LENGTH) + 8);

		var crc:Int = Crc32.make(__copy(out, out.length)) ^ FINGERPRINT_XOR;

		out.endian = Endian.BIG_ENDIAN;
		out.position = out.length;
		out.writeShort(ATTR_FINGERPRINT);
		out.writeShort(4);
		out.writeInt(crc);
	}

	/**
		Rewrites the header's length field in place.

		The field always states the body length the message will have once the
		attribute being computed is part of it, which is what makes the hash
		cover a message that does not exist yet.
	**/
	@:noCompletion private static function __setLength(bytes:ByteArray, length:Int):Void {
		var position = bytes.position;
		bytes.endian = Endian.BIG_ENDIAN;
		bytes.position = 2;
		bytes.writeShort(length);
		bytes.position = position;
	}

	/**
		The offset of an attribute within encoded bytes, walking the list rather
		than searching for the tag.

		Searching would find the same four bytes occurring inside some other
		attribute's value -- a transaction id or a software name can contain
		anything -- and hash the wrong span.
	**/
	@:noCompletion private static function __attributeOffset(bytes:ByteArray, type:Int):Int {
		if (bytes == null || bytes.length < HEADER_LENGTH) {
			return -1;
		}

		bytes.endian = Endian.BIG_ENDIAN;
		bytes.position = 2;

		var bodyLength:Int = bytes.readUnsignedShort();
		var limit:Int = HEADER_LENGTH + bodyLength;

		if (limit > bytes.length) {
			limit = bytes.length;
		}

		var offset:Int = HEADER_LENGTH;

		while (offset + 4 <= limit) {
			bytes.position = offset;

			var attributeType:Int = bytes.readUnsignedShort();
			var attributeLength:Int = bytes.readUnsignedShort();

			if (attributeType == type) {
				return offset;
			}

			var padding:Int = (4 - (attributeLength % 4)) % 4;
			offset += 4 + attributeLength + padding;
		}

		return -1;
	}

	/**
		A copy of the first `length` bytes.

		Byte by byte rather than through the underlying storage, because that
		route differs per target -- and one of them, hl, is where reaching for
		it has already broken a build. A STUN message is a hundred bytes; the
		loop costs nothing worth counting.
	**/
	/**
		The span a hash covers, with the length field it must state.

		One call rather than a copy followed by a rewrite. Those were two calls
		once, and the rewrite took a `ByteArray` where the copy produced a
		`Bytes` -- so it silently went through an implicit conversion, edited a
		temporary, and left the bytes being hashed carrying the original length.
		Signing was unaffected, because there the real message had already been
		rewritten before being copied, so the two paths disagreed and only one
		of them was wrong.
	**/
	@:noCompletion private static function __covered(bytes:ByteArray, upTo:Int, statedLength:Int):Bytes {
		var out = __copy(bytes, upTo);
		out.set(2, (statedLength >> 8) & 0xFF);
		out.set(3, statedLength & 0xFF);
		return out;
	}

	@:noCompletion private static function __copy(bytes:ByteArray, length:Int):Bytes {
		// One blit, not a byte loop with a bounds check per byte. This runs
		// once for every signed message that arrives -- each connectivity
		// check, each relay response -- and it neither needs nor touches the
		// stream position.
		var out = Bytes.alloc(length);
		out.blit(0, bytes, 0, length);
		return out;
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
