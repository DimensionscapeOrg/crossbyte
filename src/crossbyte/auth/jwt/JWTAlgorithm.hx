package crossbyte.auth.jwt;

/** JWT signature algorithms understood by CrossByte's JWT helpers. */
enum abstract JWTAlgorithm(String) from String to String {
  /** HMAC using SHA-256. */
  var HS256:String = "HS256"; 
  /** HMAC using SHA-384. */
  var HS384:String = "HS384";
  /** HMAC using SHA-512. */
  var HS512:String = "HS512";
  /** RSA PKCS#1 v1.5 using SHA-256. */
  var RS256:String = "RS256";  
  /** ECDSA using P-256 and SHA-256. */
  var ES256:String = "ES256";
  /** Edwards-curve EdDSA signatures such as Ed25519. */
  var EdDSA:String = "EdDSA"; 
  /** Unsigned token. Included for parsing/validation semantics only. */
  var NONE:String = "none";
}
