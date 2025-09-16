package crossbyte._internal.php;

import haxe.io.Bytes;
import haxe.ds.StringMap;

typedef PHPResponse = {
  var status:Int;
  var headers:StringMap<String>; // lowercased keys
  var body:Bytes;
}