package crossbyte.io;

import haxe.io.Bytes;
import haxe.Exception;
import utest.Assert;
import crossbyte.utils.CompressionAlgorithm;

class ByteArrayTest extends utest.Test {
	public function testFromBytesCopiesReadableBytes():Void {
		var bytes = Bytes.ofString("hello");
		var byteArray:ByteArray = ByteArray.fromBytes(bytes);

		Assert.equals(bytes.length, byteArray.length);
		Assert.equals("hello", byteArray.readUTFBytes(byteArray.length));
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

	public function testUnsupportedCompressionAlgorithmThrows():Void {
		var byteArray:ByteArray = ByteArray.fromBytes(Bytes.ofString("hello world"));

		Assert.raises(() -> {
			byteArray.compress(cast 1234);
		}, Exception);
	}

	public function testCompressionAlgorithmMappings():Void {
		var algorithmDeflate:CompressionAlgorithm = CompressionAlgorithm.fromString("deflate");
		var algorithmGzip:CompressionAlgorithm = CompressionAlgorithm.fromString("gzip");
		var algorithmLz4:CompressionAlgorithm = CompressionAlgorithm.fromString("lz4");
		var algorithmUnknown:CompressionAlgorithm = CompressionAlgorithm.fromString("br");

		Assert.equals(CompressionAlgorithm.DEFLATE, algorithmDeflate);
		Assert.equals(CompressionAlgorithm.GZIP, algorithmGzip);
		Assert.equals(CompressionAlgorithm.LZ4, algorithmLz4);
		Assert.isNull(algorithmUnknown);

		Assert.equals("deflate", Std.string(CompressionAlgorithm.DEFLATE));
		Assert.equals("gzip", Std.string(CompressionAlgorithm.GZIP));
		Assert.equals("lz4", Std.string(CompressionAlgorithm.LZ4));
	}
}
