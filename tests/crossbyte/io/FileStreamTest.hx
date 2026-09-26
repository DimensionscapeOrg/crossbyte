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

	public function testAShortReadThrowsEOFErrorAndConsumesNothing():Void {
		// The documented contract, which the synchronous read broke: a read
		// past the end padded the rest with zeros and returned as though it
		// had succeeded.
		var file = File.createTempFile();
		var output = new FileStream();
		var input = new FileStream();
		var target = new ByteArray();
		var thrown:Dynamic = null;

		try {
			output.open(file, FileMode.WRITE);
			output.writeBytes(__pattern(100));
			output.close();

			input.open(file, FileMode.READ);
			input.readBytes(target, 0, 60);

			try {
				input.readBytes(target, 0, 60);
			} catch (e:Dynamic) {
				thrown = e;
			}

			Assert.isTrue(Std.isOfType(thrown, crossbyte.errors.EOFError), "a short read did not raise EOFError: " + Std.string(thrown));
			// Nothing consumed: what is there can still be read.
			Assert.equals(60, input.position);
			Assert.equals(40, input.bytesAvailable);

			var rest = new ByteArray();
			input.readBytes(rest, 0, 40);
			Assert.equals(0, __bytes(rest).compare(__bytes(__pattern(100)).sub(60, 40)));
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try input.close() catch (_:Dynamic) {}
		try output.close() catch (_:Dynamic) {}
		if (file.exists) {
			file.deleteFile();
		}
	}

	public function testAChunkedCopyIsExact():Void {
		// Copying a file in chunks, the way AIR code does: read a chunk until
		// EOFError, then take what is left. With short reads padded, a 1 MB
		// copy came out 65,436 bytes longer, the extra all zeros.
		var chunk:Int = 65536;
		var total:Int = 1048576 + 100;
		var source = File.createTempFile();
		var copy = File.createTempFile();
		var input = new FileStream();
		var output = new FileStream();

		try {
			output.open(source, FileMode.WRITE);
			output.writeBytes(__pattern(total));
			output.close();

			input.open(source, FileMode.READ);
			output.open(copy, FileMode.WRITE);

			var buffer = new ByteArray();
			var fullChunks:Int = 0;

			while (true) {
				try {
					input.readBytes(buffer, 0, chunk);
				} catch (_:crossbyte.errors.EOFError) {
					break;
				}

				output.writeBytes(buffer, 0, chunk);
				fullChunks++;
			}

			var rest:Int = input.bytesAvailable;
			input.readBytes(buffer, 0, rest);
			output.writeBytes(buffer, 0, rest);
			input.close();
			output.close();

			Assert.equals(16, fullChunks);
			Assert.equals(100, rest);
			Assert.equals(total, copy.size);

			var check = new FileStream();
			var copied = new ByteArray();
			check.open(copy, FileMode.READ);
			check.readBytes(copied, 0, total);
			check.close();
			Assert.equals(0, __bytes(copied).compare(__bytes(__pattern(total))));
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try input.close() catch (_:Dynamic) {}
		try output.close() catch (_:Dynamic) {}
		for (file in [source, copy]) {
			if (file.exists) {
				file.deleteFile();
			}
		}
	}

	public function testWriteUTFTakesEveryLengthItsPrefixCanStateAndRefusesMore():Void {
		// The prefix is an unsigned 16-bit length. The synchronous stream
		// wrote it with writeInt16, which threw Overflow from 32768 up -- a
		// string ByteArray took -- and past 65535 nothing checked at all.
		var file = File.createTempFile();
		var output = new FileStream();
		var input = new FileStream();
		var mid:String = StringTools.lpad("", "y", 40000);
		var thrown:Dynamic = null;

		try {
			output.open(file, FileMode.WRITE);
			output.writeUTF(mid);

			try {
				output.writeUTF(StringTools.lpad("", "x", 70000));
			} catch (e:Dynamic) {
				thrown = e;
			}

			output.writeInt(42);
			output.close();

			Assert.isTrue(Std.isOfType(thrown, crossbyte.errors.RangeError), "70000 bytes did not raise RangeError: " + Std.string(thrown));

			input.open(file, FileMode.READ);
			Assert.equals(mid, input.readUTF());
			// Nothing was written for the refused string, so the stream is
			// still in step.
			Assert.equals(42, input.readInt());
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try input.close() catch (_:Dynamic) {}
		try output.close() catch (_:Dynamic) {}
		if (file.exists) {
			file.deleteFile();
		}
	}

	/**
	 * An exact copy. A ByteArray's storage runs past its length, and on hxcpp
	 * `Bytes.compare` compares the storage, so comparing a ByteArray directly
	 * would weigh bytes it does not hold.
	 */
	private static function __bytes(data:ByteArray):haxe.io.Bytes {
		var bytes:haxe.io.Bytes = data;
		return bytes.sub(0, data.length);
	}

	/** Bytes that are never zero, so padding cannot pass for data. **/
	private static function __pattern(length:Int):ByteArray {
		var bytes = haxe.io.Bytes.alloc(length);

		for (i in 0...length) {
			bytes.set(i, (i & 0x7F) | 1);
		}

		return ByteArray.fromBytes(bytes);
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
