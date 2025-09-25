package crossbyte.crypto;

import crossbyte.io.ByteArray;
import haxe.io.Bytes;
#if (cpp && windows)
@:cppInclude("Windows.h")
@:cppInclude("bcrypt.h")
@:cppNamespaceCode('#pragma comment(lib, "bcrypt.lib")')
#end
#if (cpp && !windows)
import sys.io.File;
#end
#if php
import php.Global;
import php.Syntax;
#end

final class SecureRandom {
	public static function getSecureRandomBytes(length:Int):ByteArray {
		#if cpp
		if (length <= 0) {
			return Bytes.alloc((length < 0) ? 0 : length);
		}
		#elseif php
		return __getSecureRandomBytesPHP(length);
		#else
		throw "Secure random bytes are currently only supported on native platforms (Windows/Unix)";
		#end
	}

	#if cpp
	#if windows
	private static inline function __getSecureRandomBytesNative(length:Int):ByteArray {
		var out:Bytes = Bytes.alloc(length);

		var ok:Bool = untyped __cpp__('
			static BCRYPT_ALG_HANDLE hAlg = NULL;
			if (hAlg == NULL) {
				if (::BCryptOpenAlgorithmProvider(&hAlg, BCRYPT_RNG_ALGORITHM, NULL, 0) != 0) {
					return false;
				}
			}
			return ::BCryptGenRandom(hAlg, (PUCHAR)&{0}->b[0], {1}, 0) == 0;
		', out, length);

		if (!ok) {
			throw "BCryptGenRandom failed";
		}
		return out;
	}
	#else
	@:noCompletion static var __urandom:sys.io.FileInput = null;
	@:noCompletion static var __lock:sys.thread.Mutex = null;

	private static function __getSecureRandomBytesNative(length:Int):ByteArray {
		if (length <= 0) {
			return Bytes.alloc(length < 0 ? 0 : length);
		}

		var out:Bytes = Bytes.alloc(length);

		if (__lock == null) {
			__lock = new sys.thread.Mutex();
		}
		__lock.acquire();
		try {
			if (__urandom == null) {
				__urandom = sys.io.File.read("/dev/urandom", true);
			}

			var filled:Int = 0;
			while (filled < length) {
				var n:Int = __urandom.readBytes(out, filled, length - filled);
				if (n <= 0) {
					throw "Short read from /dev/urandom";
				}
				filled += n;
			}
		} catch (e:Dynamic) {
			try {
				__urandom.close();
			} catch (_:Dynamic) {}
			__urandom = null;
			__lock.release();
			throw "Failed to read from /dev/urandom: " + e;
		}

		__lock.release();
		return out;
	}
	#end
	#end
	#if php
	private static function __getSecureRandomBytesPHP(length:Int):ByteArray {
		if (length < 0) {
			throw "length must be >= 0";
		}
		if (length == 0) {
			return Bytes.alloc(0);
		}

		try {
			var raw:String = Global.random_bytes(length);
			return Bytes.ofData(raw);
		} catch (e:Dynamic) {
			throw "Error generating random bytes: " + e;
		}
	}
	#end
}
