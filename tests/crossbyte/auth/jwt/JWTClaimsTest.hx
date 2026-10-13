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
 * As `Int` times, a token expiring at 2147483647 (a common "never") would be
 * accepted on cpp and Node and refused on the interpreter and the jvm, where
 * adding the leeway wraps, and anything after January 2038 would be refused
 * on the jvm. A claim of an application's own, `{sub: ..., role: "admin"}`,
 * compiles. HS256 only, so this runs everywhere.
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

	/**
		A null name has no claim: `claim` reads null, `hasClaim` is false and
		`setClaim` throws an `ArgumentError`, on every target. Natively each
		ended the process; eval and Neko threw a null access, HashLink did
		from `setClaim`, and on Node `setClaim` set a claim named "null".
	**/
	public function testANullClaimNameHasNoClaim():Void {
		var payload:JWTPayload = {sub: "a", exp: 2000000000.0};
		var name:Null<String> = null;
		Assert.isNull(payload.claim(name), "a null name read a claim");
		Assert.isFalse(payload.hasClaim(name), "a null name was a claim");
		Assert.raises(() -> payload.setClaim(name, 1), ArgumentError);
		Assert.isFalse(payload.hasClaim("null"), "a claim named null was set");
		Assert.equals("a", payload.subject);
	}

	public function testTimesAndRegisteredClaimsKeepTheirTypes():Void {
		var jwt:JWT = JWT.make(HS256([{secret: SECRET}]));

		// Made here: a time that is not a number is refused before signing:
		// by the compiler when it is written in a literal (JWTTypesTest), and
		// here when it is built by name. Field by field rather than a literal:
		// the jvm types a literal's fields, and refuses the string in a Float.
		var named:Dynamic = {};
		Reflect.setField(named, "sub", "a");
		Reflect.setField(named, "exp", "tomorrow");
		Assert.raises(() -> jwt.generateToken(JWTPayload.ofData(named)), ArgumentError);
		Assert.raises(() -> jwt.generateToken({sub: "a", exp: 1.0 / 0.0}), ArgumentError);

		// Made elsewhere and signed: refused rather than misread.
		Assert.equals(JWTRejection.MISSING_EXPIRY, jwt.verify(forge('{"sub":"a","exp":"tomorrow"}')).rejection);
		Assert.equals(JWTRejection.MALFORMED, jwt.verify(forge('{"sub":"a","exp":4102444800,"iat":"yesterday"}')).rejection);
		Assert.equals(JWTRejection.MALFORMED, jwt.verify(forge('{"sub":7,"exp":4102444800}')).rejection);
		Assert.equals(JWTRejection.MALFORMED, jwt.verify(forge('{"iss":["a"],"exp":4102444800}')).rejection);
	}

	/**
		A time given to `verify` or `verifyToken` allocates nothing: with one,
		from a local, a field or a call, a verification allocates what one
		without a time does. Each took an optional `Float`, which natively and
		on the jvm is boxed on its way in, once per token (24 bytes natively);
		and without a time the wall clock was read through a `Date`. Measured
		on a token refused at its claims, before any time is read, and on one
		that verifies.
	**/
	public function testATimeGivenToVerifyAllocatesNothing():Void {
		#if (cpp || jvm)
		var jwt:JWT = JWT.make(HS256([{secret: SECRET}]));
		__verifyTime = Date.now().getTime() / 1000;
		var sink:Int = 0;
		for (token in [forge('{"sub":7,"exp":4102444800}'), forge('{"sub":"a","exp":4102444800}')]) {
			var local:Float = __verifyTime;
			var forms:Array<{name:String, op:Void->Void}> = [
				{name: "no time", op: () -> sink += jwt.verify(token).valid ? 1 : 0},
				{name: "a local", op: () -> sink += jwt.verify(token, local).valid ? 1 : 0},
				{name: "a field", op: () -> sink += jwt.verify(token, __verifyTime).valid ? 1 : 0},
				{name: "a call", op: () -> sink += jwt.verify(token, __verifyClock()).valid ? 1 : 0},
				{name: "verifyToken, a field", op: () -> sink += jwt.verifyToken(token, __verifyTime) != null ? 1 : 0}
			];
			var without:Null<Float> = null;
			for (form in forms) {
				for (_ in 0...5000) {
					form.op();
				}
				var reading = crossbyte.test.AllocationMeter.measure(form.op, 2000, 3);
				if (Sys.getEnv("CB_ALLOC_REPORT") != null) {
					Sys.println("[ALLOC] " + crossbyte.test.AllocationMeter.platform() + " JWT.verify given " + form.name + ": " + reading);
				}
				if (without == null) {
					without = reading.perOperation;
				} else {
					// A boxed time is 16 bytes or more; the readings are averages,
					// which in a full suite can differ by a fraction of a byte.
					Assert.isTrue(Math.abs(reading.perOperation - without) < 8,
						'verify given ${form.name} allocated ${reading} where it allocated $without bytes without a time');
				}
			}
		}
		Assert.isTrue(sink > 0);
		#else
		Assert.pass();
		#end
	}

	static var __verifyTime:Float = 0;

	static function __verifyClock():Float {
		return __verifyTime;
	}

	/** A time of NaN, by which no token would be expired, is refused rather than taken. **/
	public function testATimeOfNaNIsRefused():Void {
		var jwt:JWT = JWT.make(HS256([{secret: SECRET}]));
		var expired:String = forge('{"sub":"a","exp":1000}');
		Assert.raises(() -> jwt.verify(expired, Math.NaN), ArgumentError);
		Assert.raises(() -> jwt.verifyToken(expired, Math.NaN), ArgumentError);
		Assert.equals(JWTRejection.EXPIRED, jwt.verify(expired).rejection);
		Assert.isNull(jwt.verifyToken(expired));
		#if !static
		// Where a Float can be null, null is still the wall clock, as the
		// optional time was: not a time by which nothing has expired.
		Assert.equals(JWTRejection.EXPIRED, jwt.verify(expired, null).rejection);
		Assert.isNull(jwt.verifyToken(expired, null));
		#end
	}

	/** A token with exactly these claims under a JWT header, signed with the secret. */
	static function forge(payload:String):String {
		var input:String = JWT.base64UrlEncodeString('{"alg":"HS256","typ":"JWT"}') + "." + JWT.base64UrlEncodeString(payload);
		var mac:Bytes = new Hmac(SHA256).make(Bytes.ofString(SECRET), Bytes.ofString(input));
		return input + "." + JWT.base64UrlEncodeBytes(mac);
	}
}
