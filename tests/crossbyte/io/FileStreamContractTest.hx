package crossbyte.io;

import crossbyte.core.CrossByte;
import crossbyte.errors.EOFError;
import crossbyte.events.Event;
import crossbyte.events.OutputProgressEvent;
import haxe.io.Bytes;
import utest.Assert;

/**
	FileStream against the contract `IDataInput` and `IDataOutput` describe,
	which `ByteArray` keeps: what a read returns, what a write keeps, what a
	short read throws, and that `endian`, `objectEncoding` and `position` mean
	the same opened either way.

	Each read case runs on a stream opened with `open()` and, where there are
	threads, on one opened with `openAsync()` once the file has loaded.
**/
class FileStreamContractTest extends utest.Test {
	// --- reads ---------------------------------------------------------------

	public function testReadByteIsSigned():Void {
		// It returned the unsigned byte: 0xFF read as 255.
		__eachReader([0xFF, 0x80, 0x7F], function(stream:FileStream, how:String) {
			Assert.equals(-1, stream.readByte(), how);
			Assert.equals(-128, stream.readByte(), how);
			Assert.equals(127, stream.readByte(), how);
		});
		__eachReader([0xFF], function(stream:FileStream, how:String) {
			Assert.equals(255, (stream.readUnsignedByte() : Int), how);
		});
	}

	public function testReadBooleanIsTrueForAnyNonzeroByte():Void {
		// It compared with 1, so a 2 read as false.
		__eachReader([0x02, 0x00, 0x01, 0xFF], function(stream:FileStream, how:String) {
			Assert.isTrue(stream.readBoolean(), how);
			Assert.isFalse(stream.readBoolean(), how);
			Assert.isTrue(stream.readBoolean(), how);
			Assert.isTrue(stream.readBoolean(), how);
		});
	}

	public function testAShortReadThrowsEOFErrorAndConsumesNothing():Void {
		// haxe.io.Eof escaped every read but readBytes: the documented error
		// was never thrown, and the bytes a short read took stayed taken.
		__eachReader([1, 2, 3], function(stream:FileStream, how:String) {
			for (read in [
				() -> (stream.readInt() : Dynamic),
				() -> (stream.readUnsignedInt() : Dynamic),
				() -> (stream.readFloat() : Dynamic),
				() -> (stream.readDouble() : Dynamic),
				() -> (stream.readUTFBytes(4) : Dynamic),
				() -> (stream.readObject() : Dynamic)
			]) {
				var raised:Dynamic = null;
				try {
					read();
				} catch (e:Dynamic) {
					raised = e;
				}
				Assert.isTrue(Std.isOfType(raised, EOFError), how + ": not an EOFError: " + Std.string(raised));
				Assert.equals(0, stream.position, how + ": a short read consumed bytes");
			}

			// What is there is still there.
			Assert.equals(3, stream.bytesAvailable, how);
			Assert.equals(1, stream.readByte(), how);
			Assert.equals(2, stream.readByte(), how);
			Assert.equals(3, stream.readByte(), how);
			Assert.raises(() -> stream.readByte(), EOFError);
			Assert.raises(() -> stream.readBoolean(), EOFError);
			Assert.raises(() -> stream.readShort(), EOFError);
			Assert.raises(() -> stream.readUnsignedShort(), EOFError);
		});
	}

	public function testAStringLongerThanTheFileIsAnEOFError():Void {
		// A writeUTF prefix promising more than is there.
		__eachReader([0x00, 0x09, 0x41, 0x42], function(stream:FileStream, how:String) {
			stream.endian = BIG_ENDIAN;
			Assert.raises(() -> stream.readUTF(), EOFError);
			Assert.equals(0, stream.position, how);
		});
	}

	// --- writes --------------------------------------------------------------

	public function testWriteShortKeepsTheLowSixteenBits():Void {
		// writeInt16 threw Overflow for anything outside -32768..32767, so
		// 0xFFFF, which writeShort is for as much as -1 is, could not be
		// written.
		__eachWriter(function(stream:FileStream) {
			stream.endian = BIG_ENDIAN;
			stream.writeShort(0xFFFF);
			stream.writeShort(0x12345);
			stream.writeShort(-1);
			stream.writeByte(0x1FF);
		}, function(bytes:Bytes, how:String) {
			Assert.equals("ffff2345ffffff", bytes.toHex(), how);
		});
	}

	public function testWriteBytesClampsItsRange():Void {
		// As documented, and as ByteArray clamps. Out-of-range arguments went
		// to the file layer as they were, which read past the source, on the
		// interpreter that ended the process.
		var source = ByteArray.fromBytes(Bytes.ofString("hello"));

		__eachWriter(function(stream:FileStream) {
			stream.writeBytes(source, 2, 100);
			stream.writeBytes(source, 10, 2);
			stream.writeBytes(source, 0, 0);
			stream.writeBytes(source, 4);
		}, function(bytes:Bytes, how:String) {
			Assert.equals("llohelloo", bytes.toString(), how);
		});
	}

	// --- endian --------------------------------------------------------------

	public function testTheDefaultsAreByteArrays():Void {
		// endian was read from a file handle, so asking before open() was a
		// null access, and open() then made it big-endian whatever it was.
		var stream = new FileStream();
		Assert.equals(ByteArray.defaultEndian, stream.endian);
		Assert.equals(ByteArray.defaultObjectEncoding, stream.objectEncoding);
	}

	public function testEndianSetBeforeOpeningHolds():Void {
		var file = __fileOf([0x00, 0x00, 0x00, 0x01, 0x01, 0x00, 0x00, 0x00]);

		for (async in __modes()) {
			var stream = new FileStream();
			stream.endian = BIG_ENDIAN;
			__open(stream, file, async);

			var how = async ? "openAsync" : "open";
			Assert.equals(Endian.BIG_ENDIAN, stream.endian, how);
			Assert.equals(1, stream.readInt(), how);
			// And changed while open, for what is read next.
			stream.endian = LITTLE_ENDIAN;
			Assert.equals(1, stream.readInt(), how);
			__close(stream);
		}

		__delete(file);
	}

	public function testEndianAppliesToEveryWrite():Void {
		for (endian in [Endian.BIG_ENDIAN, Endian.LITTLE_ENDIAN]) {
			__eachWriter(function(stream:FileStream) {
				stream.endian = endian;
				stream.writeInt(1);
				stream.writeShort(2);
				stream.writeUnsignedInt(3);
				stream.writeFloat(1.0);
				stream.writeDouble(1.0);
			}, function(bytes:Bytes, how:String) {
				var big:Bool = endian == Endian.BIG_ENDIAN;
				var expected:String = big ? "00000001" + "0002" + "00000003" + "3f800000" + "3ff0000000000000" : "01000000" + "0200" + "03000000" + "0000803f"
					+ "000000000000f03f";
				Assert.equals(expected, bytes.toHex(), how + ", " + endian);
			});
		}
	}

	public function testWhatIsWrittenReadsBackOpenedEitherWay():Void {
		for (endian in [Endian.BIG_ENDIAN, Endian.LITTLE_ENDIAN]) {
			var file = File.createTempFile();
			var writer = new FileStream();
			writer.endian = endian;
			writer.open(file, WRITE);
			writer.writeInt(-123456789);
			writer.writeShort(-2);
			writer.writeUnsignedInt(0xFFFFFFFF);
			writer.writeFloat(1.5);
			writer.writeDouble(-2.25);
			writer.writeUTF("héllo");
			writer.writeBoolean(true);
			writer.close();

			for (async in __modes()) {
				var how = (async ? "openAsync" : "open") + ", " + endian;
				var reader = new FileStream();
				reader.endian = endian;
				__open(reader, file, async);
				Assert.equals(-123456789, reader.readInt(), how);
				Assert.equals(-2, reader.readShort(), how);
				Assert.equals(-1, (reader.readUnsignedInt() : Int), how);
				Assert.equals(1.5, reader.readFloat(), how);
				Assert.equals(-2.25, reader.readDouble(), how);
				Assert.equals("héllo", reader.readUTF(), how);
				Assert.isTrue(reader.readBoolean(), how);
				Assert.equals(0, reader.bytesAvailable, how);
				__close(reader);
			}

			__delete(file);
		}
	}

	// --- objects -------------------------------------------------------------

	public function testObjectsAreFramedByAThirtyTwoBitLength():Void {
		// A 32-bit length in the stream's byte order, then the UTF-8: the
		// framing ByteArray's writeObject uses, so either reads the other's.
		for (endian in [Endian.BIG_ENDIAN, Endian.LITTLE_ENDIAN]) {
			__eachWriter(function(stream:FileStream) {
				stream.endian = endian;
				stream.objectEncoding = JSON;
				stream.writeObject({a: 1});
			}, function(bytes:Bytes, how:String) {
				var length:String = endian == Endian.BIG_ENDIAN ? "00000007" : "07000000";
				Assert.equals(length + Bytes.ofString('{"a":1}').toHex(), bytes.toHex(), how + ", " + endian);
			});
		}
	}

	public function testObjectsLargerThanSixtyFourKilobytesRoundTrip():Void {
		// They were framed by writeUTF's 16-bit length, so past 65,535 bytes
		// writeObject threw RangeError.
		var big:Array<String> = [for (i in 0...20000) "item" + i];

		for (encoding in [crossbyte.net.ObjectEncoding.HXSF, crossbyte.net.ObjectEncoding.JSON]) {
			for (async in __writeModes()) {
				var how = (async ? "openAsync" : "open") + ", encoding " + encoding;
				var file = File.createTempFile();
				var writer = new FileStream();
				writer.objectEncoding = encoding;

				try {
					__open(writer, file, async, WRITE);
					writer.writeObject(big);
					writer.writeObject("after");
					__close(writer);

					var reader = new FileStream();
					reader.objectEncoding = encoding;
					__open(reader, file, async);
					var back:Array<String> = reader.readObject();
					Assert.equals(big.length, back.length, how);
					Assert.equals("item19999", back[back.length - 1], how);
					Assert.equals("after", reader.readObject(), how);
					__close(reader);
				} catch (e:Dynamic) {
					Assert.fail(how + ": " + Std.string(e));
				}

				__delete(file);
			}
		}
	}

	public function testObjectEncodingAppliesToAnAsynchronousStream():Void {
		// The asynchronous stream read and wrote through its buffer, which was
		// a plain ByteArray: HXSF and little-endian, whatever the stream said.
		#if target.threaded
		var file = File.createTempFile();
		var writer = new FileStream();
		writer.objectEncoding = JSON;
		__open(writer, file, true, WRITE);
		writer.writeObject({a: 1});
		__close(writer);

		var bytes:Bytes = sys.io.File.getBytes(file.nativePath);
		Assert.equals('{"a":1}', bytes.getString(4, bytes.length - 4));

		var reader = new FileStream();
		reader.objectEncoding = JSON;
		__open(reader, file, true);
		Assert.equals(1, reader.readObject().a);
		__close(reader);
		__delete(file);
		#else
		Assert.pass();
		#end
	}

	#if format
	public function testAnAmfObjectReadsOnlyItself():Void {
		// Every byte to the end of the file was read into a buffer and one
		// object parsed from it, so the next object, and anything after,
		// was gone: the second readObject threw haxe.io.Eof.
		for (encoding in [crossbyte.net.ObjectEncoding.AMF0, crossbyte.net.ObjectEncoding.AMF3]) {
			for (async in __writeModes()) {
				var how = (async ? "openAsync" : "open") + ", encoding " + encoding;
				var file = File.createTempFile();
				var writer = new FileStream();
				writer.objectEncoding = encoding;
				__open(writer, file, async, WRITE);
				writer.writeObject({a: 1});
				writer.writeObject({b: 2});
				writer.writeInt(7);
				__close(writer);

				var reader = new FileStream();
				reader.objectEncoding = encoding;
				__open(reader, file, async);
				Assert.equals(1, reader.readObject().a, how);
				Assert.equals(2, reader.readObject().b, how);
				Assert.equals(7, reader.readInt(), how);
				Assert.equals(0, reader.bytesAvailable, how);
				__close(reader);
				__delete(file);
			}
		}
	}
	#end

	// --- position ------------------------------------------------------------

	public function testAnAsynchronousWriteGoesWhereThePositionIs():Void {
		// The writer took bytes from one buffer that only grew, from wherever
		// it had got to, so after "AAAAAAAA" was written, moving the position
		// back and writing "BB" changed nothing: AAAAAAAA, where the same
		// calls on a synchronous stream make BBAAAAAA.
		#if target.threaded
		var file = File.createTempFile();
		var stream = new FileStream();
		var drained:Bool = false;
		stream.addEventListener(OutputProgressEvent.OUTPUT_PROGRESS, (event:OutputProgressEvent) -> if (event.bytesPending == 0) drained = true);
		__open(stream, file, true, WRITE);
		stream.writeUTFBytes("AAAAAAAA");
		__pumpUntil(() -> drained, 5.0);
		stream.position = 0;
		stream.writeUTFBytes("BB");
		Assert.equals(2, stream.position);
		// Before the first write has reached the file, too.
		stream.position = 6;
		stream.writeUTFBytes("C");
		__close(stream);

		Assert.equals("BBAAAACA", sys.io.File.getContent(file.nativePath));
		__delete(file);
		#else
		Assert.pass();
		#end
	}

	// --- helpers -------------------------------------------------------------

	/** Sync and async, for reading: a Node stream reads asynchronously too, inline. **/
	private static function __modes():Array<Bool> {
		return [false, true];
	}

	/** Sync, and async where there are threads to write with. **/
	private static function __writeModes():Array<Bool> {
		#if target.threaded
		return [false, true];
		#else
		return [false];
		#end
	}

	/** Runs `check` on `values` read through each kind of stream. **/
	private static function __eachReader(values:Array<Int>, check:FileStream->String->Void):Void {
		var file = __fileOf(values);

		for (async in __modes()) {
			var stream = new FileStream();
			try {
				__open(stream, file, async);
				check(stream, async ? "openAsync" : "open");
			} catch (e:Dynamic) {
				Assert.fail((async ? "openAsync" : "open") + ": " + Std.string(e));
			}
			__close(stream);
		}

		__delete(file);
	}

	/** Runs `write` on each kind of stream, then `check` on the file's bytes. **/
	private static function __eachWriter(write:FileStream->Void, check:Bytes->String->Void):Void {
		for (async in __writeModes()) {
			var how = async ? "openAsync" : "open";
			var file = File.createTempFile();
			var stream = new FileStream();

			try {
				__open(stream, file, async, WRITE);
				write(stream);
				__close(stream);
				check(sys.io.File.getBytes(file.nativePath), how);
			} catch (e:Dynamic) {
				Assert.fail(how + ": " + Std.string(e));
			}

			__close(stream);
			__delete(file);
		}
	}

	/** Opens `file`; asynchronously, waits until a read stream has loaded. **/
	private static function __open(stream:FileStream, file:File, async:Bool, mode:FileMode = READ):Void {
		if (!async) {
			stream.open(file, mode);
			return;
		}

		var complete:Bool = false;
		var listener = (_:Event) -> complete = true;
		stream.addEventListener(Event.COMPLETE, listener);
		stream.openAsync(file, mode);

		if (mode == READ || mode == UPDATE) {
			__pumpUntil(() -> complete, 10.0);
			Assert.isTrue(complete, "the file never finished loading");
		}

		stream.removeEventListener(Event.COMPLETE, listener);
	}

	/** Closes `stream` and, asynchronously, waits until it has. **/
	private static function __close(stream:FileStream):Void {
		try {
			stream.close();
		} catch (_:Dynamic) {}

		__pumpUntil(() -> !@:privateAccess stream.__isOpen, 10.0);
	}

	private static function __fileOf(values:Array<Int>):File {
		var file = File.createTempFile();
		var bytes = Bytes.alloc(values.length);
		for (i in 0...values.length) {
			bytes.set(i, values[i]);
		}
		sys.io.File.saveBytes(file.nativePath, bytes);
		return file;
	}

	private static function __delete(file:File):Void {
		try {
			if (file.exists) {
				file.deleteFile();
			}
		} catch (_:Dynamic) {}
	}

	private static function __pumpUntil(done:Void->Bool, timeoutSeconds:Float):Void {
		var runtime = CrossByte.current();
		var deadline = haxe.Timer.stamp() + timeoutSeconds;
		while (!done() && haxe.Timer.stamp() < deadline) {
			runtime.pump(1 / 60, 0);
			crossbyte.sys.System.sleep(0.001);
		}
	}
}
