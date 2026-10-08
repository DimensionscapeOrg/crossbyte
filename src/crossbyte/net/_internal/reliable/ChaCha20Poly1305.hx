package crossbyte.net._internal.reliable;

import haxe.ds.Vector;
import haxe.io.Bytes;

/**
	ChaCha20-Poly1305 as RFC 8439 defines it, the IETF AEAD, a 32-byte key,
	a 12-byte nonce and a 16-byte tag, in Haxe, for the targets that have
	no implementation of their own to call: the jvm (Java 8, which CI runs,
	has no ChaCha20; it came in Java 11), and HashLink, neko and the
	interpreter, where only the cipher's tests use it. Natively the session
	cipher calls libsodium, and on Node, Node's `crypto`; their output is
	the same bytes, which the tests check against each other and against
	the RFC's vectors.

	One object per key, made once: the key's words are kept, and sealing or
	opening allocates nothing. Every arithmetic step ends in `| 0` so it
	wraps at 32 bits on JavaScript too, where an `Int` is a double;
	elsewhere that is free.

	Poly1305 is worked in ten 13-bit limbs, as poly1305-donna's 16-bit
	version and TweetNaCl-js do, so every product fits 32 bits: there is no
	64-bit integer to multiply into on every target. Each sum of five
	products is below 2^32, read unsigned with `>>>`, and the carries are
	taken between halves. Nothing branches on a secret, and the tag is
	compared in full whichever byte differs first.

	Not thread-safe: one per direction of one session, used on its thread.
**/
@:noCompletion
final class ChaCha20Poly1305 {
	public static inline var KEY_SIZE:Int = 32;
	public static inline var NONCE_SIZE:Int = 12;
	public static inline var TAG_SIZE:Int = 16;

	@:noCompletion private var __k0:Int;
	@:noCompletion private var __k1:Int;
	@:noCompletion private var __k2:Int;
	@:noCompletion private var __k3:Int;
	@:noCompletion private var __k4:Int;
	@:noCompletion private var __k5:Int;
	@:noCompletion private var __k6:Int;
	@:noCompletion private var __k7:Int;

	// The block being used: sixteen words of keystream.
	@:noCompletion private final __ks:Vector<Int>;

	// Poly1305's accumulator and key, in 13-bit limbs, and the key's last
	// half as eight 16-bit words.
	@:noCompletion private var __h0:Int = 0;
	@:noCompletion private var __h1:Int = 0;
	@:noCompletion private var __h2:Int = 0;
	@:noCompletion private var __h3:Int = 0;
	@:noCompletion private var __h4:Int = 0;
	@:noCompletion private var __h5:Int = 0;
	@:noCompletion private var __h6:Int = 0;
	@:noCompletion private var __h7:Int = 0;
	@:noCompletion private var __h8:Int = 0;
	@:noCompletion private var __h9:Int = 0;
	@:noCompletion private var __r0:Int = 0;
	@:noCompletion private var __r1:Int = 0;
	@:noCompletion private var __r2:Int = 0;
	@:noCompletion private var __r3:Int = 0;
	@:noCompletion private var __r4:Int = 0;
	@:noCompletion private var __r5:Int = 0;
	@:noCompletion private var __r6:Int = 0;
	@:noCompletion private var __r7:Int = 0;
	@:noCompletion private var __r8:Int = 0;
	@:noCompletion private var __r9:Int = 0;
	@:noCompletion private final __pad:Vector<Int>;

	// Sixteen bytes: a block padded with zeros, the lengths block, a tag.
	@:noCompletion private final __scratch:Bytes;

	public function new(key:Bytes, offset:Int = 0) {
		if (key == null || key.length - offset < KEY_SIZE || offset < 0) {
			throw "A ChaCha20-Poly1305 key is " + KEY_SIZE + " bytes.";
		}
		__k0 = __word(key, offset);
		__k1 = __word(key, offset + 4);
		__k2 = __word(key, offset + 8);
		__k3 = __word(key, offset + 12);
		__k4 = __word(key, offset + 16);
		__k5 = __word(key, offset + 20);
		__k6 = __word(key, offset + 24);
		__k7 = __word(key, offset + 28);
		__ks = new Vector<Int>(16);
		__pad = new Vector<Int>(8);
		__scratch = Bytes.alloc(16);
	}

	/**
		Encrypts `length` bytes of `source` from `sourceOffset` into `target`
		at `targetOffset`, and writes the tag after them: `length + TAG_SIZE`
		bytes in all. `target` may be `source`, at the same offset. `aad` is
		authenticated and not encrypted; it may be null when `aadLength` is 0.
	**/
	public function seal(nonce:Bytes, nonceOffset:Int, aad:Null<Bytes>, aadOffset:Int, aadLength:Int, source:Bytes, sourceOffset:Int, length:Int,
			target:Bytes, targetOffset:Int):Void {
		var n0:Int = __word(nonce, nonceOffset);
		var n1:Int = __word(nonce, nonceOffset + 4);
		var n2:Int = __word(nonce, nonceOffset + 8);
		__start(n0, n1, n2);
		__xor(n0, n1, n2, source, sourceOffset, length, target, targetOffset);
		__authenticate(aad, aadOffset, aadLength, target, targetOffset, length);
		__finish(target, targetOffset + length);
	}

	/**
		Checks the tag that follows `length` bytes of ciphertext in `source`
		at `sourceOffset`, and only if it is right decrypts them into
		`target` at `targetOffset` (which may be `source`). False, with
		`target` untouched, for anything that does not authenticate.
	**/
	public function open(nonce:Bytes, nonceOffset:Int, aad:Null<Bytes>, aadOffset:Int, aadLength:Int, source:Bytes, sourceOffset:Int, length:Int,
			target:Bytes, targetOffset:Int):Bool {
		if (length < 0) {
			return false;
		}
		var n0:Int = __word(nonce, nonceOffset);
		var n1:Int = __word(nonce, nonceOffset + 4);
		var n2:Int = __word(nonce, nonceOffset + 8);
		__start(n0, n1, n2);
		__authenticate(aad, aadOffset, aadLength, source, sourceOffset, length);
		__finish(__scratch, 0);
		// Every byte compared, whichever differs first.
		var difference:Int = 0;
		var tag:Int = sourceOffset + length;
		for (i in 0...TAG_SIZE) {
			difference |= __scratch.get(i) ^ source.get(tag + i);
		}
		if (difference != 0) {
			return false;
		}
		__xor(n0, n1, n2, source, sourceOffset, length, target, targetOffset);
		return true;
	}

	/** RFC 8439's ChaCha20 block, for the tests: 64 bytes of keystream. **/
	public static function block(key:Bytes, counter:Int, nonce:Bytes):Bytes {
		var cipher = new ChaCha20Poly1305(key);
		cipher.__block(counter, __word(nonce, 0), __word(nonce, 4), __word(nonce, 8));
		var out = Bytes.alloc(64);
		for (i in 0...16) {
			out.setInt32(i * 4, cipher.__ks[i]);
		}
		return out;
	}

	/** RFC 8439's Poly1305 alone, for the tests: the tag of `message` under a 32-byte one-time key. **/
	public static function poly1305(key:Bytes, message:Bytes):Bytes {
		var mac = new ChaCha20Poly1305(Bytes.alloc(KEY_SIZE));
		for (i in 0...8) {
			mac.__ks[i] = __word(key, i * 4);
		}
		mac.__polyKey();
		var whole:Int = message.length >> 4;
		mac.__poly(message, 0, whole, 1 << 11);
		var left:Int = message.length - (whole << 4);
		if (left > 0) {
			// The last, short block: a 1 after it, zeros to the end, and no
			// bit above the block.
			var last = mac.__scratch;
			last.fill(0, 16, 0);
			last.blit(0, message, whole << 4, left);
			last.set(left, 1);
			mac.__poly(last, 0, 1, 0);
		}
		var tag = Bytes.alloc(TAG_SIZE);
		mac.__finish(tag, 0);
		return tag;
	}

	/** Block 0, whose first 32 bytes are Poly1305's key for this nonce. **/
	@:noCompletion private inline function __start(n0:Int, n1:Int, n2:Int):Void {
		__block(0, n0, n1, n2);
		__polyKey();
	}

	/** `length` bytes XORed with the keystream from block 1. **/
	@:noCompletion private function __xor(n0:Int, n1:Int, n2:Int, source:Bytes, sourceOffset:Int, length:Int, target:Bytes, targetOffset:Int):Void {
		var ks:Vector<Int> = __ks;
		var counter:Int = 1;
		var done:Int = 0;
		while (done < length) {
			__block(counter, n0, n1, n2);
			counter++;
			var take:Int = length - done;
			if (take > 64) {
				take = 64;
			}
			var at:Int = 0;
			// Four bytes to a word, while there are four.
			while (at + 4 <= take) {
				var word:Int = ks[at >> 2];
				var s:Int = sourceOffset + done + at;
				var t:Int = targetOffset + done + at;
				target.set(t, source.get(s) ^ (word & 0xFF));
				target.set(t + 1, source.get(s + 1) ^ ((word >>> 8) & 0xFF));
				target.set(t + 2, source.get(s + 2) ^ ((word >>> 16) & 0xFF));
				target.set(t + 3, source.get(s + 3) ^ (word >>> 24));
				at += 4;
			}
			while (at < take) {
				var word:Int = ks[at >> 2];
				target.set(targetOffset + done + at, source.get(sourceOffset + done + at) ^ ((word >>> ((at & 3) << 3)) & 0xFF));
				at++;
			}
			done += take;
		}
	}

	/** Poly1305 over the AAD and the ciphertext, each padded to 16 bytes, then their lengths. **/
	@:noCompletion private function __authenticate(aad:Null<Bytes>, aadOffset:Int, aadLength:Int, ciphertext:Bytes, offset:Int, length:Int):Void {
		if (aadLength > 0) {
			__padded(aad, aadOffset, aadLength);
		}
		if (length > 0) {
			__padded(ciphertext, offset, length);
		}
		var lengths:Bytes = __scratch;
		lengths.setInt32(0, aadLength);
		lengths.setInt32(4, 0);
		lengths.setInt32(8, length);
		lengths.setInt32(12, 0);
		__poly(lengths, 0, 1, 1 << 11);
	}

	@:noCompletion private function __padded(message:Bytes, offset:Int, length:Int):Void {
		var whole:Int = length >> 4;
		if (whole > 0) {
			__poly(message, offset, whole, 1 << 11);
		}
		var left:Int = length - (whole << 4);
		if (left > 0) {
			var last:Bytes = __scratch;
			last.fill(0, 16, 0);
			last.blit(0, message, offset + (whole << 4), left);
			__poly(last, 0, 1, 1 << 11);
		}
	}

	/** Takes Poly1305's key from the first eight words of `__ks`, clamped, and empties the accumulator. **/
	@:noCompletion private function __polyKey():Void {
		var ks:Vector<Int> = __ks;
		var t0:Int = ks[0] & 0xFFFF;
		var t1:Int = ks[0] >>> 16;
		var t2:Int = ks[1] & 0xFFFF;
		var t3:Int = ks[1] >>> 16;
		var t4:Int = ks[2] & 0xFFFF;
		var t5:Int = ks[2] >>> 16;
		var t6:Int = ks[3] & 0xFFFF;
		var t7:Int = ks[3] >>> 16;
		__r0 = t0 & 0x1fff;
		__r1 = ((t0 >>> 13) | (t1 << 3)) & 0x1fff;
		__r2 = ((t1 >>> 10) | (t2 << 6)) & 0x1f03;
		__r3 = ((t2 >>> 7) | (t3 << 9)) & 0x1fff;
		__r4 = ((t3 >>> 4) | (t4 << 12)) & 0x00ff;
		__r5 = (t4 >>> 1) & 0x1ffe;
		__r6 = ((t4 >>> 14) | (t5 << 2)) & 0x1fff;
		__r7 = ((t5 >>> 11) | (t6 << 5)) & 0x1f81;
		__r8 = ((t6 >>> 8) | (t7 << 8)) & 0x1fff;
		__r9 = (t7 >>> 5) & 0x007f;
		for (i in 0...4) {
			var word:Int = ks[4 + i];
			__pad[i * 2] = word & 0xFFFF;
			__pad[i * 2 + 1] = word >>> 16;
		}
		__h0 = 0;
		__h1 = 0;
		__h2 = 0;
		__h3 = 0;
		__h4 = 0;
		__h5 = 0;
		__h6 = 0;
		__h7 = 0;
		__h8 = 0;
		__h9 = 0;
	}

	/** `blocks` sixteen-byte blocks of `m` from `offset` into the accumulator; `hibit` is 1 << 11 for a full block. **/
	@:noCompletion private function __poly(m:Bytes, offset:Int, blocks:Int, hibit:Int):Void {
		var h0:Int = __h0;
		var h1:Int = __h1;
		var h2:Int = __h2;
		var h3:Int = __h3;
		var h4:Int = __h4;
		var h5:Int = __h5;
		var h6:Int = __h6;
		var h7:Int = __h7;
		var h8:Int = __h8;
		var h9:Int = __h9;
		var r0:Int = __r0;
		var r1:Int = __r1;
		var r2:Int = __r2;
		var r3:Int = __r3;
		var r4:Int = __r4;
		var r5:Int = __r5;
		var r6:Int = __r6;
		var r7:Int = __r7;
		var r8:Int = __r8;
		var r9:Int = __r9;
		var s1:Int = r1 * 5;
		var s2:Int = r2 * 5;
		var s3:Int = r3 * 5;
		var s4:Int = r4 * 5;
		var s5:Int = r5 * 5;
		var s6:Int = r6 * 5;
		var s7:Int = r7 * 5;
		var s8:Int = r8 * 5;
		var s9:Int = r9 * 5;
		var at:Int = offset;
		var left:Int = blocks;
		while (left > 0) {
			var t0:Int = m.get(at) | (m.get(at + 1) << 8);
			var t1:Int = m.get(at + 2) | (m.get(at + 3) << 8);
			var t2:Int = m.get(at + 4) | (m.get(at + 5) << 8);
			var t3:Int = m.get(at + 6) | (m.get(at + 7) << 8);
			var t4:Int = m.get(at + 8) | (m.get(at + 9) << 8);
			var t5:Int = m.get(at + 10) | (m.get(at + 11) << 8);
			var t6:Int = m.get(at + 12) | (m.get(at + 13) << 8);
			var t7:Int = m.get(at + 14) | (m.get(at + 15) << 8);
			h0 += t0 & 0x1fff;
			h1 += ((t0 >>> 13) | (t1 << 3)) & 0x1fff;
			h2 += ((t1 >>> 10) | (t2 << 6)) & 0x1fff;
			h3 += ((t2 >>> 7) | (t3 << 9)) & 0x1fff;
			h4 += ((t3 >>> 4) | (t4 << 12)) & 0x1fff;
			h5 += (t4 >>> 1) & 0x1fff;
			h6 += ((t4 >>> 14) | (t5 << 2)) & 0x1fff;
			h7 += ((t5 >>> 11) | (t6 << 5)) & 0x1fff;
			h8 += ((t6 >>> 8) | (t7 << 8)) & 0x1fff;
			h9 += (t7 >>> 5) | hibit;
			var c:Int = 0;
			var d0:Int = (c + h0 * r0 + h1 * s9 + h2 * s8 + h3 * s7 + h4 * s6) | 0;
			c = d0 >>> 13;
			d0 = ((d0 & 0x1fff) + h5 * s5 + h6 * s4 + h7 * s3 + h8 * s2 + h9 * s1) | 0;
			c += d0 >>> 13;
			d0 &= 0x1fff;
			var d1:Int = (c + h0 * r1 + h1 * r0 + h2 * s9 + h3 * s8 + h4 * s7) | 0;
			c = d1 >>> 13;
			d1 = ((d1 & 0x1fff) + h5 * s6 + h6 * s5 + h7 * s4 + h8 * s3 + h9 * s2) | 0;
			c += d1 >>> 13;
			d1 &= 0x1fff;
			var d2:Int = (c + h0 * r2 + h1 * r1 + h2 * r0 + h3 * s9 + h4 * s8) | 0;
			c = d2 >>> 13;
			d2 = ((d2 & 0x1fff) + h5 * s7 + h6 * s6 + h7 * s5 + h8 * s4 + h9 * s3) | 0;
			c += d2 >>> 13;
			d2 &= 0x1fff;
			var d3:Int = (c + h0 * r3 + h1 * r2 + h2 * r1 + h3 * r0 + h4 * s9) | 0;
			c = d3 >>> 13;
			d3 = ((d3 & 0x1fff) + h5 * s8 + h6 * s7 + h7 * s6 + h8 * s5 + h9 * s4) | 0;
			c += d3 >>> 13;
			d3 &= 0x1fff;
			var d4:Int = (c + h0 * r4 + h1 * r3 + h2 * r2 + h3 * r1 + h4 * r0) | 0;
			c = d4 >>> 13;
			d4 = ((d4 & 0x1fff) + h5 * s9 + h6 * s8 + h7 * s7 + h8 * s6 + h9 * s5) | 0;
			c += d4 >>> 13;
			d4 &= 0x1fff;
			var d5:Int = (c + h0 * r5 + h1 * r4 + h2 * r3 + h3 * r2 + h4 * r1) | 0;
			c = d5 >>> 13;
			d5 = ((d5 & 0x1fff) + h5 * r0 + h6 * s9 + h7 * s8 + h8 * s7 + h9 * s6) | 0;
			c += d5 >>> 13;
			d5 &= 0x1fff;
			var d6:Int = (c + h0 * r6 + h1 * r5 + h2 * r4 + h3 * r3 + h4 * r2) | 0;
			c = d6 >>> 13;
			d6 = ((d6 & 0x1fff) + h5 * r1 + h6 * r0 + h7 * s9 + h8 * s8 + h9 * s7) | 0;
			c += d6 >>> 13;
			d6 &= 0x1fff;
			var d7:Int = (c + h0 * r7 + h1 * r6 + h2 * r5 + h3 * r4 + h4 * r3) | 0;
			c = d7 >>> 13;
			d7 = ((d7 & 0x1fff) + h5 * r2 + h6 * r1 + h7 * r0 + h8 * s9 + h9 * s8) | 0;
			c += d7 >>> 13;
			d7 &= 0x1fff;
			var d8:Int = (c + h0 * r8 + h1 * r7 + h2 * r6 + h3 * r5 + h4 * r4) | 0;
			c = d8 >>> 13;
			d8 = ((d8 & 0x1fff) + h5 * r3 + h6 * r2 + h7 * r1 + h8 * r0 + h9 * s9) | 0;
			c += d8 >>> 13;
			d8 &= 0x1fff;
			var d9:Int = (c + h0 * r9 + h1 * r8 + h2 * r7 + h3 * r6 + h4 * r5) | 0;
			c = d9 >>> 13;
			d9 = ((d9 & 0x1fff) + h5 * r4 + h6 * r3 + h7 * r2 + h8 * r1 + h9 * r0) | 0;
			c += d9 >>> 13;
			d9 &= 0x1fff;
			c = ((c << 2) + c) | 0;
			c = (c + d0) | 0;
			d0 = c & 0x1fff;
			c = c >>> 13;
			d1 += c;
			h0 = d0;
			h1 = d1;
			h2 = d2;
			h3 = d3;
			h4 = d4;
			h5 = d5;
			h6 = d6;
			h7 = d7;
			h8 = d8;
			h9 = d9;
			at += 16;
			left--;
		}
		__h0 = h0;
		__h1 = h1;
		__h2 = h2;
		__h3 = h3;
		__h4 = h4;
		__h5 = h5;
		__h6 = h6;
		__h7 = h7;
		__h8 = h8;
		__h9 = h9;
	}

	/** The accumulator reduced, the key's last half added, and the tag written to `out` at `at`. **/
	@:noCompletion private function __finish(out:Bytes, at:Int):Void {
		var h0:Int = __h0;
		var h1:Int = __h1;
		var h2:Int = __h2;
		var h3:Int = __h3;
		var h4:Int = __h4;
		var h5:Int = __h5;
		var h6:Int = __h6;
		var h7:Int = __h7;
		var h8:Int = __h8;
		var h9:Int = __h9;

		// Carried all the way round, so each limb is 13 bits.
		var c:Int = h1 >>> 13;
		h1 &= 0x1fff;
		h2 += c;
		c = h2 >>> 13;
		h2 &= 0x1fff;
		h3 += c;
		c = h3 >>> 13;
		h3 &= 0x1fff;
		h4 += c;
		c = h4 >>> 13;
		h4 &= 0x1fff;
		h5 += c;
		c = h5 >>> 13;
		h5 &= 0x1fff;
		h6 += c;
		c = h6 >>> 13;
		h6 &= 0x1fff;
		h7 += c;
		c = h7 >>> 13;
		h7 &= 0x1fff;
		h8 += c;
		c = h8 >>> 13;
		h8 &= 0x1fff;
		h9 += c;
		c = h9 >>> 13;
		h9 &= 0x1fff;
		h0 = (h0 + c * 5) | 0;
		c = h0 >>> 13;
		h0 &= 0x1fff;
		h1 += c;
		c = h1 >>> 13;
		h1 &= 0x1fff;
		h2 += c;

		// h + 5 - 2^130: taken in place of h when it carries out of bit 130,
		// which is when h is at least the prime. Chosen by mask, not branch.
		var g0:Int = h0 + 5;
		c = g0 >>> 13;
		g0 &= 0x1fff;
		var g1:Int = h1 + c;
		c = g1 >>> 13;
		g1 &= 0x1fff;
		var g2:Int = h2 + c;
		c = g2 >>> 13;
		g2 &= 0x1fff;
		var g3:Int = h3 + c;
		c = g3 >>> 13;
		g3 &= 0x1fff;
		var g4:Int = h4 + c;
		c = g4 >>> 13;
		g4 &= 0x1fff;
		var g5:Int = h5 + c;
		c = g5 >>> 13;
		g5 &= 0x1fff;
		var g6:Int = h6 + c;
		c = g6 >>> 13;
		g6 &= 0x1fff;
		var g7:Int = h7 + c;
		c = g7 >>> 13;
		g7 &= 0x1fff;
		var g8:Int = h8 + c;
		c = g8 >>> 13;
		g8 &= 0x1fff;
		var g9:Int = h9 + c;
		c = g9 >>> 13;
		g9 &= 0x1fff;
		var mask:Int = (0 - c) | 0;
		var keep:Int = ~mask;
		h0 = (h0 & keep) | (g0 & mask);
		h1 = (h1 & keep) | (g1 & mask);
		h2 = (h2 & keep) | (g2 & mask);
		h3 = (h3 & keep) | (g3 & mask);
		h4 = (h4 & keep) | (g4 & mask);
		h5 = (h5 & keep) | (g5 & mask);
		h6 = (h6 & keep) | (g6 & mask);
		h7 = (h7 & keep) | (g7 & mask);
		h8 = (h8 & keep) | (g8 & mask);
		h9 = (h9 & keep) | (g9 & mask);

		// Into eight 16-bit words, and the pad added, mod 2^128.
		var w0:Int = (h0 | (h1 << 13)) & 0xFFFF;
		var w1:Int = ((h1 >>> 3) | (h2 << 10)) & 0xFFFF;
		var w2:Int = ((h2 >>> 6) | (h3 << 7)) & 0xFFFF;
		var w3:Int = ((h3 >>> 9) | (h4 << 4)) & 0xFFFF;
		var w4:Int = ((h4 >>> 12) | (h5 << 1) | (h6 << 14)) & 0xFFFF;
		var w5:Int = ((h6 >>> 2) | (h7 << 11)) & 0xFFFF;
		var w6:Int = ((h7 >>> 5) | (h8 << 8)) & 0xFFFF;
		var w7:Int = ((h8 >>> 8) | (h9 << 5)) & 0xFFFF;
		var pad:Vector<Int> = __pad;
		var f:Int = w0 + pad[0];
		out.set(at, f & 0xFF);
		out.set(at + 1, (f >>> 8) & 0xFF);
		f = (w1 + pad[1] + (f >>> 16)) | 0;
		out.set(at + 2, f & 0xFF);
		out.set(at + 3, (f >>> 8) & 0xFF);
		f = (w2 + pad[2] + (f >>> 16)) | 0;
		out.set(at + 4, f & 0xFF);
		out.set(at + 5, (f >>> 8) & 0xFF);
		f = (w3 + pad[3] + (f >>> 16)) | 0;
		out.set(at + 6, f & 0xFF);
		out.set(at + 7, (f >>> 8) & 0xFF);
		f = (w4 + pad[4] + (f >>> 16)) | 0;
		out.set(at + 8, f & 0xFF);
		out.set(at + 9, (f >>> 8) & 0xFF);
		f = (w5 + pad[5] + (f >>> 16)) | 0;
		out.set(at + 10, f & 0xFF);
		out.set(at + 11, (f >>> 8) & 0xFF);
		f = (w6 + pad[6] + (f >>> 16)) | 0;
		out.set(at + 12, f & 0xFF);
		out.set(at + 13, (f >>> 8) & 0xFF);
		f = (w7 + pad[7] + (f >>> 16)) | 0;
		out.set(at + 14, f & 0xFF);
		out.set(at + 15, (f >>> 8) & 0xFF);
	}

	/** The ChaCha20 block for `counter` and the nonce's words, into `__ks`. **/
	@:noCompletion private function __block(counter:Int, n0:Int, n1:Int, n2:Int):Void {
		var ks:Vector<Int> = __ks;
		var x0:Int = 0x61707865;
		var x1:Int = 0x3320646e;
		var x2:Int = 0x79622d32;
		var x3:Int = 0x6b206574;
		var x4:Int = __k0;
		var x5:Int = __k1;
		var x6:Int = __k2;
		var x7:Int = __k3;
		var x8:Int = __k4;
		var x9:Int = __k5;
		var x10:Int = __k6;
		var x11:Int = __k7;
		var x12:Int = counter;
		var x13:Int = n0;
		var x14:Int = n1;
		var x15:Int = n2;
		var round:Int = 0;
		while (round < 10) {
			x0 = (x0 + x4) | 0;
			x12 ^= x0;
			x12 = (x12 << 16) | (x12 >>> 16);
			x8 = (x8 + x12) | 0;
			x4 ^= x8;
			x4 = (x4 << 12) | (x4 >>> 20);
			x0 = (x0 + x4) | 0;
			x12 ^= x0;
			x12 = (x12 << 8) | (x12 >>> 24);
			x8 = (x8 + x12) | 0;
			x4 ^= x8;
			x4 = (x4 << 7) | (x4 >>> 25);
			x1 = (x1 + x5) | 0;
			x13 ^= x1;
			x13 = (x13 << 16) | (x13 >>> 16);
			x9 = (x9 + x13) | 0;
			x5 ^= x9;
			x5 = (x5 << 12) | (x5 >>> 20);
			x1 = (x1 + x5) | 0;
			x13 ^= x1;
			x13 = (x13 << 8) | (x13 >>> 24);
			x9 = (x9 + x13) | 0;
			x5 ^= x9;
			x5 = (x5 << 7) | (x5 >>> 25);
			x2 = (x2 + x6) | 0;
			x14 ^= x2;
			x14 = (x14 << 16) | (x14 >>> 16);
			x10 = (x10 + x14) | 0;
			x6 ^= x10;
			x6 = (x6 << 12) | (x6 >>> 20);
			x2 = (x2 + x6) | 0;
			x14 ^= x2;
			x14 = (x14 << 8) | (x14 >>> 24);
			x10 = (x10 + x14) | 0;
			x6 ^= x10;
			x6 = (x6 << 7) | (x6 >>> 25);
			x3 = (x3 + x7) | 0;
			x15 ^= x3;
			x15 = (x15 << 16) | (x15 >>> 16);
			x11 = (x11 + x15) | 0;
			x7 ^= x11;
			x7 = (x7 << 12) | (x7 >>> 20);
			x3 = (x3 + x7) | 0;
			x15 ^= x3;
			x15 = (x15 << 8) | (x15 >>> 24);
			x11 = (x11 + x15) | 0;
			x7 ^= x11;
			x7 = (x7 << 7) | (x7 >>> 25);
			x0 = (x0 + x5) | 0;
			x15 ^= x0;
			x15 = (x15 << 16) | (x15 >>> 16);
			x10 = (x10 + x15) | 0;
			x5 ^= x10;
			x5 = (x5 << 12) | (x5 >>> 20);
			x0 = (x0 + x5) | 0;
			x15 ^= x0;
			x15 = (x15 << 8) | (x15 >>> 24);
			x10 = (x10 + x15) | 0;
			x5 ^= x10;
			x5 = (x5 << 7) | (x5 >>> 25);
			x1 = (x1 + x6) | 0;
			x12 ^= x1;
			x12 = (x12 << 16) | (x12 >>> 16);
			x11 = (x11 + x12) | 0;
			x6 ^= x11;
			x6 = (x6 << 12) | (x6 >>> 20);
			x1 = (x1 + x6) | 0;
			x12 ^= x1;
			x12 = (x12 << 8) | (x12 >>> 24);
			x11 = (x11 + x12) | 0;
			x6 ^= x11;
			x6 = (x6 << 7) | (x6 >>> 25);
			x2 = (x2 + x7) | 0;
			x13 ^= x2;
			x13 = (x13 << 16) | (x13 >>> 16);
			x8 = (x8 + x13) | 0;
			x7 ^= x8;
			x7 = (x7 << 12) | (x7 >>> 20);
			x2 = (x2 + x7) | 0;
			x13 ^= x2;
			x13 = (x13 << 8) | (x13 >>> 24);
			x8 = (x8 + x13) | 0;
			x7 ^= x8;
			x7 = (x7 << 7) | (x7 >>> 25);
			x3 = (x3 + x4) | 0;
			x14 ^= x3;
			x14 = (x14 << 16) | (x14 >>> 16);
			x9 = (x9 + x14) | 0;
			x4 ^= x9;
			x4 = (x4 << 12) | (x4 >>> 20);
			x3 = (x3 + x4) | 0;
			x14 ^= x3;
			x14 = (x14 << 8) | (x14 >>> 24);
			x9 = (x9 + x14) | 0;
			x4 ^= x9;
			x4 = (x4 << 7) | (x4 >>> 25);
			round++;
		}
		ks[0] = (x0 + 0x61707865) | 0;
		ks[1] = (x1 + 0x3320646e) | 0;
		ks[2] = (x2 + 0x79622d32) | 0;
		ks[3] = (x3 + 0x6b206574) | 0;
		ks[4] = (x4 + __k0) | 0;
		ks[5] = (x5 + __k1) | 0;
		ks[6] = (x6 + __k2) | 0;
		ks[7] = (x7 + __k3) | 0;
		ks[8] = (x8 + __k4) | 0;
		ks[9] = (x9 + __k5) | 0;
		ks[10] = (x10 + __k6) | 0;
		ks[11] = (x11 + __k7) | 0;
		ks[12] = (x12 + counter) | 0;
		ks[13] = (x13 + n0) | 0;
		ks[14] = (x14 + n1) | 0;
		ks[15] = (x15 + n2) | 0;
	}

	/** Four bytes, little-endian, as a word. **/
	@:noCompletion private static inline function __word(bytes:Bytes, at:Int):Int {
		return bytes.get(at) | (bytes.get(at + 1) << 8) | (bytes.get(at + 2) << 16) | (bytes.get(at + 3) << 24);
	}
}
