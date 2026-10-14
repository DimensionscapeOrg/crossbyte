package crossbyte.auth.jwt;

import crossbyte.errors.ArgumentError;
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
 * RFC 9068's `at+jwt`. A token with no `typ` (AWS Cognito's, Sign in with
 * Apple's, RFC 8037's own examples) is accepted unless `requireType` is set.
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
 *
 * ## Revoking tokens
 *
 * A token is good until its `exp` wherever it is shown, so a service that
 * signs a user out, or closes an account, before then keeps a list of the
 * tokens it no longer takes: `revocations`, by their `jti`, each held until
 * its token would have expired anyway. `revoke` checks a token is one of
 * this verifier's and lists it, and `verify` refuses it from then on as
 * `REVOKED`:
 *
 * ```haxe
 * // Given jwt:JWT, token:String.
 * jwt.revocations = new JWTRevocationList();
 * jwt.revoke(token); // signed out
 * trace(jwt.verify(token).rejection); // revoked
 * ```
 *
 * A token is revoked by its `jti`, so give each one an id of its own as it
 * is issued; one without is never refused by the list. Rotating the key
 * (`updateKeys`) ends every token it signed at once. The list is in memory
 * and bounded: `JWTRevocationList` says what happens when it is full, and
 * how to keep it across restarts and share it between processes.
 */
class JWT {
	@:noCompletion private var __keys:JWTKeys;

	/**
	 * The issuer a token's `iss` has to be, compared exactly. With
	 * `expectedIssuers` as well, `iss` may be this or any of those. Both
	 * `null` leaves `iss` unchecked.
	 */
	public var expectedIssuer:String;

	/**
	 * The issuers a token's `iss` may be, beside `expectedIssuer`: for a
	 * service that takes tokens from more than one issuer, such as its own and
	 * an account service's, under the same keys. Compared exactly; a token
	 * with no `iss` is refused once either is set, and an empty array with no
	 * `expectedIssuer` accepts no issuer. `null` by default.
	 *
	 * ```haxe
	 * // Given jwt:JWT.
	 * jwt.expectedIssuers = ["https://game.example", "https://accounts.example"];
	 * ```
	 */
	public var expectedIssuers:Null<Array<String>> = null;

	/**
	 * Whether a token must carry `iat`, and expire after it: one without is
	 * `MISSING_ISSUED_AT`, and one whose `exp` is not after its `iat` is
	 * `EXPIRY_NOT_AFTER_ISSUE`. RFC 7519 makes `iat` optional, so `false` by
	 * default; set it for tokens a service issues itself, whose age it reads.
	 * `verifySignature` does not apply it.
	 */
	public var requireIssuedAt:Bool = false;

	/**
	 * The audience this verifier is: a token's `aud` has to name it, or hold
	 * it when `aud` is an array. When `null`, a token that names any audience
	 * is refused as `WRONG_AUDIENCE` and one that names none is accepted:
	 * RFC 7519 has a recipient that does not identify itself with a token's
	 * `aud` reject it, so a token minted for another service of the same
	 * issuer cannot be replayed here.
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
	 * one type to refuse the others (an API accepting only access tokens,
	 * say, where an ID token signed by the same issuer must not pass), or to
	 * `null` to accept any.
	 */
	public var acceptedTypes:Null<Array<String>> = ["JWT", "at+jwt"];

	/**
	 * Whether a token without a `typ` header is refused. `false` by default,
	 * since several major issuers send none.
	 */
	public var requireType:Bool = false;

	/**
	 * Tokens refused before their time, by `jti`: a token on the list is
	 * `REVOKED`, checked last, so a revoked token past its `exp` reads as
	 * `EXPIRED` and one with a bad signature as `BAD_SIGNATURE`. `null`, as
	 * it starts, checks nothing and costs a verification nothing. `revoke`
	 * lists a token. One list can serve several verifiers (one for access
	 * tokens and one for refresh tokens, say); keep its `leeway` at least
	 * each one's, or let `revoke` do it, which holds each entry for this
	 * verifier's `leeway` when that is the longer. See `JWTRevocationList`.
	 */
	public var revocations:Null<JWTRevocationList> = null;

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
	 * @throws ArgumentError When `spec` is invalid, as `make` does.
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
	 * @throws IllegalOperationError When the signer holds no private key: a verify-only
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
	 * Verifies a compact JWT and returns the decoded payload on success,
	 * judging `exp`, `iat` and `nbf` by the wall clock.
	 *
	 * Returns `null` when the token is malformed, expired, signed by the wrong
	 * algorithm, or fails issuer/audience validation. `verify` makes the same
	 * checks and says which one failed.
	 *
	 * `verifyToken(token)` and `verifyToken(token, now)` are two functions
	 * rather than one taking an optional time, which natively and on the jvm
	 * is boxed on its way in. Each is inlined where it is called, and is not
	 * a value to pass on: pass `token -> jwt.verifyToken(token)`.
	 */
	public overload extern inline function verifyToken(token:String):JWTPayload {
		return __verify(token, 0.0, true, true).payload;
	}

	/**
	 * The same, judging the times by `now`, in seconds since the epoch: for a
	 * service that keeps its own clock, or for fixed-time tests.
	 *
	 * @throws ArgumentError For a `now` of NaN, by which no token would be
	 *         expired.
	 */
	public overload extern inline function verifyToken(token:String, now:Float):JWTPayload {
		return __verify(token, now, false, true).payload;
	}

	/**
	 * Verifies a compact JWT, answering with its claims or with why it was
	 * refused, judging `exp`, `iat` and `nbf` by the wall clock.
	 *
	 * Checks run cheapest first and the first failure is the answer: size and
	 * shape, the header's `alg`, `crit`, `typ` and `kid`, the signature, and
	 * then the claims: `exp` (required), `iat` when `requireIssuedAt` is set,
	 * the times against the clock, `iss` and `aud`.
	 * Nothing in a refused token is returned, so claims are never read before
	 * the signature over them has been checked. A header whose objects and
	 * arrays nest more than 32 deep is `MALFORMED`, refused before it is
	 * parsed. A header with `crit` is `UNSUPPORTED_CRITICAL`: no
	 * extension is implemented here, and RFC 7515 makes such a token invalid
	 * to a verifier that does not understand the extensions it names.
	 *
	 * Two functions, with a time and without, as `verifyToken` is.
	 */
	public overload extern inline function verify(token:String):JWTVerification {
		return __verify(token, 0.0, true, true);
	}

	/**
	 * The same, judging the times by `now`, in seconds since the epoch.
	 *
	 * @throws ArgumentError For a `now` of NaN, by which no token would be
	 *         expired.
	 */
	public overload extern inline function verify(token:String, now:Float):JWTVerification {
		return __verify(token, now, false, true);
	}

	/**
	 * Every check `verify` makes but those of the times, for a caller that
	 * judges `exp`, `nbf` and `iat` itself: revoking a token until it would
	 * have expired, say, which has to accept one that already has. The
	 * signature, header, claim types, `iss` and `aud` are checked as `verify`
	 * checks them; a token without `exp` is accepted, one whose `exp`, `iat` or
	 * `nbf` is not a number is `MALFORMED`, and `requireIssuedAt` is not
	 * applied.
	 *
	 * ```haxe
	 * // Given jwt:JWT, token:String.
	 * var result = jwt.verifySignature(token);
	 * if (result.valid) {
	 * 	trace('signed by the issuer; expires at ${result.payload.expiresAt}');
	 * }
	 * ```
	 */
	public function verifySignature(token:String):JWTVerification {
		return __verify(token, 0.0, true, false);
	}

	/**
	 * Lists `token` on `revocations`, so that `verify` refuses it as
	 * `REVOKED` until it would have expired anyway: its `exp` and the longer
	 * of this verifier's `leeway` and the list's. The token is checked first
	 * as `verifySignature` checks it, so only a token this verifier would
	 * take, but for its times, is listed, and a stream of made-up ones fills
	 * nothing. What has passed is judged by the wall clock.
	 *
	 * `revoke(token)` and `revoke(token, now)` are two functions, as
	 * `verify`'s are.
	 *
	 * @return Whether the token is refused as revoked from now on: `true`
	 *         once listed, or when it was already; `false` for a token this
	 *         verifier does not take (its signature, its issuer, its
	 *         audience), one without a `jti` or an `exp`, and one past its
	 *         time, which `verify` refuses as `EXPIRED` anyway.
	 * @throws IllegalOperationError When `revocations` is `null`.
	 */
	public overload extern inline function revoke(token:String):Bool {
		return __revoke(token, 0.0, true);
	}

	/**
	 * The same, judging what has passed by `now`, in seconds since the epoch.
	 *
	 * @throws ArgumentError For a `now` of NaN.
	 */
	public overload extern inline function revoke(token:String, now:Float):Bool {
		return __revoke(token, now, false);
	}

	@:noCompletion private function __revoke(token:String, now:Float, clock:Bool):Bool {
		final list:Null<JWTRevocationList> = revocations;
		if (list == null) {
			throw new crossbyte.errors.IllegalOperationError("JWT.revoke lists a token on revocations, and this JWT has none: set revocations to a JWTRevocationList first.");
		}
		#if !static
		// A time given as null asks the wall clock, as in `__verify`.
		if (!clock && (now : Null<Float>) == null) {
			clock = true;
		}
		#end
		if (!clock && Math.isNaN(now)) {
			throw new ArgumentError("JWT.revoke was given a time of NaN.");
		}
		final checked:JWTVerification = __verify(token, 0.0, true, false);
		if (!checked.valid) {
			return checked.rejection == REVOKED;
		}
		final tokenId:Null<String> = checked.payload.tokenId;
		final expiresAt:Null<Float> = checked.payload.expiresAt;
		if (tokenId == null || expiresAt == null) {
			return false;
		}
		// Held as long as this verifier takes a token past its exp, where
		// that is longer than the list's own leeway.
		final until:Float = expiresAt + (leeway > list.leeway ? leeway - list.leeway : 0);
		return clock ? list.revoke(tokenId, until) : list.revoke(tokenId, until, now);
	}

	/**
		`verify`, the time `now` or, with `clock`, the wall clock's; with
		`times` false, `verifySignature`.
	**/
	@:noCompletion private function __verify(token:String, now:Float, clock:Bool, times:Bool):JWTVerification {
		#if !static
		// Where a Float can be null (JavaScript, eval, neko), a time given as
		// null asks the wall clock, as the optional time it replaces did,
		// rather than judging every token by null and passing it.
		if (!clock && (now : Null<Float>) == null) {
			clock = true;
		}
		#end
		if (!clock && Math.isNaN(now)) {
			throw new crossbyte.errors.ArgumentError("JWT.verify was given a time of NaN.");
		}
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

		// One read of the keys: updateKeys may swap them meanwhile, and a
		// verification uses one set of keys throughout.
		var signer:IJWTSigner = __keys.signer;

		// A header seen before in a token that verified is not decoded again:
		// what it says is kept, and every check that depends on this
		// verifier's settings or keys is made again below.
		var known:Null<JWTHeaderSeen> = __headerSeen(token, headerEnd);
		var alg:String;
		var typ:Null<String>;
		var kid:Null<String>;

		if (known != null) {
			alg = known.alg;
			typ = known.typ;
			kid = known.kid;
			if (alg != (signer.algorithm : String)) {
				return JWTVerification.refused(ALGORITHM_MISMATCH);
			}
			if (!__typeAccepted(typ)) {
				return JWTVerification.refused(TYPE_NOT_ACCEPTED);
			}
		} else {
			// Bounded: the header is parsed before the signature is checked, so
			// it is the part anyone can write. See MAX_NESTING.
			var header:Null<Dynamic> = __decodeObject(token, 0, headerEnd, MAX_NESTING);
			if (header == null) {
				return JWTVerification.refused(MALFORMED);
			}

			var algValue:Dynamic = Reflect.field(header, "alg");
			if (!Std.isOfType(algValue, String) || !__isSupported(algValue)) {
				return JWTVerification.refused(UNSUPPORTED_ALGORITHM);
			}
			alg = algValue;
			if (alg != (signer.algorithm : String)) {
				return JWTVerification.refused(ALGORITHM_MISMATCH);
			}

			// RFC 7515 4.1.11: the extensions `crit` names are ones the token
			// may not be accepted without, and none is implemented here.
			// Ignored, a token with `"b64":false` (its payload unencoded) would
			// be read as though its payload were base64url.
			if (Reflect.hasField(header, "crit")) {
				return JWTVerification.refused(UNSUPPORTED_CRITICAL);
			}

			var typValue:Dynamic = Reflect.field(header, "typ");
			if (typValue != null && !Std.isOfType(typValue, String)) {
				return JWTVerification.refused(MALFORMED);
			}
			typ = typValue;
			if (!__typeAccepted(typ)) {
				return JWTVerification.refused(TYPE_NOT_ACCEPTED);
			}

			var kidValue:Dynamic = Reflect.field(header, "kid");
			if (kidValue != null && !Std.isOfType(kidValue, String)) {
				return JWTVerification.refused(MALFORMED);
			}
			kid = kidValue;
		}

		if (!signer.hasKey(kid)) {
			return JWTVerification.refused(UNKNOWN_KEY);
		}
		if (!signer.verifyToken(token, inputEnd, kid)) {
			return JWTVerification.refused(BAD_SIGNATURE);
		}
		if (known == null) {
			// Only now: a header is kept only once a token carrying it has been
			// shown to come from a key holder, so a stream of forged headers
			// cannot fill the list or push the real ones out.
			__rememberHeader(token.substring(0, headerEnd), alg, typ, kid);
		}

		// Unbounded: parsed only once the signature has shown the issuer wrote
		// them, and measuring them too would cost a typical token's verification 2%.
		var claims:Null<Dynamic> = __decodeObject(token, headerEnd + 1, inputEnd, 0);
		if (claims == null) {
			return JWTVerification.refused(MALFORMED);
		}

		// The registered claims, read once and checked for the JSON types RFC
		// 7519 gives them: strings for `sub`, `name`, `iss` and `jti`, numbers
		// for the times. Checked here, so the payload's typed properties
		// cannot hand back, say, an Int as a String (which the jvm answers
		// with a cast exception), and read the field with no check of their
		// own. A missing or non-numeric `exp` is MISSING_EXPIRY.
		var issuerValue:Dynamic = Reflect.field(claims, "iss");
		var tokenIdValue:Dynamic = Reflect.field(claims, "jti");
		if (!__isTextOrNull(Reflect.field(claims, "sub")) || !__isTextOrNull(Reflect.field(claims, "name")) || !__isTextOrNull(issuerValue)
			|| !__isTextOrNull(tokenIdValue)) {
			return JWTVerification.refused(MALFORMED);
		}
		var issuedAtValue:Dynamic = Reflect.field(claims, "iat");
		var issuedAt:Float = __seconds(issuedAtValue);
		var notBeforeValue:Dynamic = Reflect.field(claims, "nbf");
		var notBefore:Float = __seconds(notBeforeValue);
		if ((issuedAtValue != null && Math.isNaN(issuedAt)) || (notBeforeValue != null && Math.isNaN(notBefore))) {
			return JWTVerification.refused(MALFORMED);
		}
		var expiresAtValue:Dynamic = Reflect.field(claims, "exp");
		var expiresAt:Float = __seconds(expiresAtValue);

		if (times) {
			if (Math.isNaN(expiresAt)) {
				return JWTVerification.refused(MISSING_EXPIRY);
			}
			if (requireIssuedAt) {
				if (issuedAtValue == null) {
					return JWTVerification.refused(MISSING_ISSUED_AT);
				}
				if (!(expiresAt > issuedAt)) {
					return JWTVerification.refused(EXPIRY_NOT_AFTER_ISSUE);
				}
			}

			// Float throughout: a time past 2038 does not fit an Int, and one near
			// the limit plus the leeway wrapped where an Int is 32 bits.
			var nowSec:Float = clock ? __wallClock() : now;
			if (nowSec > expiresAt + leeway) {
				return JWTVerification.refused(EXPIRED);
			}
			if (issuedAtValue != null && (nowSec + leeway) < issuedAt) {
				return JWTVerification.refused(ISSUED_IN_FUTURE);
			}
			if (notBeforeValue != null && (nowSec + leeway) < notBefore) {
				return JWTVerification.refused(NOT_YET_VALID);
			}
		} else if (expiresAtValue != null && Math.isNaN(expiresAt)) {
			return JWTVerification.refused(MALFORMED);
		}

		var issuer:Null<String> = issuerValue;
		if ((expectedIssuer != null || expectedIssuers != null) && !__issuerAccepted(issuer)) {
			return JWTVerification.refused(WRONG_ISSUER);
		}
		var audience:JWTAudience = Reflect.field(claims, "aud");
		if (expectedAudience != null) {
			if (!audience.contains(expectedAudience)) {
				return JWTVerification.refused(WRONG_AUDIENCE);
			}
		} else if (audience != null) {
			// RFC 7519 4.1.3: a recipient that does not identify itself with a
			// value in `aud` must reject the token, so one minted for another
			// service the issuer and key serve is refused here.
			return JWTVerification.refused(WRONG_AUDIENCE);
		}

		// Last: only a token taken but for it is refused as revoked.
		var revoked:Null<JWTRevocationList> = revocations;
		if (revoked != null && tokenIdValue != null && revoked.isRevoked(tokenIdValue, expiresAt)) {
			return JWTVerification.refused(REVOKED);
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

	/**
		Headers of tokens that verified, by their encoded text. Replaced, never
		changed in place, so a verification on another thread reads either the
		old list or the new one; a header two threads add at once may be kept
		once rather than twice, which costs only a decode. At most
		`__HEADERS_KEPT`: an issuer signs under a key id or two at a time, and
		a full list starts again from the newest.
	**/
	@:noCompletion private var __headers:Array<JWTHeaderSeen> = [];

	@:noCompletion private static inline var __HEADERS_KEPT:Int = 8;

	@:noCompletion private function __headerSeen(token:String, headerEnd:Int):Null<JWTHeaderSeen> {
		var headers:Array<JWTHeaderSeen> = __headers;
		for (i in 0...headers.length) {
			var seen:JWTHeaderSeen = headers[i];
			if (seen.segment.length == headerEnd && StringTools.startsWith(token, seen.segment)) {
				return seen;
			}
		}
		return null;
	}

	@:noCompletion private function __rememberHeader(segment:String, alg:String, typ:Null<String>, kid:Null<String>):Void {
		var headers:Array<JWTHeaderSeen> = __headers;
		var next:Array<JWTHeaderSeen> = headers.length < __HEADERS_KEPT ? headers.copy() : [];
		next.push(new JWTHeaderSeen(segment, alg, typ, kid));
		__headers = next;
	}

	/** Whether `issuer` is `expectedIssuer` or one of `expectedIssuers`. **/
	@:noCompletion private function __issuerAccepted(issuer:Null<String>):Bool {
		if (issuer == null) {
			return false;
		}
		if (issuer == expectedIssuer) {
			return true;
		}
		var accepted:Null<Array<String>> = expectedIssuers;
		if (accepted != null) {
			for (candidate in accepted) {
				if (candidate == issuer) {
					return true;
				}
			}
		}
		return false;
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
	 * runs for every token and lower-casing copies of both would be an
	 * allocation per candidate.
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
		Seconds since the epoch from a claim as JSON gives it (an `Int` or a
		`Float` depending on the target and the size of the number), or NaN
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

	/**
		Seconds since the epoch by the wall clock. `Sys.time()` where there is
		one rather than `Date.now()`, which makes a `Date` per token.
	**/
	@:noCompletion private static inline function __wallClock():Float {
		#if sys
		return Sys.time(); // time of day: a token's times are seconds since the epoch
		#elseif js
		return js.lib.Date.now() / 1000; // time of day: as above
		#else
		return Date.now().getTime() / 1000; // time of day: as above
		#end
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
		// object or not at all. Asked of the text, rather than by four type
		// tests of the parsed value after the work of parsing.
		if (!__opensObject(text)) {
			return null;
		}

		// Measured before parsing, which takes a frame per level. The header
		// is parsed before the signature is checked, so a token needs no key
		// to be nested 6,000 deep in 16 KB (within a raised maxTokenLength),
		// and natively that would overflow the stack and end the process.
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
	 * @throws ArgumentError For a length no base64url string can have (one more than
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
				throw new ArgumentError("invalid base64url length");
		}
		return std;
	}

	/**
	 * Decodes a base64url string to UTF-8 text, returning `null` on failure.
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
	 * @return `true` only when both are present and equal: a missing value
	 *         (a header or cookie that was not sent) matches nothing,
	 *         another missing one included.
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
	What a header that verified said, by its encoded text: `alg`, a string
	`JWT` verifies; `typ` and `kid`, strings or null; and no `crit`.
**/
@:noCompletion
private final class JWTHeaderSeen {
	/** The header as the token carried it, encoded. **/
	public final segment:String;

	public final alg:String;
	public final typ:Null<String>;
	public final kid:Null<String>;

	public function new(segment:String, alg:String, typ:Null<String>, kid:Null<String>) {
		this.segment = segment;
		this.alg = alg;
		this.typ = typ;
		this.kid = kid;
	}
}

/**
	A signer and the header segment it signs under, made once: `updateKeys`
	swaps the two together, so no token pairs one signer's header with
	another's key. It is `{"alg":..,"typ":"JWT","kid":..}`, in that order on
	every target.
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
