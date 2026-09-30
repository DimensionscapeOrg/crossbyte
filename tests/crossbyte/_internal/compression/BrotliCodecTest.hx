package crossbyte._internal.compression;

import crossbyte._internal.brotli.Brotli;
import haxe.io.Bytes;
import haxe.Timer;
import utest.Assert;

/**
 * The pure Brotli codec, as a peer reaches it: every request body sent with
 * `Content-Encoding: br` and every response a client asked for in br decodes
 * through here, on whichever thread happened to receive it.
 */
class BrotliCodecTest extends utest.Test {
	/**
	 * Four bytes declaring a 16 MB metadata block, and then the end.
	 *
	 * The loop skipping metadata asked for more input, was told there was
	 * none, and went round again with the same length still to skip: forever,
	 * and without allocating, so no output ceiling ever tripped. One POST
	 * carrying these bytes stopped a server answering anyone, since its
	 * timeouts and its rate limiter all run on the thread that was stuck.
	 */
	public function testATruncatedMetadataBlockFailsRatherThanSpinning():Void {
		for (hex in ["ecffff7f", "2c01aa", "2c01", "2c"]) {
			var started:Float = Timer.stamp();
			Assert.raises(() -> Brotli.decompress(Bytes.ofHex(hex), 1 << 20), null, hex + " decoded");
			Assert.isTrue(Timer.stamp() - started < 5.0, hex + " took " + (Timer.stamp() - started) + "s to fail");
		}
	}

	/**
	 * The same block, complete: three bytes of metadata between the header and
	 * an empty last meta-block. A decoder must skip them and produce nothing,
	 * which is what Node's zlib does with these six bytes.
	 */
	public function testAMetadataBlockIsSkipped():Void {
		Assert.equals(0, Brotli.decompress(Bytes.ofHex("2c01aabbcc03"), 1 << 20).length);
	}

	/**
	 * A stream that ends where the literal context map should begin.
	 *
	 * The decoder scanned that map before asking whether it had been read, so
	 * it walked a map that was never allocated: null. On eval and the jvm that
	 * surfaced as an exception from inside the decoder, and natively as a
	 * segfault, the fuzz suite took the whole native runner down with the
	 * first four bytes of a valid stream. It must be refused as the codec
	 * refuses any other damaged stream.
	 */
	public function testAStreamEndingBeforeItsContextMapIsRefused():Void {
		for (hex in ["1b500000", "1b5000"]) {
			var refusal:String = null;
			try {
				Brotli.decompress(Bytes.ofHex(hex), 1 << 20);
			} catch (e:Dynamic) {
				refusal = Std.string(e);
			}
			Assert.equals("Brotli decompression failed", refusal, hex);
		}
	}
}
