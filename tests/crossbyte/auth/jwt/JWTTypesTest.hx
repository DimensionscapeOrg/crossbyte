package crossbyte.auth.jwt;

import crossbyte.auth.Secret;
import crossbyte.ds.TypeCheck;
import haxe.crypto.Hmac;
import haxe.io.Bytes;
import utest.Assert;
import crossbyte.test.Require;

/**
 * The types the JWT, auth and crypto values have.
 *
 * A token's times are `Float`, so a time that is not a number does not
 * compile, rather than failing only when the token is made with every read
 * of one testing its type. Its audience is a `JWTAudience`, not a string or
 * an array to be told apart at each use. The secrets, key pairs and header
 * and key records are `@:structInit` classes, which object literals still
 * build.
 */
class JWTTypesTest extends utest.Test {
	static inline final SECRET:String = "0123456789abcdef0123456789abcdef";

	public function testTimesAreFloats():Void {
		// Not a number: refused by the compiler, not only when the token is
		// made. The error is asked about, so a test that fails to compile for
		// some other reason does not pass for this one.
		__refusedFor("Float", TypeCheck.errorOf(JWTPayload.ofData({sub: "a", exp: "tomorrow"})), "a String time compiled");
		__refusedFor("String", TypeCheck.errorOf({
			var data:crossbyte.auth.jwt.JWTPayload.JWTPayloadData = {exp: 1.0};
			var text:String = data.exp;
		}), "a time read as a String compiled");

		// What compiled stays compiling: times all Ints, or all Floats, with
		// claims of an application's own beside them, and nulls.
		var whole:Int = 1700000000;
		var exact:Float = 1700000000.5;
		Assert.isNull(TypeCheck.errorOf(({sub: "a", iat: whole, exp: whole + 60, role: "admin"} : JWTPayload)));
		Assert.isNull(TypeCheck.errorOf(({sub: "a", iat: exact, exp: exact + 60, role: "admin"} : JWTPayload)));
		Assert.isNull(TypeCheck.errorOf(({sub: "a", iat: null, exp: null} : JWTPayload)));
		Assert.isNull(TypeCheck.errorOf(JWTPayload.ofData({sub: "a", iat: whole, exp: whole + 60})));

		// And a decoded token's times read back as Floats, Int-sized or not.
		var jwt:JWT = JWT.make(HS256([{secret: SECRET}]));
		var payload:JWTPayload = jwt.verify(forge('{"sub":"a","iat":1700000000,"exp":2147483647}'), 1700000000.0).payload;
		Require.notNull(payload);
		var expiresAt:Float = payload.expiresAt;
		Assert.equals(2147483707.0, expiresAt + 60);
		Assert.equals(1700000000.0, payload.issuedAt);
	}

	public function testTheAudienceIsOneOrSeveral():Void {
		var one:JWTPayload = {sub: "a", exp: 1.0, aud: "api"};
		var several:JWTPayload = {sub: "a", exp: 1.0, aud: ["api", "billing"]};
		var none:JWTPayload = {sub: "a", exp: 1.0};

		Assert.isTrue(one.audience.contains("api"));
		Assert.isFalse(one.audience.contains("billing"));
		Assert.isTrue(several.audience.contains("billing"));
		Assert.isFalse(several.audience.contains("other"));
		Assert.isFalse(none.audience.contains("api"));
		Assert.isFalse(one.audience.contains(null));

		Assert.same(["api"], one.audience.toArray());
		Assert.same(["api", "billing"], several.audience.toArray());
		Assert.same([], none.audience.toArray());

		// Set from either shape.
		none.audience = "api";
		Assert.isTrue(none.audience.contains("api"));
		none.audience = ["x", "y"];
		Assert.same(["x", "y"], none.audience.toArray());

		// A token's array can hold anything JSON can; only strings count.
		var jwt:JWT = JWT.make(HS256([{secret: SECRET}]), null, "api");
		var mixed:JWTPayload = jwt.verify(forge('{"sub":"a","exp":2147483647,"aud":[7,"api",null]}'), 1700000000.0).payload;
		Require.notNull(mixed);
		Assert.same(["api"], mixed.audience.toArray());
		Assert.isTrue(mixed.audience.contains("api"));
	}

	public function testSecondsIsNotPublic():Void {
		__refusedFor("private", TypeCheck.errorOf(JWTPayload.seconds(1)), "JWTPayload.seconds is callable");
	}

	/** That `error` is a compile error, and the one expected: it names `expected`. **/
	static function __refusedFor(expected:String, error:Null<String>, message:String, ?pos:haxe.PosInfos):Void {
		Assert.isTrue(error != null && error.indexOf(expected) >= 0, '$message (error: $error)', pos);
	}

	public function testTheRecordsAreClasses():Void {
		Assert.isNull(TypeCheck.errorOf(Std.isOfType(null, crossbyte.auth.Secret)), "Secret is not a class");
		Assert.isNull(TypeCheck.errorOf(Std.isOfType(null, crossbyte.auth.jwt.JWTHeader.JWTHeaderData)), "JWTHeaderData is not a class");
		Assert.isNull(TypeCheck.errorOf(Std.isOfType(null, crossbyte.auth.jwt.JWKSet.IgnoredKey)), "IgnoredKey is not a class");
		Assert.isNull(TypeCheck.errorOf(Std.isOfType(null, crossbyte.crypto.SigningKeyPair)), "SigningKeyPair is not a class");
		Assert.isNull(TypeCheck.errorOf(Std.isOfType(null, crossbyte.crypto.KeyExchange.KeyExchangeKeyPair)), "KeyExchangeKeyPair is not a class");
		Assert.isNull(TypeCheck.errorOf(Std.isOfType(null, crossbyte.crypto.KeyExchange.SessionKeys)), "SessionKeys is not a class");

		// Literals build them, leaving out what is optional.
		var keyed:Secret = {key: "kid-1", secret: "a"};
		var plain:Secret = {secret: "b"};
		Assert.equals("kid-1", keyed.key);
		Assert.isNull(plain.key);
		var header:JWTHeader = {alg: HS256};
		Assert.equals("HS256", header.algorithm);
		Assert.isNull(header.type);
		Assert.isNull(header.keyId);
		Assert.isNull(header.contentType);

		// And the key set's report of what it could not use is one.
		var set:JWKSet = JWKSet.parse('{"keys":[{"kid":"k","kty":"oct"}]}');
		Assert.equals(1, set.ignored.length);
		Assert.equals("k", set.ignored[0].kid);
		Assert.isTrue(set.ignored[0].reason.indexOf("oct") >= 0);
	}

	/** A token with exactly these claims under a JWT header, signed with the secret. */
	static function forge(payload:String):String {
		var input:String = JWT.base64UrlEncodeString('{"alg":"HS256","typ":"JWT"}') + "." + JWT.base64UrlEncodeString(payload);
		var mac:Bytes = new Hmac(SHA256).make(Bytes.ofString(SECRET), Bytes.ofString(input));
		return input + "." + JWT.base64UrlEncodeBytes(mac);
	}
}
