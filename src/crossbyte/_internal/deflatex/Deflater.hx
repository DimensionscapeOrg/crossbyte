package crossbyte._internal.deflatex;

import crossbyte._internal.deflatex.utils.BitsInput;
import crossbyte._internal.deflatex.utils.BitsOutput;
import haxe.iterators.ArrayIterator;
import haxe.io.Bytes;
import haxe.io.BytesOutput;
import haxe.io.BytesInput;
import haxe.ds.Vector;

/**
 * Deflates a given stream of data.
 */
class Deflater {
	private static var INSTANCE:Deflater = new Deflater();

	/*
	 * Compression mode (0 = none, 1 = fixed Huffman, 2 = dynamic Huffman)
	 */
	private static final MODE:Int = 2;
	private static final ENABLE_LZ77:Bool = true;

	/*
	 * Buffer and window sizes
	 */
	private static final BUFFER_SIZE:Int = 32768;
	private static final WINDOW_SIZE:Int = 256;

	/*
	 * Constant values
	 */
	private static final END_OF_BLOCK:Int = 256;
	private static final LEN_ORDER:Vector<Int> = Vector.fromArrayCopy([16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]);
	private static final N_LITERALS:Int = 286;
	private static final N_DISTANCES:Int = 30;
	private static final N_LENGTHS:Int = 19;

	private var crc:CRC32;
	private var rem:Int;

	/**
	 * Create a new Deflater.
	 */
	public function new() {
		crc = new CRC32();
	}

	/**
	 * Appplies the deflate compression on the suppliead stream.
	 * @return Bytes holding the compressed data
	 */
	public function compress(stream:Bytes):Bytes {
		var block:BitsOutput = new BitsOutput();
		var input:BytesInput = new BytesInput(stream);
		var output:BitsOutput = new BitsOutput();
		rem = 0;

		var buffer:Bytes = Bytes.alloc(BUFFER_SIZE);
		var window:LZWindow = new LZWindow(WINDOW_SIZE);

		var len:Int = 0;
		while (true) {
			len = cast(Math.min(BUFFER_SIZE, input.length - input.position));
			if (len == 0)
				break;
			input.readBytes(buffer, 0, len);
			if (block.length > 0) {
				var b:Bytes = block.getBytes();
				output.writeBits(0, 1);
				output.writeBits(MODE, 2);
				if (MODE == 0) {
					output.flushBits();
				}
				if (output.bitPos == 0 && rem == 0) {
					output.write(b);
				} else {
					for (i in 0...b.length) {
						if (i == b.length - 1 && rem > 0) {
							output.writeBits(b.get(i), rem);
						} else {
							output.writeBits(b.get(i), 8);
						}
					}
				}
				block = new BitsOutput();
			}

			crc.updateBytes(buffer, 0, len);

			if (MODE == 0) {
				block.writeInt16(len);
				block.writeInt16(len ^ 0xffff);
				block.writeBytes(buffer, 0, len);
				window.addBytes(buffer, 0, len);
				rem = 0;
				continue;
			}

			var pairs:Vector<LZPair> = new Vector<LZPair>(len);
			var litFreq:Vector<Int> = new Vector<Int>(N_LITERALS);
			var distFreq:Vector<Int> = new Vector<Int>(N_DISTANCES);
			var lenFreq:Vector<Int> = new Vector<Int>(N_LENGTHS);
			#if !static
			for (i in 0...N_LITERALS)
				litFreq[i] = 0;
			for (i in 0...N_DISTANCES)
				distFreq[i] = 0;
			for (i in 0...N_LENGTHS)
				lenFreq[i] = 0;
			#end

			var i:Int = 0;
			while (i < len) {
				var pair:LZPair = null;
				if (ENABLE_LZ77) {
					pair = window.find(buffer, i, len);
				}

				if (pair != null) {
					pairs[i] = pair;
					window.addBytes(buffer, i, pair.len);
					i += (pair.len - 1);
					distFreq[pair.distSymbol]++;
					litFreq[pair.lenSymbol]++;
				} else {
					var byte:Int = buffer.get(i);
					window.addByte(byte);
					var idx:Int = byte & 0xff;
					var lit_freq:Int = litFreq[idx];
					litFreq[idx] = lit_freq + 1;
				}

				i++;
			}
			var end:Int = litFreq[END_OF_BLOCK];
			litFreq[END_OF_BLOCK] = end + 1;

			var litCode:Vector<Int>,
				litCodeLen:Vector<Int>,
				distCode:Vector<Int>,
				distCodeLen:Vector<Int>,
				lenCode:Vector<Int>,
				lenCodeLen:Vector<Int>;
			var lengths:Array<Int>;

			if (MODE == 2) {
				var litTree:HuffmanTree = new HuffmanTree(litFreq, 15);
				var litTable:HuffmanTable = litTree.getTable();
				litCode = litTable.code;
				litCodeLen = litTable.codeLen;

				var distTree:HuffmanTree = new HuffmanTree(distFreq, 15);
				var distTable:HuffmanTable = distTree.getTable();
				distCode = distTable.code;
				distCodeLen = distTable.codeLen;

				lengths = HuffmanTable.packCodeLengths(litCodeLen, distCodeLen);

				var iter:ArrayIterator<Int> = lengths.iterator();
				while (iter.hasNext()) {
					var s:Int = iter.next();
					var len_freq:Int = lenFreq[s];
					lenFreq[s] = len_freq + 1;
					if (s == 16 || s == 17 || s == 18) {
						iter.next();
					}
				}

				var lenTree:HuffmanTree = new HuffmanTree(lenFreq, 7);
				var lenTable:HuffmanTable = lenTree.getTable();
				lenCode = lenTable.code;
				lenCodeLen = lenTable.codeLen;
			} else {
				litCode = HuffmanTable.LIT.code;
				litCodeLen = HuffmanTable.LIT.codeLen;

				distCode = HuffmanTable.DIST.code;
				distCodeLen = HuffmanTable.DIST.codeLen;

				lengths = null;
				lenCode = null;
				lenCodeLen = null;
			}

			if (MODE == 2) {
				block.writeBits(N_LITERALS - 257, 5);
				block.writeBits(N_DISTANCES - 1, 5);
				block.writeBits(N_LENGTHS - 4, 4);
				for (i in 0...N_LENGTHS) {
					block.writeBits(lenCodeLen[LEN_ORDER[i]], 3);
				}
				var iter:ArrayIterator<Int> = lengths.iterator();
				while (iter.hasNext()) {
					var s:Int = iter.next();
					block.writeBitsR(lenCode[s], lenCodeLen[s]);
					if (s == 16) {
						block.writeBits(iter.next(), 2);
					} else if (s == 17) {
						block.writeBits(iter.next(), 3);
					} else if (s == 18) {
						block.writeBits(iter.next(), 7);
					}
				}
			}

			var i:Int = 0;
			while (i < len) {
				var pair:LZPair = pairs[i];
				if (pair != null) {
					var s:Int = pair.lenSymbol;
					block.writeBitsR(litCode[s], litCodeLen[s]);
					block.writeBits(pair.lenBits, pair.lenNumBits);
					var t:Int = pair.distSymbol;
					block.writeBitsR(distCode[t], distCodeLen[t]);
					block.writeBits(pair.distBits, pair.distNumBits);
					i += (pair.len - 1);
				} else {
					var s:Int = buffer.get(i) & 0xff;
					block.writeBitsR(litCode[s], litCodeLen[s]);
				}
				i++;
			}
			block.writeBitsR(litCode[END_OF_BLOCK], litCodeLen[END_OF_BLOCK]);
			rem = block.bitPos;
			block.flushBits();
		}

		var b:Bytes = block.getBytes();
		output.writeBits(1, 1);
		output.writeBits(MODE, 2);
		if (MODE == 0) {
			output.flushBits();
		}
		if (output.bitPos == 0 && rem == 0) {
			output.write(b);
		} else {
			for (i in 0...b.length) {
				if (i == b.length - 1 && rem > 0) {
					output.writeBits(b.get(i), rem);
				} else {
					output.writeBits(b.get(i), 8);
				}
			}
		}
		output.flushBits();

		return output.getBytes();
	}

	/**
	 * Get the current value of the checksum.
	 * @return The current CRC value
	 */
	public function getCRCValue():Int {
		return crc.value;
	}

	/**
	 * Applies the deflate compression on the supplied bytes.
	 * @return Compressed output
	 */
	public static function apply(stream:Bytes):Bytes {
		return INSTANCE.compress(stream);
	}
}
