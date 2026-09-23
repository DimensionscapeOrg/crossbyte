package crossbyte.crypto;

import crossbyte.crypto.password.BCrypt;
import haxe.io.Bytes;
import utest.Assert;

class CryptoTest extends utest.Test {
	public function testSecureRandomMatchesTargetSemantics():Void {
		#if (cpp || java || jvm)
		// jvm uses java.security.SecureRandom and matches the cpp length semantics.
		Assert.equals(0, SecureRandom.getSecureRandomBytes(-1).length);
		Assert.equals(0, SecureRandom.getSecureRandomBytes(0).length);
		Assert.equals(32, SecureRandom.getSecureRandomBytes(32).length);
		#else
		Assert.isTrue(throwsDynamic(() -> SecureRandom.getSecureRandomBytes(1)));
		#end
	}

	public function testBlake3AvailabilityAndDeterministicHashing():Void {
		#if cpp
		Assert.isTrue(Blake3.isAvailable());
		Assert.isTrue(Blake3.simdDegree() >= 1);
		Assert.equals("af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262", Blake3.hashHex(Bytes.alloc(0)));
		Assert.equals("6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85", Blake3.hashStringHex("abc"));
		Assert.equals(16, Blake3.hashString("abc", 16).length);
		Assert.equals("", Blake3.hashStringHex("abc", 0));
		Assert.equals(Blake3.hashHex(Bytes.ofString("abc")), Blake3.hashStringHex("abc"));
		Assert.isTrue(throwsDynamic(() -> Blake3.hash(Bytes.ofString("abc"), -1)));
		#else
		Assert.isFalse(Blake3.isAvailable());
		Assert.equals(0, Blake3.simdDegree());
		Assert.isTrue(throwsDynamic(() -> Blake3.hash(Bytes.ofString("abc"))));
		#end
	}

	#if cpp
	/**
	 * The vectors above never reach the SSE and AVX2 code: BLAKE3 only hands
	 * work to its vector backends once an input holds two whole 1 KiB chunks,
	 * and "abc" is three bytes. When the flags those files need were being
	 * dropped, only GCC refusing to compile them gave it away; a backend that
	 * compiled and hashed wrongly would have passed everything.
	 *
	 * These are upstream's test_vectors.json entries for the same lengths, with
	 * its input pattern, byte i = i % 251: 2049 is just past where the vector
	 * path starts, 4097 fills an SSE4.1 batch of four, 8193 an AVX2 batch of
	 * eight, and 102400 builds a tree a hundred chunks wide whose parent nodes
	 * are hashed in parallel too.
	 */
	public function testBlake3MatchesThePublishedVectorsOnTheSimdPath():Void {
		for (vector in [
			{length: 2049, hash: "5f4d72f40d7a5f82b15ca2b2e44b1de3c2ef86c426c95c1af0b6879522563030"},
			{length: 4097, hash: "9b4052b38f1c5fc8b1f9ff7ac7b27cd242487b3d890d15c96a1c25b8aa0fb995"},
			{length: 8193, hash: "bab6c09cb8ce8cf459261398d2e7aef35700bf488116ceb94a36d0f5f1b7bc3b"},
			{length: 102400, hash: "bc3e3d41a1146b069abffad3c0d44860cf664390afce4d9661f7902e7943e085"}
		]) {
			var input:Bytes = Bytes.alloc(vector.length);
			for (i in 0...vector.length) {
				input.set(i, i % 251);
			}
			Assert.equals(vector.hash, Blake3.hashHex(input), 'BLAKE3 of ${vector.length} bytes');
		}
	}
	#end

	public function testEd25519AvailabilityAndValidationPaths():Void {
		Assert.isFalse(Ed25519.verifyDetached(null, Bytes.ofString("hello"), Bytes.alloc(Ed25519.PUBLIC_KEY_BYTES)));
		Assert.isFalse(Ed25519.verifyDetached(Bytes.alloc(Ed25519.SIGNATURE_BYTES), Bytes.ofString("hello"), Bytes.alloc(1)));
		Assert.equals(32, Ed25519.PUBLIC_KEY_BYTES);
		Assert.equals(64, Ed25519.SECRET_KEY_BYTES);
		Assert.equals(64, Ed25519.SIGNATURE_BYTES);

		var message = Bytes.ofString("hello");

		#if (cpp && windows)
		Assert.isTrue(Ed25519.isAvailable());
		Assert.equals("libsodium is available.", Ed25519.availabilityMessage());

		var keyPair = Ed25519.keypair();
		Assert.equals(Ed25519.PUBLIC_KEY_BYTES, keyPair.publicKey.length);
		Assert.equals(Ed25519.SECRET_KEY_BYTES, keyPair.secretKey.length);

		var signature = Ed25519.signDetached(message, keyPair.secretKey);
		Assert.equals(Ed25519.SIGNATURE_BYTES, signature.length);
		Assert.isTrue(Ed25519.verifyDetached(signature, message, keyPair.publicKey));

		var tampered = Bytes.ofString("hullo");
		Assert.isFalse(Ed25519.verifyDetached(signature, tampered, keyPair.publicKey));
		#elseif cpp
		Assert.isFalse(Ed25519.isAvailable());
		Assert.notEquals(-1, Ed25519.availabilityMessage().indexOf("wired"));
		Assert.isTrue(throwsDynamic(() -> Ed25519.keypair()));
		Assert.isTrue(throwsDynamic(() -> Ed25519.signDetached(message, Bytes.alloc(Ed25519.SECRET_KEY_BYTES))));
		Assert.isFalse(Ed25519.verifyDetached(Bytes.alloc(Ed25519.SIGNATURE_BYTES), message, Bytes.alloc(Ed25519.PUBLIC_KEY_BYTES)));
		#else
		Assert.isFalse(Ed25519.isAvailable());
		Assert.equals("Ed25519 is only available on supported native cpp targets.", Ed25519.availabilityMessage());
		Assert.isTrue(throwsDynamic(() -> Ed25519.keypair()));
		Assert.isTrue(throwsDynamic(() -> Ed25519.signDetached(message, Bytes.alloc(Ed25519.SECRET_KEY_BYTES))));
		#end
	}

	public function testBCryptSupportsVerificationAndRehashSignals():Void {
		Assert.isTrue(BCrypt.needsRehash(null));
		Assert.isTrue(BCrypt.needsRehash("not-a-bcrypt-hash"));
		Assert.isFalse(BCrypt.verify("hunter2", "not-a-bcrypt-hash"));

		#if cpp
		var hash = BCrypt.hash("hunter2", 4);
		Assert.isTrue(BCrypt.verify("hunter2", hash));
		Assert.isFalse(BCrypt.verify("wrong-password", hash));
		Assert.isFalse(BCrypt.needsRehash(hash, 4));
		Assert.isTrue(BCrypt.needsRehash(hash, 5));
		#end
	}

	private static function throwsDynamic(fn:Void->Void):Bool {
		try {
			fn();
			return false;
		} catch (_:Dynamic) {
			return true;
		}
	}
}
