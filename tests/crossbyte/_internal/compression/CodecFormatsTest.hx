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
	 * allows added the way the gzip tool writes them, then as two members --
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

	/**
	 * Every codec says a stream is bad the same way, with an IOError, and a
	 * stream too big for the caller's limit with a RangeError. They threw bare
	 * strings -- "Brotli decompression failed", "Could not perform
	 * decompression", InflateImpl's "Invalid data" -- or haxe.io.Eof, and the
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
			{algorithm: CompressionAlgorithm.ZLIB, hex: "789c4b4c"}
		];
		for (c in cases) {
			assertThrows(IOError, () -> uncompressed(c.hex, c.algorithm), Std.string(c.algorithm) + " " + c.hex);
		}
	}

	public function testEveryCodecThrowsRangeErrorPastItsLimit():Void {
		var zeros:Bytes = Bytes.alloc(256 * 1024);
		for (algorithm in [
			CompressionAlgorithm.BROTLI,
			CompressionAlgorithm.DEFLATE,
			CompressionAlgorithm.GZIP,
			CompressionAlgorithm.LZ4,
			CompressionAlgorithm.ZLIB
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
