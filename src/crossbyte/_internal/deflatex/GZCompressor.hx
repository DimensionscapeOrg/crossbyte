package crossbyte._internal.deflatex;

import crossbyte._internal.deflatex.utils.BitsOutput;
import crossbyte.errors.IOError;
import haxe.io.Bytes;
import haxe.io.BytesInput;
import haxe.io.Eof;

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
		// A name is only worth the header bytes when there is one to record.
		// The member is unnamed otherwise, which is what a gzip HTTP body
		// wants: there is no file, and inventing a name for one spends five
		// bytes per response saying so.
		var named:Bool = file_name != null && file_name.length > 0;

		var output:BitsOutput = new BitsOutput();
		output.writeByte(0x1f);
		output.writeByte(0x8b);
		output.writeByte(M_DEFLATE);
		output.writeByte(named ? F_NAME : 0);
		for (i in 0...6) {
			output.writeByte(0);
		}

		if (named) {
			output.writeString(file_name);
			output.writeByte(0);
		}

		var deflater:Deflater = new Deflater();
		var result:Bytes = deflater.compress(stream);
		output.write(result);

		var crc:CRC32 = new CRC32();
		crc.updateBytes(stream, 0, stream.length);
		output.writeInt32(crc.value);
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
	/**
		@param maxOutputSize Bytes to produce before giving up, or `0` for no
		       limit. A gzip member says nothing trustworthy about how far it
		       expands, so a caller inflating a stream it did not author wants
		       to name a ceiling.
	**/
	public static function decompress(stream:Bytes, maxOutputSize:Int = 0):Bytes {
		var input:BytesInput = new BytesInput(stream);
		try {
			var id1:Int = input.readByte();
			var id2:Int = input.readByte();
			if (id1 != 0x1f || id2 != 0x8b) {
				throw new IOError("Invalid gzip data: no gzip header");
			}
			var method:Int = input.readByte();
			if (method != M_DEFLATE) {
				throw new IOError("Invalid gzip data: compression method " + method);
			}
			var flags:Int = input.readByte();
			if ((flags & (F_HCRC | F_EXTRA | F_COMMENT)) != 0) {
				throw new IOError("Unsupported gzip data: header flags " + flags);
			}
			input.read(6);

			if ((flags & F_NAME) != 0) {
				var b:Int;
				do {
					b = input.readByte();
				} while (b != 0);
			}

			// Inflated where it lies, so the trailer is read from where the
			// deflate stream actually ends. It was taken to be the last eight
			// bytes of the input, and everything before them copied out and
			// inflated.
			var result:Bytes = Inflater.inflate(input, false, maxOutputSize, "gzip");

			var f_crc:Int = input.readInt32();
			var f_size:Int = input.readInt32();

			// Verify data
			if (result.length != f_size) {
				throw new IOError("Invalid gzip data: " + result.length + " bytes where the trailer says " + f_size);
			}
			var check:CRC32 = new CRC32();
			check.updateBytes(result, 0, result.length);
			if (check.value != f_crc) {
				throw new IOError("Invalid gzip data: CRC " + StringTools.hex(check.value, 8) + " where the trailer says " + StringTools.hex(f_crc, 8));
			}

			return result;
		} catch (e:Eof) {
			throw new IOError("Invalid gzip data: the stream ends early");
		}
	}
}
