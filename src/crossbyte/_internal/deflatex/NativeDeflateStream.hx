package crossbyte._internal.deflatex;

#if cpp
import haxe.io.Bytes;
import haxe.zip.Compress;
import haxe.zip.FlushMode;

/**
	`DeflateStream` through hxcpp's own zlib, on native: raw DEFLATE written a
	piece at a time, each piece ending on a sync flush, and `finish` ending the
	stream. The same contract as `DeflateStream`, at about 25 microseconds an
	8 KB piece where the Haxe deflater takes about 90.

	zlib writes a zlib stream (a 2-byte header first, an Adler-32 last), so
	the header comes off the first piece and the checksum off the end; what is
	left between is the raw DEFLATE `DeflateStream` writes.
**/
@:noCompletion
class NativeDeflateStream {
	private var __z:Compress;
	private var __first:Bool = true;
	private var __finished:Bool = false;

	public function new() {
		__z = new Compress(NativeZlib.LEVEL);
	}

	/** `len` bytes of `data` from `pos`, deflated and sync-flushed. **/
	public function write(data:Bytes, pos:Int = 0, len:Int = -1):Bytes {
		if (__finished) {
			throw new crossbyte.errors.IllegalOperationError("The stream was finished");
		}
		if (len < 0) {
			len = data.length - pos;
		}
		if (len == 0) {
			// The flush alone, as DeflateStream writes it: an empty stored
			// block. zlib refuses a sync flush with nothing new (Z_BUF_ERROR),
			// and every earlier piece already ended on a byte boundary.
			var marker:Bytes = Bytes.alloc(5);
			marker.set(3, 0xFF);
			marker.set(4, 0xFF);
			return marker;
		}
		// hxcpp's deflate reads to the end of the data array, which in a
		// ByteArray runs past its length into spare capacity: the piece goes
		// alone unless its array ends where it does.
		var input:Bytes = data;
		if (pos + len != data.getData().length) {
			input = Bytes.alloc(len);
			input.blit(0, data, pos, len);
			pos = 0;
		}
		__z.setFlushMode(FlushMode.SYNC);
		var header:Int = __first ? 2 : 0;
		__first = false;
		return __run(input, pos, pos + len, false, header);
	}

	/** The last block, which ends the stream. **/
	public function finish():Bytes {
		if (__finished) {
			return Bytes.alloc(0);
		}
		__finished = true;
		__z.setFlushMode(FlushMode.FINISH);
		var header:Int = __first ? 2 : 0;
		__first = false;
		var out:Bytes = __run(Bytes.alloc(0), 0, 0, true, header);
		__z.close();
		return out;
	}

	/**
		`input` from `pos` to `end` through zlib until it has taken all of it
		and given back all it will (for a sync flush, until a pass leaves
		room in the output; for the end, until zlib says it is done), less
		the first `header` bytes, and the Adler-32 at the end.
	**/
	private function __run(input:Bytes, pos:Int, end:Int, last:Bool, header:Int):Bytes {
		var out:Bytes = Bytes.alloc((end - pos) + ((end - pos) >> 10) + 64);
		var read:Int = pos;
		var written:Int = 0;
		while (true) {
			var r = __z.execute(input, read, out, written);
			read += r.read;
			written += r.write;
			if (read >= end && (last ? r.done : written < out.length)) {
				break;
			}
			if (written >= out.length) {
				var grown:Bytes = Bytes.alloc(out.length * 2);
				grown.blit(0, out, 0, written);
				out = grown;
			}
		}
		var trailer:Int = last ? 4 : 0;
		return out.sub(header, written - header - trailer);
	}
}
#end
