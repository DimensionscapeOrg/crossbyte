package crossbyte._internal.compression;

import crossbyte.errors.IOError;
import crossbyte.errors.RangeError;
import crossbyte.io.ByteArray;
import crossbyte.utils.CompressionAlgorithm;
import haxe.crypto.Adler32;
import haxe.io.Bytes;
import utest.Assert;

/**
 * The formats ByteArray reads and writes, as other implementations write and
 * read them, and what every codec throws when it cannot.
 */
class CodecFormatsTest extends utest.Test {
	private static inline var TEXT:String = "CrossByte reads zlib as zlib writes it. CrossByte reads zlib as zlib writes it. The end.";

	/** TEXT through Node's zlib.deflateSync at its default level, 9 and 1. **/
	private static final NODE_ZLIB:Array<String> = [
		"789c732eca2f2e76aa2c4955284a4d4c2956a8cac94c524884d2e5459925a9c50a99257a0ace44aa0bc9485548cd4bd1030096d91f7f",
		"78da732eca2f2e76aa2c4955284a4d4c2956a8cac94c524884d2e5459925a9c50a99257a0ace44aa0bc9485548cd4bd1030096d91f7f",
		"7801732eca2f2e76aa2c4955284a4d4c2956a8cac94c524884d2e5459925a9c50a99257a0ace44aa0bc9485548cd4bd1030096d91f7f"
	];

	/** The same, made with a preset dictionary, which a reader cannot have. **/
	private static inline var NODE_ZLIB_WITH_DICTIONARY:String = "78bb11ae039f738631148a5213538a15aa7232931412a174795166496ab14266899e02b1ea4232521552f352f40096d91f7f";

	private static function uncompressed(hex:String, algorithm:CompressionAlgorithm, limit:Int = 1 << 20):String {
		return decoded(Bytes.ofHex(hex), algorithm, limit).toString();
	}

	private static function decoded(packed:Bytes, algorithm:CompressionAlgorithm, limit:Int):Bytes {
		var data:ByteArray = ByteArray.fromBytes(packed.sub(0, packed.length));
		data.uncompress(algorithm, limit);
		return bytesOf(data);
	}

	private static function bytesOf(data:ByteArray):Bytes {
		var out:Bytes = Bytes.alloc(data.length);
		out.blit(0, data, 0, data.length);
		return out;
	}

	/**
	 * RFC 9110 defines HTTP's `deflate` as zlib, and every client and server
	 * that sends it sends zlib. ByteArray had raw deflate and nothing else, so
	 * a CrossByte client could read none of them.
	 */
	/**
		A body compressed as it is streamed, a piece at a time, inflates to
		everything written, as gzip and as zlib, across more than two
		windows, so the buffer the matches reach into slides, and with a
		write of nothing among the pieces.
	**/
	public function testAStreamedBodyInflatesToEverythingWritten():Void {
		var pieces:Array<Bytes> = [];
		var all:StringBuf = new StringBuf();
		var seed:Int = 12345;
		for (i in 0...160) {
			var line:StringBuf = new StringBuf();
			for (j in 0...(i % 7 == 0 ? 900 : 40)) {
				seed = (seed * 1103515 + 12345) & 0x7FFFFFFF;
				line.add(String.fromCharCode(97 + (seed >> 8) % 26));
				if (j % 9 == 0) line.add(' "state":"running" ');
			}
			line.add("\n");
			var text:String = line.toString();
			all.add(text);
			pieces.push(Bytes.ofString(text));
		}
		pieces.insert(3, Bytes.alloc(0));
		var expected:String = all.toString();
		Assert.isTrue(expected.length > 2 * 32768, "the stream is short of two windows: " + expected.length);

		for (gzip in [true, false]) {
			var encoder = new crossbyte._internal.deflatex.StreamEncoder(gzip);
			var body:ByteArray = new ByteArray();
			for (piece in pieces) {
				var out:Bytes = encoder.write(piece);
				body.writeBytes(ByteArray.fromBytes(out), 0, out.length);
			}
			var tail:Bytes = encoder.finish();
			body.writeBytes(ByteArray.fromBytes(tail), 0, tail.length);

			body.uncompress(gzip ? CompressionAlgorithm.GZIP : CompressionAlgorithm.ZLIB);
			Assert.equals(expected.length, body.length, (gzip ? "gzip" : "zlib") + " inflated to the wrong length");
			Assert.isTrue(body.toString() == expected, (gzip ? "gzip" : "zlib") + " inflated to something else");
		}

		for (gzip in [true, false]) {
			var empty:ByteArray = ByteArray.fromBytes(new crossbyte._internal.deflatex.StreamEncoder(gzip).finish());
			empty.uncompress(gzip ? CompressionAlgorithm.GZIP : CompressionAlgorithm.ZLIB);
			Assert.equals(0, empty.length, "an empty stream did not inflate to nothing");
		}
	}

	/**
		Later pieces reach back into earlier ones: two hundred short messages
		that repeat their fields compress, streamed, to far less than the same
		messages compressed one at a time, which is what compressing each
		chunk of a stream alone would have cost.
	**/
	public function testAStreamReachesBackIntoWhatWasWritten():Void {
		var streamed:Int = 0;
		var alone:Int = 0;
		var raw:Int = 0;
		var encoder = new crossbyte._internal.deflatex.StreamEncoder(false);
		for (i in 0...200) {
			var message:Bytes = Bytes.ofString('data: {"type":"tick","seq":$i,"state":"running","players":[1,2,3]}\n\n');
			raw += message.length;
			streamed += encoder.write(message).length;
			var single = new crossbyte._internal.deflatex.StreamEncoder(false);
			alone += single.write(message).length + single.finish().length;
		}
		streamed += encoder.finish().length;
		Assert.isTrue(streamed * 2 < alone, 'streamed $streamed bytes against $alone compressed one at a time');
		Assert.isTrue(streamed < raw, 'streamed $streamed bytes against $raw raw');
	}

	#if (java || jvm || nodejs || cpp)
	/**
		What each write returns can be inflated before the stream ends: the
		sync flush is what lets a client show a streamed response as it
		arrives rather than when it is done. On native the pieces come from
		zlib, which flushes only when told to.
	**/
	public function testEachWriteCanBeInflatedAsItArrives():Void {
		var encoder = new crossbyte._internal.deflatex.StreamEncoder(false);
		var sent:ByteArray = new ByteArray();
		var so_far:String = "";
		for (i in 0...3) {
			var text:String = 'event $i: {"type":"tick","seq":$i}\n';
			so_far += text;
			var out:Bytes = encoder.write(Bytes.ofString(text));
			sent.writeBytes(ByteArray.fromBytes(out), 0, out.length);
			Assert.equals(so_far, __inflateSoFar(sent), "the stream so far did not inflate to what was written after write " + i);
		}
	}

	private static function __inflateSoFar(zlib:ByteArray):String {
		var data:Bytes = Bytes.alloc(zlib.length);
		data.blit(0, zlib, 0, zlib.length);
		#if (java || jvm)
		var inflater = new java.util.zip.Inflater();
		inflater.setInput(data.getData(), 0, data.length);
		var out:Bytes = Bytes.alloc(65536);
		var n:Int = inflater.inflate(out.getData(), 0, out.length);
		inflater.end();
		return out.getString(0, n);
		#elseif cpp
		var inflater = new haxe.zip.Uncompress();
		inflater.setFlushMode(haxe.zip.FlushMode.SYNC);
		var out:Bytes = Bytes.alloc(65536);
		var r = inflater.execute(data, 0, out, 0);
		inflater.close();
		return out.getString(0, r.write);
		#else
		var zlibModule:Dynamic = js.Lib.require("zlib");
		var buffer:Dynamic = js.node.Buffer.from(data.getData());
		var result:Dynamic = zlibModule.inflateSync(buffer, {finishFlush: zlibModule.constants.Z_SYNC_FLUSH});
		return result.toString("utf8");
		#end
	}
	#end

	public function testZlibIsReadAsZlibWritesIt():Void {
		for (hex in NODE_ZLIB) {
			Assert.equals(TEXT, uncompressed(hex, CompressionAlgorithm.ZLIB), hex.substr(0, 4));
		}
	}

	public function testZlibIsWrittenAsZlibReadsIt():Void {
		var data:ByteArray = ByteArray.fromBytes(Bytes.ofString(TEXT));
		data.compress(CompressionAlgorithm.ZLIB);
		var packed:Bytes = bytesOf(data);

		// A header zlib accepts: deflate, a 32K window, a check value that
		// makes the pair a multiple of 31, and no dictionary.
		Assert.equals(0x78, packed.get(0));
		Assert.equals(0, ((packed.get(0) << 8) | packed.get(1)) % 31);
		Assert.equals(0, packed.get(1) & 0x20);

		// The body is the raw deflate stream, and the trailer the Adler-32 of
		// the text, big-endian.
		var body:Bytes = packed.sub(2, packed.length - 6);
		var inner:ByteArray = ByteArray.fromBytes(body);
		inner.uncompress(CompressionAlgorithm.DEFLATE);
		Assert.equals(TEXT, inner.toString());
		var adler:Int = Adler32.make(Bytes.ofString(TEXT));
		var at:Int = packed.length - 4;
		Assert.equals(adler, (packed.get(at) << 24) | (packed.get(at + 1) << 16) | (packed.get(at + 2) << 8) | packed.get(at + 3));

		data.uncompress(CompressionAlgorithm.ZLIB);
		Assert.equals(TEXT, data.toString());
	}

	public function testZlibIsNamedZlib():Void {
		Assert.equals(CompressionAlgorithm.ZLIB, CompressionAlgorithm.fromString("zlib"));
		var name:String = CompressionAlgorithm.ZLIB;
		Assert.equals("zlib", name);
		Assert.notEquals(CompressionAlgorithm.DEFLATE, CompressionAlgorithm.ZLIB);
	}

	public function testDamagedZlibIsRefusedAsBadData():Void {
		var good:Bytes = Bytes.ofHex(NODE_ZLIB[0]);

		var badAdler:Bytes = good.sub(0, good.length);
		badAdler.set(badAdler.length - 1, badAdler.get(badAdler.length - 1) ^ 1);

		// Raw deflate is not zlib: the header check fails on it.
		var raw:ByteArray = ByteArray.fromBytes(Bytes.ofString(TEXT));
		raw.compress(CompressionAlgorithm.DEFLATE);
		var rawHex:String = bytesOf(raw).toHex();

		var cases:Array<{name:String, hex:String}> = [
			{name: "Adler-32 wrong", hex: badAdler.toHex()},
			{name: "cut before the trailer", hex: good.sub(0, good.length - 3).toHex()},
			{name: "cut in the stream", hex: good.sub(0, 12).toHex()},
			{name: "header only", hex: "789c"},
			{name: "empty", hex: ""},
			{name: "raw deflate", hex: rawHex},
			{name: "preset dictionary", hex: NODE_ZLIB_WITH_DICTIONARY}
		];
		for (c in cases) {
			assertThrows(IOError, () -> uncompressed(c.hex, CompressionAlgorithm.ZLIB), "zlib " + c.name);
		}
	}

	private static inline var GZIP_TEXT:String = "gzip members, extra fields, comments and header CRCs are all RFC 1952.";

	/**
	 * GZIP_TEXT through Node's gzipSync, with the header fields RFC 1952
	 * allows added the way the gzip tool writes them, then as two members,
	 * each accepted by Node's gunzipSync. ByteArray read a name and nothing
	 * else: an extra field, a comment or a header CRC was refused as
	 * unsupported, and a second member failed its CRC, since the trailer was
	 * taken to be the input's last eight bytes.
	 */
	private static final NODE_GZIP_VARIANTS:Array<{name:String, hex:String}> = [
		{
			name: "extra field",
			hex: "1f8b080400000000000a060041420200010205c1c10980301004c056b6802028f8f01db08074709a5503b928777988d53b737ee58152379a07f0ed26380a6bf680fd5665eb0e69191725d31053748811522bd21a312ef334fc47c761db46000000"
		},
		{
			name: "comment",
			hex: "1f8b081000000000000a6120636f6d6d656e740005c1c10980301004c056b6802028f8f01db08074709a5503b928777988d53b737ee58152379a07f0ed26380a6bf680fd5665eb0e69191725d31053748811522bd21a312ef334fc47c761db46000000"
		},
		{
			name: "header CRC",
			hex: "1f8b080200000000000a03cf05c1c10980301004c056b6802028f8f01db08074709a5503b928777988d53b737ee58152379a07f0ed26380a6bf680fd5665eb0e69191725d31053748811522bd21a312ef334fc47c761db46000000"
		},
		{
			name: "every field",
			hex: "1f8b081e00000000000a020078796e616d652e74787400636f6d6d656e7400d16105c1c10980301004c056b6802028f8f01db08074709a5503b928777988d53b737ee58152379a07f0ed26380a6bf680fd5665eb0e69191725d31053748811522bd21a312ef334fc47c761db46000000"
		},
		{
			name: "two members",
			hex: "1f8b080000000000000a4bafca2c50c84dcd4d4a2d2ad65148ad28294a5448cb4ccd4929d65148cecfcd4dcd2b010057cd1da4230000001f8b080000000000000a2b5648cc4b51c8484d4c492d52700e722e56482c4a5548ccc9510872735630b43435d20300f42f5ea323000000"
		}
	];

	public function testGzipIsReadAsTheGzipFormatAllowsIt():Void {
		for (variant in NODE_GZIP_VARIANTS) {
			Assert.equals(GZIP_TEXT, uncompressed(variant.hex, CompressionAlgorithm.GZIP), variant.name);
		}
		// Zero padding after the last member is ignored, as gzip and Node do.
		Assert.equals(GZIP_TEXT, uncompressed(NODE_GZIP_VARIANTS[4].hex + "00000000", CompressionAlgorithm.GZIP), "padded");
	}

	public function testDamagedGzipIsRefusedAsBadData():Void {
		var one:String = NODE_GZIP_VARIANTS[0].hex;
		var two:String = NODE_GZIP_VARIANTS[4].hex;
		var cases:Array<{name:String, hex:String}> = [
			// The header CRC's first byte flipped.
			{name: "header CRC wrong", hex: "1f8b080200000000000a02cf" + NODE_GZIP_VARIANTS[2].hex.substr(24)},
			{name: "reserved flag", hex: "1f8b0820" + one.substr(8)},
			{name: "garbage after a member", hex: two + "78797a"},
			{name: "half a second member", hex: two.substr(0, two.length - 20)},
			{name: "extra field cut short", hex: one.substr(0, 26)}
		];
		for (c in cases) {
			assertThrows(IOError, () -> uncompressed(c.hex, CompressionAlgorithm.GZIP), "gzip " + c.name);
		}
	}

	/** The limit is on what every member inflates to together. **/
	public function testGzipMembersShareOneLimit():Void {
		var half:ByteArray = ByteArray.fromBytes(Bytes.alloc(20000));
		half.compress(CompressionAlgorithm.GZIP);
		var member:String = bytesOf(half).toHex();
		var both:String = member + member;
		Assert.equals(40000, decoded(Bytes.ofHex(both), CompressionAlgorithm.GZIP, 40000).length);
		assertThrows(RangeError, () -> decoded(Bytes.ofHex(both), CompressionAlgorithm.GZIP, 30000), "two members past the limit");
	}

	private static inline var FRAME_TEXT:String = "LZ4 frames say where they end. LZ4 frames say where they end, and what they hold. LZ4 frames say where they end.";

	/**
	 * FRAME_TEXT as the lz4 library (lz4frame.c 1.9, the one crossbyte-lz4
	 * vendors) writes it: linked 64 KB blocks with block checksums and the
	 * content size; independent 4 MB blocks with a content checksum; linked
	 * 256 KB blocks with everything.
	 */
	private static final REFERENCE_FRAMES:Array<String> = [
		"04224d1878407000000000000000d33e000000ff104c5a34206672616d657320736179207768657265207468657920656e642e201f000aa22c20616e64207768617432003f686f6c3300095020656e642e4aa0014b00000000",
		"04224d186440a73e000000ff104c5a34206672616d657320736179207768657265207468657920656e642e201f000aa22c20616e64207768617432003f686f6c3300095020656e642e00000000d17911a9",
		"04224d187c4070000000000000001d3e000000ff104c5a34206672616d657320736179207768657265207468657920656e642e201f000aa22c20616e64207768617432003f686f6c3300095020656e642e4aa0014b00000000d17911a9"
	];

	/**
	 * ByteArray had LZ4 blocks and nothing else: no way to read what the lz4
	 * tool writes, or to write a stream a reader can check for being whole.
	 */
	public function testLz4FramesAreReadAsTheLz4LibraryWritesThem():Void {
		for (hex in REFERENCE_FRAMES) {
			Assert.equals(FRAME_TEXT, uncompressed(hex, CompressionAlgorithm.LZ4_FRAME), hex.substr(8, 4));
		}
		// Frames follow one another, and skippable frames are skipped.
		var skippable:String = "532a4d18" + "03000000" + "aabbcc";
		Assert.equals(FRAME_TEXT + FRAME_TEXT,
			uncompressed(REFERENCE_FRAMES[0] + skippable + REFERENCE_FRAMES[1], CompressionAlgorithm.LZ4_FRAME));
		Assert.equals(CompressionAlgorithm.LZ4_FRAME, CompressionAlgorithm.fromString("lz4-frame"));
	}

	public function testLz4FramesAreWrittenToBeChecked():Void {
		var data:ByteArray = ByteArray.fromBytes(Bytes.ofString(FRAME_TEXT));
		data.compress(CompressionAlgorithm.LZ4_FRAME);
		var frame:Bytes = bytesOf(data);

		// The magic number, then version 01 with independent blocks, the
		// content size and a content checksum, and 4 MB blocks.
		Assert.equals("04224d18", frame.sub(0, 4).toHex());
		Assert.equals(0x6C, frame.get(4));
		Assert.equals(0x70, frame.get(5));
		Assert.equals(FRAME_TEXT.length, frame.get(6) | (frame.get(7) << 8));
		// The descriptor's checksum is the second byte of its xxHash32.
		var headerChecksum:Int = (crossbyte._internal.lz4.XXHash32.hash(frame, 4, 10) >>> 8) & 0xFF;
		Assert.equals(headerChecksum, frame.get(14));

		data.uncompress(CompressionAlgorithm.LZ4_FRAME);
		Assert.equals(FRAME_TEXT, data.toString());

		// Incompressible input is stored, flagged in the block's size.
		var noise:Bytes = Bytes.alloc(300);
		var state:Int = 0x7EED;
		for (i in 0...noise.length) {
			state ^= state << 13;
			state ^= state >>> 17;
			state ^= state << 5;
			noise.set(i, state & 0xFF);
		}
		var stored:ByteArray = ByteArray.fromBytes(noise.sub(0, noise.length));
		stored.compress(CompressionAlgorithm.LZ4_FRAME);
		var storedFrame:Bytes = bytesOf(stored);
		Assert.equals(0x80, storedFrame.get(18) & 0x80);
		Assert.equals(0, decoded(storedFrame, CompressionAlgorithm.LZ4_FRAME, 1 << 20).compare(noise));
	}

	/** Published xxHash32 values, which every frame checksum is. **/
	public function testXXHash32MatchesItsReference():Void {
		Assert.equals(0x02CC5D05, crossbyte._internal.lz4.XXHash32.hash(Bytes.alloc(0), 0, 0));
		Assert.equals(0x32D153FF, crossbyte._internal.lz4.XXHash32.hash(Bytes.ofString("abc"), 0, 3));
	}

	/**
	 * A frame says where it ends and what it holds, so every cut and every
	 * damaged checksum is refused, the thing a bare block cannot promise.
	 */
	public function testACutOrDamagedLz4FrameIsAlwaysRefused():Void {
		var whole:Bytes = Bytes.ofHex(REFERENCE_FRAMES[2]);
		for (cut in 0...whole.length) {
			assertThrows(IOError, () -> decoded(whole.sub(0, cut), CompressionAlgorithm.LZ4_FRAME, 1 << 20), "frame cut at " + cut);
		}
		for (at in [6, 14, whole.length - 9, whole.length - 1]) {
			var damaged:Bytes = whole.sub(0, whole.length);
			damaged.set(at, damaged.get(at) ^ 0x04);
			assertThrows(IOError, () -> decoded(damaged, CompressionAlgorithm.LZ4_FRAME, 1 << 20), "byte " + at + " flipped");
		}
	}

	public function testLz4FramesKeepTheLimit():Void {
		var zeros:ByteArray = ByteArray.fromBytes(Bytes.alloc(200000));
		zeros.compress(CompressionAlgorithm.LZ4_FRAME);
		var frame:Bytes = bytesOf(zeros);
		// The stated content size is past the limit: refused before a block
		// is decoded.
		assertThrows(RangeError, () -> decoded(frame, CompressionAlgorithm.LZ4_FRAME, 50000), "stated size past the limit");
		Assert.equals(200000, decoded(frame, CompressionAlgorithm.LZ4_FRAME, 200000).length);
	}

	/**
	 * Every codec says a stream is bad the same way, with an IOError, and a
	 * stream too big for the caller's limit with a RangeError. They threw bare
	 * strings, "Brotli decompression failed", "Could not perform
	 * decompression", InflateImpl's "Invalid data", or haxe.io.Eof, and the
	 * HTTP client reported every one of those as an unsupported content
	 * coding, since a String is how it is told of one.
	 */
	public function testEveryCodecThrowsIOErrorForBadData():Void {
		var cases:Array<{algorithm:CompressionAlgorithm, hex:String}> = [
			{algorithm: CompressionAlgorithm.BROTLI, hex: "ecffff7f"},
			{algorithm: CompressionAlgorithm.BROTLI, hex: "1b500000"},
			{algorithm: CompressionAlgorithm.DEFLATE, hex: "ffffffff"},
			{algorithm: CompressionAlgorithm.DEFLATE, hex: "4b4c"},
			{algorithm: CompressionAlgorithm.GZIP, hex: "1f8b"},
			{algorithm: CompressionAlgorithm.GZIP, hex: "00112233445566778899"},
			{algorithm: CompressionAlgorithm.LZ4, hex: "f0"},
			{algorithm: CompressionAlgorithm.LZ4, hex: "40616263"},
			{algorithm: CompressionAlgorithm.ZLIB, hex: "789c4b4c"},
			{algorithm: CompressionAlgorithm.LZ4_FRAME, hex: "04224d18"},
			{algorithm: CompressionAlgorithm.LZ4_FRAME, hex: "00112233"}
		];
		for (c in cases) {
			assertThrows(IOError, () -> uncompressed(c.hex, c.algorithm), Std.string(c.algorithm) + " " + c.hex);
		}
	}

	/**
		On native, gzip, zlib and raw DEFLATE come from hxcpp's own zlib, and
		on Node from Node's. A 64 KB page of JSON went to 8.3 KB through the
		pure Haxe deflater, at three and a half times zlib's cost natively and
		five times on Node; zlib writes about 6 KB. Each still reads back whole
		through the readers here, and a gzip member's header is the same
		everywhere: Node's named its system.
	**/
	public function testDeflateCodingsCompressAPageOfJson():Void {
		var json:Bytes = __jsonPage();

		for (algorithm in [CompressionAlgorithm.GZIP, CompressionAlgorithm.ZLIB, CompressionAlgorithm.DEFLATE]) {
			var data:ByteArray = ByteArray.fromBytes(json.sub(0, json.length));
			data.compress(algorithm);
			var packed:Bytes = bytesOf(data);
			#if (cpp || nodejs)
			Assert.isTrue(packed.length < 7000, Std.string(algorithm) + " wrote " + packed.length + " bytes");
			#end
			if (algorithm == CompressionAlgorithm.GZIP) {
				Assert.equals("1f8b0800000000000000", packed.sub(0, 10).toHex(), "the gzip header");
			}
			var back:Bytes = decoded(packed, algorithm, json.length);
			Assert.isTrue(back.length == json.length && back.compare(json) == 0, Std.string(algorithm) + " did not read back whole");
		}
	}

	/**
		Brotli from Node's zlib on Node, as from `crossbyte-brotli` natively.
		The page took 2.5 ms at quality 4 through the Haxe encoder, and Node's
		takes about 0.17 for the same size, so a server answering browsers
		was held to a few hundred compressed responses a second. The budget
		is a millisecond a page, and the stream reads back whole through the
		Haxe decoder.
	**/
	public function testNativeBrotliCompressesAPageOfJsonQuickly():Void {
		#if (nodejs || crossbyte_brotli_native)
		var json:Bytes = __jsonPage();
		var packed:Bytes = crossbyte._internal.brotli.Brotli.compress(json);
		var started:Float = haxe.Timer.stamp();
		for (i in 0...30) {
			crossbyte._internal.brotli.Brotli.compress(json);
		}
		var elapsed:Float = haxe.Timer.stamp() - started;
		Assert.isTrue(elapsed < 0.03, "30 pages took " + Math.round(elapsed * 1000) + " ms");
		var back:Bytes = decoded(packed, CompressionAlgorithm.BROTLI, json.length);
		Assert.isTrue(back.length == json.length && back.compare(json) == 0, "Brotli did not read back whole");
		#else
		Assert.pass();
		#end
	}

	/**
		A body compressed as it is streamed comes from hxcpp's zlib on native,
		as a whole body does. The page streamed as gzip in 8 KB pieces came to
		8.4 KB through the Haxe deflater, at three times zlib's cost; zlib
		writes 5.8 KB. It still reads back whole.
	**/
	public function testAStreamedBodyIsDeflatedByZlibOnNative():Void {
		var json:Bytes = __jsonPage();
		var encoder = new crossbyte._internal.deflatex.StreamEncoder(true);
		var out = new haxe.io.BytesBuffer();
		var at:Int = 0;
		while (at < json.length) {
			var n:Int = json.length - at < 8192 ? json.length - at : 8192;
			out.add(encoder.write(json, at, n));
			at += n;
		}
		out.add(encoder.finish());
		var packed:Bytes = out.getBytes();
		#if cpp
		Assert.isTrue(packed.length < 7000, "the stream came to " + packed.length + " bytes");
		#end
		var back:Bytes = decoded(packed, CompressionAlgorithm.GZIP, json.length);
		Assert.isTrue(back.length == json.length && back.compare(json) == 0, "the stream did not read back whole");
	}

	/** 64 KB of JSON, as an API answers a list. **/
	private static function __jsonPage():Bytes {
		var page = new StringBuf();
		page.add("[");
		var i = 0;
		while (page.length < 64 * 1024) {
			if (i > 0) page.add(",");
			page.add('{"id":$i,"name":"item number $i","price":${i * 3 % 1000}.99,"tags":["alpha","beta","gamma"],"inStock":${i % 3 != 0}}');
			i++;
		}
		page.add("]");
		return Bytes.ofString(page.toString());
	}

	/**
		CRC-32 eight bytes at a time agrees with the definition a bit at a
		time, at every length and alignment the eight-byte step can miss.
	**/
	public function testCrc32AgreesWithTheBitwiseDefinition():Void {
		var data:Bytes = Bytes.alloc(4096 + 64);
		var s:Int = 12345;
		for (i in 0...data.length) {
			s = (s * 1103515245 + 12345) & 0x7FFFFFFF;
			data.set(i, (s >> 16) & 0xFF);
		}
		for (offset in 0...9) {
			for (length in [0, 1, 2, 3, 7, 8, 9, 15, 16, 17, 31, 64, 65, 1000, 4096]) {
				var crc = new crossbyte._internal.deflatex.CRC32();
				crc.updateBytes(data, offset, length);
				Assert.equals(__bitwiseCrc32(data, offset, length), crc.value, 'offset $offset, length $length');
			}
		}
		// Updated in pieces, it is the CRC of the whole.
		var pieces = new crossbyte._internal.deflatex.CRC32();
		pieces.updateBytes(data, 0, 13);
		pieces.updateBytes(data, 13, 1000);
		pieces.updateBytes(data, 1013, 3000);
		Assert.equals(__bitwiseCrc32(data, 0, 4013), pieces.value);
	}

	private static function __bitwiseCrc32(data:Bytes, offset:Int, length:Int):Int {
		var crc:Int = 0xFFFFFFFF;
		for (i in offset...offset + length) {
			crc ^= data.get(i);
			for (k in 0...8) {
				crc = (crc & 1) != 0 ? (crc >>> 1) ^ 0xEDB88320 : crc >>> 1;
			}
		}
		return ~crc;
	}

	public function testEveryCodecThrowsRangeErrorPastItsLimit():Void {
		var zeros:Bytes = Bytes.alloc(256 * 1024);
		for (algorithm in [
			CompressionAlgorithm.BROTLI,
			CompressionAlgorithm.DEFLATE,
			CompressionAlgorithm.GZIP,
			CompressionAlgorithm.LZ4,
			CompressionAlgorithm.ZLIB,
			CompressionAlgorithm.LZ4_FRAME
		]) {
			var data:ByteArray = ByteArray.fromBytes(zeros.sub(0, zeros.length));
			data.compress(algorithm);
			var packed:Bytes = bytesOf(data);
			assertThrows(RangeError, () -> decoded(packed, algorithm, 16 * 1024), Std.string(algorithm));
			// And inside the limit, it all comes back.
			Assert.equals(zeros.length, decoded(packed, algorithm, zeros.length).length, Std.string(algorithm));
		}
	}

	private static function assertThrows(type:Class<Dynamic>, run:Void->Dynamic, what:String):Void {
		try {
			run();
			Assert.fail(what + ": nothing was thrown");
		} catch (e:Dynamic) {
			Assert.isTrue(Std.isOfType(e, type), what + ": threw " + describe(e) + ", not " + Type.getClassName(type));
		}
	}

	private static function describe(e:Dynamic):String {
		var cls = Type.getClass(e);
		return (cls == null ? "a " + Type.typeof(e) : Type.getClassName(cls)) + " (" + Std.string(e) + ")";
	}
}
