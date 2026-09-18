package crossbyte._internal.lz4;

import crossbyte.io.ByteArray;
import haxe.io.Bytes;
import haxe.ds.Vector;
#if crossbyte_lz4_native
import crossbyte.lz4.NativeLz4;
#end

class Lz4 {
	/*
	 * LZ4 block format constants.
	 *
	 * A match is at least four bytes and reaches back at most 65535. The block
	 * has to end in at least LAST_LITERALS literal bytes, and no match may
	 * start within the last MF_LIMIT, which is what lets a decoder copy in
	 * wide steps without reading past the end.
	 */
	private static final MIN_MATCH:Int = 4;
	private static final LAST_LITERALS:Int = 5;
	private static final MF_LIMIT:Int = 12;
	private static final MAX_OFFSET:Int = 0xFFFF;
	private static final MAX_HASH_SIZE:Int = 1 << 16;
	private static final MIN_HASH_SIZE:Int = 256;
	private static final NIL:Int = -1;

	@:noCompletion private static inline function __byte(source:Bytes, index:Int):Int {
		return source.get(index) & 0xFF;
	}

	/**
	 * Hash the four bytes at `at`.
	 *
	 * The multiply is spelled as a shift and a subtract because Haxe's `*` is
	 * not 32-bit on js: a product past 2^53 loses its low bits there and would
	 * hash differently than on every other target.
	 */
	private static inline function __hash(source:Bytes, at:Int, mask:Int):Int {
		var h:Int = source.get(at);
		h = (((h << 5) - h) + source.get(at + 1)) & 0xFFFFFF;
		h = (((h << 5) - h) + source.get(at + 2)) & 0xFFFFFF;
		h = (((h << 5) - h) + source.get(at + 3)) & 0xFFFFFF;
		return (h ^ (h >>> 12)) & mask;
	}

	private static inline function __matches(source:Bytes, earlier:Int, at:Int):Bool {
		return source.get(earlier) == source.get(at)
			&& source.get(earlier + 1) == source.get(at + 1)
			&& source.get(earlier + 2) == source.get(at + 2)
			&& source.get(earlier + 3) == source.get(at + 3);
	}

	/**
	 * Write a length that did not fit in its token nibble, as 255s and a
	 * remainder.
	 */
	private static function __writeLength(output:ByteArray, value:Int):Void {
		while (value >= 255) {
			output.writeByte(255);
			value -= 255;
		}
		output.writeByte(value);
	}

	/**
	 * Write one sequence: a literal run, then the match that follows it.
	 */
	private static function __writeSequence(output:ByteArray, source:Bytes, anchor:Int, literals:Int, offset:Int, matchLength:Int):Void {
		var extra:Int = matchLength - MIN_MATCH;
		output.writeByte((literals < 15 ? literals << 4 : 0xF0) | (extra < 15 ? extra : 0x0F));

		if (literals >= 15) {
			__writeLength(output, literals - 15);
		}
		if (literals > 0) {
			output.writeBytes(source, anchor, literals);
		}

		output.writeByte(offset & 0xFF);
		output.writeByte((offset >>> 8) & 0xFF);

		if (extra >= 15) {
			__writeLength(output, extra - 15);
		}
	}

	public static function compress(b:Bytes):Bytes {
		#if crossbyte_lz4_native
		if (NativeLz4.isAvailable()) {
			return NativeLz4.compress(b);
		}
		#end

		var output = new ByteArray();
		var n:Int = b.length;
		var anchor:Int = 0;

		// Below MF_LIMIT the format has no room for a match at all, and the
		// whole block goes out as the trailing literal run written afterwards.
		if (n >= MF_LIMIT) {
			var buckets:Int = MIN_HASH_SIZE;
			while (buckets < MAX_HASH_SIZE && buckets < n) {
				buckets <<= 1;
			}
			var mask:Int = buckets - 1;

			var head:Vector<Int> = new Vector<Int>(buckets);
			for (i in 0...buckets) {
				head[i] = NIL;
			}

			// A match may extend no further than this, leaving the tail
			// literal as the format requires.
			var matchLimit:Int = n - LAST_LITERALS;
			var searchLimit:Int = n - MF_LIMIT;

			var i:Int = 0;
			while (i <= searchLimit) {
				var bucket:Int = __hash(b, i, mask);
				var candidate:Int = head[bucket];
				head[bucket] = i;

				if (candidate != NIL && i - candidate <= MAX_OFFSET && __matches(b, candidate, i)) {
					var length:Int = MIN_MATCH;
					while (i + length < matchLimit && b.get(candidate + length) == b.get(i + length)) {
						length++;
					}

					__writeSequence(output, b, anchor, i - anchor, i - candidate, length);

					i += length;
					anchor = i;
				} else {
					i++;
				}
			}
		}

		// The block always ends with literals and no offset, which is how a
		// decoder knows it has reached the end.
		var literals:Int = n - anchor;
		output.writeByte(literals < 15 ? literals << 4 : 0xF0);
		if (literals >= 15) {
			__writeLength(output, literals - 15);
		}
		if (literals > 0) {
			output.writeBytes(b, anchor, literals);
		}

		return output;
	}

	/**
		@param maxOutputSize Bytes to produce before giving up, or `0` for no
			   limit. LZ4 ratios have no ceiling either -- the format's own
			   match encoding will happily replay four bytes of window a
			   million times -- so anything decoding a stream it did not author
			   wants to name one.

		The limit is checked before each write rather than after the decode, so
		a stream that keeps expanding is abandoned partway and the memory is
		never taken. The native decoder cannot do that: it returns a finished
		buffer, so its result is measured after the fact and the allocation has
		already happened. That path is opt-in and off by default.
	**/
	public static inline function decompress(b:Bytes, maxOutputSize:Int = 0):Bytes {
		#if crossbyte_lz4_native
		if (NativeLz4.isAvailable()) {
			var native:Bytes = NativeLz4.decompress(b);
			if (maxOutputSize > 0 && native != null && native.length > maxOutputSize) {
				throw "Decoded stream exceeded " + maxOutputSize + " bytes";
			}
			return native;
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
			if (clen > 0) {
				// `clen > max - oPos` rather than `oPos + clen > max`: the sum
				// of two attacker-influenced Ints can wrap, and a wrapped sum
				// passes the test it was meant to fail.
				if (maxOutputSize > 0 && clen > maxOutputSize - oPos) {
					throw "Decoded stream exceeded " + maxOutputSize + " bytes";
				}
				oBuf.position = oPos;
				oBuf.writeBytes(b, iPos, clen);
				iPos = literalEnd;
				oPos += clen;
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

			// The amplifying half: a short match length replays window bytes,
			// so this is where a bomb does its work.
			if (maxOutputSize > 0 && clen > maxOutputSize - oPos) {
				throw "Decoded stream exceeded " + maxOutputSize + " bytes";
			}

			var mPos = oPos - mOffset;
			var matchEnd = oPos + clen;
			while (oPos < matchEnd) {
				oBuf[oPos++] = oBuf[mPos++];
			}
		}

		// There was a browser branch here returning `Bytes.ofData(untyped
		// oBuf.buffer)`. `oBuf` is a ByteArray and has no `buffer`, so that
		// passed `undefined` to `ofData`, which reads `.hxBytes` off it and
		// threw -- every LZ4 decode in a page, since the branch was written.
		// Node never took it, so the js suite passed throughout.
		//
		// Even given a `buffer` it would have been wrong: that is the whole
		// backing store, where only the first `oPos` bytes were written. The
		// generic path below allocates exactly that many and is what every
		// other target already used.
		#if hl
		return oBuf.getData().toBytes(oBuf.length);
		#else
		var bOut = Bytes.alloc(oPos);
		if (oPos > 0) {
			bOut.blit(0, oBuf, 0, oPos);
		}
		return bOut;
		#end
	}
}
