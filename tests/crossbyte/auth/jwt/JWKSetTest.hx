package crossbyte.auth.jwt;

import crossbyte.crypto.PublicKeySignature;
import haxe.io.Bytes;
import utest.Assert;
import crossbyte.test.Require;

/**
 * JWK Set ingestion.
 *
 * The parsing cases run everywhere, since turning a JWK into a PEM is
 * pure Haxe. The round-trip cases need the `openssl` CLI to produce a real
 * keypair and skip without it, matching `PkJwtTest`.
 *
 * The round trip is the case that matters: a real public key is reduced
 * to the numbers a JWK publishes, rebuilt through `JWKSet`, and then used
 * to verify a signature made by the matching private key. Structural
 * checks alone would pass on a document that merely looks like a key.
 */
class JWKSetTest extends utest.Test {
	// --- parsing, no toolchain required ---

	public function testDocumentWithoutKeysArrayIsRejected():Void {
		Assert.raises(() -> JWKSet.parse("{}"), String);
		Assert.raises(() -> JWKSet.parse("not json at all"), String);
		Assert.raises(() -> JWKSet.parse(""), String);
		// A `keys` member of the wrong shape is as unusable as none.
		Assert.raises(() -> JWKSet.parse('{"keys":"nope"}'), String);
	}

	public function testEmptyKeySetParsesToNothing():Void {
		var set = JWKSet.parse('{"keys":[]}');
		Assert.equals(0, set.keys.length);
		Assert.equals(0, set.ignored.length);
		Assert.equals(0, Lambda.count(set.pemsFor("RS256")));
	}

	/**
	 * A key this build cannot use must not cost the caller the keys it
	 * can. Providers stage the next key in the set before signing with
	 * it, so an unusable entry alongside good ones is routine.
	 */
	public function testUnusableKeysAreIgnoredWithoutLosingTheRest():Void {
		var set = JWKSet.parse('{"keys":[
			{"kty":"oct","kid":"symmetric","k":"AAAA"},
			{"kty":"EC","kid":"wrong-curve","crv":"P-384","x":"AAAA","y":"BBBB"},
			{"kty":"RSA","kid":"encryption","use":"enc","n":"' + __sampleModulus() + '","e":"AQAB"},
			{"kid":"typeless"},
			{"kty":"RSA","kid":"good","n":"' + __sampleModulus() + '","e":"AQAB"}
		]}');

		Assert.equals(1, set.keys.length);
		Assert.equals("good", set.keys[0].kid);
		Assert.equals(4, set.ignored.length);

		var pems = set.pemsFor("RS256");
		Assert.isTrue(pems.exists("good"));
		Assert.isFalse(pems.exists("encryption"));

		// Every rejection carries a reason; a silent drop would look
		// identical to a provider never having published the key.
		for (entry in set.ignored) {
			Assert.isTrue(entry.reason != null && entry.reason.length > 0);
		}
	}

	public function testMalformedKeyMaterialIsIgnoredRatherThanThrown():Void {
		var set = JWKSet.parse('{"keys":[
			{"kty":"RSA","kid":"no-exponent","n":"' + __sampleModulus() + '"},
			{"kty":"RSA","kid":"bad-base64","n":"!!!not base64!!!","e":"AQAB"},
			{"kty":"EC","kid":"missing-y","crv":"P-256","x":"AAAA"}
		]}');

		Assert.equals(0, set.keys.length);
		Assert.equals(3, set.ignored.length);
	}

	/**
	 * A rotation republishes an id. The later entry wins, matching what a
	 * provider means by it, but the collision is still reported.
	 */
	public function testDuplicateKeyIdKeepsTheLastAndReportsIt():Void {
		var set = JWKSet.parse('{"keys":[
			{"kty":"RSA","kid":"rotating","n":"' + __sampleModulus() + '","e":"AQAB"},
			{"kty":"RSA","kid":"rotating","n":"' + __sampleModulus(true) + '","e":"AQAB"}
		]}');

		Assert.equals(1, set.keys.length);
		Assert.equals(1, set.ignored.length);
		Assert.equals(1, Lambda.count(set.pemsFor("RS256")));
	}

	public function testAlgorithmIsSeparatedAcrossKindsAndMismatchedAlgIsRefused():Void {
		var set = JWKSet.parse('{"keys":[
			{"kty":"RSA","kid":"r","n":"' + __sampleModulus() + '","e":"AQAB"},
			{"kty":"EC","kid":"e","crv":"P-256","x":"' + __sampleCoordinate() + '","y":"' + __sampleCoordinate(true) + '"},
			{"kty":"RSA","kid":"rs512","alg":"RS512","n":"' + __sampleModulus() + '","e":"AQAB"}
		]}');

		var rsa = set.pemsFor("RS256");
		var ec = set.pemsFor("ES256");

		Assert.equals(1, Lambda.count(rsa));
		Assert.equals(1, Lambda.count(ec));
		Assert.isTrue(rsa.exists("r"));
		Assert.isTrue(ec.exists("e"));

		// A key published for RS512 must not be pressed into RS256.
		Assert.isFalse(rsa.exists("rs512"));
		Assert.equals(1, set.ignored.length);

		Assert.equals(2, set.kids().length);
		Assert.notNull(set.get("r"));
		Assert.isNull(set.get("absent"));
	}

	/**
	 * Tokens from small issuers often carry no `kid`, so a lone key has to
	 * be reachable — but only when it is genuinely unambiguous.
	 */
	public function testSinglePemOnlyResolvesAnUnambiguousSet():Void {
		var one = JWKSet.parse('{"keys":[{"kty":"RSA","n":"' + __sampleModulus() + '","e":"AQAB"}]}');
		Assert.notNull(one.singlePem("RS256"));
		Assert.isNull(one.singlePem("ES256"));

		// Without a kid there is nothing to index by, so the map is empty
		// even though the key itself is usable.
		Assert.equals(0, Lambda.count(one.pemsFor("RS256")));

		var two = JWKSet.parse('{"keys":[
			{"kty":"RSA","kid":"a","n":"' + __sampleModulus() + '","e":"AQAB"},
			{"kty":"RSA","kid":"b","n":"' + __sampleModulus(true) + '","e":"AQAB"}
		]}');
		Assert.isNull(two.singlePem("RS256"), "an ambiguous set must not pick a key arbitrarily");
	}

	public function testGeneratedPemIsWellFormed():Void {
		var set = JWKSet.parse('{"keys":[{"kty":"RSA","kid":"k","n":"' + __sampleModulus() + '","e":"AQAB"}]}');
		var pem = set.keys[0].toPem();

		Assert.stringContains("-----BEGIN PUBLIC KEY-----", pem);
		Assert.stringContains("-----END PUBLIC KEY-----", pem);

		// Base64 bodies wrap at 64 columns; an unwrapped blob is rejected
		// by some parsers even though it decodes.
		for (line in pem.split("\n")) {
			Assert.isTrue(line.length <= 64, 'PEM line longer than 64 characters: ${line.length}');
		}
	}

	// --- round trip against a real key, needs openssl ---

	#if cpp
	/**
	 * A real RSA public key, reduced to `n` and `e` the way a provider
	 * publishes it, rebuilt through `JWKSet`, and then required to verify
	 * a signature made by the matching private key.
	 */
	public function testRsaJwkRebuildsAKeyThatVerifiesRealSignatures():Void {
		var keys = PkKeyFixture.rsa();
		var modulus = keys == null ? null : PkKeyFixture.rsaModulusBase64Url();
		if (keys == null || modulus == null) {
			Assert.pass();
			return;
		}

		var set = JWKSet.parse('{"keys":[{"kty":"RSA","kid":"live","n":"$modulus","e":"AQAB"}]}');
		Assert.equals(0, set.ignored.length, set.ignored.length > 0 ? set.ignored[0].reason : "");
		Assert.equals(1, set.keys.length);

		var rebuilt = set.pemsFor("RS256").get("live");
		Assert.notNull(rebuilt);
		Assert.equals(PublicKeyType.RSA, PublicKeySignature.keyType(rebuilt));

		var message = Bytes.ofString("crossbyte jwks rs256");
		var signature = PublicKeySignature.sign(keys.privatePem, message);
		Assert.isTrue(PublicKeySignature.verify(rebuilt, message, signature), "rebuilt RSA key failed to verify a real signature");
		Assert.isFalse(PublicKeySignature.verify(rebuilt, Bytes.ofString("different"), signature));
	}

	/**
	 * The same for P-256, where the JWK carries the affine coordinates and
	 * the encoder has to rebuild the uncompressed point.
	 */
	public function testEcJwkRebuildsAKeyThatVerifiesRealSignatures():Void {
		var keys = PkKeyFixture.ec();
		var point = keys == null ? null : PkKeyFixture.ecCoordinatesBase64Url();
		if (keys == null || point == null) {
			Assert.pass();
			return;
		}

		var set = JWKSet.parse('{"keys":[{"kty":"EC","kid":"live","crv":"P-256","x":"${point.x}","y":"${point.y}"}]}');
		Assert.equals(0, set.ignored.length, set.ignored.length > 0 ? set.ignored[0].reason : "");

		var rebuilt = set.pemsFor("ES256").get("live");
		Assert.notNull(rebuilt);
		Assert.equals(PublicKeyType.EC, PublicKeySignature.keyType(rebuilt));
		// P-256 gives 32 bytes per coordinate, so JOSE r||s is 64. A point
		// rebuilt at the wrong size would show up here before any verify.
		Assert.equals(64, PublicKeySignature.joseSignatureLength(rebuilt));

		var message = Bytes.ofString("crossbyte jwks es256");
		var signature = PublicKeySignature.sign(keys.privatePem, message, JOSE);
		Assert.isTrue(PublicKeySignature.verify(rebuilt, message, signature, JOSE), "rebuilt EC key failed to verify a real signature");
		Assert.isFalse(PublicKeySignature.verify(rebuilt, Bytes.ofString("different"), signature, JOSE));
	}

	/**
	 * The end a caller actually uses: a JWKS document straight into
	 * `JWT.make`, verifying a token signed with the matching key.
	 */
	public function testJwksFeedsJwtVerificationDirectly():Void {
		var keys = PkKeyFixture.rsa();
		var modulus = keys == null ? null : PkKeyFixture.rsaModulusBase64Url();
		if (keys == null || modulus == null) {
			Assert.pass();
			return;
		}

		var set = JWKSet.parse('{"keys":[{"kty":"RSA","kid":"live","n":"$modulus","e":"AQAB"}]}');
		var jwt = JWT.make(RS256(set.pemsFor("RS256"), keys.privatePem, "live"), "crossbyte", "tests", 0);

		var now:Int = Std.int(Date.now().getTime() / 1000);
		var token = jwt.generateToken({sub: "jwks", iat: now, exp: now + 300, iss: "crossbyte", aud: "tests"});
		Assert.notNull(token);

		var verified = jwt.verifyToken(token);
		Require.notNull(verified, "a token signed with the private key did not verify against the JWKS-derived public key");
		Assert.equals("jwks", verified.subject);
	}
	#end

	// --- fixtures ---

	/**
	 * A syntactically valid 2048-bit modulus. The bytes are arbitrary; the
	 * parsing cases only need something well formed to carry.
	 */
	private function __sampleModulus(variant:Bool = false):String {
		var raw = Bytes.alloc(256);
		for (i in 0...raw.length) {
			raw.set(i, ((i * 7) + (variant ? 3 : 1)) & 0xFF);
		}
		// A leading bit set is the usual case for a real modulus and is
		// what forces the DER encoder's zero-padding path.
		raw.set(0, 0xC0);
		return JWT.base64UrlEncodeBytes(raw);
	}

	private function __sampleCoordinate(variant:Bool = false):String {
		var raw = Bytes.alloc(32);
		for (i in 0...raw.length) {
			raw.set(i, ((i * 11) + (variant ? 5 : 2)) & 0xFF);
		}
		return JWT.base64UrlEncodeBytes(raw);
	}
}
