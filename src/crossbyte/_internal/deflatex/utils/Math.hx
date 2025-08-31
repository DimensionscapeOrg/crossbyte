package crossbyte._internal.deflatex.utils;

import haxe.Exception;

class Math {
	public inline static function bitCount(v:Int) {
		var c:Int = v - ((v >> 1) & 0x55555555);
		c = ((c >> 2) & 0x33333333) + (c & 0x33333333);
		c = ((c >> 4) + c) & 0x0F0F0F0F;
		c = ((c >> 8) + c) & 0x00FF00FF;
		c = ((c >> 16) + c) & 0x0000FFFF;
		return c;
	}

	public static function toBinary(n:Int, length:UInt):String {
		var pow:Float = std.Math.pow(2, length);
		var binary:StringBuf = new StringBuf();
		if (pow < n) {
			throw new Exception("The length must be big from number ");
		}
		var shift:Int = length - 1;
		while (shift >= 0) {
			var bit:Int = (n >> shift) & 1;
			if (bit == 1) {
				binary.add("1");
			} else {
				binary.add("0");
			}
			shift--;
		}
		return binary.toString();
	}
}
