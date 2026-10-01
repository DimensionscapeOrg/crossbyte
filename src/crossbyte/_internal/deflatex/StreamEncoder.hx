package crossbyte._internal.deflatex;

import haxe.crypto.Adler32;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;

/**
	A gzip or zlib stream written a piece at a time, over `DeflateStream`:
	the header goes out with the first piece, each piece ends on a sync flush,
	and `finish` adds the last block and the trailer, gzip's CRC-32 and
	length, zlib's Adler-32, over everything written.

	What HTTP needs to compress a body it streams: each chunk arrives with its
	own compressed bytes, which the client can inflate as they come.
**/
class StreamEncoder {
	// hxcpp's zlib on native, three times as fast and a third smaller; see
	// NativeDeflateStream.
	private var deflate:#if cpp NativeDeflateStream #else DeflateStream #end = #if cpp new NativeDeflateStream() #else new DeflateStream() #end;
	private var gzip:Bool;
	private var started:Bool = false;
	private var crc:CRC32;
	private var adler:Adler32;
	private var total:Int = 0;

	/** A gzip stream when `gzip`, a zlib stream otherwise. **/
	public function new(gzip:Bool) {
		this.gzip = gzip;
		if (gzip) {
			crc = new CRC32();
		} else {
			adler = new Adler32();
		}
	}

	/** `len` bytes of `data` from `pos`, compressed and flushed; the header first time. **/
	public function write(data:Bytes, pos:Int = 0, len:Int = -1):Bytes {
		if (len < 0) {
			len = data.length - pos;
		}
		if (len > 0) {
			if (gzip) {
				crc.updateBytes(data, pos, len);
			} else {
				adler.update(data, pos, len);
			}
			total += len;
		}

		var body:Bytes = deflate.write(data, pos, len);
		if (started) {
			return body;
		}

		started = true;
		var out:BytesBuffer = new BytesBuffer();
		__header(out);
		out.addBytes(body, 0, body.length);
		return out.getBytes();
	}

	/** The rest of the stream: its last block and its trailer. **/
	public function finish():Bytes {
		var out:BytesBuffer = new BytesBuffer();
		if (!started) {
			started = true;
			__header(out);
		}
		var last:Bytes = deflate.finish();
		out.addBytes(last, 0, last.length);

		if (gzip) {
			var value:Int = crc.value;
			for (shift in [0, 8, 16, 24]) {
				out.addByte((value >>> shift) & 0xFF);
			}
			// ISIZE: the length modulo 2^32, which an Int's low 32 bits are.
			for (shift in [0, 8, 16, 24]) {
				out.addByte((total >>> shift) & 0xFF);
			}
		} else {
			var value:Int = adler.get();
			for (shift in [24, 16, 8, 0]) {
				out.addByte((value >>> shift) & 0xFF);
			}
		}
		return out.getBytes();
	}

	private function __header(out:BytesBuffer):Void {
		if (gzip) {
			// As GZCompressor writes it: deflate, no flags, no time, no name.
			out.addByte(0x1f);
			out.addByte(0x8b);
			out.addByte(8);
			for (_ in 0...7) {
				out.addByte(0);
			}
		} else {
			// As ZlibCompressor writes it: deflate with a 32K window.
			out.addByte(0x78);
			out.addByte(0x9C);
		}
	}
}
