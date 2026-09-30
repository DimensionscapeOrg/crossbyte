package crossbyte._internal.lz4;

import crossbyte._internal.lz4.Lz4.Lz4Output;
import crossbyte.errors.IOError;
import crossbyte.errors.RangeError;
import haxe.io.Bytes;

/**
	The LZ4 frame format (lz4_Frame_format.md): what the `lz4` tool writes and
	reads, and what `.lz4` files hold. Blocks of the block format, each with
	its size, between a descriptor and an end mark, with checksums.

	Unlike a bare block, a frame says where it ends and what it should decode
	to, so one cut short or damaged is always refused.
**/
@:noCompletion
class Lz4Frame {
	static inline var MAGIC:Int = 0x184D2204;
	static inline var SKIPPABLE:Int = 0x184D2A50;

	/*
	 * What this writes: version 01, independent blocks, the content size and
	 * a content checksum (0x6C), and blocks of up to 4 MB (0x70), the lz4
	 * tool's own default. Independent blocks lose no matches here -- the
	 * block encoder reaches back 64 KB -- and one-shot input rarely needs
	 * more than one.
	 */
	static inline var FLG:Int = 0x6C;
	static inline var BD:Int = 0x70;
	static inline var BLOCK_MAX:Int = 4 << 20;

	public static function compress(input:Bytes):Bytes {
		var n:Int = input == null ? 0 : input.length;
		var blocks:Int = Std.int((n + BLOCK_MAX - 1) / BLOCK_MAX);
		var room:Int = 4 + 11 + 4 + 4;
		var left:Int = n;
		for (i in 0...blocks) {
			var size:Int = left < BLOCK_MAX ? left : BLOCK_MAX;
			room += 4 + Lz4.compressBound(size);
			left -= size;
		}
		var out:Bytes = Bytes.alloc(room);
		var p:Int = 0;

		__write32(out, p, MAGIC);
		p += 4;
		var descriptor:Int = p;
		out.set(p++, FLG);
		out.set(p++, BD);
		// The content size, 64-bit little-endian; a Bytes is under 2^31.
		__write32(out, p, n);
		__write32(out, p + 4, 0);
		p += 8;
		var headerChecksum:Int = (XXHash32.hash(out, descriptor, p - descriptor) >>> 8) & 0xFF;
		out.set(p++, headerChecksum);

		var offset:Int = 0;
		while (offset < n) {
			var size:Int = n - offset < BLOCK_MAX ? n - offset : BLOCK_MAX;
			var written:Int = Lz4.compressInto(input, offset, size, out, p + 4);
			if (written < size) {
				__write32(out, p, written);
				p += 4 + written;
			} else {
				// Stored as it is, flagged by the size's high bit, where
				// compressing did not make it smaller.
				__write32(out, p, size | 0x80000000);
				out.blit(p + 4, input, offset, size);
				p += 4 + size;
			}
			offset += size;
		}

		__write32(out, p, 0);
		p += 4;
		__write32(out, p, XXHash32.hash(input == null ? Bytes.alloc(0) : input, 0, n));
		p += 4;
		return out.sub(0, p);
	}

	/**
		Decodes every frame in `input`, in order, skipping skippable frames.

		@param maxOutputSize Bytes to produce before giving up, or `0` for no
		       limit. A frame that states a content size past it is refused
		       before anything is decoded.
		@throws IOError The data is not LZ4 frames, or is damaged or cut short.
		@throws RangeError It decodes past `maxOutputSize`.
	**/
	public static function decompress(input:Bytes, maxOutputSize:Int = 0):Bytes {
		var n:Int = input == null ? 0 : input.length;
		if (n == 0) {
			throw new IOError("Invalid LZ4 frame data: no frame");
		}
		var out = new Lz4Output(maxOutputSize, n * 4);
		var p:Int = 0;

		while (p < n) {
			__need(input, p, 4);
			var magic:Int = __read32(input, p);
			p += 4;

			if ((magic & 0xFFFFFFF0) == SKIPPABLE) {
				__need(input, p, 4);
				var skip:Int = __read32(input, p);
				p += 4;
				if (skip < 0 || skip > n - p) {
					throw new IOError("Invalid LZ4 frame data: a skippable frame runs past the end");
				}
				p += skip;
				continue;
			}
			if (magic != MAGIC) {
				throw new IOError("Invalid LZ4 frame data: " + (p == 4 ? "no LZ4 frame" : "what follows a frame is not another frame"));
			}

			__need(input, p, 3);
			var descriptor:Int = p;
			var flg:Int = input.get(p++);
			var bd:Int = input.get(p++);
			if ((flg >> 6) != 1) {
				throw new IOError("Invalid LZ4 frame data: version " + (flg >> 6));
			}
			if ((flg & 0x02) != 0 || (bd & 0x8F) != 0) {
				throw new IOError("Invalid LZ4 frame data: reserved bits are set");
			}
			var independent:Bool = (flg & 0x20) != 0;
			var blockChecksums:Bool = (flg & 0x10) != 0;
			var hasContentSize:Bool = (flg & 0x08) != 0;
			var contentChecksum:Bool = (flg & 0x04) != 0;
			if ((flg & 0x01) != 0) {
				throw new IOError("Unsupported LZ4 frame data: it needs a dictionary");
			}
			var sizeId:Int = (bd >> 4) & 7;
			if (sizeId < 4) {
				throw new IOError("Invalid LZ4 frame data: block size " + sizeId);
			}
			var blockMax:Int = 1 << (8 + 2 * sizeId);

			var contentSize:Int = -1;
			if (hasContentSize) {
				__need(input, p, 8);
				var low:Int = __read32(input, p);
				var high:Int = __read32(input, p + 4);
				p += 8;
				// Checked before anything is decoded: a frame is honest about
				// its size or it fails its own check at the end.
				if (high != 0 || low < 0) {
					throw new RangeError("LZ4 frame states a content size past what a Bytes can hold");
				}
				if (maxOutputSize > 0 && low > maxOutputSize - out.length) {
					throw new RangeError("Decoded stream exceeded " + maxOutputSize + " bytes");
				}
				contentSize = low;
			}
			__need(input, p, 1);
			var check:Int = (XXHash32.hash(input, descriptor, p - descriptor) >>> 8) & 0xFF;
			if (input.get(p++) != check) {
				throw new IOError("Invalid LZ4 frame data: the descriptor checksum does not match");
			}

			var frameStart:Int = out.length;
			while (true) {
				__need(input, p, 4);
				var word:Int = __read32(input, p);
				p += 4;
				if (word == 0) {
					break;
				}
				var stored:Bool = (word & 0x80000000) != 0;
				var size:Int = word & 0x7FFFFFFF;
				if (size > blockMax) {
					throw new IOError("Invalid LZ4 frame data: a block larger than the frame allows");
				}
				if (size > n - p) {
					throw new IOError("Invalid LZ4 frame data: the frame ends early");
				}
				var blockStart:Int = out.length;
				if (stored) {
					out.append(input, p, size);
				} else {
					Lz4.decodeBlock(input, p, p + size, out, independent ? blockStart : frameStart);
					if (out.length - blockStart > blockMax) {
						throw new IOError("Invalid LZ4 frame data: a block decodes past the frame's block size");
					}
				}
				if (blockChecksums) {
					__need(input, p + size, 4);
					if (__read32(input, p + size) != XXHash32.hash(input, p, size)) {
						throw new IOError("Invalid LZ4 frame data: a block checksum does not match");
					}
					p += 4;
				}
				p += size;
			}

			var produced:Int = out.length - frameStart;
			if (contentChecksum) {
				__need(input, p, 4);
				if (__read32(input, p) != XXHash32.hash(out.view(), frameStart, produced)) {
					throw new IOError("Invalid LZ4 frame data: the content checksum does not match");
				}
				p += 4;
			}
			if (contentSize >= 0 && produced != contentSize) {
				throw new IOError("Invalid LZ4 frame data: " + produced + " bytes where the frame says " + contentSize);
			}
		}

		return out.toBytes();
	}

	static inline function __need(input:Bytes, at:Int, count:Int):Void {
		if (count > input.length - at) {
			throw new IOError("Invalid LZ4 frame data: the frame ends early");
		}
	}

	static inline function __read32(data:Bytes, at:Int):Int {
		return data.get(at) | (data.get(at + 1) << 8) | (data.get(at + 2) << 16) | (data.get(at + 3) << 24);
	}

	static inline function __write32(data:Bytes, at:Int, value:Int):Void {
		data.set(at, value & 0xFF);
		data.set(at + 1, (value >>> 8) & 0xFF);
		data.set(at + 2, (value >>> 16) & 0xFF);
		data.set(at + 3, (value >>> 24) & 0xFF);
	}
}
