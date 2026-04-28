package crossbyte.crypto;

import crossbyte.crypto.password.BCrypt;
import haxe.io.Bytes;
import utest.Assert;

class CryptoTest extends utest.Test {
	public function testSecureRandomMatchesTargetSemantics():Void {
		#if cpp
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
