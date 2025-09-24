package crossbyte.auth.jwt;
import haxe.ds.StringMap;
import haxe.io.Bytes;
import crossbyte.auth.Secret;

enum JWTSigner {
  HS256(secrets:Array<Secret>, ?signKeyId:String);
  EdDSA(pubKeys:StringMap<Bytes>, ?privKey:Bytes, ?signKeyId:String);
  RS256(pubKeys:StringMap<String>, ?privKey:String, ?signKeyId:String);
}