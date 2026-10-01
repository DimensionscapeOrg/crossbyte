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
		at the top bit. The writer looped while a signed `v > 0x7F`, so a
		value with bit 31 set went out as one byte, and `varUIntSize` sized it
		as one; the reader refused everything from 2^31 up.
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
		ZigZag over every Int. 1 << 30 maps to 0x80000000, which the writer
		sent as a single byte that read back as 0; the reader refused what
		any value at or past 2^30 in magnitude maps to.
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
		One name, one format. `ByteArray`'s unsigned varint was called
		`readVarInt`/`writeVarInt`, the names `ByteArrayInput` and
		`ByteArrayOutput` give ZigZag, so code moved from one class to the
		other compiled and read every negative number wrong. It is
		`readVarUInt`/`writeVarUInt` in all three now, and what one class
		writes the others read.
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
		An object of any size, in either endian. HXSF and JSON text was framed
		as writeUTF frames a string, behind a 16-bit length, so writeObject
		threw a RangeError for anything past 65,535 bytes of it, a list of a
		few thousand records, and nothing documented a limit.
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
		limit reads. Unbounded, a peer's object nested a few thousand deep,
		12 KB, overflowed the stack natively and ended the process reading
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
		// Not an ObjectEncoding at all, the abstract is `from Int`, so this
		// compiles and used to read back null and write zero bytes.
		__assertEncodingRefused(cast 99);

		#if !format
		// AMF needs the optional "format" haxelib. Without it the object used to
		// go nowhere quietly, which is the worst way to find out.
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
