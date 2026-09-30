package crossbyte._internal.brotli.codec.decode;

import crossbyte._internal.brotli.codec.decode.streams.BrotliOutput;
import haxe.io.Bytes;

/**
 * The decoder's one output call. Input is read where it lies, by the bit
 * reader; the callbacks the C used for both, and the file streams the port
 * carried beside them, went with the Array<UInt> buffers they copied through.
 */
class Streams
{
	/* Writes len bytes of buf to the output, or throws past its limit. */
	static public inline function BrotliWrite(out:BrotliOutput, buf:Bytes, buf_off:Int, len:Int):Int {
		out.write(buf, buf_off, len);
		return len;
	}
}
