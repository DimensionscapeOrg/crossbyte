package crossbyte._internal.php;

import haxe.ds.StringMap;
import haxe.io.Bytes;

typedef PHPRequest = {
  var scriptFilename:String;   
  var requestMethod:String;  
  var requestUri:String;   
  @:optional var scriptName:String; 
  @:optional var queryString:String;
  @:optional var contentType:String;
  @:optional var remoteAddr:String;
  @:optional var serverName:String;
  @:optional var serverPort:String;
  @:optional var extraHeaders:StringMap<String>;
  @:optional var body:Bytes;
}