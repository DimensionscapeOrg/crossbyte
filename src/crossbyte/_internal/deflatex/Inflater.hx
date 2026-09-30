package crossbyte._internal.deflatex;

import crossbyte.errors.IOError;
import crossbyte.errors.RangeError;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import haxe.io.BytesInput;
import haxe.io.Eof;

/**
 * Inflates a raw deflate stream (RFC 1951), through `haxe.zip.InflateImpl`.
 *
 * It carried a decoder of its own beside that -- Huffman tables in balanced
 * trees, a 32K-entry window -- which nothing called any more, but whose window
 * every `new Inflater()` still allocated and cleared, and a CRC it computed
 * over every result for gzip's sake. Inflating an 846-byte message cost 96 us
 * on Node, 66 of them in the constructor. gzip computes its CRC itself now.
 */
class Inflater {
	/**
		Bytes this will produce before giving up, or `0` for no limit.

		Deflate has no bound on how far input expands -- a megabyte of zeros
		comes back as about a gigabyte -- so anything inflating a stream it
		did not author wants a ceiling. The check sits inside the read loop
		rather than on the result, so the memory is never taken in the first
		place.
	**/
	public var maxOutputSize:Int = 0;

	public function new() {}

	/**
	 * Applies the inflate decompression on the supplied stream.
	 * @return Bytes with the uncompressed data
	 */
	public function decompress(stream:Bytes):Bytes {
		return inflate(new BytesInput(stream), false, maxOutputSize, "deflate");
	}

	/**
		Inflates the stream `input` is at -- raw deflate, or zlib (RFC 1950)
		when `zlib` is set, its header parsed and its Adler-32 checked -- and
		leaves `input` just past it, where gzip finds its trailer and any
		member after it.

		@param maxOutputSize Bytes to produce before giving up, or `0` for no
		       limit.
		@param format Names the format in what is thrown.
		@throws IOError The data is not a valid stream, or ends before the
		        stream does.
		@throws RangeError It would produce more than `maxOutputSize` bytes.
	**/
	public static function inflate(input:BytesInput, zlib:Bool, maxOutputSize:Int, format:String):Bytes {
		var output = new BytesBuffer();
		var buffer = Bytes.alloc(8192);
		var produced:Int = 0;

		// InflateImpl says what is wrong with a stream by throwing a String,
		// and that it ran out by letting Eof through, which is how a caller
		// that has to tell a damaged body from a bug could not: they reached
		// it as a bare string, and the HTTP client reported every one as an
		// unsupported content coding.
		try {
			var inflater = new haxe.zip.InflateImpl(input, zlib, zlib);
			while (true) {
				var read = inflater.readBytes(buffer, 0, buffer.length);

				produced += read;
				if (maxOutputSize > 0 && produced > maxOutputSize) {
					throw new RangeError("Inflated stream exceeded " + maxOutputSize + " bytes");
				}

				output.addBytes(buffer, 0, read);
				if (read < buffer.length) {
					break;
				}
			}
		} catch (e:Eof) {
			throw new IOError("Invalid " + format + " data: the stream ends early");
		} catch (e:String) {
			throw new IOError("Invalid " + format + " data: " + e);
		}

		return output.getBytes();
	}

	/**
	 * Applies inflate decompression on the supplied bytes.
	 * @return Decompressed output
	 */
	public static function apply(stream:Bytes, maxOutputSize:Int = 0):Bytes {
		var inflater = new Inflater();
		inflater.maxOutputSize = maxOutputSize;
		return inflater.decompress(stream);
	}
}
