package crossbyte.io;

import haxe.io.Bytes;
import utest.Assert;

class ByteArrayOutputTest extends utest.Test {
	public function testInitialCapacityDoesNotLeakUnusedBytesIntoOutput():Void {
		var output = new ByteArrayOutput(8);
		output.writeInt(0x12345678);

		var bytes:Bytes = output;

		Assert.equals(4, bytes.length);
		var input:ByteArrayInput = ByteArray.fromBytes(bytes);
		Assert.equals(0x12345678, input.readInt());
		Assert.isTrue(input.eof());
	}

	public function testReserveDoesNotLeakUnusedBytesIntoOutput():Void {
		var output = new ByteArrayOutput();
		output.reserve(8);
		output.writeInt(0x12345678);

		var bytes:Bytes = output;

		Assert.equals(4, bytes.length);
		var input:ByteArrayInput = ByteArray.fromBytes(bytes);
		Assert.equals(0x12345678, input.readInt());
		Assert.isTrue(input.eof());
	}

	public function testToBytesFlushesUnflushedBytes():Void {
		var output = new ByteArrayOutput();
		output.reserve(6);
		output.writeInt(0x12345678);
		output.writeShort(0x4321);

		var copy:ByteArray = output;
		copy.position = 0;

		Assert.equals(0x12345678, copy.readInt());
		Assert.equals(0x4321, copy.readUnsignedShort());
		Assert.equals(0, copy.bytesAvailable);
	}

	public function testResetAllowsReuseWithNewCapacity():Void {
		var output = new ByteArrayOutput(1);
		output.writeByte(0x2A);
		output.reset(4);
		output.writeInt(0x12345678);

		var bytes:Bytes = output;
		var input:ByteArrayInput = ByteArray.fromBytes(bytes);

		Assert.equals(0x12345678, input.readInt());
		Assert.isTrue(input.eof());
	}

	public function testReserveAppendsAcrossChunksInOrder():Void {
		var output = new ByteArrayOutput(1);
		output.writeByte(0x11);
		output.reserve(4);
		output.writeInt(0x55667788);

		var bytes:Bytes = output;
		var input:ByteArrayInput = ByteArray.fromBytes(bytes);

		Assert.equals(0x11, input.readByte());
		Assert.equals(0x55667788, input.readInt());
		Assert.isTrue(input.eof());
	}

	public function testValidateSizeUsesCurrentChunkCapacity():Void {
		var output = new ByteArrayOutput(1);
		output.writeByte(0x11);
		output.reserve(4);

		// The chunk reserve() took, which is at least what it asked for: the
		// room in it, not the total, is what validateSize answers against.
		var room:Int = output.length - 1;
		Assert.isTrue(room >= 4);
		Assert.isTrue(output.validateSize(4));
		Assert.isTrue(output.validateSize(room));
		Assert.isFalse(output.validateSize(room + 1));
		Assert.isTrue(output.validateSizeAt(2, room - 2));
		Assert.isFalse(output.validateSizeAt(3, room - 2));
	}

	public function testBytesWrittenTracksUsedBytesAcrossChunks():Void {
		var output = new ByteArrayOutput(1);
		output.writeByte(0x11);
		Assert.equals(1, output.bytesWritten);

		output.reserve(4);
		output.writeInt(0x22334455);
		Assert.equals(5, output.bytesWritten);
	}

	public function testReserveThatFitsKeepsTheChunkItAlreadyHas():Void {
		// reserve() takes a new chunk only when the active one cannot hold the
		// bytes. Taking one every time (a guard comparing the request plus the
		// total capacity against that same total, which is never smaller) would
		// make a codec reserving per value allocate per value and abandon the
		// free tail of the chunk it left behind.
		var output = new ByteArrayOutput(16);
		output.writeByte(0x11);

		output.reserve(4);
		Assert.equals(16, output.length, "a reserve that fits should not allocate");

		output.writeInt(0x22334455);
		Assert.equals(5, output.bytesWritten);

		// One that does not fit still grows, and still starts a new chunk: of
		// at least what it asked for.
		output.reserve(32);
		Assert.isTrue(output.length >= 48, "a reserve that does not fit should allocate");

		output.writeInt(0x66778899);
		Assert.equals(9, output.bytesWritten);

		var bytes:Bytes = output;
		Assert.equals(9, bytes.length);

		var input:ByteArrayInput = ByteArray.fromBytes(bytes);
		Assert.equals(0x11, input.readByte());
		Assert.equals(0x22334455, input.readInt());
		Assert.equals(0x66778899, input.readInt());
		Assert.isTrue(input.eof());
	}

	public function testWriteIntAtPatchesAnIntegerThatStraddlesTheSeam():Void {
		// The chunk holding the first byte of the patch does not have to hold
		// the other three. A cached chunk is allocated to exactly what was
		// written into it, so here the first is three bytes long and a patch at
		// position 1 would run two bytes past its end with setInt32 on that
		// chunk, into whatever the allocator had put next to it.
		var output = new ByteArrayOutput(3);
		output.writeByte(0x11);
		output.writeByte(0x22);
		output.writeByte(0x33);

		output.reserve(4);
		output.writeInt(0);
		Assert.equals(7, output.bytesWritten);

		output.writeIntAt(1, 0x44556677);

		var bytes:Bytes = output;
		Assert.equals(7, bytes.length);

		var input:ByteArrayInput = ByteArray.fromBytes(bytes);
		Assert.equals(0x11, input.readByte());
		Assert.equals(0x44556677, input.readInt());

		// The byte after the patch is the one that was already there, not a
		// casualty of a write that ran long.
		Assert.equals(0x00, input.readByte());
		Assert.equals(0x00, input.readByte());
		Assert.isTrue(input.eof());
	}

	public function testWriteIntAtCanPatchAcrossChunkBoundary():Void {
		var output = new ByteArrayOutput(2);
		output.writeShort(0x1122);
		output.reserve(4);
		output.writeInt(0);
		output.writeIntAt(2, 0x55667788);

		var bytes:Bytes = output;
		var input:ByteArrayInput = ByteArray.fromBytes(bytes);

		Assert.equals(0x1122, input.readShort() & 0xFFFF);
		Assert.equals(0x55667788, input.readInt());
		Assert.isTrue(input.eof());
	}

	public function testValidateSizeRejectsASizeThatWouldOverflowTheCheck():Void {
		// A guard of `pos + size > current.length` would wrap negative for a
		// size near 2^31, and a negative is not greater than the length, so a
		// write that could never fit would be reported as valid.
		var output = new ByteArrayOutput(8);
		output.writeByte(0x11);

		Assert.isFalse(output.validateSize(2147483647));
		Assert.isFalse(output.validateSizeAt(2147483647, 1));
		Assert.isFalse(output.validateSize(-1));

		// A real fit is still a fit.
		Assert.isTrue(output.validateSize(7));
		Assert.isFalse(output.validateSize(8));
	}

	/**
		Every writer makes room for what it writes, as the class doc says an
		output grows. The fixed-size writers (byte, short, int, float, double,
		bytes) do not merely check, outside `final`, and throw: a
		`new ByteArrayOutput()` takes `writeInt(1)` without a `reserve(4)`
		first, in a `final` build as in any other.
	**/
	public function testFixedSizeWritersGrowTheOutput():Void {
		var output = new ByteArrayOutput();
		output.writeByte(0x7F);
		output.writeShort(0x1234);
		output.writeInt(0x55667788);
		output.writeFloat(1.5);
		output.writeDouble(-2.25);
		output.writeBoolean(true);
		output.writeBytes(Bytes.ofString("tail"));

		var bytes:Bytes = output;
		Assert.equals(1 + 2 + 4 + 4 + 8 + 1 + 4, bytes.length);
		var input:ByteArrayInput = ByteArray.fromBytes(bytes);
		Assert.equals(0x7F, input.readByte());
		Assert.equals(0x1234, input.readShort());
		Assert.equals(0x55667788, input.readInt());
		Assert.floatEquals(1.5, input.readFloat());
		Assert.floatEquals(-2.25, input.readDouble());
		Assert.isTrue(input.readBoolean());
		Assert.equals("tail", input.readUTFBytes(4));
		Assert.isTrue(input.eof());
	}

	/**
		A reserve per value grows as a write does. A reserve that did not fit
		taking a chunk of exactly its size would make a codec reserving before
		every value (each varint and string writer here does, unless told the
		room is reserved) make a chunk, and a copy, for each: 10,000 reserved
		ints would take 10,000 chunks.
	**/
	@:access(crossbyte.io.ByteArrayDataOutput)
	public function testReservingPerValueTakesFewChunks():Void {
		var output = new ByteArrayOutput();
		for (i in 0...10000) {
			output.reserve(4);
			output.writeInt(i);
		}
		for (i in 0...1000) {
			output.writeVarUInt(i);
		}

		var data:crossbyte.io.ByteArrayOutput.ByteArrayDataOutput = cast output;
		var chunks:Int = data.byteCache == null ? 1 : data.byteCache.length + 1;
		Assert.isTrue(chunks <= 24, "10000 reserved ints and 1000 varints took " + chunks + " chunks");

		var bytes:Bytes = output;
		var input:ByteArrayInput = ByteArray.fromBytes(bytes);
		for (i in 0...10000) {
			if (input.readInt() != i) {
				Assert.fail("int " + i + " came back wrong");
				return;
			}
		}
		for (i in 0...1000) {
			if (input.readVarUInt() != i) {
				Assert.fail("varint " + i + " came back wrong");
				return;
			}
		}
		Assert.isTrue(input.eof());
	}

	@:access(crossbyte.io.ByteArrayDataOutput)
	public function testGrowingByItselfTakesFewChunks():Void {
		// Grown as a ByteArray grows, by at least what it holds, so value after
		// value without reserve() is not a chunk (an allocation and a copy)
		// apiece.
		var output = new ByteArrayOutput();
		for (i in 0...10000) {
			output.writeInt(i);
		}

		var data:crossbyte.io.ByteArrayOutput.ByteArrayDataOutput = cast output;
		var chunks:Int = data.byteCache == null ? 1 : data.byteCache.length + 1;
		Assert.isTrue(chunks <= 16, "10000 ints took " + chunks + " chunks");

		var bytes:Bytes = output;
		Assert.equals(40000, bytes.length);
		var input:ByteArrayInput = ByteArray.fromBytes(bytes);
		for (i in 0...10000) {
			if (input.readInt() != i) {
				Assert.fail("int " + i + " came back wrong");
				return;
			}
		}
		Assert.isTrue(input.eof());
	}

	public function testWriteUTFRefusesWhatItsLengthPrefixCannotState():Void {
		// Sixteen bits of length; past 65535 it would wrap and desynchronise
		// every read after the string.
		var output = new ByteArrayOutput(8);
		var raised:Dynamic = null;

		try {
			output.writeUTF(StringTools.lpad("", "x", 70000));
		} catch (e:Dynamic) {
			raised = e;
		}

		Assert.isTrue(Std.isOfType(raised, crossbyte.errors.RangeError), "70000 bytes did not raise RangeError: " + Std.string(raised));
		Assert.equals(0, output.bytesWritten);
	}
}
