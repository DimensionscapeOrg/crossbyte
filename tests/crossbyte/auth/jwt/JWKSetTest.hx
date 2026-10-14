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
		Assert.raises(() -> JWKSet.parse("{}"), crossbyte.errors.ArgumentError);
		Assert.raises(() -> JWKSet.parse("not json at all"), crossbyte.errors.ArgumentError);
		Assert.raises(() -> JWKSet.parse(""), crossbyte.errors.ArgumentError);
		// A `keys` member of the wrong shape is as unusable as none.
		Assert.raises(() -> JWKSet.parse('{"keys":"nope"}'), crossbyte.errors.ArgumentError);
	}

	/**
	 * A document nested deeper than any real JWK Set is refused before it is
	 * parsed. Parsing takes a frame per level, and natively a set nested
	 * 6,000 deep (12 KB, from a provider's endpoint or whoever answers for
	 * it) would overflow the stack and end the process.
	 *
	 * The bound is 32 levels, objects and arrays together: here the set's
	 * object, its `keys` array and the key's object, then a member nesting
	 * the rest.
	 */
	public function testADeeplyNestedDocumentIsRefusedBeforeItIsParsed():Void {
		var modulus:String = __sampleModulus();
		function withMember(levels:Int):String {
			var member:String = StringTools.lpad("", "[", levels) + StringTools.lpad("", "]", levels);
			return '{"keys":[{"kty":"RSA","kid":"k","n":"$modulus","e":"AQAB","ext":$member}]}';
		}

		// 32 levels: read.
		Assert.equals(1, JWKSet.parse(withMember(29)).keys.length);
		// Brackets inside strings are text, an escaped quote's included.
		Assert.equals(1, JWKSet.parse('{"keys":[{"kty":"RSA","kid":"k","n":"$modulus","e":"AQAB","ext":"[[[[\\"[[[[' + StringTools.lpad("", "[", 64)
			+ '"}]}').keys.length);

		// 33 levels, which every parser here reads without trouble, and 6,000.
		for (levels in [30, 5997]) {
			var raised:Null<String> = null;
			try {
				JWKSet.parse(withMember(levels));
			} catch (e:Dynamic) {
				raised = Std.string(e);
			}
			Assert.isTrue(raised != null && raised.indexOf("32 levels deep") >= 0, (levels + 3) + " levels: " + raised);
		}
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
	 * be reachable, but only when it is genuinely unambiguous.
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

	public function testAFetchedSetRotatesAVerifierInPlace():Void {
		var keys = PkKeyFixture.rsa();
		var modulus = keys == null ? null : PkKeyFixture.rsaModulusBase64Url();
		if (keys == null || modulus == null) {
			Assert.pass();
			return;
		}

		var issuer = JWT.make(RS256(JWKSet.parse('{"keys":[{"kty":"RSA","kid":"next","n":"$modulus","e":"AQAB"}]}').pemsFor("RS256"),
			keys.privatePem, "next"));
		var now:Int = Std.int(Date.now().getTime() / 1000);
		var token = issuer.generateToken({sub: "rotated", iat: now, exp: now + 300});

		// A verifier still holding last period's keys has never heard of "next".
		var verifier = JWT.make(JWKSet.parse('{"keys":[{"kty":"RSA","kid":"previous","n":"$modulus","e":"AQAB"}]}').signer(RS256));
		Assert.equals(JWTRejection.UNKNOWN_KEY, verifier.verify(token).rejection);

		// Which is the cue to fetch the set again.
		verifier.updateKeys(JWKSet.parse('{"keys":[{"kty":"RSA","kid":"previous","n":"$modulus","e":"AQAB"},{"kty":"RSA","kid":"next","n":"$modulus","e":"AQAB"}]}')
			.signer(RS256));
		Assert.isTrue(verifier.verify(token).valid);

		// A set with one unnamed key serves tokens that name none, as a small
		// issuer's do, and not tokens naming a key it does not hold.
		var keyless = JWT.make(JWKSet.parse('{"keys":[{"kty":"RSA","n":"$modulus","e":"AQAB"}]}').signer(RS256));
		var input = JWT.base64UrlEncodeString('{"alg":"RS256","typ":"JWT"}') + "."
			+ JWT.base64UrlEncodeString(haxe.Json.stringify({sub: "x", iat: now, exp: now + 300}));
		var unnamed = input + "." + JWT.base64UrlEncodeBytes(crossbyte.crypto.PublicKeySignature.sign(keys.privatePem, Bytes.ofString(input)));
		Assert.isTrue(keyless.verify(unnamed).valid);
		Assert.equals(JWTRejection.UNKNOWN_KEY, keyless.verify(token).rejection);

		Assert.raises(() -> JWKSet.parse('{"keys":[]}').signer(RS256));
		Assert.raises(() -> JWKSet.parse('{"keys":[{"kty":"RSA","kid":"k","n":"$modulus","e":"AQAB"}]}').signer(HS256));
	}
	#end

	// --- Ed25519 (RFC 8037), and sets written out ---

	/** RFC 8037 A.2: the public half of the example key. */
	private static inline final RFC8037_PUBLIC:String = '{"kty":"OKP","crv":"Ed25519","x":"11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo"}';

	private static inline final RFC8037_PUBLIC_HEX:String = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a";
	private static inline final RFC8037_SEED_HEX:String = "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60";

	public function testTheRfc8037KeyParsesAsAnEd25519Key():Void {
		var set = JWKSet.parse('{"keys":[' + RFC8037_PUBLIC + ']}');
		Assert.equals(1, set.keys.length);
		Assert.equals(0, set.ignored.length);
		var key = set.keys[0];
		Assert.equals("OKP", key.kty);
		Assert.equals("Ed25519", key.crv);
		Assert.isNull(key.kid);
		Assert.equals("EdDSA", key.verificationAlgorithm());
		Assert.equals(RFC8037_PUBLIC_HEX, key.ed25519PublicKey().toHex());
		// No PEM form, and not taken for RS256 or ES256.
		Assert.raises(() -> key.toPem(), crossbyte.errors.ArgumentError);
		Assert.equals(0, Lambda.count(set.pemsFor("RS256")));
		Assert.isNull(set.singlePem("ES256"));

		// The private example (A.1) parses to its public half; `d` is not kept.
		var withPrivate = JWKSet.parse('{"keys":[{"kty":"OKP","crv":"Ed25519","d":"nWGxne_9WmC6hEr0kuwsxERJxWl7MmkZcDusAxyuf2A",'
			+ '"x":"11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo","kid":"a1"}]}');
		Assert.equals('{"kty":"OKP","kid":"a1","crv":"Ed25519","x":"11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo"}', withPrivate.get("a1").toJson());
	}

	public function testOtherOctetKeyPairsAreIgnoredWithAReason():Void {
		var set = JWKSet.parse('{"keys":['
			+ '{"kty":"OKP","kid":"x","crv":"X25519","x":"hSDwCYkwp1R0i33ctD73Wg2_Og0mOBr066SpjqqbTmo"},'
			+ '{"kty":"OKP","kid":"short","crv":"Ed25519","x":"11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHUQ"},'
			+ '{"kty":"OKP","kid":"none","crv":"Ed25519"},'
			+ '{"kty":"OKP","kid":"enc","crv":"Ed25519","use":"enc","x":"11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo"},'
			+ '{"kty":"OKP","kid":"es","crv":"Ed25519","alg":"ES256","x":"11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo"},'
			+ '{"kty":"OKP","kid":"ok","crv":"Ed25519","x":"11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo"}'
			+ ']}');
		Assert.equals(1, set.keys.length);
		Assert.equals("ok", set.keys[0].kid);
		Assert.equals(5, set.ignored.length);
		Assert.equals("x", set.ignored[0].kid);
		Assert.isTrue(set.ignored[0].reason.indexOf("X25519") >= 0, set.ignored[0].reason);
	}

	public function testOfEd25519WritesTheRfcKeyAndReadsBack():Void {
		var key = JWK.ofEd25519("2026-10", Bytes.ofHex(RFC8037_PUBLIC_HEX));
		Assert.equals('{"kty":"OKP","kid":"2026-10","use":"sig","alg":"EdDSA","crv":"Ed25519","x":"11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo"}',
			key.toJson());
		Assert.equals("EdDSA", key.verificationAlgorithm());

		var unnamed = JWK.ofEd25519(null, Bytes.ofHex(RFC8037_PUBLIC_HEX));
		Assert.equals('{"kty":"OKP","use":"sig","alg":"EdDSA","crv":"Ed25519","x":"11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo"}', unnamed.toJson());

		// The key is copied in and out.
		var raw = Bytes.ofHex(RFC8037_PUBLIC_HEX);
		var copied = JWK.ofEd25519("c", raw);
		raw.set(0, 0);
		copied.ed25519PublicKey().set(1, 0);
		Assert.equals(RFC8037_PUBLIC_HEX, copied.ed25519PublicKey().toHex());

		Assert.raises(() -> JWK.ofEd25519("k", Bytes.alloc(31)), crossbyte.errors.ArgumentError);
		Assert.raises(() -> JWK.ofEd25519("k", null), crossbyte.errors.ArgumentError);
		Assert.raises(() -> JWK.ofEd25519("", Bytes.ofHex(RFC8037_PUBLIC_HEX)), crossbyte.errors.ArgumentError);
		var rsa = JWKSet.parse('{"keys":[{"kty":"RSA","kid":"r","n":"' + __sampleModulus() + '","e":"AQAB"}]}').keys[0];
		Assert.raises(() -> rsa.ed25519PublicKey(), crossbyte.errors.ArgumentError);
	}

	public function testASetWrittenOutParsesBackTheSame():Void {
		var source = JWKSet.parse('{"keys":[
			{"kty":"RSA","kid":"r","use":"sig","alg":"RS256","n":"' + __sampleModulus() + '","e":"AQAB","x5c":["ignored"]},
			{"kty":"EC","kid":"e","crv":"P-256","x":"' + __sampleCoordinate() + '","y":"' + __sampleCoordinate(true) + '"},
			{"kty":"OKP","kid":"o","crv":"Ed25519","x":"11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo"}
		]}');
		var written = JWKSet.ofKeys(source.keys).toJson();
		Assert.equals('{"keys":[{"kty":"RSA","kid":"r","use":"sig","alg":"RS256","n":"' + __sampleModulus() + '","e":"AQAB"},'
			+ '{"kty":"EC","kid":"e","crv":"P-256","x":"' + __sampleCoordinate() + '","y":"' + __sampleCoordinate(true) + '"},'
			+ '{"kty":"OKP","kid":"o","crv":"Ed25519","x":"11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo"}]}', written);
		Assert.equals(written, source.toJson());

		var back = JWKSet.parse(written);
		Assert.equals(0, back.ignored.length);
		Assert.equals("r,e,o", back.kids().join(","));
		Assert.equals(source.get("r").toPem(), back.get("r").toPem());
		Assert.equals(source.get("e").toPem(), back.get("e").toPem());
		Assert.equals(RFC8037_PUBLIC_HEX, back.get("o").ed25519PublicKey().toHex());

		// A kid with characters JSON escapes, and one PHP's encoder would.
		var odd = JWKSet.ofKeys([JWK.ofEd25519('a/b"c\\d', Bytes.ofHex(RFC8037_PUBLIC_HEX))]).toJson();
		Assert.isTrue(odd.indexOf('"kid":"a/b\\"c\\\\d"') >= 0, odd);
		Assert.equals('a/b"c\\d', JWKSet.parse(odd).kids()[0]);

		Assert.equals('{"keys":[]}', JWKSet.ofKeys([]).toJson());
	}

	public function testOfKeysRefusesWhatWouldBeAmbiguous():Void {
		var key = Bytes.ofHex(RFC8037_PUBLIC_HEX);
		Assert.raises(() -> JWKSet.ofKeys([JWK.ofEd25519("same", key), JWK.ofEd25519("same", key)]), crossbyte.errors.ArgumentError);
		Assert.raises(() -> JWKSet.ofKeys([JWK.ofEd25519("a", key), null]), crossbyte.errors.ArgumentError);
		Assert.raises(() -> JWKSet.ofKeys(null), crossbyte.errors.ArgumentError);
		// Unnamed keys do not collide with one another here; signer says when they leave a token ambiguous.
		Assert.equals(2, JWKSet.ofKeys([JWK.ofEd25519(null, key), JWK.ofEd25519(null, key)]).keys.length);
	}

	public function testAnEdDSASignerIsMadeFromTheSet():Void {
		var key = Bytes.ofHex(RFC8037_PUBLIC_HEX);
		switch (JWKSet.ofKeys([JWK.ofEd25519("a", key), JWK.ofEd25519("b", key)]).signer(EdDSA)) {
			case EdDSA(keys, privKey, signKeyId):
				Assert.equals(2, Lambda.count(keys));
				Assert.isTrue(keys.exists("a") && keys.exists("b"));
				Assert.equals(RFC8037_PUBLIC_HEX, keys.get("a").toHex());
				Assert.isNull(privKey);
				Assert.isNull(signKeyId);
			default:
				Assert.fail("not an EdDSA signer");
		}
		switch (JWKSet.parse('{"keys":[' + RFC8037_PUBLIC + ']}').signer(EdDSA)) {
			case EdDSA(keys, _, _):
				Assert.equals(RFC8037_PUBLIC_HEX, keys.get("default").toHex());
			default:
				Assert.fail("not an EdDSA signer");
		}
		var rsaOnly = JWKSet.parse('{"keys":[{"kty":"RSA","kid":"r","n":"' + __sampleModulus() + '","e":"AQAB"}]}');
		Assert.raises(() -> rsaOnly.signer(EdDSA), crossbyte.errors.ArgumentError);
		Assert.raises(() -> JWKSet.ofKeys([JWK.ofEd25519(null, key), JWK.ofEd25519(null, key)]).signer(EdDSA), crossbyte.errors.ArgumentError);
		// The EdDSA keys stay out of the RSA signer.
		var mixed = JWKSet.parse('{"keys":[{"kty":"RSA","kid":"r","n":"' + __sampleModulus() + '","e":"AQAB"},' + RFC8037_PUBLIC + ']}');
		switch (mixed.signer(RS256)) {
			case RS256(pems, _, _):
				Assert.equals(1, Lambda.count(pems));
			default:
				Assert.fail("not an RS256 signer");
		}
	}

	/**
	 * The point of publishing: a token an issuer signs verifies at a service
	 * that holds only the set, and stops verifying when its key leaves it.
	 */
	public function testATokenVerifiesThroughAPublishedEd25519Set():Void {
		#if !(cpp || php)
		Assert.pass();
		#else
		var current = crossbyte.crypto.Ed25519.keypairFromSeed(Bytes.ofHex(RFC8037_SEED_HEX));
		var next = crossbyte.crypto.Ed25519.keypair();
		var signing = new haxe.ds.StringMap<Bytes>();
		signing.set("2026-10", current.publicKey);
		var issuer = JWT.make(EdDSA(signing, current.secretKey, "2026-10"));
		var now:Int = Std.int(Date.now().getTime() / 1000);
		var token = issuer.generateToken({sub: "player-7", iat: now, exp: now + 300});

		var published:String = JWKSet.ofKeys([JWK.ofEd25519("2026-10", current.publicKey), JWK.ofEd25519("2026-11", next.publicKey)]).toJson();
		var verifier = JWT.make(JWKSet.parse(published).signer(EdDSA));
		var result = verifier.verify(token);
		Assert.isTrue(result.valid, Std.string(result.rejection));
		Assert.equals("player-7", result.payload.subject);

		// The retired key is dropped from the set: its tokens no longer verify.
		verifier.updateKeys(JWKSet.parse(JWKSet.ofKeys([JWK.ofEd25519("2026-11", next.publicKey)]).toJson()).signer(EdDSA));
		Assert.equals(JWTRejection.UNKNOWN_KEY, verifier.verify(token).rejection);

		// A verify-only signer cannot mint.
		Assert.raises(() -> verifier.generateToken({sub: "forged", exp: now + 300}), crossbyte.errors.IllegalOperationError);
		#end
	}

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
