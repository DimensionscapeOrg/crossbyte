package crossbyte.crypto;
#if cpp
import cpp.vm.Gc;
import cpp.NativeSys;
import sys.io.File;
import sys.io.FileInput;
#end

import crossbyte.io.ByteArray;
import haxe.crypto.Sha1;
import haxe.crypto.Sha256;
import haxe.io.Bytes;


/**
 * ...
 * @author Christopher Speciale
 */
class Random
{
	private static var _nonce:Float = 0;

	public static function getSecureRandomBytes(length:Int, level:Int = 0):ByteArray
	{	
		#if cpp
		return cpp_getSecureRandomBytes(length, level);
		#else
		return _getSecureRandomBytes(length, level);
		#end
	}

	#if cpp
	private static function cpp_getSecureRandomBytes(length:Int, level:Int = 0):ByteArray{
		#if windows
		var salt:String = Std.string(Math.random());
		#else
		
		var randomBytes:Bytes = Bytes.alloc(length);
		var fInput:FileInput = File.read("/dev/urandom");

		fInput.readBytes(randomBytes, 0, length);
		fInput.close();
		
		var salt:String = randomBytes.toHex();
		#end
		
		var seed:String = salt + Std.string(NativeSys.sys_get_pid()) + Std.string(Sys.time()) + Gc.memInfo(Gc.MEM_INFO_USAGE) + length + level;
		var rng:String = _getRandomWithHardwareEntropy(seed, level);
		var digest:Bytes = Bytes.ofHex(rng);

		return _getBytesOfLength(length, digest);
	}
	
	private static function _getRandomWithHardwareEntropy(seed:String, level:Int):String
	{

		var hash:String = seed;
		// TODO: use a higher resolution timer
		var pTime:Float = Sys.cpuTime();
		var delta:Float = 0.0;
		var lv:Float = 0.0001 * level;
		var preHash:String = Sha256.encode(hash + pTime + _nonce + lv);

		while (delta < lv)
		{
			hash = Sha1.encode(hash + delta + _nonce + lv);
			delta = Sys.cpuTime() - pTime;
			_nonce++;
		}
		return Sha256.encode(seed + hash + delta + _nonce) + preHash;
	}	
	#else
	private static function _getSecureRandomBytes(length:Int, level:Int = 0):ByteArray {
        var randomBytes:Bytes = Bytes.alloc(length);
        for (i in 0...length) {
            randomBytes.b[i] = Std.random(256);
        }

        var salt:String = randomBytes.toHex();
        var seed:String = salt + Std.string(Sys.time()) + length + level;
        var rng:String = _getRandomWithEntropy(seed, level);
        var digest:Bytes = Bytes.ofHex(rng);

        return _getBytesOfLength(length, digest);
    }
	#end

	private static function _getBytesOfLength(len:Int, hb:Bytes):Bytes
	{
		var b:Bytes = Bytes.alloc(len);
		var start:Int = Std.int(_nonce % hb.length);
		var r:Int = 64 - start;
		var multiBlit:Bool = len > r;

		if (multiBlit)
		{
			b.blit(0, hb, start, r);

			var pos:Int = r;
			var remaining:Int = 0;

			while (pos < len && (remaining = len - pos) > 64)
			{
				b.blit(pos, hb, 0, 64);
				pos += 64;
			}

			b.blit(pos, hb, 0, remaining);
		}
		else {
			b.blit(0, hb, start, len);
		}
		return b;
	}
}