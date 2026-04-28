package crossbyte.io;

import haxe.io.Bytes;
import utest.Assert;

class ByteArrayTest extends utest.Test {
	public function testFromBytesCopiesReadableBytes():Void {
		var bytes = Bytes.ofString("hello");
		var byteArray:ByteArray = ByteArray.fromBytes(bytes);

		Assert.equals(bytes.length, byteArray.length);
		Assert.equals("hello", byteArray.readUTFBytes(byteArray.length));
	}
}
