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
}
