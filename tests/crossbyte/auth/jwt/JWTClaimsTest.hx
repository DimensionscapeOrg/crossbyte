package crossbyte.auth.jwt;

import crossbyte.errors.ArgumentError;
import haxe.crypto.Hmac;
import haxe.io.Bytes;
import utest.Assert;
import crossbyte.test.Require;

/**
 * JWT claims: times as seconds in a `Float`, and claims beyond the registered
 * ones.
 *
 * Times were `Int`. A token expiring at 2147483647 -- a common "never" -- was
 * accepted on cpp and Node and refused on the interpreter and the jvm, where
 * adding the leeway wrapped, and anything after January 2038 was refused on
 * the jvm. A claim of an application's own, `{sub: ..., role: "admin"}`, did
 * not compile: "has extra field role". HS256 only, so this runs everywhere.
 */
class JWTClaimsTest extends utest.Test {
	static inline final SECRET:String = "0123456789abcdef0123456789abcdef";

	public function testLongLivedTokensVerifyAlikeOnEveryTarget():Void {
		var jwt:JWT = JWT.make(HS256([{secret: SECRET}]));
		var now:Float = Date.now().getTime() / 1000;

		// 2038-01-19 02:13, the largest Int, and 2100-01-01.
		for (exp in [2147480000.0, 2147483647.0, 4102444800.0]) {
			var token:String = jwt.generateToken({sub: "svc", iat: now, exp: exp});
			var verified:JWTVerification = jwt.verify(token);
			Assert.isTrue(verified.valid, 'exp $exp: ${verified.rejection}');
			Assert.equals(exp, verified.payload.expiresAt);
		}

		// Judged at the far end of those times, the leeway neither wraps nor
		// goes missing.
		var never:String = forge('{"sub":"svc","exp":2147483647}');
		Assert.isTrue(jwt.verify(never, 2147483647.0 + 59).valid);
		Assert.equals(JWTRejection.EXPIRED, jwt.verify(never, 2147483647.0 + 61).rejection);

		var century:String = forge('{"sub":"svc","exp":4102444800}');
		Assert.isTrue(jwt.verify(century, 4102444800.0 - 1).valid);
		Assert.equals(JWTRejection.EXPIRED, jwt.verify(century, 4102444800.0 + 61).rejection);

		// NumericDate may be fractional.
		var fractional:String = forge('{"sub":"svc","exp":1700000000.5}');
		Assert.isTrue(jwt.verify(fractional, 1700000000.0 + 60).valid);
		Assert.equals(JWTRejection.EXPIRED, jwt.verify(fractional, 1700000000.5 + 60.25).rejection);
		Assert.equals(1700000000.5, jwt.verify(fractional, 1700000000.0).payload.expiresAt);
	}

	public function testWholeSecondsAreWrittenAsIntegers():Void {
		var jwt:JWT = JWT.make(HS256([{secret: SECRET}]));
		var claims = {sub: "svc", iat: 1700000000.0, exp: 1700003600.0};
		var token:String = jwt.generateToken(claims);

		// The same text on every target: the jvm prints a Float as 1.7E9.
		var json:String = JWT.safeBase64UrlDecodeString(token.split(".")[1]);
		Assert.isTrue(json.indexOf('"exp":1700003600') >= 0, json);
		Assert.isTrue(json.indexOf('"iat":1700000000') >= 0, json);
		// The caller's object is left as it was given.
		Assert.isTrue(Std.isOfType(claims.exp, Float));
	}

	public function testATokenCarriesClaimsOfItsOwn():Void {
		var jwt:JWT = JWT.make(HS256([{secret: SECRET}]));
		var now:Int = Std.int(Date.now().getTime() / 1000);

		// Written the obvious way, beside the registered claims.
		var token:String = jwt.generateToken({
			sub: "user-1",
			iat: now,
			exp: now + 60,
			role: "admin",
			groups: ["ops", "billing"],
			level: 3
		});

		var payload:JWTPayload = jwt.verifyToken(token);
		Require.notNull(payload);
		Assert.equals("user-1", payload.subject);
		Assert.equals("admin", payload.claim("role"));
		Assert.same(["ops", "billing"], payload.claim("groups"));
		Assert.equals(3, payload.claim("level"));
		Assert.isTrue(payload.hasClaim("role"));
		Assert.isFalse(payload.hasClaim("scope"));
		Assert.isNull(payload.claim("scope"));

		// A refresh-token shape with no subject, and a claim set afterwards.
		var refresh:JWTPayload = {iat: now, exp: now + 600, jti: "r-1"};
		refresh.setClaim("scope", "refresh");
		var verified:JWTPayload = jwt.verifyToken(jwt.generateToken(refresh));
		Require.notNull(verified);
		Assert.isNull(verified.subject);
		Assert.equals("r-1", verified.tokenId);
		Assert.equals("refresh", verified.claim("scope"));
	}

	public function testTimesAndRegisteredClaimsKeepTheirTypes():Void {
		var jwt:JWT = JWT.make(HS256([{secret: SECRET}]));

		// Made here: a time that is not a number is refused before signing.
		Assert.raises(() -> jwt.generateToken({sub: "a", exp: "tomorrow"}), ArgumentError);
		Assert.raises(() -> jwt.generateToken({sub: "a", exp: 1.0 / 0.0}), ArgumentError);

		// Made elsewhere and signed: refused rather than misread.
		Assert.equals(JWTRejection.MISSING_EXPIRY, jwt.verify(forge('{"sub":"a","exp":"tomorrow"}')).rejection);
		Assert.equals(JWTRejection.MALFORMED, jwt.verify(forge('{"sub":"a","exp":4102444800,"iat":"yesterday"}')).rejection);
		Assert.equals(JWTRejection.MALFORMED, jwt.verify(forge('{"sub":7,"exp":4102444800}')).rejection);
		Assert.equals(JWTRejection.MALFORMED, jwt.verify(forge('{"iss":["a"],"exp":4102444800}')).rejection);
	}

	/** A token with exactly these claims under a JWT header, signed with the secret. */
	static function forge(payload:String):String {
		var input:String = JWT.base64UrlEncodeString('{"alg":"HS256","typ":"JWT"}') + "." + JWT.base64UrlEncodeString(payload);
		var mac:Bytes = new Hmac(SHA256).make(Bytes.ofString(SECRET), Bytes.ofString(input));
		return input + "." + JWT.base64UrlEncodeBytes(mac);
	}
}
