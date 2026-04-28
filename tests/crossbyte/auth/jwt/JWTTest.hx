package crossbyte.auth.jwt;

import utest.Assert;
import haxe.Json;

class JWTTest extends utest.Test {
	public function testGeneratesAndVerifiesHS256Token():Void {
		var jwt = JWT.make(HS256([{secret: "test-secret"}]), "issuer-a", "aud-a", 0);
		var now = Std.int(haxe.Timer.stamp());
		var token = jwt.generateToken({
			sub: "subject",
			name: "Chris",
			iat: now - 5,
			exp: now + 60,
			nbf: now - 5,
			iss: "issuer-a",
			aud: "aud-a",
			jti: "token-1"
		});

		var verified = jwt.verifyToken(token);
		Assert.notNull(verified);
		Assert.equals("subject", verified.subject);
		Assert.equals("Chris", verified.name);
		Assert.equals("issuer-a", verified.issuer);
		Assert.equals("aud-a", verified.audience);
		Assert.equals("token-1", verified.tokenId);
	}

	public function testRejectsTamperedSignatureAndWrongAudienceOrIssuer():Void {
		var now = Std.int(haxe.Timer.stamp());
		var base = JWT.make(HS256([{secret: "test-secret"}]), "issuer-a", "aud-a", 0);
		var token = base.generateToken({
			sub: "subject",
			iat: now - 5,
			exp: now + 60,
			iss: "issuer-a",
			aud: "aud-a"
		});

		var parts = token.split(".");
		var payload:Dynamic = Json.parse(JWT.safeBase64UrlEncodeString(parts[1]));
		payload.sub = "tampered";
		var tamperedPayload = JWT.base64UrlEncodeString(Json.stringify(payload));
		Assert.isNull(base.verifyToken(parts[0] + "." + tamperedPayload + "." + parts[2]));

		var wrongAudience = JWT.make(HS256([{secret: "test-secret"}]), "issuer-a", "aud-b", 0);
		Assert.isNull(wrongAudience.verifyToken(token));

		var wrongIssuer = JWT.make(HS256([{secret: "test-secret"}]), "issuer-b", "aud-a", 0);
		Assert.isNull(wrongIssuer.verifyToken(token));
	}

	public function testAudienceArraysAndLeewayAreSupported():Void {
		var now = Std.int(haxe.Timer.stamp());
		var jwt = JWT.make(HS256([{secret: "test-secret"}]), null, "aud-b", 5);
		var token = jwt.generateToken({
			sub: "subject",
			iat: now + 3,
			exp: now + 1,
			nbf: now + 3,
			aud: ["aud-a", "aud-b"]
		});

		var verified = jwt.verifyToken(token);
		Assert.notNull(verified);
		Assert.equals("subject", verified.subject);
	}

	public function testExpiredOrMalformedTokensAreRejected():Void {
		var jwt = JWT.make(HS256([{secret: "test-secret"}]), null, null, 0);
		var now = Std.int(haxe.Timer.stamp());
		var expired = jwt.generateToken({
			sub: "subject",
			iat: now - 60,
			exp: now - 1
		});

		Assert.isNull(jwt.verifyToken(expired));
		Assert.isNull(jwt.verifyToken(null));
		Assert.isNull(jwt.verifyToken(""));
		Assert.isNull(jwt.verifyToken("not.a.jwt"));
		Assert.isNull(jwt.verifyToken("###.###.###"));
		Assert.isNull(jwt.verifyToken(StringTools.lpad("", "a", 4097)));
	}

	public function testNullTimestampPayloadIsRejected():Void {
		var jwt = JWT.make(HS256([{secret: "test-secret"}]));
		var token = jwt.generateToken({
			sub: "subject",
			iat: null,
			exp: null
		});

		Assert.isNull(jwt.verifyToken(token));
	}

	public function testNullablePayloadTimestampsRoundTrip():Void {
		var payload:JWTPayload = {
			sub: "subject",
			iat: null,
			exp: null
		};

		Assert.isNull(payload.issuedAt);
		Assert.isNull(payload.expiresAt);
	}

	public function testBase64UrlHelpersAndSecureCompareBehaveAsExpected():Void {
		var encoded = JWT.base64UrlEncodeString('{"value":"+/="}');
		Assert.isTrue(encoded.indexOf("+") == -1);
		Assert.isTrue(encoded.indexOf("/") == -1);
		Assert.isTrue(encoded.indexOf("=") == -1);
		Assert.equals('{"value":"+/="}', JWT.safeBase64UrlEncodeString(encoded));
		Assert.isNull(JWT.safeBase64UrlEncodeString("a"));
		Assert.equals("TQ==", JWT.normalizeBase64Url("TQ"));

		Assert.isTrue(JWT.secureCompare("abc", "abc"));
		Assert.isFalse(JWT.secureCompare("abc", "abd"));
		Assert.isFalse(JWT.secureCompare("abc", "ab"));
	}

	public function testHeaderAndSignerValidation():Void {
		var header = JWTHeader.make(HS256, "kid-1");
		Assert.equals("HS256", header.algorithm);
		Assert.equals("JWT", header.type);
		Assert.equals("kid-1", header.keyId);
		Assert.isTrue(header.isValid());

		var nonJwtType = JWTHeader.ofData({alg: HS256, typ: "JOSE"});
		Assert.isFalse(nonJwtType.isValid());

		var noneHeader = JWTHeader.ofData({alg: NONE, typ: "JWT"});
		Assert.isFalse(noneHeader.isValid());

		Assert.isTrue(throwsDynamic(() -> JWT.make(HS256([]))));
		Assert.isTrue(throwsDynamic(() -> JWT.make(HS256([{secret: ""}]))));
		Assert.isTrue(throwsDynamic(() -> JWT.make(HS256([{key: "a", secret: "1"}, {key: "a", secret: "2"}], "a"))));
		Assert.isTrue(throwsDynamic(() -> JWT.make(HS256([{key: "a", secret: "1"}, {key: "b", secret: "2"}]))));
		Assert.isTrue(throwsDynamic(() -> JWT.make(HS256([{key: "a", secret: "1"}], "missing"))));
		Assert.isTrue(throwsDynamic(() -> JWT.make(EdDSA(new haxe.ds.StringMap(), null, null))));
		Assert.isTrue(throwsDynamic(() -> JWT.make(RS256(new haxe.ds.StringMap(), null, null))));
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
