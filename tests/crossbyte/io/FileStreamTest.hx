package crossbyte.io;

import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.OutputProgressEvent;
import crossbyte.events.ProgressEvent;
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

	public function testReadBytesHonorsDestinationOffsetAndLength():Void {
		var file = File.createTempFile();
		var output = new FileStream();
		var input = new FileStream();
		var target = ByteArray.fromBytes(haxe.io.Bytes.ofString("__!!!!"));

		try {
			output.open(file, FileMode.WRITE);
			output.writeUTFBytes("abcdef");
			output.close();

			input.open(file, FileMode.READ);
			input.readBytes(target, 2, 3);

			Assert.equals(6, target.length);
			target.position = 0;
			Assert.equals("__abc!", target.readUTFBytes(target.length));
			Assert.equals(3, input.position);
			Assert.equals(3, input.bytesAvailable);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try input.close() catch (_:Dynamic) {}
		try output.close() catch (_:Dynamic) {}
		if (file.exists) {
			file.deleteFile();
		}
	}

	public function testTruncateShrinksFileAtCurrentPosition():Void {
		var file = File.createTempFile();
		var output = new FileStream();
		var input = new FileStream();

		try {
			output.open(file, FileMode.WRITE);
			output.writeUTFBytes("abcdef");
			output.position = 4;
			output.truncate();
			output.close();

			Assert.equals(4, file.size);

			input.open(file, FileMode.READ);
			Assert.equals("abcd", input.readUTFBytes(4));
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

	public function testUpdateModeCanReadExistingBytes():Void {
		var file = File.createTempFile();
		var output = new FileStream();
		var update = new FileStream();

		try {
			output.open(file, FileMode.WRITE);
			output.writeUTFBytes("abcdef");
			output.close();

			update.open(file, FileMode.UPDATE);
			Assert.equals("abc", update.readUTFBytes(3));
			Assert.equals(3, update.position);
			Assert.equals(3, update.bytesAvailable);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try update.close() catch (_:Dynamic) {}
		try output.close() catch (_:Dynamic) {}
		if (file.exists) {
			file.deleteFile();
		}
	}

	public function testUpdateModeCanOverwriteAndReadBack():Void {
		var file = File.createTempFile();
		var output = new FileStream();
		var update = new FileStream();
		var input = new FileStream();

		try {
			output.open(file, FileMode.WRITE);
			output.writeUTFBytes("abcdef");
			output.close();

			update.open(file, FileMode.UPDATE);
			update.position = 2;
			update.writeUTFBytes("XY");
			update.position = 0;
			Assert.equals("abXYef", update.readUTFBytes(6));
			update.close();

			input.open(file, FileMode.READ);
			Assert.equals("abXYef", input.readUTFBytes(6));
			Assert.equals(0, input.bytesAvailable);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try input.close() catch (_:Dynamic) {}
		try update.close() catch (_:Dynamic) {}
		try output.close() catch (_:Dynamic) {}
		if (file.exists) {
			file.deleteFile();
		}
	}

	public function testAppendModeStartsAtEndAndStillAppendsAfterSeek():Void {
		var file = File.createTempFile();
		var output = new FileStream();
		var append = new FileStream();
		var input = new FileStream();

		try {
			output.open(file, FileMode.WRITE);
			output.writeUTFBytes("abc");
			output.close();

			append.open(file, FileMode.APPEND);
			Assert.equals(3, append.position);
			append.position = 0;
			append.writeUTFBytes("XY");
			append.close();

			input.open(file, FileMode.READ);
			Assert.equals("abcXY", input.readUTFBytes(5));
			Assert.equals(0, input.bytesAvailable);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try input.close() catch (_:Dynamic) {}
		try append.close() catch (_:Dynamic) {}
		try output.close() catch (_:Dynamic) {}
		if (file.exists) {
			file.deleteFile();
		}
	}

	public function testOpenAsyncReadDispatchesProgressAndCompleteWithReadableBuffer():Void {
		#if !(cpp || neko || hl)
		Assert.pass();
		return;
		#end

		var file = File.createTempFile();
		var output = new FileStream();
		var input = new FileStream();
		var completeSeen = false;
		var progressEvents = 0;
		var progressLoaded = 0;
		var progressTotal = 0;

		try {
			output.open(file, FileMode.WRITE);
			output.writeUTFBytes("async-read");
			output.close();

			input.addEventListener(ProgressEvent.PROGRESS, (event:ProgressEvent) -> {
				progressEvents++;
				progressLoaded = event.bytesLoaded;
				progressTotal = event.bytesTotal;
			});
			input.addEventListener(Event.COMPLETE, (_:Event) -> completeSeen = true);
			input.openAsync(file, FileMode.READ);

			pumpUntil(() -> completeSeen, 2.0);

			Assert.isTrue(completeSeen);
			Assert.isTrue(progressEvents > 0);
			Assert.equals(file.size, progressLoaded);
			Assert.equals(file.size, progressTotal);
			Assert.equals(file.size, input.bytesAvailable);
			Assert.equals("async-read", input.readUTFBytes(input.bytesAvailable));
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

	public function testOpenAsyncWriteFlushesOnCloseAndDispatchesClose():Void {
		#if !(cpp || neko || hl)
		Assert.pass();
		return;
		#end

		var file = File.createTempFile();
		var stream = new FileStream();
		var input = new FileStream();
		var closeSeen = false;
		var outputProgressSeen = false;
		var lastBytesPending = -1.0;
		var lastBytesTotal = -1.0;

		try {
			stream.addEventListener(OutputProgressEvent.OUTPUT_PROGRESS, (event:OutputProgressEvent) -> {
				outputProgressSeen = true;
				lastBytesPending = event.bytesPending;
				lastBytesTotal = event.bytesTotal;
			});
			stream.addEventListener(Event.CLOSE, (_:Event) -> closeSeen = true);
			stream.openAsync(file, FileMode.WRITE);
			stream.writeUTFBytes("async-write");
			stream.close();

			pumpUntil(() -> closeSeen, 2.0);

			Assert.isTrue(closeSeen);
			Assert.isTrue(outputProgressSeen);
			Assert.equals(0.0, lastBytesPending);
			Assert.equals(11.0, lastBytesTotal);

			input.open(file, FileMode.READ);
			Assert.equals("async-write", input.readUTFBytes(11));
			Assert.equals(0, input.bytesAvailable);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try input.close() catch (_:Dynamic) {}
		try stream.close() catch (_:Dynamic) {}
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

	private static function pumpUntil(done:Void->Bool, timeoutSeconds:Float):Void {
		var runtime = CrossByte.current();
		var deadline = Sys.time() + timeoutSeconds;
		while (!done() && Sys.time() < deadline) {
			runtime.pump(1 / 60, 0);
			Sys.sleep(0.001);
		}
	}
}
