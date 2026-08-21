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

	/**
	 * A 32-bit multiply that wraps, on every target.
	 *
	 * Every hash below multiplies by a constant chosen to overflow -- that
	 * overflow is what mixes the bits, and none of these functions works
	 * without it. On a target whose `Int` is 32 bits the wrap is free. On
	 * JavaScript an `Int` is a double, so the product simply grows: it passes
	 * 2^53, starts losing its low bits, and comes back as a number that is not
	 * a 32-bit hash of anything.
	 *
	 * That is not a rounding difference, it is a different function.
	 * `fnv1a32` of "sendData" is 622618135 everywhere else and was
	 * -20905118279726560 here, so two CrossByte programs hashing the same
	 * bytes disagreed if one of them was JavaScript -- which matters the
	 * moment a hash is written to a wire, a file, or an opcode table built at
	 * compile time and read at run time.
	 *
	 * `Math.imul` is exactly a wrapping 32-bit multiply and every browser and
	 * Node has it.
	 */
	@:pure public static inline function mul32(a:Int, b:Int):Int {
		// `!macro` matters: macro code always runs on the eval interpreter,
		// whose Int is 32 bits and wraps on its own. Without the guard a build
		// targeting js would try to put js.Syntax into the macro context,
		// where there is no JavaScript to put it in.
		#if (js && !macro)
		return js.Syntax.code("Math.imul({0}, {1})", a, b);
		#else
		return a * b;
		#end
	}

	/** Computes a 32-bit FNV-1a hash for raw bytes. */
	@:pure public static inline function fnv1a32(bytes:Bytes):Int {
		var hash:Int = 0x811C9DC5;
		var prime:Int = 0x01000193;
		for (i in 0...bytes.length) {
			hash ^= bytes.get(i);
			hash = mul32(hash, prime);
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
		z = mul32(z, MM3_C1);
		z ^= (z >>> 13);
		z = mul32(z, MM3_C2);
		z ^= (z >>> 16);
		return z;
	}

	/** Combines two 32-bit hash values into a single mixed hash. */
	@:pure public static inline function combineHash32(a:Int, b:Int):Int {
		return fmix32(a ^ fmix32(b + PHI32));
	}
}
