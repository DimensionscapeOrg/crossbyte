package crossbyte._internal.deflatex;

import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import haxe.io.BytesInput;
import haxe.Exception;

/**
 * Inflates a raw deflate stream (RFC 1951), through `haxe.zip.InflateImpl`.
 *
 * It carried a decoder of its own beside that, Huffman tables in balanced
 * trees, a 32K-entry window, which nothing called any more, but whose window
 * every `new Inflater()` still allocated and cleared, and a CRC it computed
 * over every result for gzip's sake. Inflating an 846-byte message cost 96 us
 * on Node, 66 of them in the constructor. gzip computes its CRC itself now.
 */
class Inflater {
	/**
		Bytes this will produce before giving up, or `0` for no limit.

		Deflate has no bound on how far input expands, a megabyte of zeros
		comes back as about a gigabyte, so anything inflating a stream it
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
		var inflater = new haxe.zip.InflateImpl(new BytesInput(stream), false, false);
		var output = new BytesBuffer();
		var buffer = Bytes.alloc(8192);
		var produced:Int = 0;

		while (true) {
			var read = inflater.readBytes(buffer, 0, buffer.length);

			produced += read;
			if (maxOutputSize > 0 && produced > maxOutputSize) {
				throw new Exception("Inflated stream exceeded " + maxOutputSize + " bytes");
			}

			output.addBytes(buffer, 0, read);
			if (read < buffer.length) {
				break;
			}
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
