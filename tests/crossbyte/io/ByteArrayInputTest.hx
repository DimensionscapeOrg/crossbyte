package crossbyte.io;

import haxe.io.Bytes;
import utest.Assert;

class ByteArrayInputTest extends utest.Test {
	public function testPositionAndEofAdvanceAcrossPrimitiveReads():Void {
		var bytes = Bytes.alloc(7);
		bytes.set(0, 1);
		bytes.set(1, 0x34);
		bytes.set(2, 0x12);
		bytes.set(3, 0x78);
		bytes.set(4, 0x56);
		bytes.set(5, 0x34);
		bytes.set(6, 0x12);
		var input:ByteArrayInput = ByteArray.fromBytes(bytes);

		Assert.isFalse(input.eof());
		Assert.equals(7, input.bytesAvailable);

		Assert.isTrue(input.readBoolean());
		Assert.equals(1, input.position);
		Assert.equals(6, input.bytesAvailable);

		Assert.equals(0x1234, input.readShort());
		Assert.equals(3, input.position);

		Assert.equals(0x12345678, input.readInt());
		Assert.equals(7, input.position);
		Assert.equals(0, input.bytesAvailable);
		Assert.isTrue(input.eof());
	}

	public function testReadBytesRespectsDestinationOffset():Void {
		var input:ByteArrayInput = ByteArray.fromBytes(Bytes.ofString("hello"));
		var dst = Bytes.ofString("__!!");

		input.readBytes(dst, 2, 2);

		Assert.equals("__he", dst.toString());
		Assert.equals(2, input.position);
		Assert.equals(3, input.bytesAvailable);
	}

	public function testReadUTFBytesAndReadUTFAdvanceExpectedLengths():Void {
		var bytes = new ByteArray();
		bytes.writeUTFBytes("hey");
		bytes.writeUTF("ok");
		bytes.position = 0;

		var input:ByteArrayInput = bytes;

		Assert.equals("hey", input.readUTFBytes(3));
		Assert.equals(3, input.position);
		Assert.equals("ok", input.readUTF());
		Assert.isTrue(input.eof());
	}
}
