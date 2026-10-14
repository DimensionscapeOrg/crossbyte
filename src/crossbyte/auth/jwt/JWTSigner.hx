package crossbyte.auth.jwt;
import haxe.ds.StringMap;
import haxe.io.Bytes;
import crossbyte.auth.Secret;

/** Signer configuration used to construct a concrete `JWT` instance. */
enum JWTSigner {
  /**
   * HMAC-SHA256 signer with one or more shared secrets.
   *
   * A single secret with no `key` is named `default`, and the tokens it signs
   * carry `kid: "default"`; list it under that name when rotating to a second
   * secret, or those tokens stop verifying.
   */
  HS256(secrets:Array<Secret>, ?signKeyId:String);
  /**
   * EdDSA (Ed25519, RFC 8037) signer with 32-byte public keys by key id and an
   * optional 64-byte signing secret key (seed and public key, as
   * `Ed25519.keypair` makes it). Natively and on PHP with the sodium
   * extension, where `Ed25519.isSupported`; elsewhere `JWT.make` throws. A
   * signer given no secret key only verifies, so the services that check
   * tokens need not hold what mints them.
   */
  EdDSA(pubKeys:StringMap<Bytes>, ?privKey:Bytes, ?signKeyId:String);
  /** RSA-SHA256 signer with PEM verification keys and an optional PEM signing private key. */
  RS256(pubKeys:StringMap<String>, ?privKey:String, ?signKeyId:String);
  /** ECDSA P-256 signer with PEM verification keys and an optional PEM signing private key. */
  ES256(pubKeys:StringMap<String>, ?privKey:String, ?signKeyId:String);
}
