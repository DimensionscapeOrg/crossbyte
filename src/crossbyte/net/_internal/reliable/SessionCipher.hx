package crossbyte.net._internal.reliable;

import crossbyte.crypto._internal.HmacSha256;
import haxe.ds.Vector;
import haxe.io.Bytes;
#if cpp
import cpp.Pointer;
import crossbyte.crypto._internal.NativeSodium;
#end

/**
	What an encrypted reliable UDP session seals each datagram with, and opens
	each one it is sent with: the netcode.io model, keyed by the application,
	with the nonce, the replay window and the per-direction keys QUIC and DTLS
	1.3 use.

	**The key schedule.** Each end of an attempt makes `RANDOM_SIZE` random
	bytes of its own, and sends them in the clear: the side that dials in its
	CONNECT, the other in its first sealed datagram (`SEALED_HELLO`). With
	both, and the application's 32-byte key, both ends derive the same keys
	with HKDF-SHA-256 (RFC 5869), as TLS 1.3 derives its traffic keys from
	both hellos' randoms:

	- PRK = HKDF-Extract(salt = the two randoms, lower first, IKM = the
	  application's key);
	- each sender's key = HKDF-Expand(PRK, "cbrudp1 key" + its random, 32),
	  and its IV = HKDF-Expand(PRK, "cbrudp1 iv" + its random, 12);
	- the session's rebind key = HKDF-Expand(PRK, "cbrudp1 rebind", 16).

	So the two directions have keys of their own, and both ends' randoms go
	into every key: an application that gives the same key to every session
	of a player, or to two attempts, still never seals two datagrams under
	one key and nonce, from either end. Two equal randoms, a CONNECT sent
	back at its sender, are refused, since they would give both directions
	one key.

	**The nonce** is the sender's IV XOR its packet number, a 64-bit counter
	from 0, big-endian in the last eight bytes, as TLS 1.3 and QUIC build
	theirs. Only its low 32 bits are sent; the receiver takes the full number
	nearest the highest it has opened (RFC 9000, appendix A.3), so a gap of
	up to 2^31 datagrams is bridged.

	**The envelope.** The plaintext is the datagram the session would have
	sent without encryption, one frame, or a bundle, whole:

	- `SEALED`: 0xCE, the packet number's low 32 bits, then the ciphertext
	  and the 16-byte tag. `OVERHEAD` = 21 bytes.
	- `SEALED_HELLO`: 0xCF, the connection id it answers (4 bytes, 0 for
	  none), the sender's random (16), the packet number (4), then the
	  ciphertext and the tag. 41 bytes. A side sends these until it has
	  opened a datagram from its peer, which shows the peer has both randoms.

	The header, everything before the ciphertext, is the associated data:
	authenticated, not encrypted. A plaintext reliable datagram starts with
	0xCB, so neither kind is mistaken for one, and a peer from before this
	drops both as frames with the wrong magic.

	**The replay window** is `REPLAY_WINDOW` packet numbers below the highest
	opened, a bit each, as DTLS's and IPsec's are (wider than their 64, as
	WireGuard's is, for a session sending thousands a second): a number seen
	before, or below the window, is dropped before anything is decrypted,
	and counted. Only a datagram that authenticates moves the window.

	Not thread-safe: one per session, on its thread.
**/
@:noCompletion
final class SessionCipher {
	/** The application's key, and each direction's. **/
	public static inline var KEY_SIZE:Int = 32;

	/** The random each end of an attempt contributes. **/
	public static inline var RANDOM_SIZE:Int = 16;

	public static inline var IV_SIZE:Int = 12;
	public static inline var TAG_SIZE:Int = 16;
	public static inline var REBIND_KEY_SIZE:Int = 16;

	/** A sealed datagram's first byte. **/
	public static inline var SEALED:Int = 0xCE;

	/** A sealed datagram carrying its sender's random, and the connection id it answers. **/
	public static inline var SEALED_HELLO:Int = 0xCF;

	/** The marker and the packet number's low 32 bits. **/
	public static inline var SEALED_HEADER:Int = 5;

	/** The marker, the connection id answered, the sender's random, the packet number. **/
	public static inline var HELLO_HEADER:Int = 1 + 4 + RANDOM_SIZE + 4;

	/** What sealing adds to a datagram: its header and the tag, 21 bytes. **/
	public static inline var OVERHEAD:Int = SEALED_HEADER + TAG_SIZE;

	/** What sealing adds to a hello: 41 bytes. **/
	public static inline var HELLO_OVERHEAD:Int = HELLO_HEADER + TAG_SIZE;

	/** Packet numbers below the highest opened that are still taken once each. **/
	public static inline var REPLAY_WINDOW:Int = 1024;

	/** What `open` answers for a datagram it drops. **/
	public static inline var FORGED:Int = -1;

	public static inline var REPLAYED:Int = -2;
	public static inline var LATE:Int = -3;

	/**
		Failed opens a session takes before it ends: 2^36, QUIC's integrity
		limit for this AEAD (RFC 9001, 6.6). A forger needs about that many
		tries for a fair chance at one tag.
	**/
	public static inline var FORGERY_LIMIT:Float = 68719476736.0;

	/**
		Whether sessions can be encrypted here: natively (libsodium), on Node
		(its `crypto`) and on the jvm (this package's own ChaCha20-Poly1305,
		since Java 8 has none). Not on HashLink, neko or the interpreter,
		which have no secure random source for the randoms the keys depend on.
	**/
	public static var isSupported(get, never):Bool;

	/** This end's random for the attempt. **/
	public var localRandom(default, null):Bytes;

	/** The peer's, once known. **/
	public var peerRandom(default, null):Null<Bytes> = null;

	/** Whether the keys are derived: the peer's random is known. **/
	public var ready(default, null):Bool = false;

	/** The session's rebind key, derived with the rest; never sent. **/
	public var rebindKey(default, null):Null<Bytes> = null;

	/** Datagrams dropped because they did not authenticate, were replayed, or were older than the window. **/
	public var forged(default, null):Float = 0;

	public var replayed(default, null):Float = 0;
	public var late(default, null):Float = 0;

	@:noCompletion private var __appKey:Null<Bytes>;
	@:noCompletion private var __send:Null<DirectionAead> = null;
	@:noCompletion private var __receive:Null<DirectionAead> = null;
	@:noCompletion private var __sendIv:Null<Bytes> = null;
	@:noCompletion private var __receiveIv:Null<Bytes> = null;
	@:noCompletion private final __nonce:Bytes;

	// The next packet number to send, and the highest opened, as two
	// 32-bit halves: a 64-bit integer is an object on some targets.
	@:noCompletion private var __sendHigh:Int = 0;
	@:noCompletion private var __sendLow:Int = 0;
	@:noCompletion private var __opened:Bool = false;
	@:noCompletion private var __highHigh:Int = 0;
	@:noCompletion private var __highLow:Int = 0;

	// A bit for each packet number in the window, filed by its low bits.
	@:noCompletion private final __window:Vector<Int>;

	/**
		@param appKey The application's key, `KEY_SIZE` bytes; copied.
		@param localRandom This end's random, `RANDOM_SIZE` bytes, or null
		       to make one from the secure random source.
	**/
	public function new(appKey:Bytes, ?localRandom:Bytes) {
		if (appKey == null || appKey.length != KEY_SIZE) {
			throw "An encryption key is " + KEY_SIZE + " bytes.";
		}
		__appKey = Bytes.alloc(KEY_SIZE);
		__appKey.blit(0, appKey, 0, KEY_SIZE);
		if (localRandom == null) {
			localRandom = Bytes.alloc(RANDOM_SIZE);
			localRandom.blit(0, crossbyte.crypto.SecureRandom.getSecureRandomBytes(RANDOM_SIZE), 0, RANDOM_SIZE);
		} else if (localRandom.length != RANDOM_SIZE) {
			throw "A session random is " + RANDOM_SIZE + " bytes.";
		}
		this.localRandom = localRandom;
		__nonce = Bytes.alloc(IV_SIZE);
		__window = new Vector<Int>(REPLAY_WINDOW >> 5);
		for (i in 0...__window.length) {
			__window[i] = 0;
		}
	}

	/**
		Takes the peer's random and derives every key from it. False, with
		nothing derived, for one equal to this end's, or once keys are derived
		from another; true again for the same one.
	**/
	public function derive(random:Bytes, offset:Int = 0):Bool {
		if (ready) {
			return sameRandom(random, offset);
		}
		var equal:Bool = true;
		var lowerFirst:Bool = true;
		for (i in 0...RANDOM_SIZE) {
			var mine:Int = localRandom.get(i);
			var theirs:Int = random.get(offset + i);
			if (mine != theirs) {
				equal = false;
				lowerFirst = mine < theirs;
				break;
			}
		}
		if (equal || __appKey == null) {
			return false;
		}
		var peer = Bytes.alloc(RANDOM_SIZE);
		peer.blit(0, random, offset, RANDOM_SIZE);

		var salt = Bytes.alloc(RANDOM_SIZE * 2);
		salt.blit(0, lowerFirst ? localRandom : peer, 0, RANDOM_SIZE);
		salt.blit(RANDOM_SIZE, lowerFirst ? peer : localRandom, 0, RANDOM_SIZE);
		var prk:Bytes = new HmacSha256(salt).mac(__appKey);
		var expand = new HmacSha256(prk);

		var sendKey:Bytes = __expand(expand, "cbrudp1 key", localRandom, KEY_SIZE);
		var receiveKey:Bytes = __expand(expand, "cbrudp1 key", peer, KEY_SIZE);
		__sendIv = __expand(expand, "cbrudp1 iv", localRandom, IV_SIZE);
		__receiveIv = __expand(expand, "cbrudp1 iv", peer, IV_SIZE);
		rebindKey = __expand(expand, "cbrudp1 rebind", null, REBIND_KEY_SIZE);
		__send = new DirectionAead(sendKey);
		__receive = new DirectionAead(receiveKey);
		sendKey.fill(0, KEY_SIZE, 0);
		receiveKey.fill(0, KEY_SIZE, 0);
		prk.fill(0, prk.length, 0);
		// The application's key has done its work.
		__appKey.fill(0, KEY_SIZE, 0);
		__appKey = null;
		peerRandom = peer;
		ready = true;
		return true;
	}

	/** Whether `random` at `offset` is the peer's, once it is known. **/
	public function sameRandom(random:Bytes, offset:Int = 0):Bool {
		if (peerRandom == null) {
			return false;
		}
		var difference:Int = 0;
		for (i in 0...RANDOM_SIZE) {
			difference |= peerRandom.get(i) ^ random.get(offset + i);
		}
		return difference == 0;
	}

	/**
		Seals `length` bytes of `source` from `offset` into `out`, from its
		start, and says how long the datagram is: `length + OVERHEAD`, or
		`length + HELLO_OVERHEAD` for a hello, which carries this end's random
		and `answering`, the connection id it answers. -1 once the packet
		numbers have run out (2^62 of them), which ends the session.
	**/
	public function seal(source:Bytes, offset:Int, length:Int, out:Bytes, hello:Bool, answering:Int):Int {
		if (!ready || __sendHigh >= 0x40000000) {
			return -1;
		}
		var header:Int;
		if (hello) {
			out.set(0, SEALED_HELLO);
			__setInt(out, 1, answering);
			out.blit(5, localRandom, 0, RANDOM_SIZE);
			header = HELLO_HEADER;
		} else {
			out.set(0, SEALED);
			header = SEALED_HEADER;
		}
		__setInt(out, header - 4, __sendLow);
		__nonceFor(__sendIv, __sendHigh, __sendLow);
		__send.seal(__nonce, out, header, source, offset, length, out, header);
		__sendLow = (__sendLow + 1) | 0;
		if (__sendLow == 0) {
			__sendHigh++;
		}
		return header + length + TAG_SIZE;
	}

	/**
		Opens the sealed datagram in `length` bytes of `data` into `out`, from
		its start, and says how many bytes of plaintext it held; or `FORGED`,
		`REPLAYED` or `LATE` for one dropped, each counted. A hello's random
		must already have been taken with `derive`.
	**/
	public function open(data:Bytes, length:Int, out:Bytes):Int {
		var header:Int = data.get(0) == SEALED_HELLO ? HELLO_HEADER : SEALED_HEADER;
		var plain:Int = length - header - TAG_SIZE;
		if (!ready || plain < 0) {
			forged++;
			return FORGED;
		}
		// The full packet number, nearest the next expected.
		var sent:Int = __getInt(data, header - 4);
		var expectHigh:Int = __highHigh;
		var expectLow:Int = __highLow;
		if (__opened) {
			expectLow = (expectLow + 1) | 0;
			if (expectLow == 0) {
				expectHigh++;
			}
		} else {
			expectHigh = 0;
			expectLow = 0;
		}
		var delta:Int = (sent - expectLow) | 0;
		var high:Int = expectHigh;
		if (delta >= 0) {
			if (__below(sent, expectLow)) {
				high++;
			}
		} else if (__below(expectLow, sent)) {
			high--;
		}
		if (high < 0) {
			late++;
			return LATE;
		}

		// Seen, or older than the window: dropped before anything is
		// decrypted.
		var newer:Bool = !__opened || high > __highHigh || (high == __highHigh && __below(__highLow, sent));
		if (!newer) {
			// How far below the highest: within the window only if the high
			// halves are equal, or one apart across a wrap of the low half.
			var gapLow:Int = (__highLow - sent) | 0;
			var gapHigh:Int = __highHigh - high - (__below(__highLow, sent) ? 1 : 0);
			if (gapHigh != 0 || __below(REPLAY_WINDOW - 1, gapLow)) {
				late++;
				return LATE;
			}
			if (__windowHas(sent)) {
				replayed++;
				return REPLAYED;
			}
		}

		__nonceFor(__receiveIv, high, sent);
		if (!__receive.open(__nonce, data, header, data, header, plain, out, 0)) {
			forged++;
			return FORGED;
		}

		if (newer) {
			__advance(high, sent);
		} else {
			__windowSet(sent);
		}
		return plain;
	}

	/** Wipes every key this holds; it seals and opens nothing after. **/
	public function dispose():Void {
		if (__appKey != null) {
			__appKey.fill(0, KEY_SIZE, 0);
			__appKey = null;
		}
		if (__send != null) {
			__send.dispose();
			__receive.dispose();
		}
		if (rebindKey != null) {
			rebindKey.fill(0, REBIND_KEY_SIZE, 0);
		}
		ready = false;
	}

	/** The highest packet number opened moves to `high`:`low`; the bits it passed over are cleared. **/
	@:noCompletion private function __advance(high:Int, low:Int):Void {
		if (!__opened) {
			__opened = true;
			for (i in 0...__window.length) {
				__window[i] = 0;
			}
		} else {
			var stepLow:Int = (low - __highLow) | 0;
			var stepHigh:Int = high - __highHigh - (__below(low, __highLow) ? 1 : 0);
			if (stepHigh != 0 || __below(REPLAY_WINDOW - 1, stepLow)) {
				for (i in 0...__window.length) {
					__window[i] = 0;
				}
			} else {
				var at:Int = (__highLow + 1) | 0;
				for (_ in 0...stepLow) {
					__windowClear(at);
					at = (at + 1) | 0;
				}
			}
		}
		__highHigh = high;
		__highLow = low;
		__windowSet(low);
	}

	@:noCompletion private inline function __windowHas(low:Int):Bool {
		return (__window[(low >>> 5) & ((REPLAY_WINDOW >> 5) - 1)] & (1 << (low & 31))) != 0;
	}

	@:noCompletion private inline function __windowSet(low:Int):Void {
		var word:Int = (low >>> 5) & ((REPLAY_WINDOW >> 5) - 1);
		__window[word] = __window[word] | (1 << (low & 31));
	}

	@:noCompletion private inline function __windowClear(low:Int):Void {
		var word:Int = (low >>> 5) & ((REPLAY_WINDOW >> 5) - 1);
		__window[word] = __window[word] & ~(1 << (low & 31));
	}

	/** The nonce for a packet number: the IV, its last eight bytes XOR the number, big-endian. **/
	@:noCompletion private inline function __nonceFor(iv:Bytes, high:Int, low:Int):Void {
		var nonce:Bytes = __nonce;
		for (i in 0...4) {
			nonce.set(i, iv.get(i));
		}
		nonce.set(4, iv.get(4) ^ (high >>> 24));
		nonce.set(5, iv.get(5) ^ ((high >>> 16) & 0xFF));
		nonce.set(6, iv.get(6) ^ ((high >>> 8) & 0xFF));
		nonce.set(7, iv.get(7) ^ (high & 0xFF));
		nonce.set(8, iv.get(8) ^ (low >>> 24));
		nonce.set(9, iv.get(9) ^ ((low >>> 16) & 0xFF));
		nonce.set(10, iv.get(10) ^ ((low >>> 8) & 0xFF));
		nonce.set(11, iv.get(11) ^ (low & 0xFF));
	}

	/** Whether `a` is below `b`, both read as unsigned 32-bit numbers. **/
	@:noCompletion private static inline function __below(a:Int, b:Int):Bool {
		return (a ^ 0x80000000) < (b ^ 0x80000000);
	}

	/** HKDF-Expand (RFC 5869) for at most 32 bytes: the first block, T(1). **/
	@:noCompletion private static function __expand(prk:HmacSha256, label:String, context:Null<Bytes>, length:Int):Bytes {
		var contextLength:Int = context == null ? 0 : context.length;
		var info = Bytes.alloc(label.length + contextLength + 1);
		for (i in 0...label.length) {
			info.set(i, StringTools.fastCodeAt(label, i));
		}
		if (context != null) {
			info.blit(label.length, context, 0, contextLength);
		}
		info.set(info.length - 1, 1);
		var block:Bytes = prk.mac(info);
		var out:Bytes = Bytes.alloc(length);
		out.blit(0, block, 0, length);
		block.fill(0, block.length, 0);
		return out;
	}

	@:noCompletion private static inline function __setInt(bytes:Bytes, at:Int, value:Int):Void {
		bytes.set(at, value >>> 24);
		bytes.set(at + 1, (value >>> 16) & 0xFF);
		bytes.set(at + 2, (value >>> 8) & 0xFF);
		bytes.set(at + 3, value & 0xFF);
	}

	@:noCompletion private static inline function __getInt(bytes:Bytes, at:Int):Int {
		return (bytes.get(at) << 24) | (bytes.get(at + 1) << 16) | (bytes.get(at + 2) << 8) | bytes.get(at + 3);
	}

	@:noCompletion private static function get_isSupported():Bool {
		#if cpp
		return crossbyte.crypto.SecureRandom.isSupported && NativeSodium.isAvailable();
		#elseif (nodejs || jvm || java)
		return crossbyte.crypto.SecureRandom.isSupported;
		#else
		return false;
		#end
	}
}

/**
	ChaCha20-Poly1305 under one direction's key, through whatever the target
	has: libsodium natively, Node's `crypto` on Node, `ChaCha20Poly1305`
	elsewhere. The associated data is the header in front of the ciphertext.
**/
@:noCompletion
private final class DirectionAead {
	#if cpp
	@:noCompletion private final __key:Bytes;
	#elseif nodejs
	// Node's crypto, and this package's own: each where it is faster.
	@:noCompletion private final __key:Dynamic;
	@:noCompletion private final __haxe:ChaCha20Poly1305;
	#else
	@:noCompletion private final __cipher:ChaCha20Poly1305;
	#end

	public function new(key:Bytes) {
		#if cpp
		__key = Bytes.alloc(key.length);
		__key.blit(0, key, 0, key.length);
		#elseif nodejs
		// A copy, as natively: the caller wipes its own.
		__key = NodeAead.available() ? js.Syntax.code("Buffer.from({0})", NodeAead.view(key, 0, key.length)) : null;
		__haxe = new ChaCha20Poly1305(key);
		#else
		__cipher = new ChaCha20Poly1305(key);
		#end
	}

	/** Seals `length` bytes of `source` into `target`, the tag after them; the AAD is `aad`'s first `aadLength` bytes. **/
	public function seal(nonce:Bytes, aad:Bytes, aadLength:Int, source:Bytes, sourceOffset:Int, length:Int, target:Bytes, targetOffset:Int):Void {
		#if cpp
		var rc:Int = NativeSodium.chachaEncrypt(cast Pointer.arrayElem(target.getData(), targetOffset), Pointer.arrayElem(source.getData(), sourceOffset),
			length, Pointer.arrayElem(aad.getData(), 0), aadLength, Pointer.arrayElem(nonce.getData(), 0), Pointer.arrayElem(__key.getData(), 0));
		if (rc != 0) {
			throw "libsodium crypto_aead_chacha20poly1305_ietf_encrypt failed: " + rc;
		}
		#elseif nodejs
		if (__key == null || length < NODE_CRYPTO_FROM) {
			__haxe.seal(nonce, 0, aad, 0, aadLength, source, sourceOffset, length, target, targetOffset);
		} else {
			NodeAead.seal(__key, nonce, aad, aadLength, source, sourceOffset, length, target, targetOffset);
		}
		#else
		__cipher.seal(nonce, 0, aad, 0, aadLength, source, sourceOffset, length, target, targetOffset);
		#end
	}

	/** Opens `length` bytes of ciphertext and the tag after them; false, `target` untouched, if they do not authenticate. **/
	public function open(nonce:Bytes, aad:Bytes, aadLength:Int, source:Bytes, sourceOffset:Int, length:Int, target:Bytes, targetOffset:Int):Bool {
		#if cpp
		if (length == 0) {
			// libsodium needs somewhere to write nothing.
			return NativeSodium.chachaDecrypt(cast Pointer.arrayElem(source.getData(), sourceOffset), Pointer.arrayElem(source.getData(), sourceOffset),
				TAG, Pointer.arrayElem(aad.getData(), 0), aadLength, Pointer.arrayElem(nonce.getData(), 0), Pointer.arrayElem(__key.getData(), 0)) == 0;
		}
		return NativeSodium.chachaDecrypt(cast Pointer.arrayElem(target.getData(), targetOffset), Pointer.arrayElem(source.getData(), sourceOffset),
			length + TAG, Pointer.arrayElem(aad.getData(), 0), aadLength, Pointer.arrayElem(nonce.getData(), 0),
			Pointer.arrayElem(__key.getData(), 0)) == 0;
		#elseif nodejs
		if (__key == null || length < NODE_CRYPTO_FROM) {
			return __haxe.open(nonce, 0, aad, 0, aadLength, source, sourceOffset, length, target, targetOffset);
		}
		return NodeAead.open(__key, nonce, aad, aadLength, source, sourceOffset, length, target, targetOffset);
		#else
		return __cipher.open(nonce, 0, aad, 0, aadLength, source, sourceOffset, length, target, targetOffset);
		#end
	}

	public function dispose():Void {
		#if cpp
		__key.fill(0, __key.length, 0);
		#elseif nodejs
		if (__key != null) {
			js.Syntax.code("{0}.fill(0)", __key);
		}
		#end
	}

	private static inline var TAG:Int = SessionCipher.TAG_SIZE;

	/**
		On Node, the length from which Node's `crypto` seals and opens, and
		below which this package's own code does. Each call into `crypto`
		makes a cipher object and buffers, about 3 microseconds whatever the
		length; the Haxe code costs about 0.4 plus 3.3 a kilobyte and makes
		nothing. Measured on Node 24: 100 bytes 3.2 against 0.7, 1,200 bytes
		3.5 against 4.4. The two give the same bytes.
	**/
	private static inline var NODE_CRYPTO_FROM:Int = 896;
}

#if nodejs
/** Node's `crypto` for ChaCha20-Poly1305, where its OpenSSL has it (every Node from 11.2). **/
@:noCompletion
private class NodeAead {
	static var __crypto:Dynamic = null;
	static var __checked:Bool = false;
	static var __available:Bool = false;

	public static function available():Bool {
		if (!__checked) {
			__checked = true;
			try {
				__crypto = js.Lib.require("crypto");
				__available = (__crypto.getCiphers() : Array<String>).indexOf("chacha20-poly1305") >= 0;
			} catch (_:Dynamic) {
				__available = false;
			}
		}
		return __available;
	}

	/** A `Buffer` over `length` bytes of `bytes` from `offset`: a view, nothing copied. **/
	public static inline function view(bytes:Bytes, offset:Int, length:Int):Dynamic {
		var array:js.lib.Uint8Array = @:privateAccess bytes.b;
		return js.Syntax.code("Buffer.from({0}.buffer, {0}.byteOffset + {1}, {2})", array, offset, length);
	}

	public static function seal(key:Dynamic, nonce:Bytes, aad:Bytes, aadLength:Int, source:Bytes, sourceOffset:Int, length:Int, target:Bytes,
			targetOffset:Int):Void {
		var cipher:Dynamic = __crypto.createCipheriv("chacha20-poly1305", key, view(nonce, 0, 12), {authTagLength: 16});
		cipher.setAAD(view(aad, 0, aadLength), {plaintextLength: length});
		var sealed:Dynamic = cipher.update(view(source, sourceOffset, length));
		js.Syntax.code("{0}.final()", cipher);
		var tag:Dynamic = cipher.getAuthTag();
		var out:Dynamic = view(target, targetOffset, length + 16);
		sealed.copy(out, 0);
		tag.copy(out, length);
	}

	public static function open(key:Dynamic, nonce:Bytes, aad:Bytes, aadLength:Int, source:Bytes, sourceOffset:Int, length:Int, target:Bytes,
			targetOffset:Int):Bool {
		try {
			var decipher:Dynamic = __crypto.createDecipheriv("chacha20-poly1305", key, view(nonce, 0, 12), {authTagLength: 16});
			decipher.setAAD(view(aad, 0, aadLength), {plaintextLength: length});
			decipher.setAuthTag(view(source, sourceOffset + length, 16));
			var opened:Dynamic = decipher.update(view(source, sourceOffset, length));
			// Throws for a tag that does not check out, before anything is
			// copied out.
			js.Syntax.code("{0}.final()", decipher);
			opened.copy(view(target, targetOffset, length), 0);
			return true;
		} catch (_:Dynamic) {
			return false;
		}
	}
}
#end
