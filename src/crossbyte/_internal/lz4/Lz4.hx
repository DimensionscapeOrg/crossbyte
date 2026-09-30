package crossbyte._internal.lz4;

import crossbyte.errors.IOError;
import crossbyte.errors.RangeError;
import haxe.io.Bytes;
import haxe.ds.Vector;
#if crossbyte_lz4_native
import crossbyte.lz4.NativeLz4;
#end

/**
	The LZ4 block format: what `ByteArray.compress(LZ4)` writes, one block and
	nothing around it. `Lz4Frame` is the frame format, which carries these
	blocks with sizes and checksums.
**/
class Lz4 {
	/*
	 * LZ4 block format constants.
	 *
	 * A match is at least four bytes and reaches back at most 65535. The block
	 * has to end in at least LAST_LITERALS literal bytes, and no match may
	 * start within the last MF_LIMIT, which is what lets a decoder copy in
	 * wide steps without reading past the end.
	 */
	private static inline var MIN_MATCH:Int = 4;
	private static inline var LAST_LITERALS:Int = 5;
	private static inline var MF_LIMIT:Int = 12;
	private static inline var MAX_OFFSET:Int = 0xFFFF;
	private static inline var MAX_HASH_SIZE:Int = 1 << 16;
	private static inline var MIN_HASH_SIZE:Int = 256;
	private static inline var NIL:Int = -1;

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

	/** The most a block of `n` bytes can take compressed (LZ4_compressBound). **/
	public static inline function compressBound(n:Int):Int {
		return n + Std.int(n / 255) + 16;
	}

	public static function compress(b:Bytes):Bytes {
		#if crossbyte_lz4_native
		if (NativeLz4.isAvailable()) {
			return NativeLz4.compress(b);
		}
		#end

		var n:Int = b == null ? 0 : b.length;
		var out:Bytes = Bytes.alloc(compressBound(n));
		var written:Int = compressInto(b, 0, n, out, 0);
		return out.sub(0, written);
	}

	/**
		Compresses `n` bytes of `source` from `offset` as one block, into `out`
		from `outPos`, which must have `compressBound(n)` bytes of room.

		@return The block's length.
	**/
	public static function compressInto(source:Bytes, offset:Int, n:Int, out:Bytes, outPos:Int):Int {
		// Written straight into Bytes. It went through a ByteArray, whose
		// writeBytes takes a ByteArray: handed a plain Bytes, each literal run
		// made one from it, allocating and clearing a copy of the whole input
		// per run -- 27 GB of garbage compressing 900 KB -- where a ByteArray
		// input happened to be one already.
		var op:Int = outPos;
		var end:Int = offset + n;
		var anchor:Int = offset;

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
			var matchLimit:Int = end - LAST_LITERALS;
			var searchLimit:Int = end - MF_LIMIT;

			var i:Int = offset;
			while (i <= searchLimit) {
				var bucket:Int = __hash(source, i, mask);
				var candidate:Int = head[bucket];
				head[bucket] = i;

				if (candidate != NIL && i - candidate <= MAX_OFFSET && __matches(source, candidate, i)) {
					var length:Int = MIN_MATCH;
					while (i + length < matchLimit && source.get(candidate + length) == source.get(i + length)) {
						length++;
					}

					// One sequence: a literal run, then the match after it.
					var literals:Int = i - anchor;
					var extra:Int = length - MIN_MATCH;
					out.set(op++, (literals < 15 ? literals << 4 : 0xF0) | (extra < 15 ? extra : 0x0F));
					if (literals >= 15) {
						op = __writeLength(out, op, literals - 15);
					}
					if (literals > 0) {
						out.blit(op, source, anchor, literals);
						op += literals;
					}
					var distance:Int = i - candidate;
					out.set(op++, distance & 0xFF);
					out.set(op++, (distance >>> 8) & 0xFF);
					if (extra >= 15) {
						op = __writeLength(out, op, extra - 15);
					}

					i += length;
					anchor = i;
				} else {
					i++;
				}
			}
		}

		// The block always ends with literals and no offset, which is how a
		// decoder knows it has reached the end.
		var literals:Int = end - anchor;
		out.set(op++, literals < 15 ? literals << 4 : 0xF0);
		if (literals >= 15) {
			op = __writeLength(out, op, literals - 15);
		}
		if (literals > 0) {
			out.blit(op, source, anchor, literals);
			op += literals;
		}

		return op - outPos;
	}

	/**
	 * Write a length that did not fit in its token nibble, as 255s and a
	 * remainder. Returns where the next byte goes.
	 */
	private static inline function __writeLength(out:Bytes, op:Int, value:Int):Int {
		while (value >= 255) {
			out.set(op++, 255);
			value -= 255;
		}
		out.set(op++, value);
		return op;
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

		A block has no length of its own, so one cut short at the end of a
		literal run would read as complete. The format's end rules catch most:
		the last five bytes of a block are literals and its last match starts
		at least twelve bytes from the end, so a block that stops right after a
		short run, or soon after a match, is refused. The frame format
		(`Lz4Frame`) catches all of it, with sizes and checksums.

		@throws IOError The data is not a valid block, or ends early.
		@throws RangeError It decodes past `maxOutputSize`.
	**/
	public static function decompress(b:Bytes, maxOutputSize:Int = 0):Bytes {
		#if crossbyte_lz4_native
		if (NativeLz4.isAvailable()) {
			var native:Bytes = try {
				NativeLz4.decompress(b);
			} catch (e:String) {
				throw new IOError("Invalid LZ4 data: " + e);
			}
			if (maxOutputSize > 0 && native != null && native.length > maxOutputSize) {
				throw new RangeError("Decoded stream exceeded " + maxOutputSize + " bytes");
			}
			return native;
		}
		#end

		if (b == null || b.length == 0) {
			// Even an empty block is a token: one zero byte.
			throw new IOError("Invalid LZ4 data: no block");
		}
		var out = new Lz4Output(maxOutputSize, b.length * 4);
		decodeBlock(b, 0, b.length, out);
		return out.toBytes();
	}

	/**
		Decodes the block `source[start, end)` onto the end of `out`.

		A match may reach back into what `out` held before the block, as a
		frame's linked blocks do; the first block's reach stops at its start.
	**/
	public static function decodeBlock(source:Bytes, start:Int, end:Int, out:Lz4Output):Void {
		var iPos:Int = start;
		var blockStart:Int = out.length;
		// Where the last match began and ended, to hold the block to the end
		// rules once it is done. -1: no match yet.
		var lastMatchStart:Int = -1;
		var lastMatchEnd:Int = -1;

		while (true) {
			if (iPos >= end) {
				throw new IOError("Invalid LZ4 data: the block ends early");
			}
			var token:Int = source.get(iPos++);

			var length:Int = token >>> 4;
			if (length == 15) {
				while (true) {
					if (iPos >= end) {
						throw new IOError("Invalid LZ4 data: a literal length runs past the end");
					}
					var l:Int = source.get(iPos++);
					length += l;
					if (l != 255) {
						break;
					}
				}
			}

			// `length > end - iPos` rather than `iPos + length > end`: the
			// sum of two attacker-influenced Ints can wrap.
			if (length > end - iPos) {
				throw new IOError("Invalid LZ4 data: literals run past the end");
			}
			if (length > 0) {
				out.append(source, iPos, length);
				iPos += length;
			}

			if (iPos == end) {
				// A block ends after literals, never after a match.
				break;
			}

			if (end - iPos < 2) {
				throw new IOError("Invalid LZ4 data: a match offset is cut off");
			}
			var offset:Int = source.get(iPos) | (source.get(iPos + 1) << 8);
			iPos += 2;
			if (offset == 0 || offset > out.length) {
				throw new IOError("Invalid LZ4 data: a match reaches before the start");
			}

			length = (token & 0x0F) + MIN_MATCH;
			if (length == 19) {
				while (true) {
					if (iPos >= end) {
						throw new IOError("Invalid LZ4 data: a match length runs past the end");
					}
					var l:Int = source.get(iPos++);
					length += l;
					if (l != 255) {
						break;
					}
				}
			}

			lastMatchStart = out.length - blockStart;
			// The amplifying half: a short match length replays window bytes,
			// so this is where a bomb does its work. The output checks it
			// against the limit before it grows.
			out.copyBack(offset, length);
			lastMatchEnd = out.length - blockStart;
		}

		if (lastMatchStart >= 0) {
			var total:Int = out.length - blockStart;
			if (lastMatchEnd > total - LAST_LITERALS || lastMatchStart > total - MF_LIMIT) {
				throw new IOError("Invalid LZ4 data: the block ends too soon after a match, as a cut-off block does");
			}
		}
	}
}

/**
	Decoded LZ4 output: a Bytes that grows with it, never past a limit.
**/
@:noCompletion
class Lz4Output {
	public var length(default, null):Int = 0;

	var __bytes:Bytes;
	var __limit:Int;

	/**
		@param limit Bytes this may hold, or `0` for no limit.
		@param guess What to allocate first; grown by doubling from there.
	**/
	public function new(limit:Int, guess:Int) {
		__limit = limit > 0 ? limit : 0;
		var first:Int = guess < 64 ? 64 : guess;
		if (__limit > 0 && first > __limit) {
			first = __limit;
		}
		__bytes = Bytes.alloc(first);
	}

	public inline function append(source:Bytes, offset:Int, count:Int):Void {
		__room(count);
		__bytes.blit(length, source, offset, count);
		length += count;
	}

	/** Copies `count` bytes from `distance` back, overlapping as a run does. **/
	public function copyBack(distance:Int, count:Int):Void {
		__room(count);
		var bytes:Bytes = __bytes;
		var from:Int = length - distance;
		if (distance >= count) {
			bytes.blit(length, bytes, from, count);
		} else {
			for (i in 0...count) {
				bytes.set(length + i, bytes.get(from + i));
			}
		}
		length += count;
	}

	public function toBytes():Bytes {
		return length == __bytes.length ? __bytes : __bytes.sub(0, length);
	}

	/** Makes room for `count` more, refusing past the limit before growing. **/
	inline function __room(count:Int):Void {
		if (count > __bytes.length - length) {
			__grow(count);
		}
	}

	function __grow(count:Int):Void {
		// A difference, not a sum: both can be attacker-sized.
		if (__limit > 0 && count > __limit - length) {
			throw new RangeError("Decoded stream exceeded " + __limit + " bytes");
		}
		var size:Int = __bytes.length * 2;
		if (size - length < count) {
			size = length + count;
		}
		if (__limit > 0 && size > __limit) {
			size = __limit;
		}
		var grown:Bytes = Bytes.alloc(size);
		grown.blit(0, __bytes, 0, length);
		__bytes = grown;
	}
}
