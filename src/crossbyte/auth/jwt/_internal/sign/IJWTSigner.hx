package crossbyte.auth.jwt._internal.sign;

interface IJWTSigner {
  public var signKeyId(get, never):String;
  public var algorithm(get, never):JWTAlgorithm;                         
  public function sign(input:String, ?keyId:String):String;  
  public function verify(input:String, signature:String, ?keyId:String):Bool;
}