package crossbyte.auth.jwt;

import haxe.crypto.Hmac;
import haxe.io.Bytes;
import utest.Assert;

/**
	`JWT.expectedIssuers`, `JWT.requireIssuedAt` and `JWT.verifySignature`:
	the checks a game server made by hand on the tokens it takes from its own
	issuer and from an account service. HS256 only, so this runs on every
	target, PHP included. Times are fixed: every token is judged at `NOW`.
**/
class JWTOptionsTest extends utest.Test {
	static inline final SECRET:String = "0123456789abcdef0123456789abcdef";
	static inline final HEADER:String = '{"alg":"HS256","typ":"JWT"}';
	static inline final NOW:Float = 1800000000.0;
	static inline final GAME:String = "https://game.example";
	static inline final ACCOUNTS:String = "https://accounts.example";

	public function testAnyOfTheExpectedIssuersIsAccepted():Void {
		var jwt:JWT = JWT.make(HS256([{secret: SECRET}]), null, null, 5);
		jwt.expectedIssuers = [GAME, ACCOUNTS];
		Assert.isTrue(jwt.verify(forge(claims({iss: GAME})), NOW).valid);
		Assert.isTrue(jwt.verify(forge(claims({iss: ACCOUNTS})), NOW).valid);
		refused(jwt, claims({iss: "https://elsewhere.example"}), WRONG_ISSUER);
		// Compared exactly: no trimming, no case folding, no trailing slash.
		refused(jwt, claims({iss: GAME + "/"}), WRONG_ISSUER);
		refused(jwt, claims({iss: "HTTPS://game.example"}), WRONG_ISSUER);
		refused(jwt, claims({iss: " " + GAME}), WRONG_ISSUER);
		// A token naming no issuer is refused once issuers are expected.
		refused(jwt, claims({iss: null}), WRONG_ISSUER);
		// One that is not a string is malformed, as before.
		refused(jwt, claims({iss: 7}), MALFORMED);
	}

	public function testExpectedIssuerAndTheListAddUp():Void {
		var jwt:JWT = JWT.make(HS256([{secret: SECRET}]), GAME, null, 5);
		refused(jwt, claims({iss: ACCOUNTS}), WRONG_ISSUER);
		jwt.expectedIssuers = [ACCOUNTS];
		Assert.isTrue(jwt.verify(forge(claims({iss: GAME})), NOW).valid);
		Assert.isTrue(jwt.verify(forge(claims({iss: ACCOUNTS})), NOW).valid);

		// An empty list and no single issuer accepts none.
		jwt.expectedIssuer = null;
		jwt.expectedIssuers = [];
		refused(jwt, claims({iss: GAME}), WRONG_ISSUER);

		// Neither set leaves iss unchecked.
		jwt.expectedIssuers = null;
		Assert.isTrue(jwt.verify(forge(claims({iss: "https://anyone.example"})), NOW).valid);
		Assert.isTrue(jwt.verify(forge(claims({iss: null})), NOW).valid);

		// A null entry matches nothing, a missing iss included.
		jwt.expectedIssuers = [null, ACCOUNTS];
		refused(jwt, claims({iss: null}), WRONG_ISSUER);
		Assert.isTrue(jwt.verify(forge(claims({iss: ACCOUNTS})), NOW).valid);
	}

	public function testRequireIssuedAtWantsAnIatBeforeTheExpiry():Void {
		var jwt:JWT = JWT.make(HS256([{secret: SECRET}]), GAME, null, 5);
		var noIat:String = claims({iat: null});
		// Off by default: RFC 7519 makes iat optional.
		Assert.isTrue(jwt.verify(forge(noIat), NOW).valid);
		// Nor is exp after iat asked for.
		Assert.isTrue(jwt.verify(forge(claims({iat: NOW, exp: NOW})), NOW).valid);

		jwt.requireIssuedAt = true;
		Assert.isTrue(jwt.verify(forge(claims()), NOW).valid);
		refused(jwt, noIat, MISSING_ISSUED_AT);
		refused(jwt, claims({iat: NOW + 60, exp: NOW + 60}), EXPIRY_NOT_AFTER_ISSUE);
		refused(jwt, claims({iat: NOW + 61, exp: NOW + 60}), EXPIRY_NOT_AFTER_ISSUE);
		// Stamped in milliseconds: iat after exp, refused for its times
		// rather than read as tens of thousands of years ahead.
		refused(jwt, claims({iat: NOW * 1000, exp: NOW + 600}), EXPIRY_NOT_AFTER_ISSUE);
		// Checked before the clock: an expired token without iat says so.
		refused(jwt, claims({iat: null, exp: NOW - 3600}), MISSING_ISSUED_AT);
		// A missing exp is still that.
		refused(jwt, claims({exp: null}), MISSING_EXPIRY);
		// And the clock still applies after.
		refused(jwt, claims({iat: NOW - 7200, exp: NOW - 3600}), EXPIRED);
		refused(jwt, claims({iat: NOW + 600, exp: NOW + 1200}), ISSUED_IN_FUTURE);
		// Within the leeway is in time.
		Assert.isTrue(jwt.verify(forge(claims({iat: NOW + 5, exp: NOW + 600})), NOW).valid);
		// Not a number is malformed, as before.
		refused(jwt, claims({iat: "yesterday"}), MALFORMED);
	}

	public function testVerifySignatureChecksEverythingButTheTimes():Void {
		var jwt:JWT = JWT.make(HS256([{secret: SECRET}]), GAME, null, 0);
		jwt.requireIssuedAt = true;

		// Long expired, not yet valid, issued in the future, no iat, no exp:
		// all accepted by their signature, which a caller judging the times
		// itself (revoking a token until it would have expired) needs.
		var cases:Array<Dynamic> = [
			{iat: NOW - 7200, exp: NOW - 3600},
			{iat: NOW, exp: NOW + 600, nbf: NOW + 300},
			{iat: NOW + 3600, exp: NOW + 7200},
			{iat: null, exp: NOW + 600},
			{iat: NOW, exp: null},
			{iat: NOW + 60, exp: NOW}
		];
		for (times in cases) {
			var result:JWTVerification = jwt.verifySignature(forge(claims(times)));
			Assert.isTrue(result.valid, Std.string(times) + ": " + result.rejection);
			Assert.equals("user-9", result.payload.subject);
			Assert.isFalse(jwt.verify(forge(claims(times)), NOW).valid, Std.string(times));
		}
		Assert.floatEquals(NOW - 3600, jwt.verifySignature(forge(claims({iat: NOW - 7200, exp: NOW - 3600}))).payload.expiresAt);

		// Everything else is checked as verify checks it.
		var forged:String = forge(claims());
		forged = forged.substr(0, forged.length - 2) + (forged.charAt(forged.length - 2) == "A" ? "BA" : "AA");
		Assert.equals(JWTRejection.BAD_SIGNATURE, jwt.verifySignature(forged).rejection);
		Assert.equals(JWTRejection.WRONG_ISSUER, jwt.verifySignature(forge(claims({iss: ACCOUNTS}))).rejection);
		Assert.equals(JWTRejection.WRONG_AUDIENCE, jwt.verifySignature(forge(claims({aud: "other-api"}))).rejection);
		Assert.equals(JWTRejection.UNKNOWN_KEY, jwt.verifySignature(forgeWith('{"alg":"HS256","typ":"JWT","kid":"retired"}', claims())).rejection);
		Assert.equals(JWTRejection.ALGORITHM_MISMATCH, jwt.verifySignature(forgeWith('{"alg":"RS256","typ":"JWT"}', claims())).rejection);
		Assert.equals(JWTRejection.MALFORMED, jwt.verifySignature("not.a.jwt").rejection);
		Assert.equals(JWTRejection.MALFORMED, jwt.verifySignature(null).rejection);
		// Times that are not numbers are malformed, exp among them.
		Assert.equals(JWTRejection.MALFORMED, jwt.verifySignature(forge(claims({exp: "soon"}))).rejection);
		Assert.equals(JWTRejection.MALFORMED, jwt.verifySignature(forge(claims({iat: "then"}))).rejection);
		Assert.equals(JWTRejection.MALFORMED, jwt.verifySignature(forge(claims({nbf: true}))).rejection);
		Assert.isNull(jwt.verifySignature(forged).payload);
	}

	// --- fixtures ---

	static function refused(jwt:JWT, payload:String, rejection:JWTRejection, ?pos:haxe.PosInfos):Void {
		var result:JWTVerification = jwt.verify(forge(payload), NOW);
		Assert.isFalse(result.valid, pos);
		Assert.isNull(result.payload, pos);
		Assert.equals(rejection, result.rejection, pos);
	}

	/**
		Claims issued at `NOW`, for ten minutes, from `GAME`, with `overrides`
		applied; an override of `null` leaves the claim out.
	**/
	static function claims(?overrides:Dynamic):String {
		var base:Dynamic = {};
		// Whole seconds as Ints, as issuers write them.
		Reflect.setField(base, "sub", "user-9");
		Reflect.setField(base, "iat", Std.int(NOW));
		Reflect.setField(base, "exp", Std.int(NOW) + 600);
		Reflect.setField(base, "iss", GAME);
		if (overrides != null) {
			for (field in Reflect.fields(overrides)) {
				var value:Dynamic = Reflect.field(overrides, field);
				if (value == null) {
					Reflect.deleteField(base, field);
				} else {
					Reflect.setField(base, field, value);
				}
			}
		}
		return haxe.Json.stringify(base);
	}

	static function forge(payload:String):String {
		return forgeWith(HEADER, payload);
	}

	static function forgeWith(header:String, payload:String):String {
		var input:String = JWT.base64UrlEncodeString(header) + "." + JWT.base64UrlEncodeString(payload);
		var mac:Bytes = new Hmac(SHA256).make(Bytes.ofString(SECRET), Bytes.ofString(input));
		return input + "." + JWT.base64UrlEncodeBytes(mac);
	}
}
