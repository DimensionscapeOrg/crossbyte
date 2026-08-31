package crossbyte.net._internal.stun;

import crossbyte.io.ByteArray;
import crossbyte.io.Endian;
import crossbyte.net.ReflexiveAddress;
import haxe.Int64;
import haxe.crypto.Crc32;
import haxe.crypto.Hmac;
import haxe.crypto.Hmac.HashMethod;
import haxe.crypto.Md5;
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
	public static inline var CREATE_PERMISSION_REQUEST:Int = 0x0008;
	public static inline var CREATE_PERMISSION_SUCCESS:Int = 0x0108;
	public static inline var CREATE_PERMISSION_ERROR:Int = 0x0118;

	public static inline var ATTR_LIFETIME:Int = 0x000D;
	public static inline var ATTR_XOR_PEER_ADDRESS:Int = 0x0012;
	public static inline var ATTR_DATA:Int = 0x0013;
	public static inline var ATTR_REALM:Int = 0x0014;
	public static inline var ATTR_NONCE:Int = 0x0015;
	public static inline var ATTR_XOR_RELAYED_ADDRESS:Int = 0x0016;
	public static inline var ATTR_REQUESTED_TRANSPORT:Int = 0x0019;

	/** The IANA protocol number for UDP, which is the only transport TURN relays here. **/
	public static inline var TRANSPORT_UDP:Int = 17;

	/** Sent when the server wants credentials it has not been given yet. **/
	public static inline var UNAUTHORIZED:Int = 401;

	/** Sent when the nonce a request was signed against has expired. **/
	public static inline var STALE_NONCE:Int = 438;

	/**
		XORed into the CRC so a STUN fingerprint cannot be mistaken for the
		start of some other protocol that also begins with a checksum. RFC 5389
		section 15.5 picks the ASCII of "STUN" for it.
	**/
	private static inline var FINGERPRINT_XOR:Int = 0x5354554E;

	/** SHA-1 output, and so the length of every MESSAGE-INTEGRITY value. **/
	private static inline var INTEGRITY_LENGTH:Int = 20;

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
		return new StunAttribute(ATTR_XOR_MAPPED_ADDRESS, __writeXorAddress(address, port));
	}

	@:noCompletion private static function __writeXorAddress(address:String, port:Int):ByteArray {
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
	**/
	public static function xorPeerAddress(address:String, port:Int):StunAttribute {
		return new StunAttribute(ATTR_XOR_PEER_ADDRESS, __writeXorAddress(address, port));
	}

	/**
		`XOR-RELAYED-ADDRESS`, the address an allocation was granted.

		Only a relay writes one. It is here for the same reason
		`xorMappedAddress` is: so the parser can be tested against something
		other than itself.
	**/
	public static function xorRelayed(address:String, port:Int):StunAttribute {
		return new StunAttribute(ATTR_XOR_RELAYED_ADDRESS, __writeXorAddress(address, port));
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
		var out = Bytes.alloc(length);
		var position = bytes.position;

		bytes.position = 0;

		for (i in 0...length) {
			out.set(i, bytes.readUnsignedByte());
		}

		bytes.position = position;
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
