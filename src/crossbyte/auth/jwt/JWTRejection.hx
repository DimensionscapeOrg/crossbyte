package crossbyte.auth.jwt;

/**
 * Why `JWT.verify` refused a token.
 *
 * A string underneath, so a reason can go straight into a log line or a
 * metric label. Only `UNKNOWN_KEY` usually calls for action beyond refusing:
 * it is what a token signed with a newly rotated key looks like, and the cue
 * to fetch the issuer's keys again.
 */
enum abstract JWTRejection(String) to String {
	/**
	 * Not three base64url segments of JSON objects, a header field of the
	 * wrong type, or JSON nested more than 32 deep.
	 */
	var MALFORMED = "malformed";

	/** Longer than `JWT.maxTokenLength`, and not parsed at all. */
	var TOO_LARGE = "too-large";

	/** An `alg` CrossByte does not verify, `none` included. */
	var UNSUPPORTED_ALGORITHM = "unsupported-algorithm";

	/** A supported `alg`, but not the one this verifier's keys are for. */
	var ALGORITHM_MISMATCH = "algorithm-mismatch";

	/**
	 * A `crit` header: the token names extensions it must not be accepted
	 * without, and this verifier implements none. RFC 7515 makes such a token
	 * invalid for a verifier that does not understand them.
	 */
	var UNSUPPORTED_CRITICAL = "unsupported-critical";

	/** A `typ` outside `JWT.acceptedTypes`, or none where `JWT.requireType` asks for one. */
	var TYPE_NOT_ACCEPTED = "type-not-accepted";

	/** A `kid` naming no key this verifier holds, or none where it holds several. */
	var UNKNOWN_KEY = "unknown-key";

	/** The signature does not match the header and claims. */
	var BAD_SIGNATURE = "bad-signature";

	/** No `exp` claim, or one that is not a number. */
	var MISSING_EXPIRY = "missing-expiry";

	/** `exp` is in the past, beyond the leeway. */
	var EXPIRED = "expired";

	/** `nbf` is in the future, beyond the leeway. */
	var NOT_YET_VALID = "not-yet-valid";

	/** `iat` is in the future, beyond the leeway. */
	var ISSUED_IN_FUTURE = "issued-in-future";

	/** `iss` is not `JWT.expectedIssuer`. */
	var WRONG_ISSUER = "wrong-issuer";

	/**
	 * `aud` does not include `JWT.expectedAudience`, or names an audience
	 * where the verifier expects none.
	 */
	var WRONG_AUDIENCE = "wrong-audience";
}
