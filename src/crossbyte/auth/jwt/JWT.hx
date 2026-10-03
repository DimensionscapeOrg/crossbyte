package crossbyte.auth.jwt;

import haxe.io.Bytes;
import haxe.Json;
import crossbyte._internal.Utf8;
import crossbyte._internal.serial.JsonNesting;
import crossbyte.auth.jwt._internal.Base64Url;
import crossbyte.auth.jwt._internal.sign.IJWTSigner;
import crossbyte.auth.jwt._internal.sign.HS256Signer;
import crossbyte.auth.jwt._internal.sign.Ed25519Signer;
import crossbyte.auth.jwt._internal.sign.PkSigner;

using StringTools;

/**
 * Generates and verifies compact JWT strings using a configured signer.
 *
 * `verify` says why a token was refused; `verifyToken` is the same check
 * answering only with the claims or `null`.
 *
 * ## Tokens from other issuers
 *
 * A token's `typ` is compared with `acceptedTypes` in any letter case, with
 * an `application/` prefix ignored, as RFC 7515 has it; by default `JWT` and
 * RFC 9068's `at+jwt`. A token with no `typ`, AWS Cognito's, Sign in with
 * Apple's, RFC 8037's own examples, is accepted unless `requireType` is set.
 *
 * ## Rotating keys
 *
 * `updateKeys` swaps the keys for new ones and keeps every other setting.
 * Keep the retiring key in the new set until the tokens it signed expire: a
 * token names its key by `kid`, and one naming a key no longer held is
 * refused as `UNKNOWN_KEY`. A signer made with a single unnamed HS256 secret
 * signs under the key id `default`, so after rotation that secret has to be
 * listed as `{key: "default", secret: ...}` for its tokens to verify. For keys
 * an issuer publishes, `JWKSet.signer` turns a fetched key set into the
 * argument, and `UNKNOWN_KEY` is the cue to fetch it again.
 */
class JWT {
	@:noCompletion private var __keys:JWTKeys;

	/** The issuer a token's `iss` has to be. `null` leaves `iss` unchecked. */
	public var expectedIssuer:String;

	/**
	 * The audience this verifier is: a token's `aud` has to name it, or hold
	 * it when `aud` is an array. When `null`, a token that names any audience
	 * is refused as `WRONG_AUDIENCE` and one that names none is accepted,
	 * RFC 7519 has a recipient that does not identify itself with a token's
	 * `aud` reject it, and accepting one let a token minted for another
	 * service of the same issuer be replayed here.
	 */
	public var expectedAudience:String;

	/**
	 * Seconds of clock difference forgiven when judging `exp`, `nbf` and
	 * `iat` against the time. 60 by default.
	 */
	public var leeway:Int = 60;

	/**
	 * The longest token, in characters, that `verify` will parse. Longer ones
	 * are refused as `TOO_LARGE` before any decoding, which bounds what a
	 * hostile token costs. 4096 by default; tokens carrying many claims, such
	 * as an identity provider's with every group a user is in, can need more.
	 */
	public var maxTokenLength:Int = 4096;

	/**
	 * The `typ` header values accepted, compared case-insensitively and with any
	 * `application/` prefix ignored. `JWT` and `at+jwt` by default. Set it to
	 * one type to refuse the others, an API accepting only access tokens,
	 * say, where an ID token signed by the same issuer must not pass, or to
	 * `null` to accept any.
	 */
	public var acceptedTypes:Null<Array<String>> = ["JWT", "at+jwt"];

	/**
	 * Whether a token without a `typ` header is refused. `false` by default,
	 * since several major issuers send none.
	 */
	public var requireType:Bool = false;

	/**
	 * Creates a JWT helper from signer configuration and optional verification expectations.
	 */
	public static function make(spec:JWTSigner, ?issuer:String, ?audience:String, ?leeway:Int = 60):JWT {
		var jwt = new JWT(__signerFor(spec));
		jwt.expectedIssuer = issuer;
		jwt.expectedAudience = audience;
		jwt.leeway = leeway;
		return jwt;
	}

	@:noCompletion private function new(signer:IJWTSigner) {
		this.__keys = new JWTKeys(signer);
	}

	/**
	 * Replaces the keys this signs and verifies with, keeping every other
	 * setting. Built before it is swapped in, so a spec that is invalid throws
	 * here and leaves the current keys in place; and a single reference, so a
	 * verification on another thread uses either the old keys or the new, never
	 * a mixture.
	 *
	 * @throws String When `spec` is invalid, as `make` does.
	 */
	public function updateKeys(spec:JWTSigner):Void {
		__keys = new JWTKeys(__signerFor(spec));
	}

	/**
	 * Serializes and signs a payload into a compact JWT string.
	 *
	 * The payload may carry claims beyond the registered ones; see `JWTPayload`.
	 *
	 * @throws ArgumentError When `iat`, `exp` or `nbf` is present and not a
	 *         finite number of seconds.
	 * @throws String When the signer holds no private key, a verify-only
	 *         one, such as `JWKSet.signer` makes.
	 */
	public function generateToken(payload:JWTPayload):String {
		// One read: the header and the key that signs under it are swapped
		// together.
		var keys:JWTKeys = __keys;
		var claims:String = Base64Url.encode(Utf8.bytesOf(Json.stringify(__claimsToWrite(payload.toData()))));
		var input:String = keys.header + "." + claims;
		return input + "." + keys.signer.sign(input, keys.signer.signKeyId);
	}

	/**
	 * Verifies a compact JWT and returns the decoded payload on success.
	 *
	 * Returns `null` when the token is malformed, expired, signed by the wrong
	 * algorithm, or fails issuer/audience validation. `verify` makes the same
	 * checks and says which one failed.
	 *
	 * @param now The time to judge `exp`, `iat` and `nbf` against, in seconds
	 *        since the epoch. Defaults to the wall clock; pass one for a
	 *        service that keeps its own clock, or for fixed-time tests.
	 */
	public function verifyToken(token:String, ?now:Float):JWTPayload {
		return verify(token, now).payload;
	}

	/**
	 * Verifies a compact JWT, answering with its claims or with why it was
	 * refused.
	 *
	 * Checks run cheapest first and the first failure is the answer: size and
	 * shape, the header's `alg`, `crit`, `typ` and `kid`, the signature, and
	 * then the claims, `exp` (required), `iat`, `nbf`, `iss` and `aud`.
	 * Nothing in a refused token is returned, so claims are never read before
	 * the signature over them has been checked. A header whose objects and
	 * arrays nest more than 32 deep is `MALFORMED`, refused before it is
	 * parsed. A header with `crit` is `UNSUPPORTED_CRITICAL`: no
	 * extension is implemented here, and RFC 7515 makes such a token invalid
	 * to a verifier that does not understand the extensions it names.
	 *
	 * @param now As for `verifyToken`.
	 */
	public function verify(token:String, ?now:Float):JWTVerification {
		if (token == null || token.length == 0) {
			return JWTVerification.refused(MALFORMED);
		}
		if (token.length > maxTokenLength) {
			return JWTVerification.refused(TOO_LARGE);
		}

		// The three segments, found in place: the token is not split into
		// substrings, nor its signing input put back together from them.
		var headerEnd:Int = token.indexOf(".");
		var inputEnd:Int = headerEnd < 0 ? -1 : token.indexOf(".", headerEnd + 1);
		if (inputEnd < 0 || token.indexOf(".", inputEnd + 1) >= 0) {
			return JWTVerification.refused(MALFORMED);
		}

		// Bounded: the header is parsed before the signature is checked, so it
		// is the part anyone can write. See MAX_NESTING.
		var header:Null<Dynamic> = __decodeObject(token, 0, headerEnd, MAX_NESTING);
		if (header == null) {
			return JWTVerification.refused(MALFORMED);
		}

		// One read of the keys: updateKeys may swap them meanwhile, and a
		// verification uses one set of keys throughout.
		var signer:IJWTSigner = __keys.signer;

		var alg:Dynamic = Reflect.field(header, "alg");
		if (!Std.isOfType(alg, String) || !__isSupported(alg)) {
			return JWTVerification.refused(UNSUPPORTED_ALGORITHM);
		}
		if ((alg : String) != (signer.algorithm : String)) {
			return JWTVerification.refused(ALGORITHM_MISMATCH);
		}

		// RFC 7515 4.1.11: the extensions `crit` names are ones the token may
		// not be accepted without, and none is implemented here. It was
		// ignored, so a token with `"b64":false`, its payload unencoded,
		// was read as though its payload were base64url.
		if (Reflect.hasField(header, "crit")) {
			return JWTVerification.refused(UNSUPPORTED_CRITICAL);
		}

		var typ:Dynamic = Reflect.field(header, "typ");
		if (typ != null && !Std.isOfType(typ, String)) {
			return JWTVerification.refused(MALFORMED);
		}
		if (!__typeAccepted(typ)) {
			return JWTVerification.refused(TYPE_NOT_ACCEPTED);
		}

		var kid:Dynamic = Reflect.field(header, "kid");
		if (kid != null && !Std.isOfType(kid, String)) {
			return JWTVerification.refused(MALFORMED);
		}
		if (!signer.hasKey(kid)) {
			return JWTVerification.refused(UNKNOWN_KEY);
		}
		if (!signer.verifyToken(token, inputEnd, kid)) {
			return JWTVerification.refused(BAD_SIGNATURE);
		}

		// Unbounded: parsed only once the signature has shown the issuer wrote
		// them. Measuring them too cost a typical token's verification 2%.
		var claims:Null<Dynamic> = __decodeObject(token, headerEnd + 1, inputEnd, 0);
		if (claims == null) {
			return JWTVerification.refused(MALFORMED);
		}

		// The registered claims, read once and checked for the JSON types RFC
		// 7519 gives them: strings for `sub`, `name`, `iss` and `jti`, numbers
		// for the times. Checked here, so the payload's typed properties
		// cannot hand back, say, an Int as a String, which the jvm answers
		// with a cast exception, and read the field with no check of their
		// own. A missing or non-numeric `exp` is MISSING_EXPIRY.
		var issuerValue:Dynamic = Reflect.field(claims, "iss");
		if (!__isTextOrNull(Reflect.field(claims, "sub")) || !__isTextOrNull(Reflect.field(claims, "name")) || !__isTextOrNull(issuerValue)
			|| !__isTextOrNull(Reflect.field(claims, "jti"))) {
			return JWTVerification.refused(MALFORMED);
		}
		var issuedAtValue:Dynamic = Reflect.field(claims, "iat");
		var issuedAt:Float = __seconds(issuedAtValue);
		var notBeforeValue:Dynamic = Reflect.field(claims, "nbf");
		var notBefore:Float = __seconds(notBeforeValue);
		if ((issuedAtValue != null && Math.isNaN(issuedAt)) || (notBeforeValue != null && Math.isNaN(notBefore))) {
			return JWTVerification.refused(MALFORMED);
		}
		var expiresAt:Float = __seconds(Reflect.field(claims, "exp"));
		if (Math.isNaN(expiresAt)) {
			return JWTVerification.refused(MISSING_EXPIRY);
		}

		// Float throughout: a time past 2038 does not fit an Int, and one near
		// the limit plus the leeway wrapped where an Int is 32 bits.
		var nowSec:Float = now != null ? now : Date.now().getTime() / 1000;
		if (nowSec > expiresAt + leeway) {
			return JWTVerification.refused(EXPIRED);
		}
		if (issuedAtValue != null && (nowSec + leeway) < issuedAt) {
			return JWTVerification.refused(ISSUED_IN_FUTURE);
		}
		if (notBeforeValue != null && (nowSec + leeway) < notBefore) {
			return JWTVerification.refused(NOT_YET_VALID);
		}

		var issuer:Null<String> = issuerValue;
		if (expectedIssuer != null && issuer != expectedIssuer) {
			return JWTVerification.refused(WRONG_ISSUER);
		}
		var audience:JWTAudience = Reflect.field(claims, "aud");
		if (expectedAudience != null) {
			if (!audience.contains(expectedAudience)) {
				return JWTVerification.refused(WRONG_AUDIENCE);
			}
		} else if (audience != null) {
			// RFC 7519 4.1.3: a recipient that does not identify itself with a
			// value in `aud` must reject the token. One minted for another
			// service the issuer and key serve was accepted here.
			return JWTVerification.refused(WRONG_AUDIENCE);
		}

		return JWTVerification.accepted(JWTPayload.ofData(claims));
	}

	@:noCompletion private static function __signerFor(spec:JWTSigner):IJWTSigner {
		return switch (spec) {
			case HS256(secrets, signKeyId):
				new HS256Signer(secrets, signKeyId);

			case EdDSA(pubKeys, privKey, signKeyId):
				new Ed25519Signer(pubKeys, privKey, signKeyId);

			case RS256(pubKeys, privKey, signKeyId):
				new PkSigner(JWTAlgorithm.RS256, pubKeys, privKey, signKeyId);

			case ES256(pubKeys, privKey, signKeyId):
				new PkSigner(JWTAlgorithm.ES256, pubKeys, privKey, signKeyId);
		};
	}

	@:noCompletion private static function __isSupported(alg:String):Bool {
		return switch ((alg : JWTAlgorithm)) {
			case HS256 | EdDSA | RS256 | ES256: true;
			default: false;
		}
	}

	/**
	 * Whether `typ` passes `acceptedTypes` and `requireType`. RFC 7515 4.1.9: a
	 * media type, so case does not matter, and `application/` may be left off.
	 */
	@:noCompletion private function __typeAccepted(typ:Null<String>):Bool {
		if (typ == null) {
			return !requireType;
		}

		var accepted:Null<Array<String>> = acceptedTypes;
		if (accepted == null) {
			return true;
		}

		for (candidate in accepted) {
			if (candidate != null && __sameMediaType(candidate, typ)) {
				return true;
			}
		}
		return false;
	}

	/**
	 * `a` and `b` as one media type: ASCII letters in either case, and an
	 * `application/` prefix on either ignored. Compared in place, since this
	 * runs for every token and lower-casing copies of both was an allocation
	 * per candidate.
	 */
	@:noCompletion private static function __sameMediaType(a:String, b:String):Bool {
		var i:Int = __afterApplication(a);
		var j:Int = __afterApplication(b);
		if (a.length - i != b.length - j) {
			return false;
		}
		while (i < a.length) {
			if (__lowerAscii(StringTools.fastCodeAt(a, i)) != __lowerAscii(StringTools.fastCodeAt(b, j))) {
				return false;
			}
			i++;
			j++;
		}
		return true;
	}

	@:noCompletion private static function __afterApplication(value:String):Int {
		var prefix:String = "application/";
		if (value.length <= prefix.length) {
			return 0;
		}
		for (k in 0...prefix.length) {
			if (__lowerAscii(StringTools.fastCodeAt(value, k)) != StringTools.fastCodeAt(prefix, k)) {
				return 0;
			}
		}
		return prefix.length;
	}

	@:noCompletion private static inline function __lowerAscii(code:Int):Int {
		return (code >= "A".code && code <= "Z".code) ? code + 32 : code;
	}

	@:noCompletion private static inline function __isTextOrNull(value:Dynamic):Bool {
		return value == null || Std.isOfType(value, String);
	}

	/**
		Seconds since the epoch from a claim as JSON gives it, an `Int` or a
		`Float` depending on the target and the size of the number, or NaN
		when it is absent or not a finite number. NaN rather than `null`, which
		natively boxes the number in an allocation.
	**/
	@:noCompletion private static function __seconds(value:Dynamic):Float {
		return switch (Type.typeof(value)) {
			// `+ 0.0` rather than a typed assignment: on the interpreter a
			// Float variable given an Int keeps Int arithmetic, and the leeway
			// added to 2147483647 would wrap.
			case TInt: (value : Int) + 0.0;
			case TFloat:
				var number:Float = value;
				Math.isFinite(number) ? number : Math.NaN;
			default: Math.NaN;
		}
	}

	// Made once: an array literal in the loop below is an allocation per token.
	@:noCompletion private static final __WRITTEN_TIME_CLAIMS:Array<String> = ["iat", "exp", "nbf"];

	/**
	 * The claims as they go on the wire: times checked, and a time that is a
	 * whole number of seconds within Int range written as an integer. The jvm
	 * prints any Float in exponent form, `1.7E9`, which is valid JSON but not
	 * what other targets write for the same token.
	 */
	@:noCompletion private static function __claimsToWrite(claims:Dynamic):Dynamic {
		var copy:Null<Dynamic> = null;
		for (field in __WRITTEN_TIME_CLAIMS) {
			var value:Dynamic = Reflect.field(claims, field);
			if (value == null || Std.isOfType(value, Int)) {
				continue;
			}

			var seconds:Null<Float> = JWTPayload.seconds(value);
			if (seconds == null) {
				throw new crossbyte.errors.ArgumentError('The $field claim must be a finite number of seconds since the epoch.');
			}
			if (seconds == Math.ffloor(seconds) && seconds >= -2147483648.0 && seconds <= 2147483647.0) {
				// A copy, so the caller's object keeps the value it was given.
				if (copy == null) {
					copy = Reflect.copy(claims);
				}
				Reflect.setField(copy, field, Std.int(seconds));
			}
		}
		return copy != null ? copy : claims;
	}

	/**
		The deepest a token's header may nest, objects and arrays together.
		A header holds a handful of flat members.
	**/
	@:noCompletion private static inline var MAX_NESTING:Int = 32;

	/**
		Decodes the segment of `token` from `start` to `end` into a JSON
		object, or null for anything else, including JSON nested deeper
		than `maxNesting`, when that is above 0.
	**/
	@:noCompletion private static function __decodeObject(token:String, start:Int, end:Int, maxNesting:Int):Null<Dynamic> {
		var text:Null<String> = Base64Url.decodeText(token, start, end);
		if (text == null) {
			return null;
		}

		// An object or nothing: JSON whose first character is `{` parses to an
		// object or not at all. Asked of the text, where four type tests of
		// the parsed value asked it after the work of parsing.
		if (!__opensObject(text)) {
			return null;
		}

		// Measured before parsing, which takes a frame per level. The header
		// is parsed before the signature is checked, so a token needed no key
		// to be nested 6,000 deep in 16 KB, within a raised maxTokenLength,
		// and natively that overflowed the stack and ended the process.
		if (maxNesting > 0 && !JsonNesting.within(text, maxNesting)) {
			return null;
		}

		try {
			return Json.parse(text);
		} catch (_:Dynamic) {
			return null;
		}
	}

	/** Whether `text`'s first character past JSON's whitespace is `{`. **/
	@:noCompletion private static function __opensObject(text:String):Bool {
		for (i in 0...text.length) {
			switch (StringTools.fastCodeAt(text, i)) {
				case " ".code, "\t".code, "\n".code, "\r".code:
				case "{".code:
					return true;
				default:
					return false;
			}
		}
		return false;
	}

	public static inline function base64UrlEncodeString(s:String):String {
		return Base64Url.encode(Utf8.bytesOf(s));
	}

	public static inline function base64UrlEncodeBytes(b:Bytes):String {
		return Base64Url.encode(b);
	}

	/**
	 * Normalizes a base64url string into padded standard base64 form.
	 *
	 * @throws String For a length no base64url string can have (one more than
	 *         a multiple of four).
	 */
	public static inline function normalizeBase64Url(s:String):String {
		var std:String = s.split("-").join("+").split("_").join("/");
		switch (std.length % 4) {
			case 2:
				std += "==";
			case 3:
				std += "=";
			case 0:
			case 1:
				throw "invalid base64url length";
		}
		return std;
	}

	/**
	 * Decodes a base64url string to UTF-8 text, returning `null` on failure.
	 * It was named `safeBase64UrlEncodeString`, for the opposite of what it
	 * does.
	 */
	public static function safeBase64UrlDecodeString(s:String):Null<String> {
		return s == null ? null : Base64Url.decodeText(s, 0, s.length);
	}

	/**
	 * Compares two strings in constant-time. Does not short-circuit on a length
	 * mismatch: it iterates a fixed number of times over the longer string,
	 * accumulating per-byte differences, and folds in the length delta so that the
	 * comparison's running time does not leak which (if either) operand matched.
	 *
	 * @return `true` only when both are present and equal: a missing value,
	 *         a header or cookie that was not sent, matches nothing, another
	 *         missing one included. It used to read the length of a null.
	 */
	public static function secureCompare(a:String, b:String):Bool {
		if (a == null || b == null) {
			return false;
		}
		var aLen:Int = a.length;
		var bLen:Int = b.length;
		var n:Int = (aLen > bLen) ? aLen : bLen;
		var diff:Int = aLen ^ bLen;
		for (i in 0...n) {
			var ca:Int = (i < aLen) ? a.charCodeAt(i) : 0;
			var cb:Int = (i < bLen) ? b.charCodeAt(i) : 0;
			diff |= ca ^ cb;
		}
		return (aLen == bLen) && (diff == 0);
	}
}

/**
	A signer and the header segment it signs under, made once: `updateKeys`
	swaps the two together, so no token pairs one signer's header with
	another's key. The header was serialized and encoded again for every
	token. It is `{"alg":..,"typ":"JWT","kid":..}`, in that order on every
	target; its members' order followed each target's objects before.
**/
@:noCompletion
private final class JWTKeys {
	public final signer:IJWTSigner;
	public final header:String;

	public function new(signer:IJWTSigner) {
		this.signer = signer;
		var keyId:Null<String> = signer.signKeyId;
		var json:String = '{"alg":' + Json.stringify((signer.algorithm : String)) + ',"typ":"JWT"'
			+ (keyId != null ? ',"kid":' + Json.stringify(keyId) : "") + "}";
		header = Base64Url.encode(Utf8.bytesOf(json));
	}
}
