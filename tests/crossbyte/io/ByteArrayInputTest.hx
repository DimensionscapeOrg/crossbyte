package crossbyte.io;

import haxe.io.Bytes;
import utest.Assert;

class ByteArrayInputTest extends utest.Test {
	public function testPositionSetterRejectsOutOfRangeValues():Void {
		#if final
		Assert.pass();
		return;
		#end

		var input:ByteArrayInput = ByteArray.fromBytes(Bytes.ofString("abc"));

		Assert.raises(() -> input.position = -1, String);
		Assert.raises(() -> input.position = 4, String);
		Assert.equals(0, input.position);
	}

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

	public function testReadByteThrowsWhenPastEnd():Void {
		#if final
		Assert.pass();
		return;
		#end

		var input:ByteArrayInput = ByteArray.fromBytes(Bytes.ofString("a"));

		Assert.equals("a".code, input.readByte());
		Assert.raises(() -> input.readByte(), String);
		Assert.equals(1, input.position);
		Assert.isTrue(input.eof());
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

	public function testReadUTFThrowsWhenPayloadIsTruncated():Void {
		#if final
		Assert.pass();
		return;
		#end

		var bytes = new ByteArray();
		bytes.writeShort(3);
		bytes.writeUTFBytes("hi");
		bytes.position = 0;

		var input:ByteArrayInput = bytes;

		Assert.raises(() -> input.readUTF(), String);
		Assert.equals(2, input.position);
		Assert.equals(2, input.bytesAvailable);
	}

	public function testReadVarUIntSupportsLargestPositiveInt():Void {
		var bytes = Bytes.alloc(5);
		bytes.set(0, 0xFF);
		bytes.set(1, 0xFF);
		bytes.set(2, 0xFF);
		bytes.set(3, 0xFF);
		bytes.set(4, 0x07);

		var input:ByteArrayInput = ByteArray.fromBytes(bytes);

		Assert.equals(0x7FFFFFFF, input.readVarUInt());
		Assert.isTrue(input.eof());
	}

	public function testReadVarUIntRejectsOverlongEncoding():Void {
		var bytes = Bytes.alloc(6);
		for (i in 0...6) {
			bytes.set(i, 0x80);
		}

		var input:ByteArrayInput = ByteArray.fromBytes(bytes);
		Assert.raises(() -> input.readVarUInt(), String);
	}

	public function testReadVarUIntRejectsOverflow():Void {
		// A fifth byte holds the last four bits of 32. Past them (2^32 + 1
		// here) the bits must not be shifted off the top, reading 1.
		for (top in [0x10, 0x7F]) {
			var bytes = Bytes.alloc(5);
			bytes.set(0, 0x81);
			bytes.set(1, 0x80);
			bytes.set(2, 0x80);
			bytes.set(3, 0x80);
			bytes.set(4, top);

			var input:ByteArrayInput = ByteArray.fromBytes(bytes);
			Assert.raises(() -> input.readVarUInt(), String);
		}
	}

	public function testReadVarUIntReadsTheTopOfTheUnsignedRange():Void {
		// 0xFFFFFFFF, which the writer can send: the reader must not stop at
		// 2^31 - 1, or a ZigZag value that far out could not be read.
		var bytes = Bytes.alloc(5);
		bytes.set(0, 0xFF);
		bytes.set(1, 0xFF);
		bytes.set(2, 0xFF);
		bytes.set(3, 0xFF);
		bytes.set(4, 0x0F);

		var input:ByteArrayInput = ByteArray.fromBytes(bytes);
		var value:Int = input.readVarUInt();
		Assert.equals(0xFFFFFFFF, value);
		Assert.isTrue(input.eof());
	}

	public function testReadVarUTFRejectsALengthPast31Bits():Void {
		// 0xFFFFFFFF as a length, which is -1 once it is an Int. Measured as
		// an Int it is shorter than any buffer, and readUTFBytes checks its
		// length only outside `final`.
		var bytes = Bytes.alloc(6);
		bytes.set(0, 0xFF);
		bytes.set(1, 0xFF);
		bytes.set(2, 0xFF);
		bytes.set(3, 0xFF);
		bytes.set(4, 0x0F);
		bytes.set(5, 0x41);

		var input:ByteArrayInput = ByteArray.fromBytes(bytes);
		Assert.raises(() -> input.readVarUTF(), String);
	}

	public function testReadVarUIntRejectsAVarintTheBufferEndsInside():Void {
		// Every byte asks for another and the buffer runs out. The bound holds
		// in a `final` release build too, which must not read past the end.
		var bytes = Bytes.alloc(2);
		bytes.set(0, 0x80);
		bytes.set(1, 0x80);

		var input:ByteArrayInput = ByteArray.fromBytes(bytes);
		Assert.raises(() -> input.readVarUInt(), String);
	}

	public function testReadVarUTFRejectsALengthTheBufferCannotHold():Void {
		// The length is a varint, so a peer can name up to 2^31-1. A guard
		// testing `position + n > length` would overflow at this size and wrap
		// negative, so it would pass and readUTFBytes would read off the end,
		// in ordinary builds too, not just `final`.
		var bytes = Bytes.alloc(6);
		bytes.set(0, 0xFF);
		bytes.set(1, 0xFF);
		bytes.set(2, 0xFF);
		bytes.set(3, 0xFF);
		bytes.set(4, 0x07);
		bytes.set(5, 0x41);

		var input:ByteArrayInput = ByteArray.fromBytes(bytes);
		Assert.raises(() -> input.readVarUTF(), String);
	}
}
