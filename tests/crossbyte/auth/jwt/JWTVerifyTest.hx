package crossbyte.auth.jwt;

import haxe.crypto.Hmac;
import haxe.io.Bytes;
import utest.Assert;
import crossbyte.test.Require;

/**
 * `JWT.verify`: tokens from issuers that are not CrossByte, and saying why a
 * token was refused.
 *
 * verifyToken refused any token whose `typ` was not exactly `JWT` -- so AWS
 * Cognito's and Sign in with Apple's tokens, which carry none, RFC 9068 access
 * tokens (`at+jwt`) and a lower-case `jwt` all failed -- and it answered every
 * refusal, expired or forged alike, with the same null. HS256 only, so this
 * runs on every target.
 */
class JWTVerifyTest extends utest.Test {
	static inline final SECRET:String = "0123456789abcdef0123456789abcdef";
	static inline final ISSUER:String = "https://auth.example";

	public function testTokensFromOtherIssuersVerify():Void {
		var jwt:JWT = JWT.make(HS256([{secret: SECRET}]), ISSUER, "api");

		for (header in [
			'{"alg":"HS256"}', // Cognito, Sign in with Apple: no typ
			'{"alg":"HS256","typ":"at+jwt"}', // RFC 9068 access token
			'{"alg":"HS256","typ":"jwt"}',
			'{"alg":"HS256","typ":"application/jwt"}',
			'{"alg":"HS256","typ":"AT+JWT"}',
			'{"alg":"HS256","typ":"JWT"}'
		]) {
			var payload = jwt.verifyToken(forge(header, claims()));
			Assert.notNull(payload, header);
		}
	}

	public function testTheTypeAllowListStillRefusesOtherKinds():Void {
		var jwt:JWT = JWT.make(HS256([{secret: SECRET}]), ISSUER, "api");
		Assert.equals(JWTRejection.TYPE_NOT_ACCEPTED, jwt.verify(forge('{"alg":"HS256","typ":"JOSE"}', claims())).rejection);
		Assert.equals(JWTRejection.TYPE_NOT_ACCEPTED, jwt.verify(forge('{"alg":"HS256","typ":"dpop+jwt"}', claims())).rejection);

		// An API taking access tokens only: an ID token from the same issuer,
		// signed by the same key, must not pass.
		jwt.acceptedTypes = ["at+jwt"];
		Assert.isTrue(jwt.verify(forge('{"alg":"HS256","typ":"at+jwt"}', claims())).valid);
		Assert.equals(JWTRejection.TYPE_NOT_ACCEPTED, jwt.verify(forge('{"alg":"HS256","typ":"JWT"}', claims())).rejection);

		jwt.requireType = true;
		Assert.equals(JWTRejection.TYPE_NOT_ACCEPTED, jwt.verify(forge('{"alg":"HS256"}', claims())).rejection);

		jwt.acceptedTypes = null;
		Assert.isTrue(jwt.verify(forge('{"alg":"HS256","typ":"anything"}', claims())).valid);
		Assert.equals(JWTRejection.MALFORMED, jwt.verify(forge('{"alg":"HS256","typ":7}', claims())).rejection);
	}

	public function testVerifySaysWhyATokenWasRefused():Void {
		var jwt:JWT = JWT.make(HS256([{secret: SECRET}]), ISSUER, "api", 0);
		var now:Int = Std.int(Date.now().getTime() / 1000);
		var header:String = '{"alg":"HS256","typ":"JWT"}';

		var good:JWTVerification = jwt.verify(forge(header, claims()));
		Assert.isTrue(good.valid);
		Assert.isNull(good.rejection);
		Require.notNull(good.payload);
		Assert.equals("user-9", good.payload.subject);

		var forged:String = forge(header, claims());
		forged = forged.substr(0, forged.length - 2) + (forged.charAt(forged.length - 2) == "A" ? "BA" : "AA");
		expectRefused(jwt, forged, BAD_SIGNATURE);
		expectRefused(jwt, forge(header, claims({exp: now - 10})), EXPIRED);
		expectRefused(jwt, forge(header, claims({nbf: now + 600})), NOT_YET_VALID);
		expectRefused(jwt, forge(header, claims({iat: now + 600})), ISSUED_IN_FUTURE);
		expectRefused(jwt, forge(header, '{"sub":"user-9","iss":"$ISSUER","aud":"api"}'), MISSING_EXPIRY);
		expectRefused(jwt, forge(header, claims({iss: "https://elsewhere.example"})), WRONG_ISSUER);
		expectRefused(jwt, forge(header, claims({aud: "other-api"})), WRONG_AUDIENCE);
		expectRefused(jwt, forge('{"alg":"none","typ":"JWT"}', claims()), UNSUPPORTED_ALGORITHM);
		// Named by JWTAlgorithm once, and never signed or verified by anything.
		expectRefused(jwt, forge('{"alg":"HS384","typ":"JWT"}', claims()), UNSUPPORTED_ALGORITHM);
		expectRefused(jwt, forge('{"alg":"HS512","typ":"JWT"}', claims()), UNSUPPORTED_ALGORITHM);
		expectRefused(jwt, forge('{"alg":"RS256","typ":"JWT"}', claims()), ALGORITHM_MISMATCH);
		expectRefused(jwt, forge('{"alg":"HS256","typ":"JWT","kid":"retired"}', claims()), UNKNOWN_KEY);
		expectRefused(jwt, forge('{"alg":"HS256","typ":"JWT","kid":7}', claims()), MALFORMED);
		expectRefused(jwt, forge('[1,2]', claims()), MALFORMED);
		expectRefused(jwt, forge(header, '"a string"'), MALFORMED);
		expectRefused(jwt, "not.a.jwt", MALFORMED);
		expectRefused(jwt, "one.two", MALFORMED);
		expectRefused(jwt, "", MALFORMED);
		expectRefused(jwt, null, MALFORMED);
		expectRefused(jwt, StringTools.lpad("", "a", 4097), TOO_LARGE);

		// verifyToken is the same check, answering null.
		Assert.isNull(jwt.verifyToken(forge(header, claims({exp: now - 10}))));
	}

	public function testTheSizeCapIsConfigurable():Void {
		var jwt:JWT = JWT.make(HS256([{secret: SECRET}]), ISSUER, "api");
		var bulky:String = forge('{"alg":"HS256","typ":"JWT"}', claims({groups: StringTools.lpad("", "g", 5000)}));
		Assert.isTrue(bulky.length > 4096);

		Assert.equals(JWTRejection.TOO_LARGE, jwt.verify(bulky).rejection);
		jwt.maxTokenLength = 16384;
		Assert.isTrue(jwt.verify(bulky).valid);
	}

	/**
		A header or claims nested deeper than any real token are refused before
		they are parsed.

		JSON is parsed a frame per level, and the header is parsed before the
		signature is checked, so this needed no key. Natively a 16 KB token --
		within a raised `maxTokenLength`, which the doc suggests for tokens
		with many claims -- nested 6,000 deep overflowed the stack and ended
		the process, on the runtime's thread and on a worker alike.
	**/
	public function testDeeplyNestedJsonIsRefusedBeforeItIsParsed():Void {
		var jwt:JWT = JWT.make(HS256([{secret: SECRET}]), ISSUER, "api");
		jwt.maxTokenLength = 16384;
		var deep:String = StringTools.lpad("", "[", 6000) + StringTools.lpad("", "]", 6000);

		expectRefused(jwt, forge('{"alg":"HS256","typ":"JWT","x":$deep}', claims()), MALFORMED);
		expectRefused(jwt, forge('{"alg":"HS256","typ":"JWT"}', withClaim(claims(), '"x":$deep')), MALFORMED);
		// Inside strings brackets are only text.
		var bracketed:String = StringTools.lpad("", "[", 100);
		Assert.isTrue(jwt.verify(forge('{"alg":"HS256","typ":"JWT"}', withClaim(claims(), '"note":"$bracketed"'))).valid);

		// What real tokens carry nests a few levels, and passes.
		var roles:String = '"realm_access":{"roles":["a"]},"resource_access":{"client":{"roles":["b",["c",{"d":[1]}]]}}';
		Assert.isTrue(jwt.verify(forge('{"alg":"HS256","typ":"JWT"}', withClaim(claims(), roles))).valid);
	}

	/**
		A token whose `crit` header names extensions is refused: they are ones
		it must not be accepted without, this verifier implements none, and RFC
		7515 makes such a token invalid for it. `"b64":false` (RFC 7797) is
		one: the payload travels unencoded, and was taken as though it were
		base64url. A header member nobody marked critical is still ignored.
	**/
	public function testATokenNamingCriticalExtensionsIsRefused():Void {
		var jwt:JWT = JWT.make(HS256([{secret: SECRET}]), ISSUER, "api");
		expectRefused(jwt, forge('{"alg":"HS256","typ":"JWT","b64":false,"crit":["b64"]}', claims()), UNSUPPORTED_CRITICAL);
		expectRefused(jwt, forge('{"alg":"HS256","typ":"JWT","exp":1,"crit":["exp"]}', claims()), UNSUPPORTED_CRITICAL);
		expectRefused(jwt, forge('{"alg":"HS256","typ":"JWT","crit":[]}', claims()), UNSUPPORTED_CRITICAL);
		expectRefused(jwt, forge('{"alg":"HS256","typ":"JWT","crit":"b64"}', claims()), UNSUPPORTED_CRITICAL);

		Assert.isTrue(jwt.verify(forge('{"alg":"HS256","typ":"JWT","x5t":"abc","custom":1}', claims())).valid);
	}

	/**
		A token naming an audience is refused by a verifier that names none.

		RFC 7519 4.1.3: a recipient that does not identify itself with a value
		in a token's `aud` must reject it. A verifier with no `expectedAudience`
		accepted a token minted for any other service the issuer and key
		serve -- the token another service was given, replayed here.
	**/
	public function testATokenForSomeAudienceIsRefusedWhereNoneIsExpected():Void {
		var jwt:JWT = JWT.make(HS256([{secret: SECRET}]), ISSUER);
		var header:String = '{"alg":"HS256","typ":"JWT"}';
		expectRefused(jwt, forge(header, claims({aud: "another-service"})), WRONG_AUDIENCE);
		expectRefused(jwt, forge(header, claims({aud: ["another-service", "a-third"]})), WRONG_AUDIENCE);

		// A token naming none passes, as before.
		Assert.isTrue(jwt.verify(forge(header, claims({aud: null}))).valid);

		// And one naming this verifier passes once it says which it is.
		jwt.expectedAudience = "another-service";
		Assert.isTrue(jwt.verify(forge(header, claims({aud: ["another-service", "a-third"]}))).valid);
		expectRefused(jwt, forge(header, claims({aud: null})), WRONG_AUDIENCE);
	}

	public function testKeysRotateWithoutRebuildingTheVerifier():Void {
		var jwt:JWT = JWT.make(HS256([{secret: "old-secret-old-secret-old-secret-01"}]), ISSUER, "api", 0);
		jwt.acceptedTypes = ["JWT"];
		var now:Int = Std.int(Date.now().getTime() / 1000);
		var before:String = jwt.generateToken({sub: "user-1", iat: now, exp: now + 600, iss: ISSUER, aud: "api"});

		// The old single secret signed as "default"; it stays under that name
		// until its tokens have expired.
		jwt.updateKeys(HS256([
			{key: "default", secret: "old-secret-old-secret-old-secret-01"},
			{key: "2026-09", secret: "new-secret-new-secret-new-secret-02"}
		], "2026-09"));

		Assert.isTrue(jwt.verify(before).valid, "a token from before the rotation");
		var after:String = jwt.generateToken({sub: "user-2", iat: now, exp: now + 600, iss: ISSUER, aud: "api"});
		Assert.isTrue(jwt.verify(after).valid, "a token from after it");
		// Every other setting survives the swap.
		Assert.equals(ISSUER, jwt.expectedIssuer);
		Assert.same(["JWT"], jwt.acceptedTypes);

		// An invalid set throws and leaves the keys in place.
		Assert.raises(() -> jwt.updateKeys(HS256([])));
		Assert.isTrue(jwt.verify(after).valid);

		// Retiring the old key: its tokens name a key no longer held.
		jwt.updateKeys(HS256([{key: "2026-09", secret: "new-secret-new-secret-new-secret-02"}], "2026-09"));
		Assert.equals(JWTRejection.UNKNOWN_KEY, jwt.verify(before).rejection);
		Assert.isTrue(jwt.verify(after).valid);
	}

	static function expectRefused(jwt:JWT, token:String, rejection:JWTRejection, ?pos:haxe.PosInfos):Void {
		var result:JWTVerification = jwt.verify(token);
		Assert.isFalse(result.valid, pos);
		Assert.isNull(result.payload, pos);
		Assert.equals(rejection, result.rejection, pos);
	}

	/** Claims valid for ten minutes from now, with `overrides` applied. */
	static function claims(?overrides:Dynamic):String {
		var now:Int = Std.int(Date.now().getTime() / 1000);
		var base:Dynamic = {sub: "user-9", iat: now, exp: now + 600, iss: ISSUER, aud: "api"};
		if (overrides != null) {
			for (field in Reflect.fields(overrides)) {
				Reflect.setField(base, field, Reflect.field(overrides, field));
			}
		}
		return haxe.Json.stringify(base);
	}

	/** `json`, an object, with `member` -- raw JSON, `"name":value` -- added at its end. */
	static function withClaim(json:String, member:String):String {
		return json.substr(0, json.length - 1) + "," + member + "}";
	}

	/** A token with exactly this header and payload, signed with the secret. */
	static function forge(header:String, payload:String):String {
		var input:String = JWT.base64UrlEncodeString(header) + "." + JWT.base64UrlEncodeString(payload);
		var mac:Bytes = new Hmac(SHA256).make(Bytes.ofString(SECRET), Bytes.ofString(input));
		return input + "." + JWT.base64UrlEncodeBytes(mac);
	}
}
