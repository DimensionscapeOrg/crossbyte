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

	/** 174 bytes of English as Node's zlib writes them at quality 11: 53 bytes, mostly references into the static dictionary. **/
	private static inline var DICTIONARY_TEXT:String = "The government information about the international community was available through the university library, although the development of the environment remained controversial.";

	private static inline var DICTIONARY_STREAM:String = "a215009c34884bd81d68c981536b4be449eb1e9a47af5771363226381b58c05bb1e9b80fa23021ed853645b28fb233a93a2d3b9a08";

	public function testAStreamOfDictionaryReferencesDecodes():Void {
		Assert.equals(DICTIONARY_TEXT, Brotli.decompress(Bytes.ofHex(DICTIONARY_STREAM), 1 << 20).toString());
	}

	#if target.threaded
	/**
	 * Eight threads meeting the codec for the first time at once.
	 *
	 * The dictionary tables were marked built before they were built, so a
	 * thread arriving while another built them read a dictionary that was
	 * null or half filled: on the jvm seven threads in eight threw, in six
	 * runs of six, and natively about one run in nine crashed the process.
	 * URLLoader decodes on up to sixteen pool threads, so a burst of loads at
	 * startup is exactly this. Each thread decodes a stream made of dictionary
	 * references, which reads the dictionary, and encodes text, which reads
	 * the hash built from it.
	 */
	public function testThreadsMeetingTheCodecAtOnceAllSucceed():Void {
		var threads:Int = 8;
		var packed:Bytes = Bytes.ofHex(DICTIONARY_STREAM);

		for (round in 0...10) {
			crossbyte._internal.brotli.codec.BrotliCodec.__forgetTables();

			var go = new sys.thread.Lock();
			var results = new sys.thread.Deque<String>();
			for (i in 0...threads) {
				sys.thread.Thread.create(() -> {
					go.wait();
					try {
						var decoded:String = Brotli.decompress(packed, 1 << 20).toString();
						var again:String = Brotli.decompress(Brotli.compress(Bytes.ofString(DICTIONARY_TEXT)), 1 << 20).toString();
						results.add(decoded == DICTIONARY_TEXT && again == DICTIONARY_TEXT ? "ok" : "decoded wrongly: " + decoded);
					} catch (e:Dynamic) {
						results.add("threw: " + Std.string(e));
					}
				});
			}

			for (i in 0...threads) {
				go.release();
			}
			for (i in 0...threads) {
				var result:String = results.pop(true);
				Assert.equals("ok", result, "round " + round + ", thread " + i + ": " + result);
			}
		}
	}
	#end
}
