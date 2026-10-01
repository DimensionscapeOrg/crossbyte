package crossbyte._internal.deflatex;

import haxe.io.Bytes;

/**
	hxcpp's own zlib, for the one-shot DEFLATE codings on native.

	The pure Haxe `Deflater` took 743 microseconds for 64 KB of JSON and wrote
	8.3 KB of it; zlib at its default level takes about 210 and writes 6.0 KB.
	An HTTP server compressing a page-sized body for every browser, which
	asks for it every time, was held to about 1,300 responses a second by
	that alone. hxcpp already links zlib for `haxe.zip`, so this adds no
	dependency.

	A body compressed as it streams goes through the same zlib, flushed after
	each piece; see `NativeDeflateStream`.
**/
#if cpp
@:noCompletion
class NativeZlib {
	/** zlib's own default, which Node's `zlib.gzip` and Apache use. **/
	public static inline var LEVEL:Int = 6;

	/** A zlib stream (RFC 1950): what HTTP calls `deflate`. **/
	public static function zlib(input:Bytes):Bytes {
		var r = __deflate(input, 0, 0);
		return r.out.sub(0, r.written);
	}

	/** Raw DEFLATE (RFC 1951): the zlib stream less its 2-byte header and 4-byte Adler-32. **/
	public static function raw(input:Bytes):Bytes {
		var r = __deflate(input, 0, 0);
		return r.out.sub(2, r.written - 6);
	}

	/**
		An unnamed gzip member (RFC 1952), as `GZCompressor` writes one: the
		10-byte header with no flags, modification time or system named, the
		raw DEFLATE, then its CRC-32 and length.
	**/
	public static function gzip(input:Bytes):Bytes {
		// The zlib stream is written 8 bytes in, so its DEFLATE begins where a
		// gzip header ends. The header goes over the first 10 bytes, the zlib
		// header among them, and the CRC and length over the Adler-32 and the
		// 4 bytes left after it.
		var r = __deflate(input, 8, 4);
		var out:Bytes = r.out;
		var trailer:Int = 8 + r.written - 4;
		out.set(0, 0x1f);
		out.set(1, 0x8b);
		out.set(2, 8);
		for (i in 3...10) {
			out.set(i, 0);
		}
		var crc = new CRC32();
		crc.updateBytes(input, 0, input.length);
		out.setInt32(trailer, crc.value);
		out.setInt32(trailer + 4, input.length);
		return out.sub(0, trailer + 8);
	}

	static function __deflate(input:Bytes, before:Int, after:Int):{out:Bytes, written:Int} {
		// hxcpp's deflate reads the whole of the data array, which in a
		// ByteArray runs past its length into spare capacity.
		var source:Bytes = input.getData().length == input.length ? input : input.sub(0, input.length);
		var n:Int = source.length;
		// zlib's compressBound, header and Adler-32 included, with room over.
		var bound:Int = n + (n >> 12) + (n >> 14) + (n >> 25) + 13 + 16;
		var out:Bytes = Bytes.alloc(before + bound + after);
		var c = new haxe.zip.Compress(LEVEL);
		c.setFlushMode(haxe.zip.FlushMode.FINISH);
		var r = c.execute(source, 0, out, before);
		c.close();
		if (!r.done || r.read != n) {
			throw new crossbyte.errors.IOError("zlib did not compress the whole input");
		}
		return {out: out, written: r.write};
	}
}
#end
