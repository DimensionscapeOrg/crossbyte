package crossbyte.auth.jwt;

/**
 * JWS algorithm names: the four `JWT` signs and verifies with, and `none`.
 *
 * `JWT.verify` refuses any other `alg` as `UNSUPPORTED_ALGORITHM`, `none`
 * included.
 */
enum abstract JWTAlgorithm(String) from String to String {
  /** HMAC using SHA-256, with a shared secret: `JWTSigner.HS256`. */
  var HS256:String = "HS256";
  /** RSA PKCS#1 v1.5 using SHA-256: `JWTSigner.RS256`, natively. */
  var RS256:String = "RS256";
  /** ECDSA using P-256 and SHA-256: `JWTSigner.ES256`, natively. */
  var ES256:String = "ES256";
  /** Ed25519 signatures (RFC 8037): `JWTSigner.EdDSA`, natively. */
  var EdDSA:String = "EdDSA";
  /** Unsigned token. Named so it can be compared against; never accepted. */
  var NONE:String = "none";
}
