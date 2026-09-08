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

		Assert.isTrue(output.validateSize(4));
		Assert.isFalse(output.validateSize(5));
		Assert.isTrue(output.validateSizeAt(2, 2));
		Assert.isFalse(output.validateSizeAt(3, 2));
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
		// bytes. It used to take one every time -- the guard compared the
		// request plus the total capacity against that same total, which is
		// never smaller -- so a codec reserving per value allocated per value
		// and abandoned the free tail of the chunk it left behind.
		var output = new ByteArrayOutput(16);
		output.writeByte(0x11);

		output.reserve(4);
		Assert.equals(16, output.length, "a reserve that fits should not allocate");

		output.writeInt(0x22334455);
		Assert.equals(5, output.bytesWritten);

		// One that does not fit still grows, and still starts a new chunk.
		output.reserve(32);
		Assert.equals(48, output.length, "a reserve that does not fit should allocate");

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
		// position 1 runs two bytes past its end -- which setInt32 on that
		// chunk did, into whatever the allocator had put next to it.
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
}
