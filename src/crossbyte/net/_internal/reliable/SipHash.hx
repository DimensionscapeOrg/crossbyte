package crossbyte.net._internal.reliable;

import haxe.io.Bytes;

/**
	SipHash-2-4 under one 128-bit key: a keyed hash of a short message, 64
	bits long, which nobody without the key can compute or predict. It is
	what a reliable datagram server makes its join cookies and its rebind
	challenges with, and what a session proves it holds its rebind secret
	with, each one a few dozen bytes, made or checked per CONNECT, per
	reset or per REBIND, and what Linux makes its SYN cookies with.

	Written over 32-bit halves, so it gives the same answer on every target,
	JavaScript's doubles included (every addition ends in `| 0`), and
	allocates nothing: the state is this object's, and the answer is left in
	`high` and `low`. Checked against libsodium's `crypto_shorthash`, which
	is the reference's 64 vectors.

	One object serves one thread: `hash` works in its fields.
**/
@:noCompletion
final class SipHash {
	/** The key's length, in bytes. **/
	public static inline var KEY_SIZE:Int = 16;

	/** The answer's top 32 bits: bytes 4 to 7 of it, little-endian, as libsodium stores it. **/
	public var high(default, null):Int = 0;

	/** The answer's low 32 bits: bytes 0 to 3. **/
	public var low(default, null):Int = 0;

	// The key: k0 and k1, each as its low and high word.
	@:noCompletion private var __k0l:Int;
	@:noCompletion private var __k0h:Int;
	@:noCompletion private var __k1l:Int;
	@:noCompletion private var __k1h:Int;

	// The state while hashing, each word as its low and high half.
	@:noCompletion private var __v0l:Int = 0;
	@:noCompletion private var __v0h:Int = 0;
	@:noCompletion private var __v1l:Int = 0;
	@:noCompletion private var __v1h:Int = 0;
	@:noCompletion private var __v2l:Int = 0;
	@:noCompletion private var __v2h:Int = 0;
	@:noCompletion private var __v3l:Int = 0;
	@:noCompletion private var __v3h:Int = 0;

	/** Keyed with the `KEY_SIZE` bytes of `key` from `at`, read as libsodium reads them. **/
	public function new(key:Bytes, at:Int = 0) {
		__k0l = __le32(key, at);
		__k0h = __le32(key, at + 4);
		__k1l = __le32(key, at + 8);
		__k1h = __le32(key, at + 12);
	}

	/** Hashes `length` bytes of `data` from `offset`; the answer is in `high` and `low`. **/
	public function hash(data:Bytes, offset:Int, length:Int):Void {
		// "somepseudorandomlygeneratedbytes", XOR the key.
		__v0l = __k0l ^ 0x70736575;
		__v0h = __k0h ^ 0x736f6d65;
		__v1l = __k1l ^ 0x6e646f6d;
		__v1h = __k1h ^ 0x646f7261;
		__v2l = __k0l ^ 0x6e657261;
		__v2h = __k0h ^ 0x6c796765;
		__v3l = __k1l ^ 0x79746573;
		__v3h = __k1h ^ 0x74656462;

		var at:Int = offset;
		var whole:Int = offset + (length & ~7);
		while (at < whole) {
			var ml:Int = __le32(data, at);
			var mh:Int = __le32(data, at + 4);
			__v3l ^= ml;
			__v3h ^= mh;
			__round();
			__round();
			__v0l ^= ml;
			__v0h ^= mh;
			at += 8;
		}

		// The last block: what is left, little-endian, and the length's low
		// byte at the top.
		var bl:Int = 0;
		var bh:Int = (length & 0xFF) << 24;
		var left:Int = length & 7;
		for (i in 0...left) {
			var value:Int = data.get(at + i);
			if (i < 4) {
				bl |= value << (i << 3);
			} else {
				bh |= value << ((i - 4) << 3);
			}
		}
		__v3l ^= bl;
		__v3h ^= bh;
		__round();
		__round();
		__v0l ^= bl;
		__v0h ^= bh;

		__v2l ^= 0xFF;
		__round();
		__round();
		__round();
		__round();

		low = __v0l ^ __v1l ^ __v2l ^ __v3l;
		high = __v0h ^ __v1h ^ __v2h ^ __v3h;
	}

	/**
		One SipRound. A 64-bit addition is the low halves added, then the
		high halves with the carry: the low sum is below an addend, compared
		as unsigned by flipping the sign bit, exactly when it carried.
	**/
	@:noCompletion private inline function __round():Void {
		// v0 += v1; v1 = rotl(v1, 13); v1 ^= v0; v0 = rotl(v0, 32)
		var sum:Int = (__v0l + __v1l) | 0;
		__v0h = (__v0h + __v1h + (__below(sum, __v0l) ? 1 : 0)) | 0;
		__v0l = sum;
		var h:Int = (__v1h << 13) | (__v1l >>> 19);
		var l:Int = (__v1l << 13) | (__v1h >>> 19);
		__v1h = h ^ __v0h;
		__v1l = l ^ __v0l;
		var swap:Int = __v0h;
		__v0h = __v0l;
		__v0l = swap;

		// v2 += v3; v3 = rotl(v3, 16); v3 ^= v2
		sum = (__v2l + __v3l) | 0;
		__v2h = (__v2h + __v3h + (__below(sum, __v2l) ? 1 : 0)) | 0;
		__v2l = sum;
		h = (__v3h << 16) | (__v3l >>> 16);
		l = (__v3l << 16) | (__v3h >>> 16);
		__v3h = h ^ __v2h;
		__v3l = l ^ __v2l;

		// v0 += v3; v3 = rotl(v3, 21); v3 ^= v0
		sum = (__v0l + __v3l) | 0;
		__v0h = (__v0h + __v3h + (__below(sum, __v0l) ? 1 : 0)) | 0;
		__v0l = sum;
		h = (__v3h << 21) | (__v3l >>> 11);
		l = (__v3l << 21) | (__v3h >>> 11);
		__v3h = h ^ __v0h;
		__v3l = l ^ __v0l;

		// v2 += v1; v1 = rotl(v1, 17); v1 ^= v2; v2 = rotl(v2, 32)
		sum = (__v2l + __v1l) | 0;
		__v2h = (__v2h + __v1h + (__below(sum, __v2l) ? 1 : 0)) | 0;
		__v2l = sum;
		h = (__v1h << 17) | (__v1l >>> 15);
		l = (__v1l << 17) | (__v1h >>> 15);
		__v1h = h ^ __v2h;
		__v1l = l ^ __v2l;
		swap = __v2h;
		__v2h = __v2l;
		__v2l = swap;
	}

	/** Whether `a` is below `b`, both read as unsigned 32-bit values. **/
	@:noCompletion private static inline function __below(a:Int, b:Int):Bool {
		return (a ^ 0x80000000) < (b ^ 0x80000000);
	}

	@:noCompletion private static inline function __le32(bytes:Bytes, at:Int):Int {
		return bytes.get(at) | (bytes.get(at + 1) << 8) | (bytes.get(at + 2) << 16) | (bytes.get(at + 3) << 24);
	}
}
