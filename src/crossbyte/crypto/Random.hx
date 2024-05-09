package crossbyte.crypto;
import crossbyte.io.ByteArray;
import haxe.io.Bytes;

import cpp.NativeSys;
/**
 * ...
 * @author Christopher Speciale
 */
class Random 
{	
	public static function getSecureRandomBytes(length:Int):ByteArray{		
		var seed:String = "ABCDEF" + Std.string(NativeSys.sys_get_pid()) + Std.string(Sys.time()) + Std.string(Date.now().getTime());
		
		var seedBytes:Bytes = Bytes.ofString(seed);
		
		var randomBytes:ByteArray = new ByteArray(length);
	
		var seedLength:Int = seedBytes.length;
		
		for (i in 0...length){
			var randomIndex:Int = Std.int(Math.random() * seedLength);
			var byte:Int = seedBytes.get(randomIndex);
			
			randomBytes.writeByte(byte);
		}
		
		return randomBytes;		
	}
	
}