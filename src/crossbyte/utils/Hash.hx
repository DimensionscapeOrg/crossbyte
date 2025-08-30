package crossbyte.utils;

import haxe.io.Bytes;

class Hash {
	public static inline function fnv1a32(bytes:Bytes):Int {
		var hash:Int = 0x811c9dc5;
		var prime:Int = 0x01000193;

		for (i in 0...bytes.length) {
			hash ^= bytes.get(i);
			hash = (hash * prime) & 0xFFFFFFFF;
		}

		return hash;
	}
}
