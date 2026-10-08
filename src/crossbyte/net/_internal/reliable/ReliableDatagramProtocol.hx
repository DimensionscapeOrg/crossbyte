package crossbyte.net._internal.reliable;

import crossbyte.Seq32;
import crossbyte.io.ByteArray;
import haxe.io.Bytes;

enum abstract ReliableDatagramFrameType(Int) from Int to Int {
	var CONNECT = 0;
	var HANDSHAKE = 1;
	var PACKET = 2;
	var ACK = 3;
	var FIN = 4;

	/** Sent once, never acknowledged or resent. **/
	var UNRELIABLE = 5;

	/**
		Unreliable, and dropped by the receiver when something newer has
		arrived on the same channel. The sequence field carries the channel in
		its top byte and a 24-bit counter below it; see `sequencedField`.
	**/
	var SEQUENCED = 6;

	/**
		About the peer's address, never acknowledged or resent: a server's
		join cookie, a client's REBIND and the server's answer to it. The
		first byte of the payload says which (`ReliableDatagramProtocol`'s
		`PATH_COOKIE`, `PATH_REBIND`, `PATH_REBOUND`), and a frame with none
		is not a frame. A peer from before 1.0 drops it, as a decoder drops
		every type it does not know.
	**/
	var PATH = 7;
}

final class ReliableDatagramFrame {
	public var resend(default, null):Bool;
	public var sequence(default, null):Seq32;
	public var type(default, null):ReliableDatagramFrameType;

	/**
		What the frame carries. Null on an ACK or a FIN that carries nothing,
		when it was decoded by `decodeInto`.
	**/
	public var payload(default, null):ByteArray;

	/**
		Whether the frame carries a cumulative acknowledgement, and its value.
		Two fields rather than a `Null<Seq32>`, which on hxcpp is an object
		made for every frame: sequence numbers start anywhere in 32 bits, so
		none of them is a small integer the runtime keeps made.
	**/
	public var hasAck(default, null):Bool;

	public var ackValue(default, null):Seq32;

	/** The acknowledgement, or null for none. For tests; not for a hot path. **/
	public var ack(get, never):Null<Seq32>;

	/**
		Whether more of this message follows in the next PACKET. Set on every
		fragment of a reliable message but the last.
	**/
	public var more(default, null):Bool;

	/**
		On a CONNECT or a HANDSHAKE: the sender takes bundles, several frames
		to a datagram. Every CONNECT and HANDSHAKE this build sends says so.
	**/
	public var bundles(default, null):Bool;

	/**
		On a FIN: a graceful close, holding the place in the sequence after
		the last frame its sender sent, and acted on in order. A FIN without
		it ends the session at once; see `ReliableDatagramProtocol`.
	**/
	public var graceful(default, null):Bool;

	/**
		On an ACK: how long, in seconds, its sender held it before sending it,
		from the arrival of the newest frame it acknowledges; -1 when it does
		not say. See `ReliableDatagramProtocol.ACK_DELAY_MASK`.
	**/
	public var ackDelay(default, null):Float;

	/**
		On a CONNECT: whether it came from a peer on 1.0 or later, which puts
		an extension ahead of what its `connect` passed (see
		`ReliableDatagramProtocol`), `payload` is then what `connect`
		passed, and nothing of the extension. With it, `features` is what
		the peer declares, and `hasCookie`, `cookieHigh` and `cookieLow` the
		join cookie it returns, if it returns one.

		Only a CONNECT sets these; on any other frame they say whatever the
		last CONNECT decoded into the same frame said, and nothing reads them.
	**/
	public var extended(default, null):Bool = false;

	/** On an extended CONNECT: `FEATURE_COOKIE`, `FEATURE_REBIND`, or'd. **/
	public var features(default, null):Int = 0;

	public var hasCookie(default, null):Bool = false;
	public var cookieHigh(default, null):Int = 0;
	public var cookieLow(default, null):Int = 0;

	/**
		On an extended CONNECT with `FEATURE_ENCRYPT`: its sender's random,
		`RANDOM_SIZE` bytes, in `random`, storage of the frame's own, made
		the first time and filled again for each, so read it before anything
		else is decoded into the frame.
	**/
	public var hasRandom(default, null):Bool = false;

	public var random(default, null):haxe.io.Bytes = null;

	/** For a frame to keep; the hot path decodes into one with `decodeInto`. **/
	public function new(type:ReliableDatagramFrameType, sequence:Seq32, payload:ByteArray, resend:Bool, ?ack:Seq32, more:Bool = false,
			bundles:Bool = false, graceful:Bool = false) {
		__set(type, sequence, payload, resend, ack == null ? 0 : (ack : Int), ack != null, more, bundles, graceful, -1);
	}

	@:noCompletion public inline function __set(type:ReliableDatagramFrameType, sequence:Seq32, payload:ByteArray, resend:Bool, ackValue:Seq32,
			hasAck:Bool, more:Bool, bundles:Bool, graceful:Bool, ackDelay:Float):Void {
		this.type = type;
		this.sequence = sequence;
		this.payload = payload;
		this.resend = resend;
		this.ackValue = ackValue;
		this.hasAck = hasAck;
		this.more = more;
		this.bundles = bundles;
		this.graceful = graceful;
		this.ackDelay = ackDelay;
	}

	@:noCompletion public inline function __setConnect(extended:Bool, features:Int, hasCookie:Bool, cookieHigh:Int, cookieLow:Int,
			hasRandom:Bool):Void {
		this.extended = extended;
		this.features = features;
		this.hasCookie = hasCookie;
		this.cookieHigh = cookieHigh;
		this.cookieLow = cookieLow;
		this.hasRandom = hasRandom;
	}

	/** Copies a CONNECT's random from `bytes` at `at` into the frame's own storage. **/
	@:noCompletion public function __takeRandom(bytes:haxe.io.Bytes, at:Int):Void {
		if (random == null) {
			random = haxe.io.Bytes.alloc(ReliableDatagramProtocol.RANDOM_SIZE);
		}
		random.blit(0, bytes, at, ReliableDatagramProtocol.RANDOM_SIZE);
	}

	private function get_ack():Null<Seq32> {
		return hasAck ? ackValue : null;
	}
}

/**
	The frame format: a two byte magic, a byte of type and flags, a four byte
	sequence, an optional four byte acknowledgement, then the payload. All of
	it big-endian.

	The flags byte holds the type in its low three bits, and above them:
	`GRACEFUL_MASK` (0x08), `BUNDLES_MASK` (0x10), `MORE_MASK` (0x20),
	`RESEND_MASK` (0x40) and `ACK_PRESENT_MASK` (0x80). A decoder that meets
	a type it does not know drops the frame, which is what lets a newer peer
	send types an older one has never heard of; and one that meets a flag it
	does not know ignores it, which is what lets a CONNECT say the sender
	takes bundles.

	A FIN comes in two kinds. One with `GRACEFUL_MASK` is a graceful close:
	its sequence is the place after the last frame its sender sent, and it
	is acknowledged, sent again and delivered in order exactly as a PACKET
	is, so its receiver acts on it only once everything sent before it has
	arrived. A FIN without it ends the session at once, whatever is still
	on its way: the abortive close, a server's answer to a peer it holds no
	session for, and every FIN a peer from before 1.0 sends, which also
	takes a graceful FIN that way, ignoring the flag, as it always took a
	FIN.

	An ACK's payload, when it has one, is a selective acknowledgement: a map
	of the frames the receiver holds past the cumulative acknowledgement,
	bit `i` of it, lowest bit of the first byte first, standing for frame
	`ack + 1 + i`. It names up to `SACK_BITS` frames and is cut after its
	last set byte. An ACK without one, from an older peer or one holding
	nothing past a gap, says only what the cumulative value says; an older
	peer given one ignores it.

	An ACK with `ACK_DELAY_MASK`, the bit a FIN calls graceful, which no
	ACK set before, starts its payload with two bytes saying how long its
	sender held it, in `ACK_DELAY_UNIT`s, and the map follows. Its receiver
	takes that off the round trip it measures, as QUIC's ACK Delay is taken
	off. Only a peer that said it reads them is sent one: a HANDSHAKE from
	this build carries six bytes, the peer's connection id echoed (0 for
	none) and then the most its sender holds an acknowledgement, in the same
	units, and a peer whose HANDSHAKE carries fewer is from before 1.0, and
	acknowledged every pass, as it always was.

	An ACK with `ACK_DUPLICATE_MASK`, the bit a PACKET calls a resend,
	which no ACK set before, was drawn by a frame its sender already had:
	a copy sent again after the first had arrived. Its receiver takes it as
	that copy delivered, RFC 2883's D-SACK put to the use RFC 8985 makes of
	it, and judges loss from when the copy went (see
	`ReliableDatagramSocket.__creditDuplicate`). A peer from before 1.0
	neither sends nor reads it.

	A bundle is several frames in one datagram: `BUNDLE_MAGIC`, then each
	frame preceded by its length in two bytes. A session sends one only to a
	peer whose CONNECT or HANDSHAKE said it takes them, since an older peer
	would drop the whole datagram as a frame with the wrong magic.

	A CONNECT from a peer on 1.0 or later sets `CONNECT_EXTENDED_MASK`,
	the bit a FIN calls graceful, and its payload starts with an
	extension, ahead of what the peer's `connect` passed: a byte saying how
	many bytes of extension follow it; a byte of features, `FEATURE_REBIND`
	(the sender answers a reset that carries a rebind challenge) and
	`FEATURE_COOKIE` (a join cookie follows); the cookie, `COOKIE_SIZE`
	bytes, when there is one; and zeros. The zeros pad the datagram to
	`MIN_CONNECT_SIZE`, the most anything sends back to a CONNECT, a
	cookie, or a HANDSHAKE carrying a rebind key, so that answering one
	never sends more than it was sent. A CONNECT with the bit that is
	shorter than that, or whose extension runs past its end, is not a
	frame. A peer from before 1.0 sets none of this, and read none of it:
	it took no payload on a CONNECT.

	A PATH frame is about the address its sender or receiver is at, and its
	payload starts with what it is. `PATH_COOKIE` is a server's answer to a
	CONNECT from an address it will not open a session for until the sender
	shows it receives there: the sequence field echoes the CONNECT's
	connection id, and the cookie follows, 16 bytes in all; the peer
	returns the cookie in its next CONNECT. A cookie is the server's keyed
	hash of the address, the port, the connection id and the time, so the
	server keeps nothing while it waits.

	A rebind moves a session to the address its peer's frames now come from
	(`ReliableDatagramServerSocket.allowRebind`). A server that allows it
	gives each peer whose CONNECT declared `FEATURE_REBIND` a key of
	`REBIND_KEY_SIZE` random bytes, after the six of its HANDSHAKE (22 in
	all), for as long as the peer has not shown it took the HANDSHAKE; a
	peer that reads six takes none, and is never offered a rebind. Its
	reset, the FIN that ends a session at once, answering a frame from an
	address with no session, then carries a challenge in its sequence
	field, where a reset carried 0: four bytes, the server's keyed hash of
	the address and port the frame came from and the time, never 0. A peer
	from before 1.0, or one with no key, ends its session on it as on any
	reset. A peer with a key, whose session is live, answers instead with a
	`PATH_REBIND`, 20 bytes: its connection id in the sequence field, then
	the challenge, then eight bytes of proof, its keyed hash with the
	session's key of the connection id and the challenge. A server that
	finds all three right moves the session to the address the REBIND came
	from, and answers from the session with a `PATH_REBOUND`, 12 bytes: the
	connection id, and the challenge it answers. Neither is acknowledged or
	resent: the peer sends its REBIND again until a REBOUND comes.

	An encrypted session (`ReliableDatagramSocket.encryptionKey`) seals
	every datagram it sends but its CONNECTs and its PATH frames; see
	`SessionCipher` for the envelopes, which start with a byte no frame
	starts with, and the keys. Its CONNECT says so with `FEATURE_ENCRYPT`,
	and carries its random, `RANDOM_SIZE` bytes, after the cookie when
	there is one. Answered with a sealed HANDSHAKE that carries the other
	side's random, an encrypted CONNECT is padded to
	`MIN_SEALED_CONNECT_SIZE` rather than `MIN_CONNECT_SIZE`; shorter, or
	with an extension too short for the random, it is not a frame. A peer
	from before this reads past the random as past padding, and answers
	in the clear, which the CONNECT's sender refuses.

	A server that will not open the session a CONNECT asks for, because
	of encryption, says why with a `PATH_REFUSE`, 9 bytes: the CONNECT's
	connection id in the sequence field, then the reason,
	`REFUSE_ENCRYPTION_REQUIRED` (the server gives this peer a key, and
	the CONNECT asked for none) or `REFUSE_NO_KEY` (the CONNECT asked for
	encryption, and the server has no key for it). It is no larger than
	the CONNECT it answers, and counts against `maxResetsPerSecond`.
**/
final class ReliableDatagramProtocol {
	public static inline var HEADER_SIZE:Int = 7;
	public static inline var ACK_FIELD_SIZE:Int = 4;
	public static inline var MAGIC:Int = 0xCBDA;
	public static inline var MAX_PAYLOAD_SIZE:Int = 1200;

	/** The largest frame there is: header, acknowledgement and a full payload. **/
	public static inline var MAX_FRAME_SIZE:Int = HEADER_SIZE + ACK_FIELD_SIZE + MAX_PAYLOAD_SIZE;

	/**
		The most frames past the cumulative acknowledgement a selective
		acknowledgement can name: the whole of the largest window, 500 frames,
		rounded up to whole bytes.
	**/
	public static inline var SACK_BITS:Int = 512;

	public static inline var SACK_BYTES:Int = SACK_BITS >> 3;

	/** The first two bytes of a datagram that carries several frames. **/
	public static inline var BUNDLE_MAGIC:Int = 0xCBDB;

	/** What a bundle adds: its magic once, and a length before each frame. **/
	public static inline var BUNDLE_HEADER_SIZE:Int = 2;

	public static inline var BUNDLE_ENTRY_SIZE:Int = 2;

	/**
		The most a bundle may be: the largest single frame. So bundling never
		sends a datagram larger than one frame already could, and a path that
		carries frames carries bundles.
	**/
	public static inline var BUNDLE_LIMIT:Int = MAX_FRAME_SIZE;

	/** Channels a SEQUENCED frame can name, and the counter's range within one. **/
	public static inline var SEQUENCED_COUNTER_MASK:Int = 0xFFFFFF;

	/** On an ACK: a delay leads the payload. The bit is `GRACEFUL_MASK`, which means that only on a FIN. **/
	public static inline var ACK_DELAY_MASK:Int = 0x08;

	/**
		On an ACK: a frame its sender already had drew it, a duplicate. The bit
		is `RESEND_MASK`, which means that only on a frame that is sent again;
		`encodeInto` sets it for `resend`, and a decoded ACK reads it as
		`resend`.
	**/
	public static inline var ACK_DUPLICATE_MASK:Int = 0x40;

	/** What one unit of an ACK's delay, or of a HANDSHAKE's announced one, stands for: ten microseconds. **/
	public static inline var ACK_DELAY_UNIT:Float = 0.00001;

	/** The longest delay two bytes of units say: 0.65535 seconds. **/
	public static inline var MAX_ACK_DELAY:Float = 0.65535;

	/** A HANDSHAKE's payload from this build: an echoed id, four bytes, and an announced delay, two. **/
	public static inline var HANDSHAKE_PAYLOAD_SIZE:Int = 6;

	/** On a CONNECT: its payload starts with the extension. The bit is `GRACEFUL_MASK`, which means that only on a FIN. **/
	public static inline var CONNECT_EXTENDED_MASK:Int = 0x08;

	/** A CONNECT's feature: a join cookie follows the features byte. **/
	public static inline var FEATURE_COOKIE:Int = 0x01;

	/** A CONNECT's feature: its sender answers a reset carrying a rebind challenge with a REBIND. **/
	public static inline var FEATURE_REBIND:Int = 0x02;

	/**
		A CONNECT's feature: its sender seals its session, and its random,
		`RANDOM_SIZE` bytes, follows the features byte, and the cookie when
		there is one.
	**/
	public static inline var FEATURE_ENCRYPT:Int = 0x04;

	/** The random an encrypted CONNECT carries. **/
	public static inline var RANDOM_SIZE:Int = SessionCipher.RANDOM_SIZE;

	/** A join cookie's length. **/
	public static inline var COOKIE_SIZE:Int = 8;

	/** The secret a HANDSHAKE gives a peer that may rebind. **/
	public static inline var REBIND_KEY_SIZE:Int = 16;

	/**
		The most a server sends back to a CONNECT, and so the least an
		extended CONNECT may be: a HANDSHAKE carrying a rebind key, 29 bytes.
		A cookie's frame is 16.
	**/
	public static inline var MIN_CONNECT_SIZE:Int = HEADER_SIZE + HANDSHAKE_PAYLOAD_SIZE + REBIND_KEY_SIZE;

	/** The most an extension adds to a CONNECT whose payload needs no padding: its length, its features, a cookie. **/
	public static inline var CONNECT_EXTENSION_MAX:Int = 2 + COOKIE_SIZE;

	/** And to an encrypted CONNECT's: the random besides. **/
	public static inline var SEALED_CONNECT_EXTENSION_MAX:Int = CONNECT_EXTENSION_MAX + RANDOM_SIZE;

	/**
		The most a server sends back to an encrypted CONNECT, and so the least
		one may be: its HANDSHAKE, sealed as a hello, 54 bytes.
	**/
	public static inline var MIN_SEALED_CONNECT_SIZE:Int = SessionCipher.HELLO_OVERHEAD + HEADER_SIZE + HANDSHAKE_PAYLOAD_SIZE;

	/** A PATH frame's kinds, its payload's first byte. **/
	public static inline var PATH_COOKIE:Int = 1;

	public static inline var PATH_REBIND:Int = 2;
	public static inline var PATH_REBOUND:Int = 3;
	public static inline var PATH_REFUSE:Int = 4;

	/** A REFUSE's reasons: the server encrypts this session, and the CONNECT asked for no encryption. **/
	public static inline var REFUSE_ENCRYPTION_REQUIRED:Int = 1;

	/** The CONNECT asked for encryption, and the server has no key for it. **/
	public static inline var REFUSE_NO_KEY:Int = 2;

	/** A REFUSE's frame: the header, the kind, the reason; 9 bytes. **/
	public static inline var REFUSE_FRAME_SIZE:Int = HEADER_SIZE + 2;

	/** A cookie's frame: the header, the kind, the cookie. **/
	public static inline var COOKIE_FRAME_SIZE:Int = HEADER_SIZE + 1 + COOKIE_SIZE;

	/** A rebind challenge: four bytes, in a reset's sequence field and in the REBIND and REBOUND after it. **/
	public static inline var CHALLENGE_SIZE:Int = 4;

	/** A REBIND's proof that its sender holds the session's rebind key. **/
	public static inline var REBIND_PROOF_SIZE:Int = 8;

	/** A REBIND's frame: the header, the kind, the challenge, the proof; 20 bytes. **/
	public static inline var REBIND_FRAME_SIZE:Int = HEADER_SIZE + 1 + CHALLENGE_SIZE + REBIND_PROOF_SIZE;

	/** A REBOUND's frame: the header, the kind, the challenge it answers; 12 bytes. **/
	public static inline var REBOUND_FRAME_SIZE:Int = HEADER_SIZE + 1 + CHALLENGE_SIZE;

	/** A HANDSHAKE's payload when it gives a rebind key: the usual six bytes, then the key. **/
	public static inline var REBIND_HANDSHAKE_PAYLOAD_SIZE:Int = HANDSHAKE_PAYLOAD_SIZE + REBIND_KEY_SIZE;

	/** Seconds as whole `ACK_DELAY_UNIT`s, held to two bytes. **/
	public static inline function delayUnits(seconds:Float):Int {
		if (!(seconds > 0)) {
			return 0;
		}
		var units:Int = Std.int(seconds / ACK_DELAY_UNIT + 0.5);
		return units > 0xFFFF ? 0xFFFF : units;
	}

	@:noCompletion private static inline var ACK_PRESENT_MASK:Int = 0x80;
	@:noCompletion private static inline var RESEND_MASK:Int = 0x40;
	@:noCompletion private static inline var MORE_MASK:Int = 0x20;
	@:noCompletion private static inline var BUNDLES_MASK:Int = 0x10;
	@:noCompletion private static inline var GRACEFUL_MASK:Int = 0x08;
	@:noCompletion private static inline var TYPE_MASK:Int = 0x07;

	/**
		A SEQUENCED frame's sequence field: the channel in the top byte and the
		counter, which wraps at 2^24, below it. One field rather than a byte of
		its own, so the frame is the same size as any other.
	**/
	public static inline function sequencedField(channel:Int, counter:Int):Seq32 {
		return (channel << 24) | (counter & SEQUENCED_COUNTER_MASK);
	}

	public static inline function channelOf(field:Seq32):Int {
		return ((field : Int) >>> 24) & 0xFF;
	}

	public static inline function counterOf(field:Seq32):Int {
		return (field : Int) & SEQUENCED_COUNTER_MASK;
	}

	/**
		Whether counter `a` is newer than `b` on a 24-bit wrapping scale: it is
		ahead by less than half the range. The same rule `Seq32` applies at 32
		bits, so a channel keeps its order across the wrap.
	**/
	public static inline function counterIsNewer(a:Int, b:Int):Bool {
		var ahead:Int = (a - b) & SEQUENCED_COUNTER_MASK;
		return ahead != 0 && ahead < 0x800000;
	}

	public static function decode(packet:ByteArray):ReliableDatagramFrame {
		if (packet == null) {
			return null;
		}
		return decodeRange(packet, 0, packet.length);
	}

	/**
		The frame in `length` bytes of `packet` from `from`: a whole datagram,
		or one entry of a bundle. Null for anything that is not a frame this
		build knows.
	**/
	public static function decodeRange(packet:ByteArray, from:Int, length:Int):ReliableDatagramFrame {
		return decodeInto(packet, from, length, false, new ReliableDatagramFrame(ACK, 0, null, false), true);
	}

	/**
		`decodeRange` into a frame the caller keeps for the purpose, which
		is what a session does with each arrival: nothing holds a decoded
		frame past the call that takes it, so one frame serves them all, where
		each had one made for it.

		@param owned Whether `packet` is this frame's alone, a datagram made
		       for it that nobody else reads: then a frame that is the whole
		       datagram carries its payload in `packet` itself, moved down to
		       its start, rather than in a copy.
		@param keepEmpty Whether an ACK or a FIN with nothing in it is given
		       an empty payload, as `decodeRange` gives one; a session passes
		       false, and reads null.
		@param reuse A payload of the caller's to copy a payload into, when
		       one is copied, in place of a new one: the caller's to empty
		       once it has finished with the frame (see `Arrivals`).
		@return `into`, or null for anything that is not a frame this build
		        knows, `into` then unchanged.
	**/
	public static function decodeInto(packet:ByteArray, from:Int, length:Int, owned:Bool, into:ReliableDatagramFrame,
			keepEmpty:Bool = false, ?reuse:ByteArray):ReliableDatagramFrame {
		// Read off the storage rather than through the stream API: the header
		// is a handful of fixed offsets, and a datagram is decoded for every
		// packet a session receives.
		if (length < HEADER_SIZE) {
			return null;
		}

		var bytes:Bytes = packet;
		if (((bytes.get(from) << 8) | bytes.get(from + 1)) != MAGIC) {
			return null;
		}

		var meta:Int = bytes.get(from + 2);
		// Every value the three bits can hold is a type now, PATH the last.
		var typeValue:Int = meta & TYPE_MASK;

		var ackPresent:Bool = (meta & ACK_PRESENT_MASK) != 0;
		var start:Int = HEADER_SIZE;
		if (ackPresent) {
			if (length < HEADER_SIZE + ACK_FIELD_SIZE) {
				return null;
			}
			start += ACK_FIELD_SIZE;
		}

		var sequence:Seq32 = __getInt(bytes, from + 3);
		var ack:Int = ackPresent ? __getInt(bytes, from + HEADER_SIZE) : 0;

		// An ACK that says how long it was held: the two bytes lead the payload.
		var delay:Float = -1;
		if (typeValue == (ACK : Int) && (meta & ACK_DELAY_MASK) != 0) {
			if (length < start + 2) {
				return null;
			}
			delay = ((bytes.get(from + start) << 8) | bytes.get(from + start + 1)) * ACK_DELAY_UNIT;
			start += 2;
		}

		// A CONNECT's extension, read off and stepped over: what is left is
		// what the peer's connect passed.
		var connect:Bool = typeValue == (CONNECT : Int);
		var extended:Bool = false;
		var features:Int = 0;
		var hasCookie:Bool = false;
		var cookieHigh:Int = 0;
		var cookieLow:Int = 0;
		var hasRandom:Bool = false;
		if (connect && (meta & CONNECT_EXTENDED_MASK) != 0) {
			// Padded by every sender to what may be sent back: shorter, it
			// would draw more than it brought.
			if (length < MIN_CONNECT_SIZE || length < start + 2) {
				return null;
			}
			var extension:Int = bytes.get(from + start);
			if (extension < 1 || start + 1 + extension > length) {
				return null;
			}
			features = bytes.get(from + start + 1);
			if ((features & FEATURE_COOKIE) != 0) {
				if (extension < 1 + COOKIE_SIZE) {
					return null;
				}
				hasCookie = true;
				cookieHigh = __getInt(bytes, from + start + 2);
				cookieLow = __getInt(bytes, from + start + 6);
			}
			if ((features & FEATURE_ENCRYPT) != 0) {
				// The random after the cookie, and padded to what a sealed
				// answer is. Copied now, before the payload is moved over it.
				var before:Int = hasCookie ? COOKIE_SIZE : 0;
				if (extension < 1 + before + RANDOM_SIZE || length < MIN_SEALED_CONNECT_SIZE) {
					return null;
				}
				into.__takeRandom(bytes, from + start + 2 + before);
				hasRandom = true;
			}
			extended = true;
			start += 1 + extension;
		} else if (typeValue == (PATH : Int) && length <= start) {
			// A PATH frame says what it is in its first byte.
			return null;
		}

		var payloadLength:Int = length - start;
		var payload:ByteArray = null;
		if (payloadLength == 0 && !keepEmpty && (typeValue == (ACK : Int) || typeValue == (FIN : Int))) {
			// Nothing reads one.
		} else if (owned && from == 0 && length == packet.length) {
			// Moved down within its own buffer: overlapping, and moving down,
			// which every target copies safely.
			if (payloadLength > 0) {
				bytes.blit(0, bytes, start, payloadLength);
			}
			packet.length = payloadLength;
			payload = packet;
		} else if (reuse != null) {
			crossbyte.events._internal.Arrivals.refill(reuse, bytes, from + start, payloadLength);
			payload = reuse;
		} else {
			payload = new ByteArray();
			if (payloadLength > 0) {
				payload.length = payloadLength;
				(payload : Bytes).blit(0, bytes, from + start, payloadLength);
			}
		}
		if (payload != null) {
			payload.position = 0;
		}

		into.__set(cast typeValue, sequence, payload, (meta & RESEND_MASK) != 0, ack, ackPresent, (meta & MORE_MASK) != 0,
			(meta & BUNDLES_MASK) != 0, typeValue == (FIN : Int) && (meta & GRACEFUL_MASK) != 0, delay);
		if (connect) {
			into.__setConnect(extended, features, hasCookie, cookieHigh, cookieLow, hasRandom);
		}
		return into;
	}

	/**
		Writes the payload of an extended CONNECT into `out` at `at`, the
		extension, padded to `MIN_CONNECT_SIZE` for the whole frame, then
		`length` bytes of `payload` from `offset`, and says how many bytes
		it took. The frame it goes in sets `CONNECT_EXTENDED_MASK` and
		carries no acknowledgement. `out` must have room:
		`CONNECT_EXTENSION_MAX` more than the payload, or `MIN_CONNECT_SIZE`.

		@param features `FEATURE_REBIND`, or 0; `FEATURE_COOKIE` is added
		       when `hasCookie`, and `FEATURE_ENCRYPT` with a `random`.
		@param random The sender's random, for an encrypted session; the
		       frame is then padded to `MIN_SEALED_CONNECT_SIZE`, and `out`
		       needs `SEALED_CONNECT_EXTENSION_MAX` more than the payload,
		       or that.
	**/
	public static function writeConnectPayload(out:Bytes, at:Int, features:Int, hasCookie:Bool, cookieHigh:Int, cookieLow:Int, payload:Bytes,
			offset:Int, length:Int, ?random:Bytes):Int {
		var extension:Int = 1 + (hasCookie ? COOKIE_SIZE : 0) + (random != null ? RANDOM_SIZE : 0);
		// Zeros after the cookie and the random, until the frame is as long
		// as an answer.
		var short:Int = (random != null ? MIN_SEALED_CONNECT_SIZE : MIN_CONNECT_SIZE) - (HEADER_SIZE + 1 + extension + length);
		if (short > 0) {
			extension += short;
		}
		features = hasCookie ? (features | FEATURE_COOKIE) : (features & ~FEATURE_COOKIE);
		features = random != null ? (features | FEATURE_ENCRYPT) : (features & ~FEATURE_ENCRYPT);
		out.set(at, extension);
		out.set(at + 1, features);
		var next:Int = at + 2;
		if (hasCookie) {
			__setInt(out, next, cookieHigh);
			__setInt(out, next + 4, cookieLow);
			next += COOKIE_SIZE;
		}
		if (random != null) {
			out.blit(next, random, 0, RANDOM_SIZE);
			next += RANDOM_SIZE;
		}
		var end:Int = at + 1 + extension;
		while (next < end) {
			out.set(next, 0);
			next++;
		}
		if (payload != null && length > 0) {
			out.blit(next, payload, offset, length);
			next += length;
		}
		return next - at;
	}

	/**
		An extended CONNECT in a buffer of its own, as a 1.0 peer sends one;
		`encode` makes one from before 1.0. For tests, and for callers that
		want a frame to keep.
	**/
	public static function encodeConnect(connectionId:Int, ?payload:ByteArray, features:Int = FEATURE_REBIND, hasCookie:Bool = false,
			cookieHigh:Int = 0, cookieLow:Int = 0, ?random:Bytes):ByteArray {
		var length:Int = payload != null ? payload.length : 0;
		var body = new ByteArray();
		body.length = SEALED_CONNECT_EXTENSION_MAX + MIN_SEALED_CONNECT_SIZE + length;
		var written:Int = writeConnectPayload(body, 0, features, hasCookie, cookieHigh, cookieLow, payload, 0, length, random);
		var frame = new ByteArray();
		frame.length = HEADER_SIZE + written;
		var size:Int = encodeInto(frame, CONNECT, connectionId, body, 0, written, false, 0, false, false, 0, true);
		frame.length = size;
		frame.position = 0;
		return frame;
	}

	/** Whether a datagram is a bundle rather than a frame. **/
	public static function isBundle(packet:ByteArray):Bool {
		if (packet == null || packet.length < BUNDLE_HEADER_SIZE) {
			return false;
		}
		var bytes:Bytes = packet;
		return ((bytes.get(0) << 8) | bytes.get(1)) == BUNDLE_MAGIC;
	}

	/**
		The length of the bundle entry at `at`, whose frame begins
		`BUNDLE_ENTRY_SIZE` bytes later; or -1 where there is none, because
		the bundle has ended or the length runs past it. Read in a loop from
		`BUNDLE_HEADER_SIZE`, the caller keeping what came before a bad entry
		and stopping there.
	**/
	public static function bundleEntryLength(packet:ByteArray, at:Int):Int {
		var total:Int = packet.length;
		if (at < 0 || at > total - BUNDLE_ENTRY_SIZE) {
			return -1;
		}
		var bytes:Bytes = packet;
		var length:Int = (bytes.get(at) << 8) | bytes.get(at + 1);
		return length > total - at - BUNDLE_ENTRY_SIZE ? -1 : length;
	}

	/**
		A frame in a buffer of its own. `encodeInto` is the one to use per
		packet; this is kept for callers that want the frame to keep.
	**/
	public static function encode(type:ReliableDatagramFrameType, sequence:Seq32, ?payload:ByteArray, resend:Bool = false, ?ack:Seq32,
			more:Bool = false, graceful:Bool = false):ByteArray {
		var payloadLength:Int = payload != null ? payload.length : 0;
		var frame:ByteArray = new ByteArray();
		frame.length = HEADER_SIZE + ACK_FIELD_SIZE + payloadLength;
		var written:Int = encodeInto(frame, type, sequence, payload, 0, payloadLength, resend, ack == null ? 0 : (ack : Int), ack != null, more, 0,
			graceful);
		frame.length = written;
		frame.position = 0;
		return frame;
	}

	/**
		Writes a frame into `out` at `start`, and says how many bytes it took.
		Nothing is allocated: `out` is a buffer the caller reuses, a
		session's pending bundle, where each frame is written in place, which
		is safe because a send has finished with its bytes before it returns:
		natively it is a system call, and on Node `DatagramSocket.send` copies
		them first.

		A CONNECT or HANDSHAKE always says this build takes bundles.

		@param payload Whatever is to be carried, from `offset` for `length`
		       bytes; it must fit `MAX_PAYLOAD_SIZE`, which the socket checks
		       before it gets here.
		@param ack The cumulative acknowledgement, when `hasAck`.
		@param graceful The 0x08 bit: on a FIN, that it is the graceful kind,
		       in sequence; on an ACK, that its payload starts with a delay
		       (`ACK_DELAY_MASK`), which the caller has written there; on a
		       CONNECT, that its payload starts with the extension
		       (`CONNECT_EXTENDED_MASK`; see `writeConnectPayload`).
	**/
	public static function encodeInto(out:ByteArray, type:ReliableDatagramFrameType, sequence:Seq32, payload:ByteArray, offset:Int, length:Int,
			resend:Bool, ack:Int, hasAck:Bool, more:Bool, start:Int = 0, graceful:Bool = false):Int {
		var bytes:Bytes = out;
		var meta:Int = (type : Int);
		if (resend) {
			meta |= RESEND_MASK;
		}
		if (more) {
			meta |= MORE_MASK;
		}
		if (graceful) {
			meta |= GRACEFUL_MASK;
		}
		if (hasAck) {
			meta |= ACK_PRESENT_MASK;
		}
		if (type == CONNECT || type == HANDSHAKE) {
			meta |= BUNDLES_MASK;
		}

		bytes.set(start, MAGIC >> 8);
		bytes.set(start + 1, MAGIC & 0xFF);
		bytes.set(start + 2, meta);
		__setInt(bytes, start + 3, sequence);

		var at:Int = start + HEADER_SIZE;
		if (hasAck) {
			__setInt(bytes, at, ack);
			at += ACK_FIELD_SIZE;
		}

		if (payload != null && length > 0) {
			bytes.blit(at, payload, offset, length);
			at += length;
		}
		return at - start;
	}

	/** How many bytes `encodeInto` will write for a frame like this. **/
	public static inline function frameSize(length:Int, hasAck:Bool):Int {
		return HEADER_SIZE + (hasAck ? ACK_FIELD_SIZE : 0) + length;
	}

	private static inline function __setInt(bytes:Bytes, at:Int, value:Int):Void {
		bytes.set(at, value >>> 24);
		bytes.set(at + 1, (value >>> 16) & 0xFF);
		bytes.set(at + 2, (value >>> 8) & 0xFF);
		bytes.set(at + 3, value & 0xFF);
	}

	// Assembled with `|`, which leaves a 32-bit signed Int on every target:
	// the top byte shifted into the sign is the wrap Seq32 already expects.
	private static inline function __getInt(bytes:Bytes, at:Int):Int {
		return (bytes.get(at) << 24) | (bytes.get(at + 1) << 16) | (bytes.get(at + 2) << 8) | bytes.get(at + 3);
	}
}
