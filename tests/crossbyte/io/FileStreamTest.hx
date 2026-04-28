package crossbyte.io;

import utest.Assert;

class FileStreamTest extends utest.Test {
	public function testReadBytesDefaultLengthUsesRemainingBytes():Void {
		var file = File.createTempFile();
		var output = new FileStream();
		var input = new FileStream();
		var source = ByteArray.fromBytes(haxe.io.Bytes.ofString("abcdef"));
		var target = new ByteArray();

		try {
			output.open(file, FileMode.WRITE);
			output.writeBytes(source);
			output.close();

			input.open(file, FileMode.READ);
			input.position = 2;
			input.readBytes(target);

			Assert.equals(4, target.length);
			target.position = 0;
			Assert.equals("cdef", target.readUTFBytes(target.length));
			Assert.equals(0, input.bytesAvailable);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try input.close() catch (_:Dynamic) {}
		try output.close() catch (_:Dynamic) {}
		if (file.exists) {
			file.deleteFile();
		}
	}

	public function testWriteBytesHonorsOffsetAndLength():Void {
		var file = File.createTempFile();
		var output = new FileStream();
		var input = new FileStream();
		var source = ByteArray.fromBytes(haxe.io.Bytes.ofString("abcdef"));

		try {
			output.open(file, FileMode.WRITE);
			output.writeBytes(source, 1, 3);
			output.close();

			input.open(file, FileMode.READ);
			Assert.equals("bcd", input.readUTFBytes(3));
			Assert.equals(0, input.bytesAvailable);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try input.close() catch (_:Dynamic) {}
		try output.close() catch (_:Dynamic) {}
		if (file.exists) {
			file.deleteFile();
		}
	}

	public function testWriteUTFUsesUtf8ByteLength():Void {
		var file = File.createTempFile();
		var output = new FileStream();
		var input = new FileStream();
		var value = "h\u00E9llo";

		try {
			output.open(file, FileMode.WRITE);
			output.writeUTF(value);
			output.close();

			input.open(file, FileMode.READ);
			Assert.equals(value, input.readUTF());
			Assert.equals(0, input.bytesAvailable);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try input.close() catch (_:Dynamic) {}
		try output.close() catch (_:Dynamic) {}
		if (file.exists) {
			file.deleteFile();
		}
	}
}
