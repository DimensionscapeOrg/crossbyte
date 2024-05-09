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
    
    public static function getSecureRandomBytes(length:Int, level:Int = 0, ?seed:Null<String>, ):ByteArray {
        var salt:String = seed == null ? Math.random * 2147483647 : seed;
        var seed:String = salt + Std.string(NativeSys.sys_get_pid()) + Std.string(Sys.time()) + Gc.memInfo(Gc.MEM_INFO_USAGE);
        var rng:String = _getRandomWithHardwareEntropy(seed, level);
                
        var digest:Bytes = Bytes.ofString(rng);
        
        return digest;
    }
    
    private static function _getRandomWithHardwareEntropy(seed:String, level:Int):String { 
        var hash:String = seed;
        var pTime:Float = Sys.cpuTime();
        var delta:Float = 0.0;
        var lv:Float = 0.0001 * level;
        while (delta < lv) {             
            hash = Sha1.encode(hash + delta + counter);
            delta = Sys.cpuTime() - pTime;
           _counter++;
        }
        return Sha256.encode(seed + hash + delta + _counter);
    }
}