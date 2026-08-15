package crossbyte.auth.jwt;

import crossbyte.auth.jwt._internal.sign.Ed25519Signer;
import crossbyte.crypto.Ed25519;
import haxe.ds.StringMap;
import haxe.io.Bytes;
import utest.Assert;

/**
 * EdDSA JWT signing per RFC 8037.
 *
 * Known-answer source: RFC 8037 appendix A — Ed25519 key (A.1) and the JWS
 * signing example (A.4/A.5).
 */
class EdDSAJwtTest extends utest.Test {
	private static inline final SEED_HEX:String = "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60";
	private static inline final PUBLIC_HEX:String = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a";
	private static inline final JWS_SIGNING_INPUT:String = "eyJhbGciOiJFZERTQSJ9.RXhhbXBsZSBvZiBFZDI1NTE5IHNpZ25pbmc";
	private static inline final JWS_SIGNATURE:String = "hgyY0il_MGCjP0JzlnLWG1PPOt7-09PGcvMg3AIbQR6dWbhijcNR4ki4iylGjg5BhVsPt9g7sVvpAr_MuM0KAg";

	private static function rfcSecretKey():Bytes {
		// libsodium secret keys are seed || public key.
		var secretKey = Bytes.alloc(Ed25519.SECRET_KEY_BYTES);
		secretKey.blit(0, Bytes.ofHex(SEED_HEX), 0, 32);
		secretKey.blit(32, Bytes.ofHex(PUBLIC_HEX), 0, 32);
		return secretKey;
	}

	private static function rfcPublicKeys(keyId:String = "rfc8037"):StringMap<Bytes> {
		var keys = new StringMap<Bytes>();
		keys.set(keyId, Bytes.ofHex(PUBLIC_HEX));
		return keys;
	}

	#if (cpp && windows)
	public function testRfc8037KnownAnswerVector():Void {
		var signer = new Ed25519Signer(rfcPublicKeys(), rfcSecretKey());

		Assert.equals(JWS_SIGNATURE, signer.sign(JWS_SIGNING_INPUT));
		Assert.isTrue(signer.verify(JWS_SIGNING_INPUT, JWS_SIGNATURE));

		// Tampered input, tampered signature, and undecodable signature all fail.
		Assert.isFalse(signer.verify(JWS_SIGNING_INPUT + "x", JWS_SIGNATURE));
		Assert.isFalse(signer.verify(JWS_SIGNING_INPUT, "A" + JWS_SIGNATURE.substr(1)));
		Assert.isFalse(signer.verify(JWS_SIGNING_INPUT, "!!not-base64url!!"));
		Assert.isFalse(signer.verify(JWS_SIGNING_INPUT, ""));
	}

	public function testJwtRoundTripWithFreshKeypair():Void {
		var keyPair = Ed25519.keypair();
		var publicKeys = new StringMap<Bytes>();
		publicKeys.set("k1", keyPair.publicKey);

		var jwt = JWT.make(EdDSA(publicKeys, keyPair.secretKey, "k1"), "issuer-a", "aud-a", 0);
		var now = Std.int(Date.now().getTime() / 1000);
		var token = jwt.generateToken({
			sub: "subject",
			iat: now - 5,
			exp: now + 60,
			iss: "issuer-a",
			aud: "aud-a"
		});

		var verified = jwt.verifyToken(token);
		Assert.notNull(verified);
		Assert.equals("subject", verified.subject);
		Assert.equals("issuer-a", verified.issuer);

		// Tampered payload is rejected.
		var parts = token.split(".");
		var tampered = parts[0] + "." + JWT.base64UrlEncodeString('{"sub":"tampered","exp":' + (now + 60) + '}') + "." + parts[2];
		Assert.isNull(jwt.verifyToken(tampered));

		// An HS256 token is rejected by the EdDSA verifier (alg mismatch).
		var hs = JWT.make(HS256([{secret: "test-secret"}]), "issuer-a", "aud-a", 0);
		var hsToken = hs.generateToken({sub: "subject", iat: now - 5, exp: now + 60, iss: "issuer-a", aud: "aud-a"});
		Assert.isNull(jwt.verifyToken(hsToken));

		// Expired tokens are rejected with zero leeway.
		var expired = jwt.generateToken({sub: "subject", iat: now - 300, exp: now - 120, iss: "issuer-a", aud: "aud-a"});
		Assert.isNull(jwt.verifyToken(expired));

		// A verifier holding a different key id cannot verify this token.
		var otherKeys = new StringMap<Bytes>();
		otherKeys.set("k2", keyPair.publicKey);
		var otherJwt = JWT.make(EdDSA(otherKeys, null, null), "issuer-a", "aud-a", 0);
		Assert.isNull(otherJwt.verifyToken(token));
	}

	public function testConstructorAndSignValidation():Void {
		var goodKeys = rfcPublicKeys();
		var secretKey = rfcSecretKey();

		// Public key length is enforced.
		var badPublic = new StringMap<Bytes>();
		badPublic.set("bad", Bytes.alloc(Ed25519.PUBLIC_KEY_BYTES - 1));
		Assert.raises(() -> new Ed25519Signer(badPublic, null, null));

		// Private key length is enforced.
		Assert.raises(() -> new Ed25519Signer(goodKeys, Bytes.alloc(32), null));

		// A private key that does not match the declared public key is rejected.
		var otherPair = Ed25519.keypair();
		Assert.raises(() -> new Ed25519Signer(goodKeys, otherPair.secretKey, null));

		// Unknown signKeyId and empty key map are rejected.
		Assert.raises(() -> new Ed25519Signer(goodKeys, secretKey, "missing"));
		Assert.raises(() -> new Ed25519Signer(new StringMap<Bytes>(), null, null));

		// Multiple keys with a private key require an explicit signKeyId.
		var twoKeys = rfcPublicKeys("a");
		twoKeys.set("b", Bytes.ofHex(PUBLIC_HEX));
		Assert.raises(() -> new Ed25519Signer(twoKeys, secretKey, null));
		var pinned = new Ed25519Signer(twoKeys, secretKey, "a");
		Assert.equals(JWS_SIGNATURE, pinned.sign(JWS_SIGNING_INPUT));

		// Verify-only signers refuse to sign but verify normally.
		var verifyOnly = new Ed25519Signer(goodKeys, null, null);
		Assert.raises(() -> verifyOnly.sign(JWS_SIGNING_INPUT));
		Assert.isTrue(verifyOnly.verify(JWS_SIGNING_INPUT, JWS_SIGNATURE));
	}
	#else
	public function testEdDSARequiresNativeBackend():Void {
		Assert.raises(() -> JWT.make(EdDSA(rfcPublicKeys(), null, null)));
	}
	#end
}
