package crossbyte._internal.deflatex;

import crossbyte._internal.deflatex.utils.BitsOutput;
import haxe.ds.Vector;
import haxe.io.Bytes;

/**
	DEFLATE for data written a piece at a time. Each `write` returns what its
	piece deflates to, ending on a sync flush, so everything returned so far
	inflates to everything written so far and a reader sees each piece as it
	is sent. `finish` ends the stream.

	Matches reach back 32 KB into what was written before, so a stream of short
	messages that repeat themselves (server-sent events naming the same
	fields) compresses as one long message would, not as each message alone.
	The input is kept in a buffer of twice the window, slid down by a window
	as it fills, and the hash chains slid with it, as zlib does: about two
	operations a byte over the life of a stream, where priming a fresh match
	finder with the window on every write would cost 32 KB a write.
**/
class DeflateStream extends Deflater {
	private static inline var W:Int = 32768;

	/** The input, at positions 0 to `end`; the last `W` of it is the window. **/
	private var buffer:Bytes;
	private var end:Int = 0;
	private var finished:Bool = false;

	public function new() {
		super();
		buffer = Bytes.alloc(2 * W);
		// Chains for a whole window, kept for the life of the stream.
		prepare(2 * W);
	}

	/**
		`len` bytes of `data` from `pos`, deflated, up to a sync flush: a block
		of them and an empty stored block, which ends on a byte boundary. A
		write of nothing is the flush alone.
	**/
	public function write(data:Bytes, pos:Int = 0, len:Int = -1):Bytes {
		if (finished) {
			throw "DeflateStream: written after finish";
		}
		if (len < 0) {
			len = data.length - pos;
		}

		var output:BitsOutput = new BitsOutput();
		if (len > 0) {
			// BFINAL = 0, BTYPE = 01: a fixed-Huffman block, not the last.
			output.writeBits(0, 1);
			output.writeBits(1, 2);

			var offset:Int = pos;
			var remaining:Int = len;
			while (remaining > 0) {
				var take:Int = remaining > W ? W : remaining;
				if (end + take > buffer.length) {
					slide();
				}
				buffer.blit(end, data, offset, take);
				var from:Int = end;
				end += take;
				encode(output, from, end);
				offset += take;
				remaining -= take;
			}

			output.writeBitsR(HuffmanTable.LIT.code[Deflater.END_OF_BLOCK], HuffmanTable.LIT.codeLen[Deflater.END_OF_BLOCK]);
		}

		// Sync flush: BFINAL = 0, BTYPE = 00, then to the byte boundary, then a
		// stored block's LEN 0 and NLEN 0xFFFF.
		output.writeBits(0, 1);
		output.writeBits(0, 2);
		output.flushBits();
		output.writeByte(0x00);
		output.writeByte(0x00);
		output.writeByte(0xFF);
		output.writeByte(0xFF);
		return output.getBytes();
	}

	/** The end of the stream: a last block holding nothing. **/
	public function finish():Bytes {
		finished = true;
		var output:BitsOutput = new BitsOutput();
		output.writeBits(1, 1);
		output.writeBits(1, 2);
		output.writeBitsR(HuffmanTable.LIT.code[Deflater.END_OF_BLOCK], HuffmanTable.LIT.codeLen[Deflater.END_OF_BLOCK]);
		output.flushBits();
		return output.getBytes();
	}

	/** Positions `from` to `to` of the buffer as literals and matches. **/
	private function encode(output:BitsOutput, from:Int, to:Int):Void {
		var litCode:Vector<Int> = HuffmanTable.LIT.code;
		var litCodeLen:Vector<Int> = HuffmanTable.LIT.codeLen;
		var i:Int = from;

		while (i < to) {
			var length:Int = 0;
			var distance:Int = 0;

			if (i + Deflater.MIN_MATCH <= to) {
				length = findAt(buffer, i, to);
				distance = matchDistance;
			}

			if (length < Deflater.MIN_MATCH) {
				var b:Int = buffer.get(i);
				output.writeBitsR(litCode[b], litCodeLen[b]);
				i++;
				continue;
			}

			if (length < Deflater.MAX_MATCH && i + 1 + Deflater.MIN_MATCH <= to) {
				var next:Int = findAt(buffer, i + 1, to);
				if (next > length) {
					var b:Int = buffer.get(i);
					output.writeBitsR(litCode[b], litCodeLen[b]);
					i++;
					length = next;
					distance = matchDistance;
				}
			}

			writeMatch(output, distance, length);
			insertThrough(buffer, i + length - 1, to);
			i += length;
		}
	}

	/**
		Drops the oldest window: the newest moves down by `W`, and so does every
		position the chains hold, those that fell off becoming the end of a
		chain. `prev` is indexed by position modulo the window, which a move of
		exactly one window leaves where it was.
	**/
	private function slide():Void {
		buffer.blit(0, buffer, W, end - W);
		end -= W;
		inserted -= W;
		if (inserted < Deflater.NIL) {
			inserted = Deflater.NIL;
		}
		for (i in 0...head.length) {
			var at:Int = head[i];
			head[i] = at >= W ? at - W : Deflater.NIL;
		}
		for (i in 0...prev.length) {
			var at:Int = prev[i];
			prev[i] = at >= W ? at - W : Deflater.NIL;
		}
	}
}
