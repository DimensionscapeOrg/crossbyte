package crossbyte.auth.jwt;
enum abstract JWTAlgorithm(String) from String to String {
  var HS256:String = "HS256"; 
  var HS384:String = "HS384";
  var HS512:String = "HS512";
  var RS256:String = "RS256";  
  var ES256:String = "ES256";
  var EdDSA:String = "EdDSA"; 
  var NONE:String = "none";
}