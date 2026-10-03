package crossbyte._internal.compression;

import haxe.io.Bytes;
import crossbyte.io.ByteArray;
import crossbyte.utils.CompressionAlgorithm;
import utest.Assert;
import crossbyte._internal.lz4.Lz4;
import crossbyte._internal.deflatex.Deflater;
import crossbyte._internal.deflatex.Inflater;
import crossbyte.test.Require;

/**
 * Round-trip / robustness coverage for the internal compression primitives:
 * the pure-Haxe LZ4 codec and the Haxe deflater.
 */
class CompressionRoundTripTest extends utest.Test {
	/**
	 * The assertion this file did not have: that compressing makes the data
	 * smaller.
	 *
	 * Everything else here checks fidelity, same length back, same bytes
	 * back, and a codec that stores its input verbatim satisfies every one
	 * of those perfectly. Three of the four did exactly that.
	 * `Deflater.compress` wrote stored blocks and nothing else: a `0x01`
	 * header, the length, its complement, then the raw bytes. No Huffman
	 * coding, no LZ77. gzip wrapped the same, and `Lz4.compress` emitted one
	 * literal run without ever looking for a match. All three returned more
	 * bytes than they were given, and every round-trip case above passed
	 * throughout.
	 *
	 * That was not academic. `HTTPRequestHandler` serves `Content-Encoding:
	 * gzip` and `deflate` through these, so a server negotiating gzip sent
	 * more bytes than it would have uncompressed and made the client
	 * decompress them for nothing.
	 *
	 * So this asserts, for all four: a codec that stops compressing fails
	 * here rather than passing quietly on fidelity alone.
	 */
	public function testCompressionActuallyCompresses():Void {
		// Twelve bytes repeated five hundred times. Any real encoder collapses
		// this to almost nothing, the four land between 23 and 77 bytes,
		// so a tenth of the input is a floor none of them can approach without
		// having genuinely stopped working.
		var sample = new ByteArray();

		for (i in 0...500) {
			sample.writeUTFBytes("compress me ");
		}

		var original:Int = sample.length;
		var ceiling:Int = Std.int(original / 10);

		for (algorithm in [
			CompressionAlgorithm.BROTLI,
			CompressionAlgorithm.DEFLATE,
			CompressionAlgorithm.GZIP,
			CompressionAlgorithm.LZ4
		]) {
			var size:Int = measure(algorithm, original);

			Assert.isTrue(size < ceiling,
				algorithm + " did not compress a highly repetitive payload: " + original + " bytes in, " + size + " out");
		}
	}

	/**
	 * That data with nothing to find does not grow much.
	 *
	 * The other half of an encoder being real. Deflate answers this with the
	 * stored block it falls back to, which costs five bytes per 64K; LZ4's
	 * block format has no stored form at all, so a little expansion is
	 * inherent there. Either way an encoder that inflates noise by a
	 * noticeable fraction is broken, and on an HTTP body that is the case
	 * where compressing is worse than not.
	 */
	public function testIncompressibleDataBarelyGrows():Void {
		var n:Int = 4096;
		var noise:Bytes = pseudoRandom(n);

		// Room for a stored block header and a token per literal run, and no
		// more: about 3% of the payload.
		var ceiling:Int = n + Std.int(n / 64) + 64;

		for (algorithm in [
			CompressionAlgorithm.BROTLI,
			CompressionAlgorithm.DEFLATE,
			CompressionAlgorithm.GZIP,
			CompressionAlgorithm.LZ4
		]) {
			var data = new ByteArray();
			data.writeBytes(noise, 0, noise.length);

			data.compress(algorithm);
			var size:Int = data.length;

			data.uncompress(algorithm);
			Assert.equals(n, data.length, algorithm + " did not round-trip incompressible data");

			Assert.isTrue(size <= ceiling, algorithm + " grew incompressible data from " + n + " to " + size);
		}
	}

	/**
	 * That a payload past 64K still works.
	 *
	 * Deflate's stored fallback has to emit more than one block above 65535,
	 * and only the last may carry the final-block bit; the match finder's
	 * window wraps somewhere in here too. Both are paths a small fixture never
	 * reaches.
	 */
	public function testLargePayloadRoundTripsAndCompresses():Void {
		var text = new ByteArray();
		while (text.length < 70000) {
			text.writeUTFBytes("CrossByte serves this body over HTTP. ");
		}

		var original:Int = text.length;

		for (algorithm in [
			CompressionAlgorithm.BROTLI,
			CompressionAlgorithm.DEFLATE,
			CompressionAlgorithm.GZIP,
			CompressionAlgorithm.LZ4
		]) {
			var data = new ByteArray();
			data.writeBytes(text, 0, original);

			data.compress(algorithm);
			var size:Int = data.length;

			data.uncompress(algorithm);
			Assert.equals(original, data.length, algorithm + " did not round-trip a large payload");
			Assert.isTrue(size < Std.int(original / 10),
				algorithm + " did not compress a large repetitive payload: " + original + " bytes in, " + size + " out");
		}
	}

	/**
	 * Deterministic noise, from shifts and xors only.
	 *
	 * The usual multiply-based generator is not portable here: Haxe's `*` is
	 * not 32-bit on js, so past 2^53 it loses its low bits and the sequence
	 * collapses into a short cycle, which compresses, and would leave this
	 * fixture testing the opposite of what it means to.
	 */
	private function pseudoRandom(n:Int):Bytes {
		var b:Bytes = Bytes.alloc(n);
		var state:Int = 0x12345678;

		for (i in 0...n) {
			state ^= state << 13;
			state ^= state >>> 17;
			state ^= state << 5;
			b.set(i, (state >>> 16) & 0xFF);
		}

		return b;
	}

	/**
	 * Compresses a fresh sample and returns the compressed size, checking on
	 * the way back that whatever it did is reversible.
	 */
	private function measure(algorithm:CompressionAlgorithm, count:Int):Int {
		var data = new ByteArray();

		for (i in 0...Std.int(count / 12)) {
			data.writeUTFBytes("compress me ");
		}

		data.compress(algorithm);
		var compressed:Int = data.length;

		data.uncompress(algorithm);
		Assert.equals(count, data.length, algorithm + " did not round-trip");

		return compressed;
	}

	private function assertBytesEqual(expected:Bytes, actual:Bytes):Void {
		Assert.equals(expected.length, actual.length);
		if (expected.length != actual.length) {
			return;
		}
		var mismatch:Int = -1;
		for (i in 0...expected.length) {
			if (expected.get(i) != actual.get(i)) {
				mismatch = i;
				break;
			}
		}
		Assert.equals(-1, mismatch, "byte mismatch at index " + mismatch);
	}

	private function roundTrip(data:Bytes):Void {
		var packed:Bytes = Lz4.compress(data);
		var restored:Bytes = Lz4.decompress(packed);
		assertBytesEqual(data, restored);
	}

	public function testLz4RoundTripsEmpty():Void {
		roundTrip(Bytes.alloc(0));
	}

	public function testLz4RoundTripsFewBytes():Void {
		var b:Bytes = Bytes.alloc(5);
		b.set(0, 0x00);
		b.set(1, 0x7F);
		b.set(2, 0xFF);
		b.set(3, 0x10);
		b.set(4, 0xAB);
		roundTrip(b);
	}

	public function testLz4RoundTripsLongRuns():Void {
		// Highly repetitive data -> long literal/match runs.
		var n:Int = 4096;
		var b:Bytes = Bytes.alloc(n);
		for (i in 0...n) {
			b.set(i, (i % 7 == 0) ? 0x41 : 0x42);
		}
		roundTrip(b);
	}

	public function testLz4RoundTripsSingleByteRun():Void {
		var n:Int = 1000;
		var b:Bytes = Bytes.alloc(n);
		b.fill(0, n, 0x5A);
		roundTrip(b);
	}

	public function testLz4RoundTripsPseudoRandom():Void {
		// Deterministic LCG so the test is reproducible across runs/targets.
		var n:Int = 2048;
		var b:Bytes = Bytes.alloc(n);
		var state:Int = 0x12345678;
		for (i in 0...n) {
			state = (state * 1103515245 + 12345) & 0x7FFFFFFF;
			b.set(i, (state >> 16) & 0xFF);
		}
		roundTrip(b);
	}

	// Zeros pack into a stream small enough to arrive in a single frame, and
	// LZ4's match encoding is what expands it again: a short length replaying
	// window bytes. That is the shape of the bomb, and it does not need to be
	// large to have it, 32 KB from 139 bytes is already 235x. Kept small on
	// purpose: decoding one is markedly slower on eval than on a compiled
	// target, so a megabyte here would have cost the interpreter minutes.
	private static inline var BOMB_SIZE:Int = 32 * 1024;

	private function lz4Bomb():Bytes {
		return Lz4.compress(Bytes.alloc(BOMB_SIZE));
	}

	public function testLz4RefusesAStreamThatOutgrowsItsLimit():Void {
		var packed:Bytes = lz4Bomb();
		Assert.isTrue(packed.length < BOMB_SIZE / 100,
			"expected a small stream to decode large, got " + packed.length + " bytes");

		Assert.raises(() -> Lz4.decompress(packed, 4096));
	}

	public function testLz4AcceptsAStreamInsideItsLimit():Void {
		var packed:Bytes = lz4Bomb();

		// Exactly the decoded size is inside the limit, not over it.
		var restored:Bytes = Lz4.decompress(packed, BOMB_SIZE);
		Assert.equals(BOMB_SIZE, restored.length);

		// And zero still means no limit, which every existing caller relies on.
		Assert.equals(BOMB_SIZE, Lz4.decompress(packed).length);
	}

	/**
	 * Inflating costs the inflate and nothing more.
	 *
	 * `Inflater` delegates to `haxe.zip.InflateImpl`, and beside that it kept a
	 * decoder of its own nothing called, whose 32K-entry window every `new
	 * Inflater()` still allocated and cleared, and a CRC of every result that
	 * only gzip reads. An 846-byte game message cost 96 us to inflate on Node,
	 * 66 of them in the constructor; on eval it was 2.4 times the inflate
	 * itself. Timed against the same inflate done directly, interleaved, and
	 * each side by its fastest round: a collection or another process landing
	 * on one round says nothing about either, and natively a whole side is a
	 * few milliseconds, which a loaded machine can double.
	 */
	public function testInflatingCostsNoMoreThanTheInflate():Void {
		var message:Bytes = Bytes.alloc(846);
		for (i in 0...message.length) {
			message.set(i, (i * 13 + (i >> 4)) & 0xFF);
		}
		var packed:Bytes = Deflater.apply(message);

		var viaInflater:Float = Math.POSITIVE_INFINITY;
		var direct:Float = Math.POSITIVE_INFINITY;
		for (round in 0...10) {
			var started:Float = haxe.Timer.stamp();
			for (i in 0...40) {
				Inflater.apply(packed, 1 << 20);
			}
			viaInflater = Math.min(viaInflater, haxe.Timer.stamp() - started);

			started = haxe.Timer.stamp();
			for (i in 0...40) {
				inflateDirectly(packed);
			}
			direct = Math.min(direct, haxe.Timer.stamp() - started);
		}

		Assert.isTrue(viaInflater < direct * 1.6, "Inflater's fastest round took " + viaInflater + "s against " + direct + "s for the inflate alone");
	}

	/** What `Inflater.decompress` does, with nothing else. **/
	private function inflateDirectly(packed:Bytes):Bytes {
		var inflate = new haxe.zip.InflateImpl(new haxe.io.BytesInput(packed), false, false);
		var output = new haxe.io.BytesBuffer();
		var buffer = Bytes.alloc(8192);
		while (true) {
			var read = inflate.readBytes(buffer, 0, buffer.length);
			output.addBytes(buffer, 0, read);
			if (read < buffer.length) {
				break;
			}
		}
		return output.getBytes();
	}

	/** Deterministic text with the repetition real text has. **/
	private function words(length:Int):Bytes {
		var vocabulary:Array<String> = "the of and to in is it that was for on are with as his they at be this from have or by one had not but what all were when we there can an your which their said if do will each about how up out them then she many some so these would other into has more her two like him see time could no make than first been its who now people".split(" ");
		var out = new StringBuf();
		var state:Int = 0x2468ACE1;
		while (out.length < length) {
			state ^= state << 13;
			state ^= state >>> 17;
			state ^= state << 5;
			out.add(vocabulary[(state >>> 8) % vocabulary.length]);
			out.add((state & 7) == 0 ? ". " : " ");
		}
		return Bytes.ofString(out.toString().substr(0, length));
	}

	/**
	 * An LZ4 block has no length of its own, so one cut short where a literal
	 * run happens to end read as complete: the auditor's block cut in half
	 * decoded 10,133 bytes of 20,006 and nothing said so. The format's end
	 * rules, the last five bytes literals, the last match starting twelve
	 * or more from the end, are what a cut block almost never meets, and
	 * are now enforced. Of every cut point of a 6 KB block, about a third
	 * decoded; now almost none do.
	 */
	public function testAnLz4BlockCutShortIsRefused():Void {
		var packed:Bytes = Lz4.compress(words(6000));
		var decoded:Int = 0;
		for (cut in 1...packed.length) {
			try {
				Lz4.decompress(packed.sub(0, cut), 1 << 20);
				decoded++;
			} catch (e:crossbyte.errors.IOError) {
				// Refused, as a cut block should be.
			}
		}
		Assert.isTrue(decoded * 100 < packed.length, decoded + " of " + packed.length + " cut points decoded as if whole");
	}

	/** Even an empty block is one byte, the token; no bytes at all is not a block. **/
	public function testNoBytesIsNotAnLz4Block():Void {
		Assert.raises(() -> Lz4.decompress(Bytes.alloc(0)), crossbyte.errors.IOError);
		Assert.equals(0, Lz4.decompress(Lz4.compress(Bytes.alloc(0))).length);
	}

	/**
	 * The encoder wrote through a ByteArray, whose writeBytes takes a
	 * ByteArray. Given a plain Bytes, every literal run made one from it,
	 * allocating and clearing a copy of the whole input per run, quadratic,
	 * and natively 900 KB of it crashed the process. ByteArray.compress
	 * passed itself and escaped it; any other caller did not.
	 */
	public function testCompressingPlainBytesCostsWhatAByteArrayDoes():Void {
		var text:Bytes = words(48 * 1024);
		var asByteArray:ByteArray = ByteArray.fromBytes(text.sub(0, text.length));

		var plain:Float = 0;
		var wrapped:Float = 0;
		for (round in 0...3) {
			var started:Float = haxe.Timer.stamp();
			var a:Bytes = Lz4.compress(text);
			plain += haxe.Timer.stamp() - started;

			started = haxe.Timer.stamp();
			var b:Bytes = Lz4.compress(asByteArray);
			wrapped += haxe.Timer.stamp() - started;

			Assert.equals(a.toHex(), b.toHex());
		}
		Assert.isTrue(plain < wrapped * 2 + 0.05, "plain Bytes took " + plain + "s against " + wrapped + "s as a ByteArray");
	}

	public function testUncompressCarriesTheLimitIntoTheLz4Decoder():Void {
		// The limit used to be applied to the finished buffer, so the memory
		// was taken before anything objected. This asserts the public path
		// refuses; that it refuses *during* the decode is the point of passing
		// maxOutputSize down rather than measuring afterwards.
		var bomb:ByteArray = ByteArray.fromBytes(lz4Bomb());
		bomb.position = 0;
		Assert.raises(() -> bomb.uncompress(CompressionAlgorithm.LZ4, 4096));

		var ok:ByteArray = ByteArray.fromBytes(lz4Bomb());
		ok.uncompress(CompressionAlgorithm.LZ4, BOMB_SIZE);
		Assert.equals(BOMB_SIZE, ok.length);
		Assert.equals(0, ok.position);
	}
}
