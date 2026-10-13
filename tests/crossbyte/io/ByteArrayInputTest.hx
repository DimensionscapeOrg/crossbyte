package crossbyte.io;

import haxe.io.Bytes;
import crossbyte.io.ByteArray;
import utest.Assert;

class ByteArrayInputTest extends utest.Test {
	public function testPositionSetterRejectsOutOfRangeValues():Void {
		var input:ByteArrayInput = ByteArray.fromBytes(Bytes.ofString("abc"));

		Assert.raises(() -> input.position = -1, crossbyte.errors.RangeError);
		Assert.raises(() -> input.position = 4, crossbyte.errors.RangeError);
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
		var input:ByteArrayInput = ByteArray.fromBytes(Bytes.ofString("a"));

		Assert.equals("a".code, input.readByte());
		Assert.raises(() -> input.readByte(), crossbyte.errors.EOFError);
		Assert.equals(1, input.position);
		Assert.isTrue(input.eof());
	}

	/**
		Each fixed-size read of a payload one byte short throws the EOFError
		and moves nothing, in every build: under `-D final` the check was
		compiled out, and natively the read went on past the buffer.
		`ci.yml` runs this class built with `-D final` too.
	**/
	public function testFixedSizeReadsOfAShortPayloadThrowInEveryBuild():Void {
		var reads:Array<{size:Int, read:ByteArrayInput->Void}> = [
			{size: 1, read: input -> input.readByte()},
			{size: 1, read: input -> input.readBoolean()},
			{size: 2, read: input -> input.readShort()},
			{size: 4, read: input -> input.readInt()},
			{size: 4, read: input -> input.readFloat()},
			{size: 8, read: input -> input.readDouble()},
			{size: 3, read: input -> input.readBytes(Bytes.alloc(3))},
			{size: 2, read: input -> input.readUtf()}
		];

		for (entry in reads) {
			var bytes = Bytes.alloc(entry.size + 1);
			bytes.fill(0, bytes.length, 0);
			var input:ByteArrayInput = ByteArray.fromBytes(bytes);
			input.position = 2;
			Assert.raises(() -> entry.read(input), crossbyte.errors.EOFError, "a read of " + entry.size + " bytes from " + (entry.size - 1));
			Assert.equals(2, input.position);
		}
	}

	public function testRequireSaysWhetherTheBytesAreThere():Void {
		var input:ByteArrayInput = ByteArray.fromBytes(Bytes.alloc(12));
		input.require(12);
		input.readInt();
		input.require(8);
		Assert.raises(() -> input.require(9), crossbyte.errors.EOFError);
		Assert.raises(() -> input.require(-1), crossbyte.errors.EOFError);
		// A count whose sum with the position wraps negative.
		Assert.raises(() -> input.require(0x7FFFFFFF), crossbyte.errors.EOFError);
		Assert.equals(4, input.position, "require moved the position");
		input.require(0);
	}

	public function testReadUTFBytesAndReadUTFAdvanceExpectedLengths():Void {
		var bytes = new ByteArray();
		bytes.writeUtfBytes("hey");
		bytes.writeUtf("ok");
		bytes.position = 0;

		var input:ByteArrayInput = bytes;

		Assert.equals("hey", input.readUtfBytes(3));
		Assert.equals(3, input.position);
		Assert.equals("ok", input.readUtf());
		Assert.isTrue(input.eof());
	}

	/**
		Checked in every build, `final` included, and the position left at the
		length, where it was, for a reader to try again once the rest has
		arrived. It was left past the length.
	**/
	public function testReadUTFThrowsWhenPayloadIsTruncated():Void {
		var bytes = new ByteArray();
		bytes.writeShort(3);
		bytes.writeUtfBytes("hi");
		bytes.position = 0;

		var input:ByteArrayInput = bytes;

		Assert.raises(() -> input.readUtf(), crossbyte.errors.EOFError);
		Assert.equals(0, input.position);
		Assert.equals(4, input.bytesAvailable);
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
		Assert.raises(() -> input.readVarUInt(), crossbyte.errors.RangeError);
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
			Assert.raises(() -> input.readVarUInt(), crossbyte.errors.RangeError);
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
		// an Int it is shorter than any buffer, and readUtfBytes checks its
		// length only outside `final`.
		var bytes = Bytes.alloc(6);
		bytes.set(0, 0xFF);
		bytes.set(1, 0xFF);
		bytes.set(2, 0xFF);
		bytes.set(3, 0xFF);
		bytes.set(4, 0x0F);
		bytes.set(5, 0x41);

		var input:ByteArrayInput = ByteArray.fromBytes(bytes);
		Assert.raises(() -> input.readVarUtf(), crossbyte.errors.EOFError);
	}

	public function testReadVarUIntRejectsAVarintTheBufferEndsInside():Void {
		// Every byte asks for another and the buffer runs out. The bound holds
		// in a `final` release build too, which must not read past the end.
		var bytes = Bytes.alloc(2);
		bytes.set(0, 0x80);
		bytes.set(1, 0x80);

		var input:ByteArrayInput = ByteArray.fromBytes(bytes);
		Assert.raises(() -> input.readVarUInt(), crossbyte.errors.EOFError);
	}

	public function testReadVarUTFRejectsALengthTheBufferCannotHold():Void {
		// The length is a varint, so a peer can name up to 2^31-1. A guard
		// testing `position + n > length` would overflow at this size and wrap
		// negative, so it would pass and readUtfBytes would read off the end,
		// in ordinary builds too, not just `final`.
		var bytes = Bytes.alloc(6);
		bytes.set(0, 0xFF);
		bytes.set(1, 0xFF);
		bytes.set(2, 0xFF);
		bytes.set(3, 0xFF);
		bytes.set(4, 0x07);
		bytes.set(5, 0x41);

		var input:ByteArrayInput = ByteArray.fromBytes(bytes);
		Assert.raises(() -> input.readVarUtf(), crossbyte.errors.EOFError);
	}

	/**
		A destination range that does not fit is refused in every build.
		`Bytes.blit` checks `pos + len`, which a large offset wraps negative,
		and natively the copy then went ahead, 2 GB past the buffer.
	**/
	public function testReadBytesRefusesADestinationRangeThatDoesNotFit():Void {
		var source = new crossbyte.io.ByteArray();
		for (_ in 0...64) {
			source.writeByte(0x41);
		}
		source.position = 0;
		var input:ByteArrayInput = source;
		var dst = Bytes.alloc(16);
		Assert.raises(() -> input.readBytes(dst, 0x7FFFFFF0, 32));
		Assert.raises(() -> input.readBytes(dst, -1, 4));
		Assert.raises(() -> input.readBytes(dst, 12, 8));
		Assert.equals(0, input.position);
		input.readBytes(dst, 12, 4);
		Assert.equals(0x41, dst.get(15));
		Assert.equals(4, input.position);
	}

	/**
		Strings read as `ByteArray` reads them: a NUL is a character like any
		other (JavaScript and HashLink stopped there), and a string's bytes
		end where its length says (JavaScript read on into a sequence cut
		short, taking the next field's bytes).
	**/
	public function testStringsReadAsByteArrayReadsThem():Void {
		var bytes = new crossbyte.io.ByteArray();
		bytes.writeByte(0x61);
		bytes.writeByte(0x00);
		bytes.writeByte(0x62);
		bytes.writeByte(0x41);
		bytes.writeByte(0xE2);
		bytes.writeByte(0x82);
		bytes.writeByte(0x58);
		bytes.position = 0;
		var input:ByteArrayInput = bytes;
		// Built, not a literal: HashLink compiles "a\u0000b" as a, NUL, NUL.
		Assert.equals("a" + String.fromCharCode(0) + "b", input.readUtfBytes(3));
		var cut:String = input.readUtfBytes(3);
		#if !(cpp || neko)
		Assert.equals("A\uFFFD", cut);
		#end
		Assert.equals(6, input.position);
		Assert.equals(0x58, input.readByte());
	}

	/**
		A string cut short leaves the position where it was, so a reader can
		try again once the rest has arrived: `readUtf` moved it past the
		length, and `readVarUtf` past the varint.
	**/
	public function testAStringCutShortLeavesThePositionAlone():Void {
		var fixed = new crossbyte.io.ByteArray();
		fixed.writeByte(5);
		fixed.writeByte(0);
		fixed.writeUtfBytes("abc");
		fixed.position = 0;
		var input:ByteArrayInput = fixed;
		Assert.raises(() -> input.readUtf());
		Assert.equals(0, input.position);

		var varied = new crossbyte.io.ByteArray();
		varied.writeByte(5);
		varied.writeUtfBytes("abc");
		varied.position = 0;
		var input2:ByteArrayInput = varied;
		Assert.raises(() -> input2.readVarUtf());
		Assert.equals(0, input2.position);
	}
}
