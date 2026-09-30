package crossbyte._internal.deflatex;

import crossbyte.errors.IOError;
import haxe.crypto.Adler32;
import haxe.io.Bytes;
import haxe.io.BytesInput;

/**
 * The zlib format (RFC 1950): a two-byte header, a deflate stream, and an
 * Adler-32 of the uncompressed data, big-endian.
 *
 * What HTTP's `deflate` content coding is (RFC 9110 8.4.1.2), and what zlib,
 * Node's `zlib.deflateSync`/`inflateSync` and Java's Deflater mean by
 * deflate. `Deflater` writes the raw stream inside it.
 */
class ZlibCompressor {
	/*
	 * 0x78: deflate with a 32K window. 0x9C: no preset dictionary, the
	 * default compression level, and a check value making the pair a multiple
	 * of 31 -- the header zlib itself writes by default. The level is only a
	 * hint to someone deciding whether to recompress.
	 */
	private static inline var CMF:Int = 0x78;
	private static inline var FLG:Int = 0x9C;

	public static function compress(stream:Bytes):Bytes {
		var deflated:Bytes = new Deflater().compress(stream);
		var out:Bytes = Bytes.alloc(2 + deflated.length + 4);
		out.set(0, CMF);
		out.set(1, FLG);
		out.blit(2, deflated, 0, deflated.length);

		var adler:Int = Adler32.make(stream);
		var at:Int = 2 + deflated.length;
		out.set(at, (adler >>> 24) & 0xFF);
		out.set(at + 1, (adler >>> 16) & 0xFF);
		out.set(at + 2, (adler >>> 8) & 0xFF);
		out.set(at + 3, adler & 0xFF);
		return out;
	}

	/**
		@param maxOutputSize Bytes to produce before giving up, or `0` for no
		       limit.
		@throws IOError The data is not zlib, is damaged, or ends early.
		@throws RangeError It would produce more than `maxOutputSize` bytes.
	**/
	public static function decompress(stream:Bytes, maxOutputSize:Int = 0):Bytes {
		// The header is checked here so that what is wrong can be said: data
		// that is not zlib at all -- a raw deflate stream, most likely -- fails
		// its check value, where the inflater would only say "Invalid data".
		if (stream == null || stream.length < 2) {
			throw new IOError("Invalid zlib data: too short for a header");
		}
		var cmf:Int = stream.get(0);
		var flg:Int = stream.get(1);
		if ((cmf & 0x0F) != 8 || (cmf >> 4) > 7 || ((cmf << 8) | flg) % 31 != 0) {
			throw new IOError("Invalid zlib data: no zlib header");
		}
		if ((flg & 0x20) != 0) {
			throw new IOError("Invalid zlib data: a preset dictionary is required");
		}

		return Inflater.inflate(new BytesInput(stream), true, maxOutputSize, "zlib");
	}

	/**
		Whether `stream` begins with a valid zlib header: the test an HTTP
		client applies to a `deflate` body, since servers send both zlib and,
		wrongly but commonly, raw deflate.
	**/
	public static function hasHeader(stream:Bytes):Bool {
		if (stream == null || stream.length < 2) {
			return false;
		}
		return isHeader(stream.get(0), stream.get(1));
	}

	/** Whether two bytes are a zlib header: DEFLATE, a window it allows, a valid check. **/
	public static inline function isHeader(cmf:Int, flg:Int):Bool {
		return (cmf & 0x0F) == 8 && (cmf >> 4) <= 7 && ((cmf << 8) | flg) % 31 == 0;
	}
}
