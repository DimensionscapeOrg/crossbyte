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

	/**
		The unsigned range at each edge where the encoded length changes and
		at the top bit. The writer looped while a signed `v > 0x7F`, so a
		value with bit 31 set went out as one byte, and `varUIntSize` sized it
		as one; the reader refused everything from 2^31 up.
	**/
	public function testVarUIntRoundTripsTheWholeUnsignedRange():Void {
		var values:Array<Int> = [0, 0x7F, 0x80, 0x3FFF, 0x4000, 1 << 30, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF];
		var sizes:Array<Int> = [1, 1, 2, 2, 3, 5, 5, 5, 5];

		for (i in 0...values.length) {
			Assert.equals(sizes[i], ByteArrayOutput.varUIntSize(values[i]), 'varUIntSize of ${StringTools.hex(values[i], 8)}');

			var one = new ByteArrayOutput();
			one.writeVarUInt(values[i]);
			var written:Bytes = one;
			Assert.equals(sizes[i], written.length, 'encoded length of ${StringTools.hex(values[i], 8)}');
		}

		var output = new ByteArrayOutput();
		for (value in values) {
			output.writeVarUInt(value);
		}

		var bytes:Bytes = output;
		var input:ByteArrayInput = ByteArray.fromBytes(bytes);
		for (value in values) {
			var read:Int = input.readVarUInt();
			Assert.equals(value, read, 'read back ${StringTools.hex(value, 8)}');
		}
		Assert.isTrue(input.eof());
	}

	/**
		ZigZag over every Int. 1 << 30 maps to 0x80000000, which the writer
		sent as a single byte that read back as 0; the reader refused what
		any value at or past 2^30 in magnitude maps to.
	**/
	public function testVarIntRoundTripsTheWholeIntRange():Void {
		var values:Array<Int> = [0, 1, -1, 63, -64, 64, -65, 1 << 29, -(1 << 29), 1 << 30, -(1 << 30), 0x7FFFFFFF, 0x80000000];

		var output = new ByteArrayOutput();
		for (value in values) {
			output.writeVarInt(value);
		}

		var bytes:Bytes = output;
		var input:ByteArrayInput = ByteArray.fromBytes(bytes);
		for (value in values) {
			Assert.equals(value, input.readVarInt(), 'read back $value');
		}
		Assert.isTrue(input.eof());
	}

	/**
		One name, one format. `ByteArray`'s unsigned varint was called
		`readVarInt`/`writeVarInt`, the names `ByteArrayInput` and
		`ByteArrayOutput` give ZigZag, so code moved from one class to the
		other compiled and read every negative number wrong. It is
		`readVarUInt`/`writeVarUInt` in all three now, and what one class
		writes the others read.
	**/
	public function testVarUIntIsOneFormatInEveryClass():Void {
		var values:Array<Int> = [0, 1, 0x7F, 0x80, 300, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF];

		var fromByteArray = new ByteArray();
		for (value in values) {
			fromByteArray.writeVarUInt(value);
		}
		fromByteArray.position = 0;
		var input:ByteArrayInput = fromByteArray;
		for (value in values) {
			var read:Int = input.readVarUInt();
			Assert.equals(value, read, 'ByteArray wrote ${StringTools.hex(value, 8)}');
		}

		var fromOutput = new ByteArrayOutput();
		for (value in values) {
			fromOutput.writeVarUInt(value);
		}
		var bytes:Bytes = fromOutput;
		var back:ByteArray = ByteArray.fromBytes(bytes);
		for (value in values) {
			var read:Int = back.readVarUInt();
			Assert.equals(value, read, 'ByteArrayOutput wrote ${StringTools.hex(value, 8)}');
		}
		Assert.equals(0, back.bytesAvailable);
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
		// Not an ObjectEncoding at all, the abstract is `from Int`, so this
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
