package crossbyte._internal.lz4;

import crossbyte.io.ByteArray;
import haxe.io.Bytes;
#if crossbyte_lz4_native
import crossbyte.lz4.NativeLz4;
#end

class Lz4 {
	@:noCompletion private static inline function __byte(source:Bytes, index:Int):Int {
		return source.get(index) & 0xFF;
	}

	public static inline function compress(b:Bytes):Bytes {
		#if crossbyte_lz4_native
		if (NativeLz4.isAvailable()) {
			return NativeLz4.compress(b);
		}
		#end

		var output = new ByteArray();
		var literalLength = b.length;

		if (literalLength >= 15) {
			output.writeByte(0xF0);
			var remaining = literalLength - 15;
			while (remaining >= 255) {
				output.writeByte(255);
				remaining -= 255;
			}
			output.writeByte(remaining);
		} else {
			output.writeByte(literalLength << 4);
		}

		output.writeBytes(b, 0, b.length);
		return output;
	}

	public static inline function decompress(b:Bytes):Bytes {
		#if crossbyte_lz4_native
		if (NativeLz4.isAvailable()) {
			return NativeLz4.decompress(b);
		}
		#end

		var iLen = b.length;
		var oBuf = new ByteArray();
		var iPos = 0;
		var oPos = 0;

		while (iPos < iLen) {
			var token = __byte(b, iPos++);

			var clen = token >>> 4;
			if (clen == 15) {
				while (true) {
					if (iPos >= iLen) {
						throw "Could not perform decompression";
					}
					var l = __byte(b, iPos++);
					clen += l;
					if (l != 255) {
						break;
					}
				}
			}

			var literalEnd = iPos + clen;
			if (literalEnd > iLen) {
				throw "Could not perform decompression";
			}
			while (iPos < literalEnd) {
				oBuf[oPos++] = __byte(b, iPos++);
			}

			if (iPos == iLen) {
				break;
			}

			if (iPos + 1 >= iLen) {
				throw "Could not perform decompression";
			}

			var mOffset = __byte(b, iPos + 0) | (__byte(b, iPos + 1) << 8);
			if (mOffset == 0 || mOffset > oPos) {
				throw "Could not perform decompression";
			}
			iPos += 2;

			clen = (token & 0x0F) + 4;
			if (clen == 19) {
				while (true) {
					if (iPos >= iLen) {
						throw "Could not perform decompression";
					}
					var l = __byte(b, iPos++);
					clen += l;
					if (l != 255) {
						break;
					}
				}
			}

			var mPos = oPos - mOffset;
			var matchEnd = oPos + clen;
			while (oPos < matchEnd) {
				oBuf[oPos++] = oBuf[mPos++];
			}
		}

		#if js
		return Bytes.ofData(untyped oBuf.buffer);
		#elseif hl
		return oBuf.getData().toBytes(oBuf.length);
		#else
		var bOut = Bytes.alloc(oPos);
		for (i in 0...oPos) {
			bOut.set(i, oBuf[i]);
		}
		return bOut;
		#end
	}
}
