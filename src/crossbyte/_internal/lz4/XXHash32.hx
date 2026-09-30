package crossbyte._internal.lz4;

import haxe.io.Bytes;

/**
	xxHash32 (https://github.com/Cyan4973/xxHash), which the LZ4 frame format
	uses for its descriptor, block and content checksums.
**/
@:noCompletion
class XXHash32 {
	static inline var PRIME1:Int = 0x9E3779B1;
	static inline var PRIME2:Int = 0x85EBCA77;
	static inline var PRIME3:Int = 0xC2B2AE3D;
	static inline var PRIME4:Int = 0x27D4EB2F;
	static inline var PRIME5:Int = 0x165667B1;

	/** The hash of `length` bytes of `data` from `offset`. **/
	public static function hash(data:Bytes, offset:Int, length:Int, seed:Int = 0):Int {
		var p:Int = offset;
		var end:Int = offset + length;
		var h:Int;

		if (length >= 16) {
			var limit:Int = end - 16;
			var v1:Int = (seed + PRIME1 + PRIME2) | 0;
			var v2:Int = (seed + PRIME2) | 0;
			var v3:Int = seed;
			var v4:Int = (seed - PRIME1) | 0;
			while (p <= limit) {
				v1 = __round(v1, __read32(data, p));
				v2 = __round(v2, __read32(data, p + 4));
				v3 = __round(v3, __read32(data, p + 8));
				v4 = __round(v4, __read32(data, p + 12));
				p += 16;
			}
			h = (__rotl(v1, 1) + __rotl(v2, 7) + __rotl(v3, 12) + __rotl(v4, 18)) | 0;
		} else {
			h = (seed + PRIME5) | 0;
		}

		h = (h + length) | 0;

		while (p + 4 <= end) {
			h = __mul(__rotl((h + __mul(__read32(data, p), PRIME3)) | 0, 17), PRIME4);
			p += 4;
		}
		while (p < end) {
			h = __mul(__rotl((h + __mul(data.get(p), PRIME5)) | 0, 11), PRIME1);
			p++;
		}

		h ^= h >>> 15;
		h = __mul(h, PRIME2);
		h ^= h >>> 13;
		h = __mul(h, PRIME3);
		h ^= h >>> 16;
		return h;
	}

	static inline function __round(acc:Int, input:Int):Int {
		return __mul(__rotl((acc + __mul(input, PRIME2)) | 0, 13), PRIME1);
	}

	static inline function __rotl(x:Int, r:Int):Int {
		return (x << r) | (x >>> (32 - r));
	}

	static inline function __read32(data:Bytes, at:Int):Int {
		return data.get(at) | (data.get(at + 1) << 8) | (data.get(at + 2) << 16) | (data.get(at + 3) << 24);
	}

	/**
		The low 32 bits of a product. Haxe's `*` is not 32-bit on js, where a
		product past 2^53 loses its low bits, so it is done in halves: each
		partial product stays under 2^49, exact everywhere.
	**/
	static inline function __mul(a:Int, b:Int):Int {
		return ((a & 0xFFFF) * b + (((a >>> 16) * b) << 16)) | 0;
	}
}
