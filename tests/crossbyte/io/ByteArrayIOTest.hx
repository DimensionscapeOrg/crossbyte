package crossbyte.io;

import crossbyte.errors.EOFError;
import crossbyte.errors.IOError;
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
		at the top bit. A writer looping while a signed `v > 0x7F` would send a
		value with bit 31 set as one byte, `varUIntSize` would size it as one,
		and a reader must not refuse everything from 2^31 up.
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
		ZigZag over every Int. 1 << 30 maps to 0x80000000, which must go out
		as more than a single byte, and the reader must accept what any value
		at or past 2^30 in magnitude maps to.
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
		One name, one format: `readVarUInt`/`writeVarUInt` in all three classes,
		and what one class writes the others read. Were `ByteArray`'s unsigned
		varint called `readVarInt`/`writeVarInt`, the names `ByteArrayInput` and
		`ByteArrayOutput` give ZigZag, code moved from one class to the other
		would compile and read every negative number wrong.
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

	/**
		An object of any size, in either endian. HXSF and JSON text framed as
		writeUTF frames a string, behind a 16-bit length, would make writeObject
		throw a RangeError for anything past 65,535 bytes of it (a list of a few
		thousand records).
	**/
	public function testAMegabyteObjectRoundTrips():Void {
		var text:String = StringTools.lpad("", "abcdefgh", 1 << 20);
		for (encoding in [ObjectEncoding.HXSF, ObjectEncoding.JSON]) {
			for (endian in [Endian.LITTLE_ENDIAN, Endian.BIG_ENDIAN]) {
				var out = new ByteArray();
				out.endian = endian;
				out.objectEncoding = encoding;
				out.writeObject({text: text, count: 3});
				out.writeInt(0x5EED);

				out.position = 0;
				var back = out.readObject();
				Assert.equals(text.length, back.text.length, 'encoding $encoding, $endian');
				Assert.isTrue(back.text == text, 'encoding $encoding, $endian: the text came back changed');
				Assert.equals(3, back.count);
				Assert.equals(0x5EED, out.readInt(), 'encoding $encoding, $endian: the object was not read to its end');
			}
		}
	}

	/**
		The frame: the text's length in bytes as an unsigned 32-bit integer,
		in the stream's endian, then the text as UTF-8.
	**/
	public function testAnObjectIsAThirtyTwoBitLengthThenItsText():Void {
		for (endian in [Endian.LITTLE_ENDIAN, Endian.BIG_ENDIAN]) {
			var out = new ByteArray();
			out.endian = endian;
			out.objectEncoding = ObjectEncoding.JSON;
			out.writeObject("ab");

			Assert.equals(8, out.length);
			out.position = 0;
			Assert.equals(4, out.readUnsignedInt(), 'length in $endian');
			Assert.equals('"ab"', out.readUTFBytes(4));
		}
	}

	/**
		An object only part of which has arrived reads as an EOFError and
		leaves `position` where it was, so a socket's reader can try again
		when the rest comes, as it can with a truncated readInt.
	**/
	public function testATruncatedObjectLeavesThePositionAlone():Void {
		for (encoding in [ObjectEncoding.HXSF, ObjectEncoding.JSON]) {
			var whole = new ByteArray();
			whole.objectEncoding = encoding;
			whole.writeObject({name: "crossbyte"});

			var part = new ByteArray();
			part.objectEncoding = encoding;
			part.writeBytes(whole, 0, whole.length - 1);
			part.position = 0;
			Assert.raises(() -> part.readObject(), EOFError, 'encoding $encoding');
			Assert.equals(0, part.position, 'encoding $encoding: a truncated object moved the position');

			part.position = part.length;
			part.writeByte(whole[whole.length - 1]);
			part.position = 0;
			Assert.equals("crossbyte", part.readObject().name);
		}
	}

	/**
		An object nested more than 256 levels deep is refused with an
		IOError, in every encoding, and its bytes are consumed; one within the
		limit reads. Unbounded, a peer's object nested a few thousand deep
		(12 KB) would overflow the stack natively and end the process reading
		it, through any socket's `readObject`.
	**/
	public function testAnObjectNestedTooDeepIsRefused():Void {
		for (encoding in [ObjectEncoding.HXSF, ObjectEncoding.JSON]) {
			for (depth in [300, 6000]) {
				var input = __framed(__nested(encoding, depth));
				input.objectEncoding = encoding;
				Assert.raises(() -> input.readObject(), IOError, 'encoding $encoding, $depth deep');
				Assert.equals(input.length, input.position, 'encoding $encoding, $depth deep: the refused object was not consumed');
			}

			var within = __framed(__nested(encoding, 200));
			within.objectEncoding = encoding;
			Assert.notNull(within.readObject(), 'encoding $encoding: an object 200 deep was refused');
		}

		#if format
		// AMF0: a strict array of one, nested; the innermost holds null.
		var amf = new ByteArray();
		amf.endian = Endian.BIG_ENDIAN;
		for (_ in 0...6000) {
			amf.writeByte(0x0A);
			amf.writeUnsignedInt(1);
		}
		amf.writeByte(0x05);
		amf.position = 0;
		amf.objectEncoding = ObjectEncoding.AMF0;
		Assert.raises(() -> amf.readObject(), IOError, "AMF0, 6000 deep");
		#end
	}

	/**
		An object holding more values than `ByteArray.maxObjectValues` is
		refused with an IOError, in every encoding, and its bytes are
		consumed; one holding as many reads. Each null of a run counts:
		unbounded, `au100000000h` (twelve bytes) would make an array of
		100,000,000 slots, 800 MB natively, wherever a peer's object is read.
	**/
	public function testAnObjectHoldingTooManyValuesIsRefused():Void {
		// The default bound: an array and a million nulls is one too many.
		Assert.equals(1000000, ByteArray.maxObjectValues);
		for (text in ["au1000000h", "au5000000h", "au2147483646h"]) {
			var input = __framed(text);
			Assert.raises(() -> input.readObject(), IOError, text);
			Assert.equals(input.length, input.position, '$text: the refused object was not consumed');
		}
		var atBound = __framed("au999999h");
		Assert.equals(999999, (atBound.readObject() : Array<Dynamic>).length);

		var saved:Int = ByteArray.maxObjectValues;
		ByteArray.maxObjectValues = 1000;
		try {
			// A value a byte at a time, in either text encoding.
			for (encoding in [ObjectEncoding.HXSF, ObjectEncoding.JSON]) {
				for (count in [999, 1000]) {
					var input = __framed(__flat(encoding, count));
					input.objectEncoding = encoding;
					if (count == 999) {
						Assert.equals(999, (input.readObject() : Array<Dynamic>).length, 'encoding $encoding: an array and 999 values was refused');
					} else {
						Assert.raises(() -> input.readObject(), IOError, 'encoding $encoding, an array and $count values');
						Assert.equals(input.length, input.position, 'encoding $encoding: the refused object was not consumed');
					}
				}
			}
			// Names count too: the object, then a name and a value a member.
			var members = new StringBuf();
			for (i in 0...499) {
				members.add((i > 0 ? "," : "") + '"m$i":0');
			}
			var json = __framed("{" + members.toString() + "}");
			json.objectEncoding = ObjectEncoding.JSON;
			Assert.equals(0, Reflect.field(json.readObject(), "m498"), "an object of 999 values was refused");
			json = __framed("{" + members.toString() + ',"m499":0}');
			json.objectEncoding = ObjectEncoding.JSON;
			Assert.raises(() -> json.readObject(), IOError, "an object of 1,001 values");

			// Each value once, wherever it starts: the array, a string with
			// a quote in it, the object, its name, the inner array and its
			// four literals are nine.
			var mixed = '[ "a\\"b" , {"k" : [true,false,null,-1.5e3]} ]';
			for (most in [9, 8]) {
				ByteArray.maxObjectValues = most;
				var input = __framed(mixed);
				input.objectEncoding = ObjectEncoding.JSON;
				if (most == 9) {
					Assert.equals('a"b', (input.readObject() : Array<Dynamic>)[0], "nine values were refused");
				} else {
					Assert.raises(() -> input.readObject(), IOError, "nine values read with a bound of eight");
				}
			}

			// Zero or less is no limit.
			ByteArray.maxObjectValues = 0;
			Assert.equals(5000, (__framed("au5000h").readObject() : Array<Dynamic>).length);
		} catch (e:Dynamic) {
			ByteArray.maxObjectValues = saved;
			throw e;
		}
		ByteArray.maxObjectValues = saved;
	}

	#if format
	/**
		AMF0 and AMF3 are bounded as HXSF is: a value at a time, and a length
		claimed ahead of a string, bytes or a vector is read as the bytes
		arrive, never allocated ahead of them, as `format`, which makes a buffer
		of the length claimed first, would: five bytes asking for 2 GB.
	**/
	public function testAMFIsBoundedInValuesAndInWhatItAllocates():Void {
		// Each claims far more than follows, and reads as running out.
		var claims:Array<{name:String, encoding:ObjectEncoding, bytes:Array<Int>}> = [
			{name: "AMF0 long string of 2 GB", encoding: ObjectEncoding.AMF0, bytes: [0x0C, 0x7F, 0xFF, 0xFF, 0xF0, 0x61, 0x62, 0x63]},
			{name: "AMF3 string of 256 MB", encoding: ObjectEncoding.AMF3, bytes: [0x06, 0xFF, 0xFF, 0xFF, 0xFF, 0x61]},
			{name: "AMF3 byte array of 256 MB", encoding: ObjectEncoding.AMF3, bytes: [0x0C, 0xFF, 0xFF, 0xFF, 0xFF, 0x61]},
			{name: "AMF3 vector of 2^28 ints", encoding: ObjectEncoding.AMF3, bytes: [0x0D, 0xFF, 0xFF, 0xFF, 0xFF, 0x01]},
			{name: "AMF3 vector of 2^28 objects", encoding: ObjectEncoding.AMF3, bytes: [0x10, 0xFF, 0xFF, 0xFF, 0xFF, 0x01, 0x01]}
		];
		for (claim in claims) {
			var input = new ByteArray();
			for (byte in claim.bytes) {
				input.writeByte(byte);
			}
			input.position = 0;
			input.objectEncoding = claim.encoding;
			Assert.raises(() -> input.readObject(), EOFError, claim.name);
			Assert.equals(0, input.position, claim.name + ": a truncated object moved the position");
		}

		var saved:Int = ByteArray.maxObjectValues;
		ByteArray.maxObjectValues = 1000;
		try {
			for (count in [999, 1000]) {
				// AMF0: a strict array of nulls.
				var amf0 = new ByteArray();
				amf0.endian = Endian.BIG_ENDIAN;
				amf0.writeByte(0x0A);
				amf0.writeUnsignedInt(count);
				for (_ in 0...count) {
					amf0.writeByte(0x05);
				}
				// AMF3: a fixed vector of ints.
				var amf3 = new ByteArray();
				amf3.endian = Endian.BIG_ENDIAN;
				amf3.writeByte(0x0D);
				var header:Int = (count << 1) | 1;
				amf3.writeByte(0x80 | (header >> 7));
				amf3.writeByte(header & 0x7F);
				amf3.writeByte(0x01);
				for (i in 0...count) {
					amf3.writeInt(i);
				}
				for (input in [amf0, amf3]) {
					input.position = 0;
					input.objectEncoding = input == amf0 ? ObjectEncoding.AMF0 : ObjectEncoding.AMF3;
					if (count == 999) {
						// An array, or for the fixed vector a Vector, whose
						// length the jvm does not read through Dynamic.
						var value:Dynamic = input.readObject();
						var length:Int = Std.isOfType(value, Array) ? (value : Array<Dynamic>).length : (cast value : haxe.ds.Vector<Dynamic>).length;
						Assert.equals(999, length, 'encoding ${input.objectEncoding}: 1,000 values were refused');
					} else {
						Assert.raises(() -> input.readObject(), IOError, 'encoding ${input.objectEncoding}: 1,001 values');
					}
				}
			}
		} catch (e:Dynamic) {
			ByteArray.maxObjectValues = saved;
			throw e;
		}
		ByteArray.maxObjectValues = saved;
	}
	#end

	/**
		HXSF that would read its own bytes again is refused with an IOError.
		A negative string or bytes length would move the read back, so six bytes
		would read the same value for ever, adding it to an array until memory
		ran out; a run of no nulls, or fewer, would set an element already read.
	**/
	public function testMalformedHXSFIsRefused():Void {
		for (text in ["ay-4:h", "as-4:h", "as-8:h", "ay-8:h", "au0h", "au-5h", "ai1u-1h"]) {
			var input = __framed(text);
			Assert.raises(() -> input.readObject(), IOError, text);
		}
		Assert.same([1, null, null, 2], __framed("ai1u2i2h").readObject());
	}

	/** An array of `count` zeros, flat, as `encoding` writes it. **/
	private static function __flat(encoding:ObjectEncoding, count:Int):String {
		var text = new StringBuf();
		text.add(encoding == ObjectEncoding.JSON ? "[" : "a");
		for (i in 0...count) {
			text.add(encoding == ObjectEncoding.JSON ? (i > 0 ? ",0" : "0") : "z");
		}
		text.add(encoding == ObjectEncoding.JSON ? "]" : "h");
		return text.toString();
	}

	/** The text of arrays nested `depth` deep, the innermost empty. **/
	private static function __nested(encoding:ObjectEncoding, depth:Int):String {
		var open:String = encoding == ObjectEncoding.JSON ? "[" : "a";
		var close:String = encoding == ObjectEncoding.JSON ? "]" : "h";
		var text = new StringBuf();
		for (_ in 0...depth) {
			text.add(open);
		}
		for (_ in 0...depth) {
			text.add(close);
		}
		return text.toString();
	}

	/** ASCII `text` framed as `writeObject` frames an object's text. **/
	private static function __framed(text:String):ByteArray {
		var out = new ByteArray();
		out.writeUnsignedInt(text.length);
		out.writeUTFBytes(text);
		out.position = 0;
		return out;
	}

	public function testAnEncodingThisBuildCannotDoIsRefused():Void {
		// Not an ObjectEncoding at all: the abstract is `from Int`, so this
		// compiles, and must neither read back null nor write zero bytes.
		__assertEncodingRefused(cast 99);

		#if !format
		// AMF needs the optional "format" haxelib. Without it the object must
		// not go nowhere quietly, which is the worst way to find out.
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
