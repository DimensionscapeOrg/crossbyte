package crossbyte._internal.socket;

import haxe.crypto.Base64;
import haxe.crypto.Hmac;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;

/**
	Decrypts a PKCS#8 key encrypted the way OpenSSL encrypts one today --
	PBES2, a PBKDF2 key, AES in CBC mode (RFC 8018 6.2) -- for the targets
	whose TLS is mbedTLS.

	mbedTLS 2, which upstream hxcpp, hl, neko and eval carry, decrypts PBES2
	with DES and triple DES alone: its table of PBES2 ciphers has no AES in
	it. So the key `openssl pkcs8 -topk8`, `openssl req` or `openssl genpkey
	-aes256` writes -- every encrypted PKCS#8 key OpenSSL has made by
	default since 1.1 -- failed to load there with "Requested encryption or
	digest alg not available", password or no password, on the target
	CrossByte serves from. The jvm reads it through the JDK and Node through
	OpenSSL. The hxcpp fork's mbedTLS 3.6 reads it too, but it is decrypted
	here on every mbedTLS target all the same, so that a key loads
	whichever hxcpp a build has.

	What this cannot decrypt it leaves to mbedTLS, which reads the rest:
	PBES2 with DES, the PKCS#12 schemes, and OpenSSL's older encryption of
	a PKCS#1 or SEC1 key.

	Not on a hot path: a key is read once, when a server or client is set
	up. The AES here is the plain byte-wise one of FIPS 197, written for
	being checked rather than for speed, and it decrypts a key file the
	process already holds with a password it was given -- nothing an
	attacker can time.
**/
@:noCompletion
class EncryptedKey {
	private static inline var PBES2:String = "2a864886f70d01050d";
	private static inline var PBKDF2:String = "2a864886f70d01050c";
	private static inline var HMAC_SHA1:String = "2a864886f70d0207";
	private static inline var HMAC_SHA256:String = "2a864886f70d0209";
	private static inline var AES_128_CBC:String = "608648016503040102";
	private static inline var AES_192_CBC:String = "608648016503040116";
	private static inline var AES_256_CBC:String = "60864801650304012a";

	/**
		`pem` decrypted, as an unencrypted PKCS#8 PEM, when it is an
		encrypted PKCS#8 key this decrypts; `null` when it is anything else,
		for mbedTLS to read as it is.

		@throws String when the password does not decrypt it.
	**/
	public static function decryptPem(pem:String, password:String):Null<String> {
		var begin:String = "-----BEGIN ENCRYPTED PRIVATE KEY-----";
		var end:String = "-----END ENCRYPTED PRIVATE KEY-----";
		var from:Int = pem.indexOf(begin);
		var to:Int = pem.indexOf(end);
		if (from < 0 || to < from) {
			return null;
		}

		var base64:StringBuf = new StringBuf();
		for (line in pem.substring(from + begin.length, to).split("\n")) {
			base64.add(StringTools.trim(line));
		}
		var der:Null<Bytes> = null;
		try {
			der = Base64.decode(base64.toString());
		} catch (_:Dynamic) {}
		if (der == null) {
			return null;
		}

		var plain:Null<Bytes> = decrypt(der, password);
		if (plain == null) {
			return null;
		}

		var text:String = Base64.encode(plain);
		var out:StringBuf = new StringBuf();
		out.add("-----BEGIN PRIVATE KEY-----\n");
		var at:Int = 0;
		while (at < text.length) {
			out.add(text.substr(at, 64));
			out.add("\n");
			at += 64;
		}
		out.add("-----END PRIVATE KEY-----\n");
		return out.toString();
	}

	/**
		An EncryptedPrivateKeyInfo's PrivateKeyInfo, or `null` when it is not
		PBES2 with PBKDF2 and AES.
	**/
	public static function decrypt(der:Bytes, password:String):Null<Bytes> {
		try {
			var info = __element(der, 0, 0x30);
			var algorithm = __element(der, info.start, 0x30);
			var encrypted = __element(der, algorithm.end, 0x04);

			var schemeOid = __element(der, algorithm.start, 0x06);
			if (__hex(der, schemeOid) != PBES2) {
				return null;
			}
			var parameters = __element(der, schemeOid.end, 0x30);

			var kdf = __element(der, parameters.start, 0x30);
			var kdfOid = __element(der, kdf.start, 0x06);
			if (__hex(der, kdfOid) != PBKDF2) {
				return null;
			}
			var kdfParameters = __element(der, kdfOid.end, 0x30);
			var salt = __element(der, kdfParameters.start, 0x04);
			var iterations = __element(der, salt.end, 0x02);
			var hash:HashMethod = SHA1;
			var next:Int = iterations.end;
			if (next < kdfParameters.end && der.get(next) == 0x02) {
				// keyLength, which the cipher decides anyway.
				next = __element(der, next, 0x02).end;
			}
			if (next < kdfParameters.end) {
				var prf = __element(der, next, 0x30);
				var prfOid = __hex(der, __element(der, prf.start, 0x06));
				hash = switch (prfOid) {
					case HMAC_SHA1: SHA1;
					case HMAC_SHA256: SHA256;
					default: return null;
				}
			}

			var cipher = __element(der, kdf.end, 0x30);
			var cipherOid = __element(der, cipher.start, 0x06);
			var keyLength:Int = switch (__hex(der, cipherOid)) {
				case AES_128_CBC: 16;
				case AES_192_CBC: 24;
				case AES_256_CBC: 32;
				default: return null;
			}
			var iv = __element(der, cipherOid.end, 0x04);
			if (iv.end - iv.start != 16) {
				return null;
			}

			var count:Int = 0;
			for (i in iterations.start...iterations.end) {
				count = (count << 8) | der.get(i);
			}
			if (count < 1 || count > 10000000) {
				return null;
			}

			var key:Bytes = __pbkdf2(hash, Bytes.ofString(password), der.sub(salt.start, salt.end - salt.start), count, keyLength);
			var plain:Null<Bytes> = __decryptCbc(key, der.sub(iv.start, 16), der.sub(encrypted.start, encrypted.end - encrypted.start));
			// A wrong password decrypts to noise, whose padding is wrong but
			// once in 256 times; and noise that passes is no DER sequence.
			if (plain == null || plain.length == 0 || plain.get(0) != 0x30) {
				throw "The key could not be decrypted: the password is not the one it was encrypted with.";
			}
			return plain;
		} catch (e:EncryptedKeyFailure) {
			return null;
		}
	}

	/** PBKDF2 (RFC 8018 5.2). **/
	private static function __pbkdf2(hash:HashMethod, password:Bytes, salt:Bytes, iterations:Int, length:Int):Bytes {
		var hmac = new Hmac(hash);
		var out = new BytesBuffer();
		var block:Int = 1;
		while (out.length < length) {
			var first = new BytesBuffer();
			first.add(salt);
			first.addByte((block >>> 24) & 0xFF);
			first.addByte((block >>> 16) & 0xFF);
			first.addByte((block >>> 8) & 0xFF);
			first.addByte(block & 0xFF);
			var u:Bytes = hmac.make(password, first.getBytes());
			var t:Bytes = u.sub(0, u.length);
			for (_ in 1...iterations) {
				u = hmac.make(password, u);
				for (i in 0...t.length) {
					t.set(i, t.get(i) ^ u.get(i));
				}
			}
			out.add(t);
			block++;
		}
		return out.getBytes().sub(0, length);
	}

	/** AES-CBC decryption with PKCS#7 padding removed, or null when the padding is not there. **/
	private static function __decryptCbc(key:Bytes, iv:Bytes, data:Bytes):Null<Bytes> {
		if (data.length == 0 || data.length % 16 != 0) {
			return null;
		}
		var schedule:Array<Int> = __expandKey(key);
		var rounds:Int = (key.length >> 2) + 6;
		var out:Bytes = Bytes.alloc(data.length);
		var previous:Bytes = iv;
		var block:Bytes = Bytes.alloc(16);
		var at:Int = 0;
		while (at < data.length) {
			block.blit(0, data, at, 16);
			__decryptBlock(block, schedule, rounds);
			for (i in 0...16) {
				out.set(at + i, block.get(i) ^ previous.get(i));
			}
			previous = data.sub(at, 16);
			at += 16;
		}

		var pad:Int = out.get(out.length - 1);
		if (pad < 1 || pad > 16) {
			return null;
		}
		for (i in 0...pad) {
			if (out.get(out.length - 1 - i) != pad) {
				return null;
			}
		}
		return out.sub(0, out.length - pad);
	}

	// FIPS 197. The tables are made rather than written out, from the
	// multiplicative inverse and the affine map that define them (5.1.1).
	private static var __sbox:Array<Int> = null;
	private static var __inverse:Array<Int> = null;

	private static function __tables():Void {
		if (__inverse != null) {
			return;
		}
		var sbox:Array<Int> = [for (_ in 0...256) 0];
		var inverse:Array<Int> = [for (_ in 0...256) 0];
		var p:Int = 1;
		var q:Int = 1;
		do {
			// p times 3, q divided by 3: q stays p's inverse.
			p = (p ^ ((p << 1) & 0xFF) ^ ((p & 0x80) != 0 ? 0x1B : 0)) & 0xFF;
			q ^= (q << 1) & 0xFF;
			q ^= (q << 2) & 0xFF;
			q ^= (q << 4) & 0xFF;
			if ((q & 0x80) != 0) {
				q ^= 0x09;
			}
			var x:Int = q ^ __rotate(q, 1) ^ __rotate(q, 2) ^ __rotate(q, 3) ^ __rotate(q, 4);
			sbox[p] = (x ^ 0x63) & 0xFF;
		} while (p != 1);
		sbox[0] = 0x63;
		for (i in 0...256) {
			inverse[sbox[i]] = i;
		}
		__sbox = sbox;
		__inverse = inverse;
	}

	private static inline function __rotate(x:Int, shift:Int):Int {
		return ((x << shift) | (x >> (8 - shift))) & 0xFF;
	}

	/** The round keys, a byte each, in the order AddRoundKey takes them. **/
	private static function __expandKey(key:Bytes):Array<Int> {
		__tables();
		var nk:Int = key.length >> 2;
		var rounds:Int = nk + 6;
		var words:Int = 4 * (rounds + 1);
		var w:Array<Int> = [for (i in 0...words * 4) 0];
		for (i in 0...key.length) {
			w[i] = key.get(i);
		}
		var rcon:Int = 1;
		for (i in nk...words) {
			var t0:Int = w[(i - 1) * 4];
			var t1:Int = w[(i - 1) * 4 + 1];
			var t2:Int = w[(i - 1) * 4 + 2];
			var t3:Int = w[(i - 1) * 4 + 3];
			if (i % nk == 0) {
				var first:Int = t0;
				t0 = __sbox[t1] ^ rcon;
				t1 = __sbox[t2];
				t2 = __sbox[t3];
				t3 = __sbox[first];
				rcon = __times2(rcon);
			} else if (nk > 6 && i % nk == 4) {
				t0 = __sbox[t0];
				t1 = __sbox[t1];
				t2 = __sbox[t2];
				t3 = __sbox[t3];
			}
			w[i * 4] = w[(i - nk) * 4] ^ t0;
			w[i * 4 + 1] = w[(i - nk) * 4 + 1] ^ t1;
			w[i * 4 + 2] = w[(i - nk) * 4 + 2] ^ t2;
			w[i * 4 + 3] = w[(i - nk) * 4 + 3] ^ t3;
		}
		return w;
	}

	/** The inverse cipher (FIPS 197 5.3), in place; byte `r + 4c` is row r, column c. **/
	private static function __decryptBlock(state:Bytes, w:Array<Int>, rounds:Int):Void {
		var s:Array<Int> = [for (i in 0...16) state.get(i)];
		__addRoundKey(s, w, rounds);
		var round:Int = rounds - 1;
		while (round >= 1) {
			__invShiftRows(s);
			__invSubBytes(s);
			__addRoundKey(s, w, round);
			__invMixColumns(s);
			round--;
		}
		__invShiftRows(s);
		__invSubBytes(s);
		__addRoundKey(s, w, 0);
		for (i in 0...16) {
			state.set(i, s[i]);
		}
	}

	private static inline function __addRoundKey(s:Array<Int>, w:Array<Int>, round:Int):Void {
		var base:Int = round * 16;
		for (i in 0...16) {
			s[i] ^= w[base + i];
		}
	}

	private static function __invShiftRows(s:Array<Int>):Void {
		// Row r moves r columns right.
		for (r in 1...4) {
			var row:Array<Int> = [for (c in 0...4) s[r + 4 * c]];
			for (c in 0...4) {
				s[r + 4 * ((c + r) % 4)] = row[c];
			}
		}
	}

	private static inline function __invSubBytes(s:Array<Int>):Void {
		for (i in 0...16) {
			s[i] = __inverse[s[i]];
		}
	}

	private static function __invMixColumns(s:Array<Int>):Void {
		for (c in 0...4) {
			var a0:Int = s[4 * c];
			var a1:Int = s[4 * c + 1];
			var a2:Int = s[4 * c + 2];
			var a3:Int = s[4 * c + 3];
			s[4 * c] = __mul(a0, 14) ^ __mul(a1, 11) ^ __mul(a2, 13) ^ __mul(a3, 9);
			s[4 * c + 1] = __mul(a0, 9) ^ __mul(a1, 14) ^ __mul(a2, 11) ^ __mul(a3, 13);
			s[4 * c + 2] = __mul(a0, 13) ^ __mul(a1, 9) ^ __mul(a2, 14) ^ __mul(a3, 11);
			s[4 * c + 3] = __mul(a0, 11) ^ __mul(a1, 13) ^ __mul(a2, 9) ^ __mul(a3, 14);
		}
	}

	private static inline function __times2(x:Int):Int {
		return ((x << 1) ^ ((x & 0x80) != 0 ? 0x1B : 0)) & 0xFF;
	}

	/** Multiplication in GF(2^8). **/
	private static function __mul(a:Int, b:Int):Int {
		var product:Int = 0;
		while (b != 0) {
			if ((b & 1) != 0) {
				product ^= a;
			}
			a = __times2(a);
			b >>= 1;
		}
		return product;
	}

	private static function __hex(der:Bytes, element:DerElement):String {
		return der.sub(element.start, element.end - element.start).toHex();
	}

	/** The DER element at `at`, which must carry `tag`. **/
	private static function __element(der:Bytes, at:Int, tag:Int):DerElement {
		if (at + 2 > der.length || der.get(at) != tag) {
			throw new EncryptedKeyFailure();
		}
		var first:Int = der.get(at + 1);
		var start:Int = at + 2;
		var length:Int = first;
		if (first >= 0x80) {
			var count:Int = first & 0x7F;
			if (count == 0 || count > 3 || start + count > der.length) {
				throw new EncryptedKeyFailure();
			}
			length = 0;
			for (i in 0...count) {
				length = (length << 8) | der.get(start + i);
			}
			start += count;
		}
		if (start + length > der.length) {
			throw new EncryptedKeyFailure();
		}
		return new DerElement(start, start + length);
	}
}

@:noCompletion
private class DerElement {
	public final start:Int;
	public final end:Int;

	public function new(start:Int, end:Int) {
		this.start = start;
		this.end = end;
	}
}

/** Thrown inside `EncryptedKey.decrypt` for a structure it does not read, which leaves the key to mbedTLS. **/
@:noCompletion
private class EncryptedKeyFailure extends haxe.Exception {
	public function new() {
		super("not a key this reads");
	}
}
