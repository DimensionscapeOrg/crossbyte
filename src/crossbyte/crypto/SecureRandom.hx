package crossbyte.crypto;

import crossbyte.io.ByteArray;
import haxe.io.Bytes;
#if cpp
import sys.io.File;
#end

#if (cpp && windows)
@:cppInclude("Windows.h")
@:cppInclude("bcrypt.h")
@:cppNamespaceCode('#pragma comment(lib, "bcrypt.lib")')
#end
final class SecureRandom {
	public static function getSecureRandomBytes(length:Int):ByteArray {
		#if cpp
		return __getSecureRandomBytesNative(length);
		#else
		throw "Secure random bytes are currently only supported on native platforms (Windows/Unix)";
		#end
	}

	#if cpp
	#if windows
	private static function __getSecureRandomBytesNative(length:Int):ByteArray {
		var randomBytes = Bytes.alloc(length);

		// Pass the raw buffer pointer using __cpp__
		var success = untyped __cpp__('::BCryptGenRandom(NULL, (PUCHAR)&{0}->b[0], {1}, 0x00000002) == 0', randomBytes, length);

		if (!success)
			throw "Failed to generate secure random bytes using BCryptGenRandom.";

		return randomBytes;
	}
	#else
	// Unix fallback
	private static function __getSecureRandomBytesNative(length:Int):ByteArray {
		var randomBytes = Bytes.alloc(length);
		try {
			var file = sys.io.File.read("/dev/urandom");
			file.readBytes(randomBytes, 0, length);
			file.close();
		} catch (e:Dynamic) {
			throw "Failed to read from /dev/urandom: " + e;
		}
		return randomBytes;
	}
	#end
	#end
}
