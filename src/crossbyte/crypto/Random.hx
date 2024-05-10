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
     private static var _nonce:Float = 0;
    
    public static function getSecureRandomBytes(length:Int, level:Int = 0, ?salt:Null<String>, ):ByteArray {
        salt = salt == null ? Std.string(Math.random() * 2147483647) : salt;
        var seed:String = salt + Std.string(NativeSys.sys_get_pid()) + Std.string(Sys.time()) + Gc.memInfo(Gc.MEM_INFO_USAGE);
        var rng:String = _getRandomWithHardwareEntropy(seed, level);
                
        var digest:Bytes = Bytes.ofString(rng);
        
        return digest;
    }
    
    private static function _getRandomWithHardwareEntropy(seed:String, level:Int):String { 
        var hash:String = seed;
        //TODO: use a higher resolution timer
        var pTime:Float = Sys.cpuTime();
        var delta:Float = 0.0;
        var lv:Float = 0.0001 * level;
        while (delta < lv) {             
            hash = Sha1.encode(hash + delta + _nonce);
            delta = Sys.cpuTime() - pTime;
           _nonce++;
        }
        return Sha256.encode(seed + hash + delta + _nonce);
    }
}