package crossbyte.db.mongodb._internal;

import haxe.ds.Vector;
import haxe.io.Bytes;

/**
	SHA-1 or SHA-256, with HMAC and PBKDF2 over it: what SCRAM needs.

	Written here rather than taken from `haxe.crypto`, whose hashes take a
	whole message at once. PBKDF2 is thousands of HMACs of a short message
	under one key, MongoDB asks for 15,000 with SHA-256, and an HMAC's key
	pads hash to the same two blocks every time. Kept as midstates, each
	iteration is two compressions on words already in hand, with nothing
	allocated; `haxe.crypto.Hmac` would hash four blocks and build a buffer
	for each. It is the same arithmetic as `haxe.crypto.Sha256`, and is
	checked against the RFC 6070 and RFC 7677 vectors.

	Additions end in `| 0` so they wrap at 32 bits on JavaScript too, where
	an `Int` is a double; elsewhere that is free.
**/
class ScramDigest {
	/** The digest length in bytes: 20 for SHA-1, 32 for SHA-256. **/
	public var size(default, null):Int;

	@:noCompletion private var __sha256:Bool;
	@:noCompletion private var __words:Int;
	@:noCompletion private var __w:Vector<Int>;
	@:noCompletion private var __block:Vector<Int>;

	public function new(sha256:Bool) {
		__sha256 = sha256;
		__words = sha256 ? 8 : 5;
		size = __words * 4;
		__w = new Vector<Int>(sha256 ? 64 : 80);
		__block = new Vector<Int>(16);
	}

	/** The digest of `data`. **/
	public function hash(data:Bytes):Bytes {
		#if php
		return Bytes.ofData(php.Global.hash(__algorithm(), data.getData(), true));
		#else
		var state:Vector<Int> = __initial();
		__absorb(state, data, 0);
		return __toBytes(state);
		#end
	}

	#if php
	// PHP's integers are 64 bits wide, so a shift or an addition here would
	// not wrap where SHA needs it to; PHP's own hash functions are used there,
	// as Haxe's std does for haxe.crypto.
	@:noCompletion private inline function __algorithm():String {
		return __sha256 ? "sha256" : "sha1";
	}
	#end

	/** HMAC of `data` under `key`. **/
	public function hmac(key:Bytes, data:Bytes):Bytes {
		#if php
		// Through typed locals, so Haxe converts between its bytes and PHP's
		// strings both ways; a cast would pass the one for the other.
		var mac:String = cast php.Global.hash_hmac(__algorithm(), data.getData(), key.getData(), true);
		return Bytes.ofData(mac);
		#else
		var inner:Vector<Int> = __initial();
		var outer:Vector<Int> = __initial();
		__keyStates(key, inner, outer);
		__absorb(inner, data, 64);
		// The outer hash takes the inner digest as one short final block.
		__finishShort(outer, inner);
		return __toBytes(outer);
		#end
	}

	/**
		PBKDF2 with this digest's HMAC, for one block of output, the
		digest's own length, which is all SCRAM asks for.
	**/
	public function pbkdf2(password:Bytes, salt:Bytes, iterations:Int):Bytes {
		#if php
		var secret:String = password.getData();
		var seasoning:String = salt.getData();
		var derived:String = php.Syntax.code("hash_pbkdf2({0}, {1}, {2}, {3}, 0, true)", __algorithm(), secret, seasoning, iterations);
		return Bytes.ofData(derived);
		#else
		var innerKey:Vector<Int> = __initial();
		var outerKey:Vector<Int> = __initial();
		__keyStates(password, innerKey, outerKey);

		// U1 = HMAC(P, salt || INT(1)).
		var first:Bytes = Bytes.alloc(salt.length + 4);
		first.blit(0, salt, 0, salt.length);
		first.setInt32(salt.length, 0x01000000);

		var u:Vector<Int> = __copy(innerKey);
		__absorb(u, first, 64);
		var outer:Vector<Int> = __copy(outerKey);
		__finishShort(outer, u);
		u = outer;

		var total:Vector<Int> = __copy(u);
		var work:Vector<Int> = new Vector<Int>(__words);

		for (_ in 1...iterations) {
			// U_i = HMAC(P, U_{i-1}): the inner hash from the key's midstate
			// over one short block, then the outer the same way.
			for (k in 0...__words) {
				work[k] = innerKey[k];
			}

			__finishShort(work, u);

			for (k in 0...__words) {
				u[k] = outerKey[k];
			}

			__finishShort(u, work);

			for (k in 0...__words) {
				total[k] = total[k] ^ u[k];
			}
		}

		return __toBytes(total);
		#end
	}

	/** The states after one block of the key XOR ipad, and of the key XOR opad. **/
	@:noCompletion private function __keyStates(key:Bytes, inner:Vector<Int>, outer:Vector<Int>):Void {
		var material:Bytes = key.length > 64 ? hash(key) : key;
		var padded:Bytes = Bytes.alloc(64);
		padded.fill(0, 64, 0);
		padded.blit(0, material, 0, material.length);

		for (i in 0...16) {
			var word:Int = __wordAt(padded, i * 4);
			__block[i] = word ^ 0x36363636;
		}

		__compress(inner, __block);

		for (i in 0...16) {
			var word:Int = __wordAt(padded, i * 4);
			__block[i] = word ^ 0x5C5C5C5C;
		}

		__compress(outer, __block);
	}

	/**
		Completes a hash whose state has absorbed exactly one 64-byte block,
		with the digest words of `message` as the rest of the input: one
		block holding the message, the padding and a length of 64 + its size.
	**/
	@:noCompletion private function __finishShort(state:Vector<Int>, message:Vector<Int>):Void {
		var block:Vector<Int> = __block;

		for (k in 0...__words) {
			block[k] = message[k];
		}

		block[__words] = 0x80000000;

		for (k in (__words + 1)...15) {
			block[k] = 0;
		}

		block[15] = (64 + size) * 8;
		__compress(state, block);
	}

	/**
		Runs `data` through `state`, with the padding and a length that
		counts `before` bytes already absorbed.
	**/
	@:noCompletion private function __absorb(state:Vector<Int>, data:Bytes, before:Int):Void {
		var block:Vector<Int> = __block;
		var length:Int = data.length;
		var offset:Int = 0;

		while (offset + 64 <= length) {
			for (i in 0...16) {
				block[i] = __wordAt(data, offset + i * 4);
			}

			__compress(state, block);
			offset += 64;
		}

		// The tail, a 1 bit, zeros, and the length in bits: one block or two.
		var tail:Bytes = Bytes.alloc(128);
		tail.fill(0, 128, 0);
		var remaining:Int = length - offset;
		tail.blit(0, data, offset, remaining);
		tail.set(remaining, 0x80);
		var blocks:Int = remaining + 9 <= 64 ? 1 : 2;
		var bits:Float = (before + length) * 8.0;
		var end:Int = blocks * 64;
		tail.setInt32(end - 8, 0);
		// Big-endian, unlike Bytes.setInt32.
		var high:Int = Std.int(bits / 4294967296.0);
		var low:Float = bits - high * 4294967296.0;
		__putWord(tail, end - 8, high);
		__putWord(tail, end - 4, low > 2147483647.0 ? Std.int(low - 4294967296.0) : Std.int(low));

		for (b in 0...blocks) {
			for (i in 0...16) {
				block[i] = __wordAt(tail, b * 64 + i * 4);
			}

			__compress(state, block);
		}
	}

	@:noCompletion private inline function __compress(state:Vector<Int>, block:Vector<Int>):Void {
		if (__sha256) {
			__compress256(state, block);
		} else {
			__compress1(state, block);
		}
	}

	@:noCompletion private function __compress256(state:Vector<Int>, block:Vector<Int>):Void {
		var w:Vector<Int> = __w;

		for (t in 0...16) {
			w[t] = block[t];
		}

		for (t in 16...64) {
			var x:Int = w[t - 15];
			var y:Int = w[t - 2];
			var s0:Int = ((x >>> 7) | (x << 25)) ^ ((x >>> 18) | (x << 14)) ^ (x >>> 3);
			var s1:Int = ((y >>> 17) | (y << 15)) ^ ((y >>> 19) | (y << 13)) ^ (y >>> 10);
			w[t] = (w[t - 16] + s0 + w[t - 7] + s1) | 0;
		}

		var a:Int = state[0];
		var b:Int = state[1];
		var c:Int = state[2];
		var d:Int = state[3];
		var e:Int = state[4];
		var f:Int = state[5];
		var g:Int = state[6];
		var h:Int = state[7];
		var k:Vector<Int> = __K256;

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

		state[0] = (state[0] + a) | 0;
		state[1] = (state[1] + b) | 0;
		state[2] = (state[2] + c) | 0;
		state[3] = (state[3] + d) | 0;
		state[4] = (state[4] + e) | 0;
		state[5] = (state[5] + f) | 0;
		state[6] = (state[6] + g) | 0;
		state[7] = (state[7] + h) | 0;
	}

	@:noCompletion private function __compress1(state:Vector<Int>, block:Vector<Int>):Void {
		var w:Vector<Int> = __w;

		for (t in 0...16) {
			w[t] = block[t];
		}

		for (t in 16...80) {
			var x:Int = w[t - 3] ^ w[t - 8] ^ w[t - 14] ^ w[t - 16];
			w[t] = (x << 1) | (x >>> 31);
		}

		var a:Int = state[0];
		var b:Int = state[1];
		var c:Int = state[2];
		var d:Int = state[3];
		var e:Int = state[4];

		for (t in 0...80) {
			var f:Int;
			var k:Int;

			if (t < 20) {
				f = (b & c) | ((~b) & d);
				k = 0x5A827999;
			} else if (t < 40) {
				f = b ^ c ^ d;
				k = 0x6ED9EBA1;
			} else if (t < 60) {
				f = (b & c) | (b & d) | (c & d);
				k = 0x8F1BBCDC;
			} else {
				f = b ^ c ^ d;
				k = 0xCA62C1D6;
			}

			var temp:Int = (((a << 5) | (a >>> 27)) + f + e + k + w[t]) | 0;
			e = d;
			d = c;
			c = (b << 30) | (b >>> 2);
			b = a;
			a = temp;
		}

		state[0] = (state[0] + a) | 0;
		state[1] = (state[1] + b) | 0;
		state[2] = (state[2] + c) | 0;
		state[3] = (state[3] + d) | 0;
		state[4] = (state[4] + e) | 0;
	}

	@:noCompletion private function __initial():Vector<Int> {
		var state:Vector<Int> = new Vector<Int>(__words);
		var iv:Vector<Int> = __sha256 ? __IV256 : __IV1;

		for (k in 0...__words) {
			state[k] = iv[k];
		}

		return state;
	}

	@:noCompletion private function __copy(state:Vector<Int>):Vector<Int> {
		var out:Vector<Int> = new Vector<Int>(__words);

		for (k in 0...__words) {
			out[k] = state[k];
		}

		return out;
	}

	@:noCompletion private function __toBytes(state:Vector<Int>):Bytes {
		var out:Bytes = Bytes.alloc(size);

		for (k in 0...__words) {
			__putWord(out, k * 4, state[k]);
		}

		return out;
	}

	@:noCompletion private static inline function __wordAt(bytes:Bytes, at:Int):Int {
		return (bytes.get(at) << 24) | (bytes.get(at + 1) << 16) | (bytes.get(at + 2) << 8) | bytes.get(at + 3);
	}

	@:noCompletion private static inline function __putWord(bytes:Bytes, at:Int, word:Int):Void {
		bytes.set(at, (word >>> 24) & 0xFF);
		bytes.set(at + 1, (word >>> 16) & 0xFF);
		bytes.set(at + 2, (word >>> 8) & 0xFF);
		bytes.set(at + 3, word & 0xFF);
	}

	@:noCompletion private static final __IV1:Vector<Int> = Vector.fromArrayCopy([0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]);

	@:noCompletion private static final __IV256:Vector<Int> = Vector.fromArrayCopy([
		0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A, 0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19
	]);

	@:noCompletion private static final __K256:Vector<Int> = Vector.fromArrayCopy([
		0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5, 0x3956C25B, 0x59F111F1, 0x923F82A4, 0xAB1C5ED5, 0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3,
		0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174, 0xE49B69C1, 0xEFBE4786, 0x0FC19DC6, 0x240CA1CC, 0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
		0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7, 0xC6E00BF3, 0xD5A79147, 0x06CA6351, 0x14292967, 0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13,
		0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85, 0xA2BFE8A1, 0xA81A664B, 0xC24B8B70, 0xC76C51A3, 0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
		0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5, 0x391C0CB3, 0x4ED8AA4A, 0x5B9CCA4F, 0x682E6FF3, 0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208,
		0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2
	]);
}
