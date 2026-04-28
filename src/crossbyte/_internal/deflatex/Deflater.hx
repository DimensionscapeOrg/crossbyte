package crossbyte._internal.deflatex;

import crossbyte._internal.deflatex.utils.BitsInput;
import crossbyte._internal.deflatex.utils.BitsOutput;
import haxe.iterators.ArrayIterator;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import haxe.io.BytesOutput;
import haxe.io.BytesInput;
import haxe.ds.Vector;

/**
 * Deflates a given stream of data.
 */
class Deflater {

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
		crc = new CRC32();
		crc.updateBytes(stream, 0, stream.length);

		var output = new BytesBuffer();
		var offset = 0;
		var remaining = stream.length;

		if (remaining == 0) {
			output.addByte(0x01);
			output.addByte(0x00);
			output.addByte(0x00);
			output.addByte(0xFF);
			output.addByte(0xFF);
			return output.getBytes();
		}

		while (remaining > 0) {
			var blockLen = remaining > 0xFFFF ? 0xFFFF : remaining;
			var finalBlock = (remaining == blockLen);
			output.addByte(finalBlock ? 0x01 : 0x00);
			output.addByte(blockLen & 0xFF);
			output.addByte((blockLen >>> 8) & 0xFF);
			var nlen = blockLen ^ 0xFFFF;
			output.addByte(nlen & 0xFF);
			output.addByte((nlen >>> 8) & 0xFF);
			output.addBytes(stream, offset, blockLen);
			offset += blockLen;
			remaining -= blockLen;
		}

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
		return new Deflater().compress(stream);
	}
}
