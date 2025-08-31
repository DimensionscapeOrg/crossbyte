package crossbyte._internal.lz4;

import crossbyte.io.ByteArray;
import haxe.io.Bytes;
import haxe.io.Int32Array;
import haxe.io.UInt8Array;

class Lz4 {
	static var hashTable:ByteArray = new ByteArray(65536);

	static inline function encodeBound(size:Int):Int {
		return untyped size > 0x7e000000 ? 0 : size + (size / 255 | 0) + 16;
	}

	public static inline function compress(b:Bytes):Bytes {
		var iBuf:ByteArray = new ByteArray(b.length);
		for (i in 0...b.length)
			iBuf[i] = b.get(i);

		var iLen = iBuf.length;
		if (iLen >= 0x7e000000) {
			throw("LZ4 range error");
			return null;
		}

		// "The last match must start at least 12 bytes before end of block"
		var lastMatchPos = iLen - 12;

		// "The last 5 bytes are always literals"
		var lastLiteralPos = iLen - 5;

		// if (hashTable == null)
		/*for (i in 0...hashTable.length) {
			hashTable[i] = 0;
		}*/
		hashTable = new ByteArray(65536);

		var oLen = encodeBound(iLen);
		var oBuf = new ByteArray(oLen);
		var iPos = 0;
		var oPos = 0;
		var anchorPos = 0;

		// Sequence-finding loop
		while (true) {
			var refPos = 0;
			var mOffset = 0;
			var sequence = iBuf[iPos] << 8 | iBuf[iPos + 1] << 16 | iBuf[iPos + 2] << 24;

			// Match-finding loop
			while (iPos <= lastMatchPos) {
				sequence = sequence >>> 8 | iBuf[iPos + 3] << 24;
				var hash = (sequence * 0x9e37 & 0xffff) + (sequence * 0x79b1 >>> 16) & 0xffff;

				hash = ((hash >> 16) ^ hash) >>> 0 & 0xffff;

				refPos = hashTable[hash] - 1;
				hashTable[hash] = iPos + 1;
				mOffset = iPos - refPos;
				if (mOffset < 65536
					&& iBuf[refPos + 0] == ((sequence) & 0xff)
					&& iBuf[refPos + 1] == ((sequence >>> 8) & 0xff)
					&& iBuf[refPos + 2] == ((sequence >>> 16) & 0xff)
					&& iBuf[refPos + 3] == ((sequence >>> 24) & 0xff)) {
					break;
				}
				iPos += 1;
			}

			// No match found
			if (iPos > lastMatchPos)
				break;

			// Match found
			var lLen = iPos - anchorPos;
			var mLen = iPos;
			iPos += 4;
			refPos += 4;
			while (iPos < lastLiteralPos && iBuf[iPos] == iBuf[refPos]) {
				iPos += 1;
				refPos += 1;
			}
			mLen = iPos - mLen;
			var token = mLen < 19 ? mLen - 4 : 15;

			// Write token, length of literals if needed
			if (lLen >= 15) {
				oBuf[oPos++] = 0xf0 | token;
				var l = lLen - 15;
				while (l >= 255) {
					oBuf[oPos++] = 255;
					l -= 255;
				}
				oBuf[oPos++] = l;
			} else {
				oBuf[oPos++] = (lLen << 4) | token;
			}

			// Write literals
			while (lLen-- > 0) {
				oBuf[oPos++] = iBuf[anchorPos++];
			}

			if (mLen == 0)
				break;

			// Write offset of match
			oBuf[oPos + 0] = mOffset;
			oBuf[oPos + 1] = mOffset >>> 8;
			oPos += 2;

			// Write length of match if needed
			if (mLen >= 19) {
				var l = mLen - 19;
				while (l >= 255) {
					oBuf[oPos++] = 255;
					l -= 255;
				}
				oBuf[oPos++] = l;
			}

			anchorPos = iPos;
		}

		// Last sequence is literals only
		var lLen = iLen - anchorPos;
		if (lLen >= 15) {
			oBuf[oPos++] = 0xf0;
			var l = lLen - 15;
			while (l >= 255) {
				oBuf[oPos++] = 255;
				l -= 255;
			}
			oBuf[oPos++] = l;
		} else {
			oBuf[oPos++] = lLen << 4;
		}
		while (lLen-- > 0) {
			oBuf[oPos++] = iBuf[anchorPos++];
		}

		#if js
		return Bytes.ofData(untyped oBuf.buffer.slice(0, oPos));
		#elseif hl
		return oBuf.getData().toBytes(oPos);
		#else
		var bOut = Bytes.alloc(oPos);
		for (i in 0...oPos) {
			bOut.set(i, oBuf[i]);
		}
		return bOut;
		#end
	}

	public static inline function decompress(b:Bytes):Bytes {
		var iBuf:ByteArray = new ByteArray(b.length);
		for (i in 0...b.length)
			iBuf[i] = b.get(i);

		var iLen = iBuf.length;
		var oBuf = new ByteArray();
		var iPos = 0;
		var oPos = 0;

		while (iPos < iLen) {
			var token = iBuf[iPos++];

			// Literals
			var clen = token >>> 4;

			// Length of literals
			if (clen != 0) {
				if (clen == 15) {
					var l = 0;
					while (true) {
						l = iBuf[iPos++];
						if (l != 255)
							break;
						clen += 255;
					}
					clen += l;
				}

				// Copy literals
				var end = iPos + clen;

				while (iPos < end) {
					oBuf[oPos++] = iBuf[iPos++];
				}
				if (iPos == iLen)
					break;
			}

			// Match
			var mOffset = iBuf[iPos + 0] | (iBuf[iPos + 1] << 8);
			if (mOffset == 0 || mOffset > oPos)
				throw "Could not perform decompression";
			iPos += 2;

			// Length of match
			clen = (token & 0x0f) + 4;
			if (clen == 19) {
				var l = 0;
				while (true) {
					l = iBuf[iPos++];
					if (l != 255)
						break;
					clen += 255;
				}
				clen += l;
			}

			// Copy match
			var mPos = oPos - mOffset;
			var end = oPos + clen;
			while (oPos < end) {
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
