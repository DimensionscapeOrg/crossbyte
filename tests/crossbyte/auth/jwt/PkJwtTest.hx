package crossbyte.auth.jwt;

import crossbyte.crypto.PublicKeySignature;
import haxe.ds.StringMap;
import haxe.io.Bytes;
import utest.Assert;

/**
 * RS256 and ES256 JWTs over the mbedTLS bridge.
 *
 * Keys are generated at test time with the `openssl` CLI and cached in the
 * temp directory, so nothing expirable is committed. Cases skip when no
 * toolchain is present.
 */
class PkJwtTest extends utest.Test {
	#if (cpp && windows)
	public function testRsaSignVerifyAndTamper():Void {
		var keys = PkKeyFixture.rsa();
		if (keys == null) {
			Assert.pass();
			return;
		}

		var message = Bytes.ofString("crossbyte rs256");
		var signature = PublicKeySignature.sign(keys.privatePem, message);

		// A 2048-bit RSA signature is exactly the modulus size.
		Assert.equals(256, signature.length);
		Assert.isTrue(PublicKeySignature.verify(keys.publicPem, message, signature));
		Assert.isFalse(PublicKeySignature.verify(keys.publicPem, Bytes.ofString("other"), signature));
		Assert.equals(PublicKeyType.RSA, PublicKeySignature.keyType(keys.publicPem));
	}

	public function testEcdsaJoseAndDerFormats():Void {
		var keys = PkKeyFixture.ec();
		if (keys == null) {
			Assert.pass();
			return;
		}

		var message = Bytes.ofString("crossbyte es256");

		// JWS carries r||s; P-256 gives 32 bytes each.
		Assert.equals(64, PublicKeySignature.joseSignatureLength(keys.publicPem));
		var jose = PublicKeySignature.sign(keys.privatePem, message, JOSE);
		Assert.equals(64, jose.length);
		Assert.isTrue(PublicKeySignature.verify(keys.publicPem, message, jose, JOSE));
		Assert.isFalse(PublicKeySignature.verify(keys.publicPem, Bytes.ofString("other"), jose, JOSE));

		// The same key also round-trips ASN.1 DER, which is what X.509 uses.
		var der = PublicKeySignature.sign(keys.privatePem, message);
		Assert.isTrue(PublicKeySignature.verify(keys.publicPem, message, der));
		// A DER signature is not valid when read as raw r||s.
		Assert.isFalse(PublicKeySignature.verify(keys.publicPem, message, der, JOSE));

		Assert.equals(PublicKeyType.EC, PublicKeySignature.keyType(keys.publicPem));
		Assert.equals(-1, PublicKeySignature.joseSignatureLength(PkKeyFixture.rsa().publicPem));
	}

	public function testRs256JwtRoundTrip():Void {
		var keys = PkKeyFixture.rsa();
		if (keys == null) {
			Assert.pass();
			return;
		}

		var publicKeys = new StringMap<String>();
		publicKeys.set("k1", keys.publicPem);

		var jwt = JWT.make(RS256(publicKeys, keys.privatePem, "k1"), "issuer-a", "aud-a", 0);
		var now = Std.int(Date.now().getTime() / 1000);
		var token = jwt.generateToken({sub: "subject", iat: now - 5, exp: now + 60, iss: "issuer-a", aud: "aud-a"});

		var verified = jwt.verifyToken(token);
		Assert.notNull(verified);
		Assert.equals("subject", verified.subject);

		// A tampered payload must not verify.
		var parts = token.split(".");
		var tampered = parts[0] + "." + JWT.base64UrlEncodeString('{"sub":"x","exp":' + (now + 60) + "}") + "." + parts[2];
		Assert.isNull(jwt.verifyToken(tampered));

		// Expiry is still enforced for asymmetric tokens.
		Assert.isNull(jwt.verifyToken(jwt.generateToken({sub: "s", iat: now - 300, exp: now - 120, iss: "issuer-a", aud: "aud-a"})));
	}

	public function testEs256JwtRoundTrip():Void {
		var keys = PkKeyFixture.ec();
		if (keys == null) {
			Assert.pass();
			return;
		}

		var publicKeys = new StringMap<String>();
		publicKeys.set("k1", keys.publicPem);

		var jwt = JWT.make(ES256(publicKeys, keys.privatePem, "k1"), "issuer-a", "aud-a", 0);
		var now = Std.int(Date.now().getTime() / 1000);
		var token = jwt.generateToken({sub: "subject", iat: now - 5, exp: now + 60, iss: "issuer-a", aud: "aud-a"});

		var verified = jwt.verifyToken(token);
		Assert.notNull(verified);
		Assert.equals("subject", verified.subject);

		// hxcpp builds mbedTLS with MBEDTLS_ECDSA_DETERMINISTIC, so nonces
		// follow RFC 6979 and signing the same payload twice is reproducible.
		// That is the stronger property: it removes the nonce-reuse failure
		// mode that has leaked ECDSA private keys in the wild.
		var again = jwt.generateToken({sub: "subject", iat: now - 5, exp: now + 60, iss: "issuer-a", aud: "aud-a"});
		Assert.equals(token.split(".")[2], again.split(".")[2]);
		Assert.notNull(jwt.verifyToken(again));

		// Determinism is per-payload, not a constant signature.
		var other = jwt.generateToken({sub: "different", iat: now - 5, exp: now + 60, iss: "issuer-a", aud: "aud-a"});
		Assert.notEquals(token.split(".")[2], other.split(".")[2]);
		Assert.notNull(jwt.verifyToken(other));
	}

	public function testVerifyOnlySignerAndKeyMismatches():Void {
		var rsa = PkKeyFixture.rsa();
		var ec = PkKeyFixture.ec();
		if (rsa == null || ec == null) {
			Assert.pass();
			return;
		}

		var publicKeys = new StringMap<String>();
		publicKeys.set("k1", rsa.publicPem);

		// Verify-only: the common shape for consuming another party's tokens.
		var verifier = JWT.make(RS256(publicKeys, null, "k1"), "issuer-a", "aud-a", 0);
		var signer = JWT.make(RS256(publicKeys, rsa.privatePem, "k1"), "issuer-a", "aud-a", 0);
		var now = Std.int(Date.now().getTime() / 1000);
		var token = signer.generateToken({sub: "s", iat: now - 5, exp: now + 60, iss: "issuer-a", aud: "aud-a"});

		Assert.notNull(verifier.verifyToken(token));

		// An EC key offered as RS256 would fail every verification at runtime
		// with no clue why, so it is rejected at construction.
		var wrongKind = new StringMap<String>();
		wrongKind.set("k1", ec.publicPem);
		Assert.raises(() -> JWT.make(RS256(wrongKind, null, "k1")));
		Assert.raises(() -> JWT.make(ES256(publicKeys, null, "k1")));

		// Empty key sets and unknown signing ids are configuration errors.
		Assert.raises(() -> JWT.make(RS256(new StringMap<String>(), null, null)));
		Assert.raises(() -> JWT.make(RS256(publicKeys, rsa.privatePem, "missing")));

		// An RS256 token must not verify under an ES256 verifier (alg confusion).
		var ecKeys = new StringMap<String>();
		ecKeys.set("k1", ec.publicPem);
		var ecJwt = JWT.make(ES256(ecKeys, null, "k1"), "issuer-a", "aud-a", 0);
		Assert.isNull(ecJwt.verifyToken(token));
	}
	#else
	public function testPkSignersRequireNativeBackend():Void {
		Assert.isFalse(PublicKeySignature.isAvailable());

		var keys = new StringMap<String>();
		keys.set("k1", "not-a-key");
		Assert.raises(() -> JWT.make(RS256(keys, null, "k1")));
		Assert.raises(() -> JWT.make(ES256(keys, null, "k1")));
	}
	#end
}
