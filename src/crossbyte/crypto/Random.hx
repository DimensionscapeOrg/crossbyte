package crossbyte.crypto;
import cpp.vm.Gc;
import crossbyte.io.ByteArray;
import haxe.crypto.Sha1;
import haxe.crypto.Sha256;
import haxe.io.Bytes;

import cpp.NativeSys;
/**
 * ...
 * @author Christopher Speciale
 */
class Random 
{	
    private static var _counter:Float = 0;
	
    public static function getSecureRandomBytes(length:Int):ByteArray {
		//Dont use environment variables for this
        var salt:String = #if more_secure_random_bytes Sys.getEnv(RANDOM_BYTES_SALT) #else "ABCDEF";
        var seed:String = salt + Std.string(NativeSys.sys_get_pid()) + Std.string(Sys.cpuTime()) + Gc.memInfo(Gc.MEM_INFO_USAGE);
        var rng:String = _getRandomWithHardwareEntropy(seed);
		        
        var digest:Bytes = Bytes.ofString(rng);
		
        return digest;
    }
	
    private static function _getRandomWithHardwareEntropy(seed:String):String {
        var pTime:Float = Sys.cpuTime();
        var delta:Float = 0.0;
        while (delta < 0.001) {
			_counter++;
            seed = Sha256.encode(seed + _counter + delta);
            delta = Sys.cpuTime() - pTime;
        }
        return seed;
    }
}