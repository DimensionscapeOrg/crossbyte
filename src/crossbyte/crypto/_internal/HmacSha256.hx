package crossbyte.crypto._internal;

import haxe.io.Bytes;

/**
	HMAC-SHA-256 under one key, with the key's two padded blocks hashed once,
	when the key is given, rather than for every message.

	An HMAC hashes the key XOR ipad and then the message, and hashes the key
	XOR opad and then that digest. The key's blocks hash to the same state
	every time, so that state is kept: each MAC is the message's own blocks
	and one more. `haxe.crypto.Hmac` hashes the key's blocks for every MAC,
	builds the padded key and both messages as new buffers, and converts
	each to an array of words first; a JWT verified per request paid that
	every time.

	A message held in a `String` is read straight from it, a character at a
	time, when every character is ASCII, what a JWT's signing input always
	is, with no `Bytes.ofString` copy. Other text is encoded as UTF-8
	first, as `Bytes.ofString` encodes it.

	The arithmetic is `haxe.crypto.Sha256`'s, checked against RFC 4231's
	vectors. Additions end in `| 0` so they wrap at 32 bits on JavaScript
	too, where an `Int` is a double; elsewhere that is free. JavaScript keeps
	its words in an `Int32Array`, which holds them as 32-bit integers.

	One object serves any number of threads at once: the key's states are
	only read after construction, and every MAC works in a scratch array of
	its own.
**/
@:noCompletion
final class HmacSha256 {
	/** The length of a MAC, in bytes. **/
	public static inline final SIZE:Int = 32;

	@:noCompletion private static inline final __SCHEDULE:Int = 64;
	@:noCompletion private static inline final __STATE:Int = 64;
	@:noCompletion private static inline final __SCRATCH:Int = 72;

	/** The state after the key XOR ipad: where every inner hash starts. **/
	@:noCompletion private final __inner:Words;

	/** The state after the key XOR opad: where every outer hash starts. **/
	@:noCompletion private final __outer:Words;

	#if php
	@:noCompletion private final __key:Bytes;
	#end

	public function new(key:Bytes) {
		#if php
		__key = key;
		#end
		var material:Bytes = key.length > 64 ? sha256(key) : key;
		var padded:Bytes = Bytes.alloc(64);
		padded.fill(0, 64, 0);
		padded.blit(0, material, 0, material.length);

		var scratch:Words = new Words(__SCRATCH);
		__inner = new Words(8);
		__outer = new Words(8);

		for (i in 0...16) {
			scratch[i] = __wordAt(padded, i * 4) ^ 0x36363636;
		}
		__start(scratch, __IV);
		__compress(scratch);
		__save(scratch, __inner);

		for (i in 0...16) {
			scratch[i] = __wordAt(padded, i * 4) ^ 0x5C5C5C5C;
		}
		__start(scratch, __IV);
		__compress(scratch);
		__save(scratch, __outer);

		// The padded key held the secret; it is not needed again.
		padded.fill(0, 64, 0);
	}

	/** The MAC of `data`. **/
	public function mac(data:Bytes):Bytes {
		#if php
		return __php(data);
		#else
		var scratch:Words = __newScratch();
		__start(scratch, __inner);
		__absorbBytes(scratch, data);
		__finish(scratch);
		return __toBytes(scratch);
		#end
	}

	/**
		The MAC of `text`'s characters from `start` up to `end`, as UTF-8,
		what `mac(Bytes.ofString(text.substring(start, end)))` answers.
	**/
	public function macText(text:String, start:Int, end:Int):Bytes {
		#if php
		return __php(Bytes.ofString(text.substring(start, end)));
		#else
		var scratch:Words = __digestText(text, start, end);
		return __toBytes(scratch);
		#end
	}

	/**
		Whether `expected` is the MAC of `text`'s characters from `start` up to
		`end`, compared in constant time: every byte of it is read, whatever
		the first difference.
	**/
	public function verifyText(text:String, start:Int, end:Int, expected:Bytes):Bool {
		if (expected == null || expected.length != SIZE) {
			return false;
		}
		#if php
		return crossbyte.crypto.ConstantTime.equals(macText(text, start, end), expected);
		#else
		var scratch:Words = __digestText(text, start, end);
		var difference:Int = 0;
		for (k in 0...8) {
			difference |= scratch[__STATE + k] ^ __wordAt(expected, k * 4);
		}
		return difference == 0;
		#end
	}

	/** SHA-256 of `data`. **/
	public static function sha256(data:Bytes):Bytes {
		#if php
		return haxe.crypto.Sha256.make(data);
		#else
		var scratch:Words = __newScratch();
		__start(scratch, __IV);
		__absorbBytes(scratch, data, 0);
		return __toBytes(scratch);
		#end
	}

	/**
		The words a MAC works in: its own on a target with threads, and on
		JavaScript, which runs one thread, one array kept for every MAC,
		a typed array is a costly allocation there. Nothing a MAC does can
		start another before it ends.
	**/
	@:noCompletion private static inline function __newScratch():Words {
		#if js
		return __jsScratch;
		#else
		return new Words(__SCRATCH);
		#end
	}

	#if js
	@:noCompletion private static final __jsScratch:Words = new Words(__SCRATCH);
	#end

	#if php
	// PHP's integers are 64 bits wide, so a shift or an addition here would
	// not wrap where SHA needs it to: PHP's own HMAC there, as ScramDigest
	// does.
	@:noCompletion private function __php(data:Bytes):Bytes {
		var mac:String = cast php.Global.hash_hmac("sha256", data.getData(), __key.getData(), true);
		return Bytes.ofData(mac);
	}
	#end

	/**
		The inner hash of the text and the outer hash over it: the MAC's
		words, in the state's place in a new scratch array.
	**/
	@:noCompletion private function __digestText(text:String, start:Int, end:Int):Words {
		var scratch:Words = __newScratch();
		__start(scratch, __inner);

		if (!__absorbAscii(scratch, text, start, end)) {
			// Not ASCII: hashed as Bytes.ofString would encode it.
			__start(scratch, __inner);
			__absorbBytes(scratch, Bytes.ofString(text.substring(start, end)));
		}

		__finish(scratch);
		return scratch;
	}

	/**
		The outer hash, from the opad state, over the inner digest in the
		scratch's state words: one block, holding the digest, its padding and
		a length of 64 + 32 bytes.
	**/
	@:noCompletion private function __finish(scratch:Words):Void {
		for (k in 0...8) {
			scratch[k] = scratch[__STATE + k];
		}
		scratch[8] = 0x80000000;
		for (k in 9...15) {
			scratch[k] = 0;
		}
		scratch[15] = (64 + SIZE) * 8;
		__start(scratch, __outer);
		__compress(scratch);
	}

	/**
		Absorbs `text` from `start` to `end` into a state that has taken one
		block (the key's), padding and length included. False, with the state
		spoiled, when a character is not ASCII.
	**/
	@:noCompletion private static function __absorbAscii(scratch:Words, text:String, start:Int, end:Int):Bool {
		var at:Int = start;
		// Every code read, OR-ed together: anything above 0x7F means the
		// text was not ASCII, checked once at the end.
		var seen:Int = 0;

		while (end - at >= 64) {
			for (i in 0...16) {
				var p:Int = at + (i << 2);
				var c0:Int = StringTools.fastCodeAt(text, p);
				var c1:Int = StringTools.fastCodeAt(text, p + 1);
				var c2:Int = StringTools.fastCodeAt(text, p + 2);
				var c3:Int = StringTools.fastCodeAt(text, p + 3);
				seen |= c0 | c1 | c2 | c3;
				scratch[i] = (c0 << 24) | (c1 << 16) | (c2 << 8) | c3;
			}
			__compress(scratch);
			at += 64;
		}

		var remaining:Int = end - at;
		for (i in 0...16) {
			scratch[i] = 0;
		}
		for (j in 0...remaining) {
			var c:Int = StringTools.fastCodeAt(text, at + j);
			seen |= c;
			scratch[j >> 2] = scratch[j >> 2] | (c << (24 - ((j & 3) << 3)));
		}

		if ((seen & ~0x7F) != 0) {
			return false;
		}

		__pad(scratch, remaining, 64 + (end - start));
		return true;
	}

	/**
		Absorbs `data` into a state that has taken `before` bytes already (the
		key's block, or none), padding and length included.
	**/
	@:noCompletion private static function __absorbBytes(scratch:Words, data:Bytes, before:Int = 64):Void {
		var length:Int = data.length;
		var at:Int = 0;

		while (length - at >= 64) {
			for (i in 0...16) {
				scratch[i] = __wordAt(data, at + (i << 2));
			}
			__compress(scratch);
			at += 64;
		}

		var remaining:Int = length - at;
		for (i in 0...16) {
			scratch[i] = 0;
		}
		for (j in 0...remaining) {
			scratch[j >> 2] = scratch[j >> 2] | (data.get(at + j) << (24 - ((j & 3) << 3)));
		}

		__pad(scratch, remaining, before + length);
	}

	/**
		Ends a message whose last `remaining` bytes (under 64) are already in
		the block: the 1 bit, zeros, and the length in bits, `total` bytes,
		big-endian, in this block, or in one more when they do not fit.
	**/
	@:noCompletion private static function __pad(scratch:Words, remaining:Int, total:Int):Void {
		scratch[remaining >> 2] = scratch[remaining >> 2] | (0x80 << (24 - ((remaining & 3) << 3)));

		if (remaining + 9 > 64) {
			__compress(scratch);
			for (i in 0...16) {
				scratch[i] = 0;
			}
		}

		// total * 8 as 64 bits: the high word takes what the shift drops.
		scratch[14] = total >>> 29;
		scratch[15] = total << 3;
		__compress(scratch);
	}

	/** One SHA-256 compression of the block in the scratch's first 16 words. **/
	@:noCompletion private static function __compress(w:Words):Void {
		for (t in 16...64) {
			var x:Int = w[t - 15];
			var y:Int = w[t - 2];
			var s0:Int = ((x >>> 7) | (x << 25)) ^ ((x >>> 18) | (x << 14)) ^ (x >>> 3);
			var s1:Int = ((y >>> 17) | (y << 15)) ^ ((y >>> 19) | (y << 13)) ^ (y >>> 10);
			w[t] = (w[t - 16] + s0 + w[t - 7] + s1) | 0;
		}

		var a:Int = w[__STATE];
		var b:Int = w[__STATE + 1];
		var c:Int = w[__STATE + 2];
		var d:Int = w[__STATE + 3];
		var e:Int = w[__STATE + 4];
		var f:Int = w[__STATE + 5];
		var g:Int = w[__STATE + 6];
		var h:Int = w[__STATE + 7];
		var k:Words = __K;

		for (t in 0...64) {
			var s1:Int = ((e >>> 6) | (e << 26)) ^ ((e >>> 11) | (e << 21)) ^ ((e >>> 25) | (e << 7));
			var ch:Int = (e & f) ^ ((~e) & g);
			var t1:Int = (h + s1 + ch + k[t] + w[t]) | 0;
			var s0:Int = ((a >>> 2) | (a << 30)) ^ ((a >>> 13) | (a << 19)) ^ ((a >>> 22) | (a << 10));
			var maj:Int = (a & b) ^ (a & c) ^ (b & c);
			var t2:Int = (s0 + maj) | 0;
			h = g;
			g = f;
			f = e;
			e = (d + t1) | 0;
			d = c;
			c = b;
			b = a;
			a = (t1 + t2) | 0;
		}

		w[__STATE] = (w[__STATE] + a) | 0;
		w[__STATE + 1] = (w[__STATE + 1] + b) | 0;
		w[__STATE + 2] = (w[__STATE + 2] + c) | 0;
		w[__STATE + 3] = (w[__STATE + 3] + d) | 0;
		w[__STATE + 4] = (w[__STATE + 4] + e) | 0;
		w[__STATE + 5] = (w[__STATE + 5] + f) | 0;
		w[__STATE + 6] = (w[__STATE + 6] + g) | 0;
		w[__STATE + 7] = (w[__STATE + 7] + h) | 0;
	}

	@:noCompletion private static inline function __start(scratch:Words, from:Words):Void {
		for (k in 0...8) {
			scratch[__STATE + k] = from[k];
		}
	}

	@:noCompletion private static inline function __save(scratch:Words, to:Words):Void {
		for (k in 0...8) {
			to[k] = scratch[__STATE + k];
		}
	}

	@:noCompletion private static function __toBytes(scratch:Words):Bytes {
		var out:Bytes = Bytes.alloc(SIZE);
		for (k in 0...8) {
			var word:Int = scratch[__STATE + k];
			out.set(k * 4, (word >>> 24) & 0xFF);
			out.set(k * 4 + 1, (word >>> 16) & 0xFF);
			out.set(k * 4 + 2, (word >>> 8) & 0xFF);
			out.set(k * 4 + 3, word & 0xFF);
		}
		return out;
	}

	@:noCompletion private static inline function __wordAt(bytes:Bytes, at:Int):Int {
		return (bytes.get(at) << 24) | (bytes.get(at + 1) << 16) | (bytes.get(at + 2) << 8) | bytes.get(at + 3);
	}

	@:noCompletion private static function __words(values:Array<Int>):Words {
		var words:Words = new Words(values.length);
		for (i in 0...values.length) {
			words[i] = values[i];
		}
		return words;
	}

	@:noCompletion private static final __IV:Words = __words([
		0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A, 0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19
	]);

	@:noCompletion private static final __K:Words = __words([
		0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5, 0x3956C25B, 0x59F111F1, 0x923F82A4, 0xAB1C5ED5, 0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3,
		0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174, 0xE49B69C1, 0xEFBE4786, 0x0FC19DC6, 0x240CA1CC, 0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
		0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7, 0xC6E00BF3, 0xD5A79147, 0x06CA6351, 0x14292967, 0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13,
		0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85, 0xA2BFE8A1, 0xA81A664B, 0xC24B8B70, 0xC76C51A3, 0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
		0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5, 0x391C0CB3, 0x4ED8AA4A, 0x5B9CCA4F, 0x682E6FF3, 0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208,
		0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2
	]);
}

#if js
private typedef Words = js.lib.Int32Array;
#else
private typedef Words = haxe.ds.Vector<Int>;
#end
