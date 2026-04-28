package crossbyte.io;

import haxe.io.Bytes;
import utest.Assert;

class ByteArrayIOTest extends utest.Test {
	public function testWriteUTFDoesNotRequireManualReserve():Void {
		var output = new ByteArrayOutput();
		output.writeUTF("héllo");

		var bytes:Bytes = output;
		var input:ByteArrayInput = ByteArray.fromBytes(bytes);

		Assert.equals("héllo", input.readUTF());
		Assert.isTrue(input.eof());
	}

	public function testWriteVarUTFDoesNotRequireManualReserve():Void {
		var output = new ByteArrayOutput();
		output.writeVarUTF("héllo");

		var bytes:Bytes = output;
		var input:ByteArrayInput = ByteArray.fromBytes(bytes);

		Assert.equals("héllo", input.readVarUTF());
		Assert.isTrue(input.eof());
	}

	public function testVarIntRoundTripPreservesSignedValues():Void {
		var output = new ByteArrayOutput();
		var values = [-1, 0, 1, 127, 128, 16384, -1234567];

		for (value in values) {
			output.writeVarInt(value);
		}

		var bytes:Bytes = output;
		var input:ByteArrayInput = ByteArray.fromBytes(bytes);

		for (value in values) {
			Assert.equals(value, input.readVarInt());
		}

		Assert.isTrue(input.eof());
	}

	public function testReadBytesDefaultLengthFillsDestination():Void {
		var input:ByteArrayInput = ByteArray.fromBytes(Bytes.ofString("abcdef"));
		input.position = 2;

		var dst = Bytes.alloc(3);
		input.readBytes(dst);

		Assert.equals("cde", dst.toString());
		Assert.equals(5, input.position);
		Assert.equals(1, input.bytesAvailable);
	}
}
