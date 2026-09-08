package crossbyte.crypto;

import crossbyte.crypto.password.Argon2id;
import haxe.io.Bytes;
import utest.Assert;
import crossbyte.test.Require;

/**
 * Tests for the expanded libsodium bridge (proposal 0001):
 * Aead, X25519, KeyExchange, GenericHash, HKDF, Argon2id, ConstantTime,
 * SecureMemory.
 *
 * Known-answer sources:
 * - XChaCha20-Poly1305-IETF: draft-irtf-cfrg-xchacha-03 Appendix A.3.1.
 * - X25519: RFC 7748 section 6.1.
 * - BLAKE2b: RFC 7693 appendix A / reference vectors.
 * - HKDF-SHA-256: RFC 5869 appendix A.1.
 */
class SodiumExpansionTest extends utest.Test {
	private static inline final XCHACHA_PLAINTEXT_HEX:String = "4c616469657320616e642047656e746c656d656e206f662074686520636c617373206f66202739393a204966204920636f756c64206f6666657220796f75206f6e6c79206f6e652074697020666f7220746865206675747572652c2073756e73637265656e20776f756c642062652069742e";
	private static inline final XCHACHA_AAD_HEX:String = "50515253c0c1c2c3c4c5c6c7";
	private static inline final XCHACHA_KEY_HEX:String = "808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f";
	private static inline final XCHACHA_NONCE_HEX:String = "404142434445464748494a4b4c4d4e4f5051525354555657";
	private static inline final XCHACHA_CIPHERTEXT_HEX:String = "bd6d179d3e83d43b9576579493c0e939572a1700252bfaccbed2902c21396cbb731c7f1b0b4aa6440bf3a82f4eda7e39ae64c6708c54c216cb96b72e1213b4522f8c9ba40db5d945b11b69b982c1bb9e3f3fac2bc369488f76b2383565d3fff921f9664c97637da9768812f615c68b13b52e";
	private static inline final XCHACHA_TAG_HEX:String = "c0875924c1c7987947deafd8780acf49";

	private static inline final X25519_ALICE_SK_HEX:String = "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a";
	private static inline final X25519_ALICE_PK_HEX:String = "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a";
	private static inline final X25519_BOB_SK_HEX:String = "5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb";
	private static inline final X25519_BOB_PK_HEX:String = "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f";
	private static inline final X25519_SHARED_HEX:String = "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742";

	private static inline final BLAKE2B_512_ABC_HEX:String = "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923";
	private static inline final BLAKE2B_512_EMPTY_HEX:String = "786a02f742015903c6c6fd852552d272912f4740e15847618a86e217f71f5419d25e1031afee585313896444934eb04b903a685b1448b755d56f701afe9be2ce";

	private static inline final HKDF_IKM_HEX:String = "0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b";
	private static inline final HKDF_SALT_HEX:String = "000102030405060708090a0b0c";
	private static inline final HKDF_INFO_HEX:String = "f0f1f2f3f4f5f6f7f8f9";
	private static inline final HKDF_PRK_HEX:String = "077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5";
	private static inline final HKDF_OKM_HEX:String = "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865";

	public function testConstantsMatchLibsodiumAbi():Void {
		Assert.equals(32, Aead.KEY_BYTES);
		Assert.equals(24, Aead.NONCE_BYTES);
		Assert.equals(16, Aead.TAG_BYTES);
		Assert.equals(32, X25519.SCALAR_BYTES);
		Assert.equals(32, X25519.POINT_BYTES);
		Assert.equals(32, KeyExchange.PUBLIC_KEY_BYTES);
		Assert.equals(32, KeyExchange.SECRET_KEY_BYTES);
		Assert.equals(32, KeyExchange.SESSION_KEY_BYTES);
		Assert.equals(16, GenericHash.BYTES_MIN);
		Assert.equals(32, GenericHash.BYTES_DEFAULT);
		Assert.equals(64, GenericHash.BYTES_MAX);
		Assert.equals(32, HKDF.SHA256_PRK_BYTES);
		Assert.equals(8160, HKDF.SHA256_EXPAND_MAX_BYTES);
		Assert.equals(16, Argon2id.SALT_BYTES);
		Assert.equals(1, Argon2id.OPSLIMIT_MIN);
		Assert.equals(8192, Argon2id.MEMLIMIT_MIN);
		Assert.equals(2, Argon2id.OPSLIMIT_INTERACTIVE);
		Assert.equals(67108864, Argon2id.MEMLIMIT_INTERACTIVE);
	}

	public function testAeadKnownAnswerVector():Void {
		#if (cpp && windows)
		Assert.isTrue(Aead.isAvailable());

		var key = Bytes.ofHex(XCHACHA_KEY_HEX);
		var nonce = Bytes.ofHex(XCHACHA_NONCE_HEX);
		var plaintext = Bytes.ofHex(XCHACHA_PLAINTEXT_HEX);
		var aad = Bytes.ofHex(XCHACHA_AAD_HEX);

		var sealed = Aead.encrypt(plaintext, nonce, key, aad);
		Assert.equals(plaintext.length + Aead.TAG_BYTES, sealed.length);
		Assert.equals(XCHACHA_CIPHERTEXT_HEX + XCHACHA_TAG_HEX, sealed.toHex());

		var opened = Aead.decrypt(sealed, nonce, key, aad);
		Require.notNull(opened);
		Assert.equals(plaintext.toHex(), opened.toHex());
		#else
		Assert.isFalse(Aead.isAvailable());
		Assert.isTrue(throwsDynamic(() -> Aead.encrypt(Bytes.ofString("x"), Bytes.alloc(Aead.NONCE_BYTES), Bytes.alloc(Aead.KEY_BYTES))));
		Assert.isNull(Aead.decrypt(Bytes.alloc(Aead.TAG_BYTES), Bytes.alloc(Aead.NONCE_BYTES), Bytes.alloc(Aead.KEY_BYTES)));
		#end
	}

	public function testAeadRejectsTamperingAndMisuse():Void {
		#if (cpp && windows)
		var key = Aead.generateKey();
		var nonce = Aead.generateNonce();
		var plaintext = Bytes.ofString("attack at dawn");
		var aad = Bytes.ofString("header-v1");

		var sealed = Aead.encrypt(plaintext, nonce, key, aad);

		// Bit-flip in ciphertext body.
		var tampered = sealed.sub(0, sealed.length);
		tampered.set(3, tampered.get(3) ^ 0x01);
		Assert.isNull(Aead.decrypt(tampered, nonce, key, aad));

		// Bit-flip in tag.
		var tamperedTag = sealed.sub(0, sealed.length);
		tamperedTag.set(sealed.length - 1, tamperedTag.get(sealed.length - 1) ^ 0x80);
		Assert.isNull(Aead.decrypt(tamperedTag, nonce, key, aad));

		// Wrong key, wrong nonce, wrong/missing AD.
		Assert.isNull(Aead.decrypt(sealed, nonce, Aead.generateKey(), aad));
		Assert.isNull(Aead.decrypt(sealed, Aead.generateNonce(), key, aad));
		Assert.isNull(Aead.decrypt(sealed, nonce, key, Bytes.ofString("header-v2")));
		Assert.isNull(Aead.decrypt(sealed, nonce, key));

		// Truncation below the tag length can never authenticate.
		Assert.isNull(Aead.decrypt(sealed.sub(0, Aead.TAG_BYTES - 1), nonce, key, aad));

		// Empty plaintext round-trips (tag-only ciphertext).
		var emptySealed = Aead.encrypt(Bytes.alloc(0), nonce, key);
		Assert.equals(Aead.TAG_BYTES, emptySealed.length);
		var emptyOpened = Aead.decrypt(emptySealed, nonce, key);
		Require.notNull(emptyOpened);
		Assert.equals(0, emptyOpened.length);

		// Misuse throws rather than silently proceeding.
		Assert.isTrue(throwsDynamic(() -> Aead.encrypt(plaintext, Bytes.alloc(Aead.NONCE_BYTES - 1), key)));
		Assert.isTrue(throwsDynamic(() -> Aead.encrypt(plaintext, nonce, Bytes.alloc(Aead.KEY_BYTES + 1))));
		Assert.isTrue(throwsDynamic(() -> Aead.decrypt(sealed, Bytes.alloc(1), key)));
		Assert.isTrue(throwsDynamic(() -> Aead.decrypt(sealed, nonce, Bytes.alloc(0))));
		#else
		Assert.isTrue(throwsDynamic(() -> Aead.generateKey()));
		#end
	}

	public function testX25519Rfc7748Vectors():Void {
		#if (cpp && windows)
		Assert.isTrue(X25519.isAvailable());

		var aliceSecret = Bytes.ofHex(X25519_ALICE_SK_HEX);
		var bobSecret = Bytes.ofHex(X25519_BOB_SK_HEX);

		var alicePublic = X25519.scalarmultBase(aliceSecret);
		var bobPublic = X25519.scalarmultBase(bobSecret);
		Assert.equals(X25519_ALICE_PK_HEX, alicePublic.toHex());
		Assert.equals(X25519_BOB_PK_HEX, bobPublic.toHex());

		var aliceShared = X25519.scalarmult(aliceSecret, bobPublic);
		var bobShared = X25519.scalarmult(bobSecret, alicePublic);
		Assert.equals(X25519_SHARED_HEX, aliceShared.toHex());
		Assert.equals(X25519_SHARED_HEX, bobShared.toHex());

		// All-zero peer point is small-order and must be rejected.
		Assert.isTrue(throwsDynamic(() -> X25519.scalarmult(aliceSecret, Bytes.alloc(X25519.POINT_BYTES))));

		// Misuse.
		Assert.isTrue(throwsDynamic(() -> X25519.scalarmultBase(Bytes.alloc(X25519.SCALAR_BYTES - 1))));
		Assert.isTrue(throwsDynamic(() -> X25519.scalarmult(aliceSecret, Bytes.alloc(X25519.POINT_BYTES + 1))));
		#else
		Assert.isFalse(X25519.isAvailable());
		Assert.isTrue(throwsDynamic(() -> X25519.scalarmultBase(Bytes.alloc(X25519.SCALAR_BYTES))));
		#end
	}

	public function testKeyExchangeSessionKeysAgree():Void {
		#if (cpp && windows)
		Assert.isTrue(KeyExchange.isAvailable());

		var client = KeyExchange.keypair();
		var server = KeyExchange.keypair();
		Assert.equals(KeyExchange.PUBLIC_KEY_BYTES, client.publicKey.length);
		Assert.equals(KeyExchange.SECRET_KEY_BYTES, client.secretKey.length);

		var clientKeys = KeyExchange.clientSessionKeys(client.publicKey, client.secretKey, server.publicKey);
		var serverKeys = KeyExchange.serverSessionKeys(server.publicKey, server.secretKey, client.publicKey);

		// Client rx must equal server tx and vice versa.
		Assert.equals(serverKeys.tx.toHex(), clientKeys.rx.toHex());
		Assert.equals(serverKeys.rx.toHex(), clientKeys.tx.toHex());

		// The two directions are distinct keys.
		Assert.notEquals(clientKeys.rx.toHex(), clientKeys.tx.toHex());

		// Session keys are usable AEAD keys end to end.
		var nonce = Aead.generateNonce();
		var sealed = Aead.encrypt(Bytes.ofString("kx roundtrip"), nonce, clientKeys.tx);
		var opened = Aead.decrypt(sealed, nonce, serverKeys.rx);
		Require.notNull(opened);
		Assert.equals("kx roundtrip", opened.toString());

		Assert.isTrue(throwsDynamic(() -> KeyExchange.clientSessionKeys(client.publicKey, Bytes.alloc(1), server.publicKey)));
		#else
		Assert.isFalse(KeyExchange.isAvailable());
		Assert.isTrue(throwsDynamic(() -> KeyExchange.keypair()));
		#end
	}

	public function testGenericHashKnownAnswersAndKeying():Void {
		#if (cpp && windows)
		Assert.isTrue(GenericHash.isAvailable());

		Assert.equals(BLAKE2B_512_ABC_HEX, GenericHash.hash(Bytes.ofString("abc"), null, 64).toHex());
		Assert.equals(BLAKE2B_512_EMPTY_HEX, GenericHash.hash(Bytes.alloc(0), null, 64).toHex());
		Assert.equals(BLAKE2B_512_ABC_HEX, GenericHash.hashHex(Bytes.ofString("abc"), null, 64));

		// Default output length.
		Assert.equals(GenericHash.BYTES_DEFAULT, GenericHash.hash(Bytes.ofString("abc")).length);

		// Keyed hashing changes the digest; determinism holds per key.
		var key = SecureRandom.getSecureRandomBytes(32);
		var keyed = GenericHash.hash(Bytes.ofString("abc"), key);
		Assert.notEquals(GenericHash.hash(Bytes.ofString("abc")).toHex(), keyed.toHex());
		Assert.equals(keyed.toHex(), GenericHash.hash(Bytes.ofString("abc"), key).toHex());

		// Output and key bounds.
		Assert.isTrue(throwsDynamic(() -> GenericHash.hash(Bytes.ofString("abc"), null, GenericHash.BYTES_MIN - 1)));
		Assert.isTrue(throwsDynamic(() -> GenericHash.hash(Bytes.ofString("abc"), null, GenericHash.BYTES_MAX + 1)));
		Assert.isTrue(throwsDynamic(() -> GenericHash.hash(Bytes.ofString("abc"), Bytes.alloc(GenericHash.KEY_BYTES_MAX + 1))));
		#else
		Assert.isFalse(GenericHash.isAvailable());
		Assert.isTrue(throwsDynamic(() -> GenericHash.hash(Bytes.ofString("abc"))));
		#end
	}

	public function testHkdfRfc5869Vector():Void {
		#if (cpp && windows)
		Assert.isTrue(HKDF.isAvailable());

		var ikm = Bytes.ofHex(HKDF_IKM_HEX);
		var salt = Bytes.ofHex(HKDF_SALT_HEX);
		var info = Bytes.ofHex(HKDF_INFO_HEX);

		var prk = HKDF.sha256Extract(salt, ikm);
		Assert.equals(HKDF_PRK_HEX, prk.toHex());

		var okm = HKDF.sha256Expand(prk, info, 42);
		Assert.equals(HKDF_OKM_HEX, okm.toHex());

		Assert.equals(HKDF_OKM_HEX, HKDF.sha256(ikm, salt, info, 42).toHex());

		// Null salt and null info are valid per RFC 5869.
		Assert.equals(HKDF.SHA256_PRK_BYTES, HKDF.sha256Extract(null, ikm).length);
		Assert.equals(16, HKDF.sha256Expand(prk, null, 16).length);

		Assert.isTrue(throwsDynamic(() -> HKDF.sha256Expand(prk, info, 0)));
		Assert.isTrue(throwsDynamic(() -> HKDF.sha256Expand(prk, info, HKDF.SHA256_EXPAND_MAX_BYTES + 1)));
		Assert.isTrue(throwsDynamic(() -> HKDF.sha256Expand(Bytes.alloc(HKDF.SHA256_PRK_BYTES - 1), info, 16)));
		#else
		Assert.isFalse(HKDF.isAvailable());
		Assert.isTrue(throwsDynamic(() -> HKDF.sha256(Bytes.ofString("ikm"), null, null, 32)));
		#end
	}

	public function testArgon2idHashVerifyAndDerive():Void {
		#if (cpp && windows)
		Assert.isTrue(Argon2id.isAvailable());

		var hash = Argon2id.hash("correct horse battery staple", Argon2id.OPSLIMIT_MIN, Argon2id.MEMLIMIT_MIN);
		Assert.isTrue(StringTools.startsWith(hash, "$argon2id$"));
		Assert.isTrue(Argon2id.verify(hash, "correct horse battery staple"));
		Assert.isFalse(Argon2id.verify(hash, "correct horse battery staples"));
		Assert.isFalse(Argon2id.verify(hash, ""));
		Assert.isFalse(Argon2id.verify("not a phc string", "anything"));

		Assert.isFalse(Argon2id.needsRehash(hash, Argon2id.OPSLIMIT_MIN, Argon2id.MEMLIMIT_MIN));
		Assert.isTrue(Argon2id.needsRehash(hash, Argon2id.OPSLIMIT_INTERACTIVE, Argon2id.MEMLIMIT_INTERACTIVE));
		Assert.isTrue(Argon2id.needsRehash("not a phc string", Argon2id.OPSLIMIT_MIN, Argon2id.MEMLIMIT_MIN));

		// Raw derivation: deterministic per salt, salt-sensitive, length-exact.
		var saltA = Bytes.ofHex("000102030405060708090a0b0c0d0e0f");
		var saltB = Bytes.ofHex("0f0e0d0c0b0a09080706050403020100");
		var derivedA1 = Argon2id.derive("passphrase", saltA, 32, Argon2id.OPSLIMIT_MIN, Argon2id.MEMLIMIT_MIN);
		var derivedA2 = Argon2id.derive("passphrase", saltA, 32, Argon2id.OPSLIMIT_MIN, Argon2id.MEMLIMIT_MIN);
		var derivedB = Argon2id.derive("passphrase", saltB, 32, Argon2id.OPSLIMIT_MIN, Argon2id.MEMLIMIT_MIN);
		Assert.equals(32, derivedA1.length);
		Assert.equals(derivedA1.toHex(), derivedA2.toHex());
		Assert.notEquals(derivedA1.toHex(), derivedB.toHex());

		Assert.isTrue(throwsDynamic(() -> Argon2id.derive("passphrase", Bytes.alloc(Argon2id.SALT_BYTES - 1), 32, Argon2id.OPSLIMIT_MIN, Argon2id.MEMLIMIT_MIN)));
		Assert.isTrue(throwsDynamic(() -> Argon2id.derive("passphrase", saltA, 0, Argon2id.OPSLIMIT_MIN, Argon2id.MEMLIMIT_MIN)));
		#else
		Assert.isFalse(Argon2id.isAvailable());
		Assert.isTrue(throwsDynamic(() -> Argon2id.hash("pw")));
		Assert.isFalse(Argon2id.verify("$argon2id$bogus", "pw"));
		#end
	}

	public function testConstantTimeEqualsAndSecureWipe():Void {
		#if (cpp && windows)
		Assert.isTrue(ConstantTime.isAvailable());

		var a = Bytes.ofHex("00112233445566778899aabbccddeeff");
		var b = Bytes.ofHex("00112233445566778899aabbccddeeff");
		var c = Bytes.ofHex("00112233445566778899aabbccddee00");

		Assert.isTrue(ConstantTime.equals(a, b));
		Assert.isFalse(ConstantTime.equals(a, c));
		Assert.isFalse(ConstantTime.equals(a, a.sub(0, 8)));
		Assert.isFalse(ConstantTime.equals(null, b));
		Assert.isFalse(ConstantTime.equals(a, null));
		Assert.isTrue(ConstantTime.equals(Bytes.alloc(0), Bytes.alloc(0)));

		var secret = Bytes.ofHex("deadbeefdeadbeef");
		SecureMemory.wipe(secret);
		Assert.equals("0000000000000000", secret.toHex());
		SecureMemory.wipe(Bytes.alloc(0));
		SecureMemory.wipe(null);
		#else
		// Pure fallback comparison still behaves correctly even without sodium.
		Assert.isTrue(ConstantTime.equals(Bytes.ofString("ab"), Bytes.ofString("ab")));
		Assert.isFalse(ConstantTime.equals(Bytes.ofString("ab"), Bytes.ofString("ac")));
		var secret = Bytes.ofString("shh");
		SecureMemory.wipe(secret);
		Assert.equals(0, secret.get(0) | secret.get(1) | secret.get(2));
		#end
	}

	private static function throwsDynamic(fn:() -> Void):Bool {
		try {
			fn();
			return false;
		} catch (_:Dynamic) {
			return true;
		}
	}
}
