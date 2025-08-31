package crossbyte._internal.deflatex;

import crossbyte._internal.deflatex.utils.BitsInput;
import crossbyte._internal.deflatex.utils.BitsOutput;
import haxe.io.Bytes;
import haxe.Exception;

/**
 * Implements the gzip file format for storing DEFLATE-compressed streams.
 */
class GZCompressor {
	/*
	 * Compression methods
	 */
	private static final M_DEFLATE:Int = 8;

	/*
	 * Header flags
	 */
	private static final F_TEXT:Int = 1;
	private static final F_HCRC:Int = 2;
	private static final F_EXTRA:Int = 4;
	private static final F_NAME:Int = 8;
	private static final F_COMMENT:Int = 16;

	/**
	 * Reads a series of bytes from an input stream and
	 * executes a compression algorithm over them,
	 * returning the resulting stream.
	 * @param stream The input bytes of data to be compressed
	 * @return The output bytes of compressed data
	 */
	public static function compress(file_name:String, stream:Bytes):Bytes {
		var output:BitsOutput = new BitsOutput();
		output.writeByte(0x1f);
		output.writeByte(0x8b);
		output.writeByte(M_DEFLATE);
		output.writeByte(F_NAME);
		for (i in 0...6) {
			output.writeByte(0);
		}

		output.writeString(file_name);
		output.writeByte(0);

		var deflater:Deflater = new Deflater();
		var result:Bytes = deflater.compress(stream);
		output.write(result);

		output.writeInt32(deflater.getCRCValue());
		output.writeInt32(stream.length);

		return output.getBytes();
	}

	/**
	 * Reads a series of bytes from a compressed stream and
	 * executes a decompression algorithm over them,
	 * returning the resulting stream.
	 * @param stream The input stream for the compressed data
	 * @return The output bytes with the decompressed data
	 */
	public static function decompress(stream:Bytes):Bytes {
		var input:BitsInput = new BitsInput(stream);
		var id1:Int = input.readByte();
		var id2:Int = input.readByte();
		if (id1 != 0x1f || id2 != 0x8b) {
			throw new Exception("Invalid magic");
		}
		var method:Int = input.readByte();
		if (method != M_DEFLATE) {
			throw new Exception("Unsupported compression method");
		}
		var flags:Int = input.readByte();
		if ((flags & (F_HCRC | F_EXTRA | F_COMMENT)) != 0) {
			throw new Exception("Unsupported flags");
		}
		input.read(6);

		if ((flags & F_NAME) != 0) {
			var b:Int;
			do {
				b = input.readByte();
			} while (b != 0);
		}

		var inflater:Inflater = new Inflater();
		var length:Int = input.length - input.position - 8;
		var content:Bytes = Bytes.alloc(length);
		input.readBytes(content, 0, length);
		var result:Bytes = inflater.decompress(content);

		var f_crc:Int = input.readInt32();
		var f_size:Int = input.readInt32();

		// Verify data
		if (result.length != f_size) {
			throw new Exception("Size mismatch, expected = " + f_size + ", actual = " + result.length);
		}
		var crc:Int = inflater.CRC;
		if (crc != f_crc) {
			throw new Exception("CRC mismatch, expected = " + StringTools.hex(f_crc) + ", actual = " + StringTools.hex(crc));
		}

		return result;
	}
}
