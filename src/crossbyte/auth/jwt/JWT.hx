package crossbyte.auth.jwt;

import haxe.io.Bytes;
import haxe.crypto.Base64;
import haxe.Json;
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
 * RFC 9068's `at+jwt`. A token with no `typ` -- AWS Cognito's, Sign in with
 * Apple's, RFC 8037's own examples -- is accepted unless `requireType` is set.
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
	@:noCompletion private var __signer:IJWTSigner;

	public var expectedIssuer:String;
	public var expectedAudience:String;
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
	 * one type to refuse the others -- an API accepting only access tokens,
	 * say, where an ID token signed by the same issuer must not pass -- or to
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
		this.__signer = signer;
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
		__signer = __signerFor(spec);
	}

	/** Serializes and signs a payload into a compact JWT string. */
	public function generateToken(payload:JWTPayload):String {
		var signer:IJWTSigner = __signer;
		var header:JWTHeader = JWTHeader.make(signer.algorithm, signer.signKeyId, "JWT");
		var headerStr:String = base64UrlEncodeString(Json.stringify(header.toData()));
		var payloadStr:String = base64UrlEncodeString(Json.stringify(payload.toData()));
		var signature:String = signer.sign(headerStr + "." + payloadStr, header.keyId);
		return headerStr + "." + payloadStr + "." + signature;
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
	 * shape, the header's `alg`, `typ` and `kid`, the signature, and then the
	 * claims -- `exp` (required), `iat`, `nbf`, `iss` and `aud`. Nothing in a
	 * refused token is returned, so claims are never read before the signature
	 * over them has been checked.
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

		var parts = token.split('.');
		if (parts.length != 3) {
			return JWTVerification.refused(MALFORMED);
		}

		var header:Null<Dynamic> = __decodeObject(parts[0]);
		if (header == null) {
			return JWTVerification.refused(MALFORMED);
		}

		// One read of the signer: updateKeys may swap it meanwhile, and a
		// verification uses one set of keys throughout.
		var signer:IJWTSigner = __signer;

		var alg:Dynamic = Reflect.field(header, "alg");
		if (!Std.isOfType(alg, String) || !__isSupported(alg)) {
			return JWTVerification.refused(UNSUPPORTED_ALGORITHM);
		}
		if ((alg : String) != (signer.algorithm : String)) {
			return JWTVerification.refused(ALGORITHM_MISMATCH);
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
		if (!signer.verify(parts[0] + "." + parts[1], parts[2], kid)) {
			return JWTVerification.refused(BAD_SIGNATURE);
		}

		var claims:Null<Dynamic> = __decodeObject(parts[1]);
		if (claims == null) {
			return JWTVerification.refused(MALFORMED);
		}
		var payload:JWTPayload = JWTPayload.ofData(claims);

		var nowSec:Float = now != null ? now : Date.now().getTime() / 1000;
		if (payload.expiresAt == null) {
			return JWTVerification.refused(MISSING_EXPIRY);
		}
		if (nowSec > payload.expiresAt + leeway) {
			return JWTVerification.refused(EXPIRED);
		}
		if (payload.issuedAt != null && (nowSec + leeway) < payload.issuedAt) {
			return JWTVerification.refused(ISSUED_IN_FUTURE);
		}
		if (payload.notBeforeTime != null && (nowSec + leeway) < payload.notBeforeTime) {
			return JWTVerification.refused(NOT_YET_VALID);
		}

		if (expectedIssuer != null && payload.issuer != expectedIssuer) {
			return JWTVerification.refused(WRONG_ISSUER);
		}
		if (expectedAudience != null && !__audMatches(expectedAudience, payload.audience)) {
			return JWTVerification.refused(WRONG_AUDIENCE);
		}

		return JWTVerification.accepted(payload);
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

		var normalized:String = __mediaType(typ);
		for (candidate in accepted) {
			if (candidate != null && __mediaType(candidate) == normalized) {
				return true;
			}
		}
		return false;
	}

	@:noCompletion private static function __mediaType(value:String):String {
		var lower:String = value.toLowerCase();
		return lower.startsWith("application/") ? lower.substr("application/".length) : lower;
	}

	/** Decodes one segment into a JSON object, or null for anything else. */
	@:noCompletion private static function __decodeObject(segment:String):Null<Dynamic> {
		var text:Null<String> = safeBase64UrlEncodeString(segment);
		if (text == null) {
			return null;
		}

		var value:Dynamic;
		try {
			value = Json.parse(text);
		} catch (_:Dynamic) {
			return null;
		}

		if (value == null || Std.isOfType(value, String) || Std.isOfType(value, Float) || Std.isOfType(value, Bool) || Std.isOfType(value, Array)) {
			return null;
		}
		return value;
	}

	@:noCompletion private static function __audMatches(expected:String, aud:Dynamic):Bool {
		if (aud == null) {
			return false;
		}
		if (Std.isOfType(aud, String)) {
			return (cast aud : String) == expected;
		}
		if (Std.isOfType(aud, Array)) {
			var arr:Array<Dynamic> = cast aud;
			for (v in arr) {
				if (Std.isOfType(v, String) && (cast v : String) == expected) {
					return true;
				}
			}
			return false;
		}
		return false;
	}

	public static inline function base64UrlEncodeString(s:String):String {
		return base64UrlEncodeBytes(Bytes.ofString(s));
	}

	@:noCompletion private static inline function __stripPad(s:String):String {
		var i:Int = s.length, eq = '='.code;
		while (i > 0 && s.charCodeAt(i - 1) == eq) {
			i--;
		}
		return s.substr(0, i);
	}

	public static inline function base64UrlEncodeBytes(b:Bytes):String {
		var s:String = Base64.encode(b);
		s = s.split("+").join("-").split("/").join("_");
		return __stripPad(s);
	}

	/** Normalizes a base64url string into padded standard base64 form. */
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

	/** Safely decodes a base64url string to UTF-8 text, returning `null` on failure. */
	public static function safeBase64UrlEncodeString(s:String):Null<String> {
		var b64:String = s.split("-").join("+").split("_").join("/");
		switch (b64.length % 4) {
			case 2:
				b64 += "==";
			case 3:
				b64 += "=";
			case 0:
			case 1:
				return null;
		}
		try {
			return Base64.decode(b64).toString();
		} catch (_:Dynamic) {
			return null;
		}
	}

	/**
	 * Compares two strings in constant-time. Does not short-circuit on a length
	 * mismatch: it iterates a fixed number of times over the longer string,
	 * accumulating per-byte differences, and folds in the length delta so that the
	 * comparison's running time does not leak which (if either) operand matched.
	 */
	public static function secureCompare(a:String, b:String):Bool {
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
