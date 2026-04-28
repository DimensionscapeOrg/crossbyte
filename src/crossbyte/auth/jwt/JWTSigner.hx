package crossbyte.auth.jwt;
import haxe.ds.StringMap;
import haxe.io.Bytes;
import crossbyte.auth.Secret;

/** Signer configuration used to construct a concrete `JWT` instance. */
enum JWTSigner {
  /** HMAC-SHA256 signer with one or more shared secrets. */
  HS256(secrets:Array<Secret>, ?signKeyId:String);
  /** EdDSA signer with verification keys and an optional signing private key. */
  EdDSA(pubKeys:StringMap<Bytes>, ?privKey:Bytes, ?signKeyId:String);
  /** RSA-SHA256 signer with verification keys and an optional signing private key. */
  RS256(pubKeys:StringMap<String>, ?privKey:String, ?signKeyId:String);
}
