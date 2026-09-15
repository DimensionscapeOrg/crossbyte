package crossbyte.io;

import crossbyte.net.ObjectEncoding;
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

	public function testObjectsRoundTripThroughHxsfAndJson():Void {
		for (encoding in [ObjectEncoding.HXSF, ObjectEncoding.JSON]) {
			var out = new ByteArray();
			out.objectEncoding = encoding;
			out.writeObject({name: "crossbyte", count: 3});

			Assert.isTrue(out.length > 0, "writeObject wrote nothing for encoding " + encoding);

			out.position = 0;
			var back = out.readObject();
			Assert.equals("crossbyte", back.name);
			Assert.equals(3, back.count);
		}
	}

	public function testAnEncodingThisBuildCannotDoIsRefused():Void {
		// Not an ObjectEncoding at all -- the abstract is `from Int`, so this
		// compiles and used to read back null and write zero bytes.
		__assertEncodingRefused(cast 99);

		#if !format
		// AMF needs the optional "format" haxelib. Without it the object used to
		// go nowhere quietly, which is the worst way to find out.
		__assertEncodingRefused(ObjectEncoding.AMF0);
		__assertEncodingRefused(ObjectEncoding.AMF3);
		#end
	}

	private function __assertEncodingRefused(encoding:ObjectEncoding):Void {
		var out = new ByteArray();
		out.objectEncoding = encoding;
		Assert.raises(() -> out.writeObject({value: 1}));
		Assert.equals(0, out.length, "a refused writeObject still wrote bytes");

		// Something readable is present, so the throw is about the encoding and
		// not about running out of bytes.
		var input = new ByteArray();
		input.writeUTF("not an object");
		input.position = 0;
		input.objectEncoding = encoding;
		Assert.raises(() -> input.readObject());
	}
}
