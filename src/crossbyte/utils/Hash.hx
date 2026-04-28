package crossbyte.utils;

import haxe.io.Bytes;

/** Small collection of fast non-cryptographic hash helpers used across CrossByte. */
class Hash {
	/** 32-bit golden ratio constant used during finalization. */
	public static inline final PHI32:Int = 0x9E3779B9;
	/** Murmur-style mix constant 1. */
	public static inline final MM3_C1:Int = 0x85EBCA6B;
	/** Murmur-style mix constant 2. */
	public static inline final MM3_C2:Int = 0xC2B2AE35;

	/** Computes a 32-bit FNV-1a hash for raw bytes. */
	@:pure public static inline function fnv1a32(bytes:Bytes):Int {
		var hash:Int = 0x811C9DC5;
		var prime:Int = 0x01000193;
		for (i in 0...bytes.length) {
			hash ^= bytes.get(i);
			hash = (hash * prime);
		}
		return hash;
	}

	/** Computes a 32-bit FNV-1a hash for a string's UTF-8 bytes. */
	@:pure public static inline function fnv1a32String(s:String):Int {
		return fnv1a32(Bytes.ofString(s));
	}

	/** Finalizes a 32-bit hash value with an avalanche mix. */
	@:pure public static inline function fmix32(z:Int):Int {
		z += PHI32;
		z ^= (z >>> 16);
		z *= MM3_C1;
		z ^= (z >>> 13);
		z *= MM3_C2;
		z ^= (z >>> 16);
		return z;
	}

	/** Combines two 32-bit hash values into a single mixed hash. */
	@:pure public static inline function combineHash32(a:Int, b:Int):Int {
		return fmix32(a ^ fmix32(b + PHI32));
	}
}
