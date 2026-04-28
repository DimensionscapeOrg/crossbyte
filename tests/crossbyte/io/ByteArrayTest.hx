package crossbyte.io;

import haxe.io.Bytes;
import haxe.Exception;
import utest.Assert;
import crossbyte.utils.CompressionAlgorithm;

class ByteArrayTest extends utest.Test {
	public function testClearResetsLengthPositionAndBytesAvailable():Void {
		var byteArray = new ByteArray();
		byteArray.writeUTFBytes("hello");
		byteArray.position = 2;

		byteArray.clear();

		Assert.equals(0, byteArray.length);
		Assert.equals(0, byteArray.position);
		Assert.equals(0, byteArray.bytesAvailable);
	}

	public function testFromBytesCopiesReadableBytes():Void {
		var bytes = Bytes.ofString("hello");
		var byteArray:ByteArray = ByteArray.fromBytes(bytes);

		Assert.equals(bytes.length, byteArray.length);
		Assert.equals("hello", byteArray.readUTFBytes(byteArray.length));
	}

	public function testLengthExpansionZeroFillsAndTruncationClampsPosition():Void {
		var byteArray = new ByteArray();
		byteArray.writeByte(0x41);
		byteArray.length = 4;

		Assert.equals(4, byteArray.length);
		byteArray.position = 1;
		Assert.equals(0, byteArray.readUnsignedByte());
		Assert.equals(0, byteArray.readUnsignedByte());
		Assert.equals(0, byteArray.readUnsignedByte());

		byteArray.position = 4;
		byteArray.length = 2;

		Assert.equals(2, byteArray.length);
		Assert.equals(2, byteArray.position);
	}

	public function testReadBytesWithOffsetPreservesExistingPrefix():Void {
		var source:ByteArray = ByteArray.fromBytes(Bytes.ofString("hello"));
		var target:ByteArray = ByteArray.fromBytes(Bytes.ofString("xx"));

		source.readBytes(target, 1, 3);

		Assert.equals(4, target.length);
		target.position = 0;
		Assert.equals("xhel", target.readUTFBytes(target.length));
		Assert.equals(3, source.position);
		Assert.equals(2, source.bytesAvailable);
	}

	public function testWriteBytesRespectsOffsetAndDefaultLength():Void {
		var source:ByteArray = ByteArray.fromBytes(Bytes.ofString("hello"));
		var target = new ByteArray();

		target.writeBytes(source, 2);

		Assert.equals(3, target.length);
		target.position = 0;
		Assert.equals("llo", target.readUTFBytes(target.length));
		Assert.equals(0, source.position);
	}

	public function testCompressAndUncompressDEFLATE():Void {
		var byteArray:ByteArray = ByteArray.fromBytes(Bytes.ofString("hello world"));
		byteArray.compress(CompressionAlgorithm.DEFLATE);
		byteArray.uncompress(CompressionAlgorithm.DEFLATE);

		Assert.equals("hello world", byteArray.toString());
	}

	public function testCompressAndUncompressLZ4():Void {
		var byteArray:ByteArray = ByteArray.fromBytes(Bytes.ofString("hello world"));
		byteArray.compress(CompressionAlgorithm.LZ4);
		byteArray.uncompress(CompressionAlgorithm.LZ4);

		Assert.equals("hello world", byteArray.toString());
	}

	public function testCompressAndUncompressGZIP():Void {
		var byteArray:ByteArray = ByteArray.fromBytes(Bytes.ofString("hello world"));
		byteArray.compress(CompressionAlgorithm.GZIP);
		byteArray.uncompress(CompressionAlgorithm.GZIP);

		Assert.equals("hello world", byteArray.toString());
	}

	public function testCompressAndUncompressBrotli():Void {
		var byteArray:ByteArray = ByteArray.fromBytes(Bytes.ofString("hello world hello world"));
		byteArray.compress(CompressionAlgorithm.BROTLI);
		byteArray.uncompress(CompressionAlgorithm.BROTLI);

		Assert.equals("hello world hello world", byteArray.toString());
	}

	public function testBrotliDecodesKnownFixture():Void {
		var byteArray:ByteArray = ByteArray.fromBytes(Bytes.ofHex("0b0c8068656c6c6f2066726f6d2062726f746c69206669787475726503"));
		byteArray.uncompress(CompressionAlgorithm.BROTLI);

		Assert.equals("hello from brotli fixture", byteArray.toString());
	}

	public function testBrotliRoundTripsBinaryBytes():Void {
		var bytes = Bytes.alloc(7);
		bytes.set(0, 0);
		bytes.set(1, 1);
		bytes.set(2, 2);
		bytes.set(3, 255);
		bytes.set(4, 0);
		bytes.set(5, 128);
		bytes.set(6, 64);

		var byteArray:ByteArray = ByteArray.fromBytes(bytes);
		byteArray.compress(CompressionAlgorithm.BROTLI);
		byteArray.uncompress(CompressionAlgorithm.BROTLI);

		Assert.equals(bytes.length, byteArray.length);
		byteArray.position = 0;
		for (i in 0...bytes.length) {
			Assert.equals(bytes.get(i), byteArray.readUnsignedByte());
		}
	}

	public function testInvalidBrotliPayloadThrows():Void {
		var byteArray:ByteArray = ByteArray.fromBytes(Bytes.ofString("not brotli"));

		Assert.raises(() -> {
			byteArray.uncompress(CompressionAlgorithm.BROTLI);
		});
	}

	public function testUnsupportedCompressionAlgorithmThrows():Void {
		var byteArray:ByteArray = ByteArray.fromBytes(Bytes.ofString("hello world"));

		Assert.raises(() -> {
			byteArray.compress(cast 1234);
		}, Exception);
	}

	public function testCompressionAlgorithmMappings():Void {
		var algorithmDeflate:CompressionAlgorithm = CompressionAlgorithm.fromString("deflate");
		var algorithmGzip:CompressionAlgorithm = CompressionAlgorithm.fromString("gzip");
		var algorithmBrotli:CompressionAlgorithm = CompressionAlgorithm.fromString("br");
		var algorithmLz4:CompressionAlgorithm = CompressionAlgorithm.fromString("lz4");
		var algorithmUnknown:CompressionAlgorithm = CompressionAlgorithm.fromString("zstd");

		Assert.equals(CompressionAlgorithm.DEFLATE, algorithmDeflate);
		Assert.equals(CompressionAlgorithm.GZIP, algorithmGzip);
		Assert.equals(CompressionAlgorithm.BROTLI, algorithmBrotli);
		Assert.equals(CompressionAlgorithm.LZ4, algorithmLz4);
		Assert.isNull(algorithmUnknown);

		Assert.equals("deflate", Std.string(CompressionAlgorithm.DEFLATE));
		Assert.equals("gzip", Std.string(CompressionAlgorithm.GZIP));
		Assert.equals("br", Std.string(CompressionAlgorithm.BROTLI));
		Assert.equals("lz4", Std.string(CompressionAlgorithm.LZ4));
	}
}
