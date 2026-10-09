package crossbyte.io;

// import cpp.zip.Compress;
// import cpp.zip.Uncompress;
import haxe.Int64;
import crossbyte._internal.brotli.Brotli;
import crossbyte._internal.lz4.Lz4;
import crossbyte._internal.lz4.Lz4Frame;
import crossbyte._internal.deflatex.Deflater;
import crossbyte._internal.deflatex.GZCompressor;
import crossbyte._internal.deflatex.Inflater;
import crossbyte._internal.deflatex.ZlibCompressor;
import haxe.Exception;
import haxe.Constraints.IMap;
import haxe.ds.ObjectMap;
import haxe.io.Bytes;
import haxe.io.BytesData;
import haxe.io.BytesInput;
import haxe.io.BytesOutput;
import haxe.io.FPHelper;
import haxe.Json;
import haxe.Serializer;
import haxe.Unserializer;
import crossbyte.errors.EOFError;
import crossbyte.errors.RangeError;
import crossbyte.net.ObjectEncoding;
import crossbyte.utils.CompressionAlgorithm;
#if format
import format.amf.Reader as AMFReader;
import format.amf.Tools as AMFTools;
import format.amf.Writer as AMFWriter;
import format.amf.Value as AMFValue;
import format.amf3.Reader as AMF3Reader;
import format.amf3.Tools as AMF3Tools;
import format.amf3.Value as AMF3Value;
import format.amf3.Writer as AMF3Writer;
import crossbyte._internal.serial.BoundedAMF.BoundedAMFReader;
import crossbyte._internal.serial.BoundedAMF.BoundedAMF3Reader;
#end
import crossbyte._internal.serial.BoundedJson;
import crossbyte._internal.serial.BoundedUnserializer;
import crossbyte.errors.IOError;

/**
	The ByteArray class provides methods and properties to optimize reading,
	writing, and working with binary data.
	_Note:_ The ByteArray class is for advanced developers who need to
	access data on the byte level.
	In-memory data is a packed array (the most compact representation for
	the data type) of bytes, but an instance of the ByteArray class can be
	manipulated with the standard `[]`(array access) operators. It
	also can be read and written to as an in-memory file, using methods similar
	to those in the Socket class.
	ByteArray is a Haxe abstract over a hidden `ByteArrayData` type, so it has
	no runtime identity of its own. To test for one at runtime, compare against
	`ByteArrayData`:
	```hx
	import crossbyte.io.ByteArray;
	import crossbyte.io.ByteArray.ByteArrayData;

	if (Std.isOfType(value, ByteArrayData)) {
		var bytes:ByteArray = value;
	}
	```
	Compression support is limited to the algorithms available in
	`CompressionAlgorithm`: `br`, `deflate`, `gzip`, `lz4`, `lz4-frame` and
	`zlib`.
	Possible uses of the ByteArray class include the following:
	* Creating a custom protocol to connect to a server.
	* Writing your own URLEncoder/URLDecoder.
	* Writing your own AMF/Remoting packet.
	* Optimizing the size of your data by using data types.
	* Working with binary data loaded from a local file.
	* Supporting new binary file formats.
**/
@:access(haxe.io.Bytes)
@:access(crossbyte.utils.ByteArrayData)
@:transitive
abstract ByteArray(ByteArrayData) from ByteArrayData to ByteArrayData {
	/**
		The endianness a new ByteArray starts with. Every instance takes its
		`endian` from this at construction; changing it afterwards affects only
		ByteArrays made from then on, not ones that already exist.

		It is `Endian.LITTLE_ENDIAN` on every target, chosen rather than
		inherited: it does not follow the host's byte order, so a ByteArray
		written on one machine reads the same on another. Set it to
		`Endian.BIG_ENDIAN` if you mostly work in network byte order and would
		rather not say so on each instance.
	**/
	public static var defaultEndian(get, set):Endian;

	/**
		Denotes the default object encoding for the ByteArray class to use for a
		new ByteArray instance. When you create a new ByteArray instance, the
		encoding on that instance starts with the value of
		`defaultObjectEncoding`. The `defaultObjectEncoding` property is
		initialized to `ObjectEncoding.DEFAULT`, which is `HXSF` on every
		target.
		When an object is written to or read from binary data, the
		`objectEncoding` value is used to determine whether HXSF, JSON, AMF3
		or AMF0 is used. The value is a constant from the ObjectEncoding
		class.
	**/
	public static var defaultObjectEncoding(get, set):ObjectEncoding;

	/**
		The most values one object read may make: every element, member,
		name and key, and each null of a run, in any encoding. `readObject`
		refuses an object holding more with an `IOError` (a socket's too,
		which reads through a ByteArray), and `SharedObject` and
		`SharedChannel` refuse one as they read it. 1,000,000 unless changed;
		zero or less is no limit.

		A bound on bytes does not bound this. An HXSF array can hold a run of
		nulls in a few bytes, and `au100000000h` (twelve of them) would make
		an array of 100,000,000 slots, 800 MB natively, from any peer that
		could send an object. Every other value costs at least a byte, so a
		frame of 1 MB holds a million at most.

		It is one setting for the whole process, read as each object is: a
		program reading larger objects of its own, from files it wrote,
		raises it for every reader, its peers' included. Held, a million
		values is 4 to 8 MB natively as numbers in an array and about 50 MB
		as small objects or strings, and on the jvm up to 65 MB.
	**/
	public static var maxObjectValues(get, set):Int;

	/**
		The number of bytes of data available for reading from the current
		position in the byte array to the end of the array.
		Use the `bytesAvailable` property in conjunction with the
		read methods each time you access a ByteArray object to ensure that you
		are reading valid data.
	**/
	public var bytesAvailable(get, never):UInt;

	/**
		Changes or reads the byte order for the data; either
		`Endian.BIG_ENDIAN` or `Endian.LITTLE_ENDIAN`.
	**/
	public var endian(get, set):Endian;

	/**
		The length of the ByteArray object, in bytes.
		If the length is set to a value that is larger than the current length,
		the right side of the byte array is filled with zeros.
		If the length is set to a value that is smaller than the current
		length, the byte array is truncated.
	**/
	public var length(get, set):UInt;

	/**
		Which serialization format `readObject` and `writeObject` use. The value
		is a constant from `ObjectEncoding`.

		`HXSF` (Haxe Serialization Format, via `haxe.Serializer`) is the default,
		and `JSON` is always available. `AMF0` and `AMF3` are read and written
		only when the optional `format` haxelib is on the build (`-lib format`).
		Asking for one this build cannot do throws, rather than reading `null`
		or writing nothing.
	**/
	public var objectEncoding(get, set):ObjectEncoding;

	/**
		Moves, or returns the current position, in bytes, of the file pointer into
		the ByteArray object. This is the point at which the next call to a read
		method starts reading or a write method starts writing.
	**/
	public var position(get, set):UInt;

	/**
		Creates a ByteArray instance representing a packed array of bytes, so that
		you can use the methods and properties in this class to optimize your data
		storage and stream.
	**/
	public inline function new(length:Int = 0):Void {
		@:privateAccess
		this = new ByteArrayData(length);
	}

	/**
		Clears the contents of the byte array and resets the `length`
		and `position` properties to 0.

		The memory the bytes took is kept, unlike AIR's `clear()`, which
		frees it: a byte array cleared and filled again reuses its buffer and
		allocates nothing, which is what a buffer reused for every message
		wants, and what `Socket` relies on for its own. To give the memory
		back, drop the byte array and let the collector take it.
	**/
	public inline function clear():Void {
		this.clear();
	}

	/**
		Compresses the byte array in place. The entire byte array is compressed.

		After the call, `length` is the new length and `position` is at the end
		of the byte array.

		@param algorithm Which of `CompressionAlgorithm` to use. The default is
			   `LZ4`, which favours speed over ratio; `DEFLATE` and `GZIP` trade
			   the other way, and `BROTLI` further still.

		`DEFLATE` writes a raw deflate stream
		([RFC 1951](https://www.ietf.org/rfc/rfc1951.txt)) and nothing else:
		no header, no checksum, no length. `GZIP` writes the same compressed
		bytes inside a gzip container ([RFC 1952](https://www.ietf.org/rfc/rfc1952.txt)),
		which adds metadata around them: a magic number, the original size, a
		CRC, and optionally a filename and modification time.

		That distinction is the one that catches people out. A .gz or .zip file
		is not a deflate stream, so `uncompress(DEFLATE)` will not read one:
		the container has to be parsed off first. In the other direction,
		`compress(DEFLATE)` does not produce a file any gzip or zip tool will
		open, because none of the metadata those formats require is there.
		Where you want a file, use `GZIP`; where you want the bytes, use
		`DEFLATE`.

		`ZLIB` ([RFC 1950](https://www.ietf.org/rfc/rfc1950.txt)) is the third
		wrapping of the same stream: a two-byte header and an Adler-32. It is
		what HTTP's `deflate` content coding means, and what zlib, Node's
		`zlib.deflateSync` and Java's `Deflater` produce and expect.

		`LZ4` is the same split: a bare block, which carries no length, and
		`LZ4_FRAME`, what the `lz4` tool writes, which wraps blocks in sizes and
		checksums. A block cut short can pass for a whole one; a frame cannot.
	**/
	public inline function compress(algorithm:CompressionAlgorithm = LZ4):Void {
		this.compress(algorithm);
	}

	/**
		Compresses the byte array using the deflate compression algorithm. The
		entire byte array is compressed.
		After the call, the `length` property of the ByteArray is
		set to the new length. The `position` property is set to the
		end of the byte array.
		The deflate compression algorithm is described at
		[http://www.ietf.org/rfc/rfc1951.txt](http://www.ietf.org/rfc/rfc1951.txt).
		In order to use the deflate format to compress a ByteArray instance's
		data in a specific format such as gzip or zip, you cannot simply call
		`deflate()`. You must create a ByteArray structured according
		to the compression format's specification, including the appropriate
		metadata as well as the compressed data obtained using the deflate format.
		Likewise, in order to decode data compressed in a format such as gzip or
		zip, you can't simply call `inflate()` on that data. First, you
		must separate the metadata from the compressed data, and you can then use
		the deflate format to decompress the compressed data.
	**/
	public inline function deflate():Void {
		this.deflate();
	}

	/**
		Converts a Bytes object into a ByteArray, which is also what
		assigning a `Bytes` to a `ByteArray` does.

		The ByteArray uses `bytes`' own storage rather than a copy: natively,
		on the jvm, hl, neko and JavaScript, a change made through either
		shows in the other, until the ByteArray grows past that storage and
		takes a buffer of its own. The interpreter copies, so there the two
		are independent from the start. For a ByteArray of its own on every
		target, copy first: `ByteArray.fromBytes(bytes.sub(0, bytes.length))`.

		A `ByteArray` passed in comes back as it is.

		@param	bytes	A Bytes instance
		@returns	A ByteArray over `bytes`, or null for null.
	**/
	@:from public static function fromBytes(bytes:Bytes):ByteArray {
		if (bytes == null)
			return null;

		if ((bytes is ByteArrayData)) {
			return cast bytes;
		} else {
			return ByteArrayData.fromBytes(bytes);
		}
	}

	/**
		Converts a BytesData object into a ByteArray.
		@param	buffer	A BytesData instance
		@returns	A new ByteArray
	**/
	@:from @:noCompletion public static function fromBytesData(bytesData:BytesData):ByteArray {
		if (bytesData == null)
			return null;

		return ByteArrayData.fromBytes(Bytes.ofData(bytesData));
	}

	@:arrayAccess @:noCompletion private inline function get(index:Int):Int {
		return this.get(index);
	}

	/**
		Decompresses the byte array using the deflate compression algorithm. The
		byte array must have been compressed using the same algorithm.
		After the call, the `length` property of the ByteArray is
		set to the new length. The `position` property is set to 0.
		The deflate compression algorithm is described at
		[http://www.ietf.org/rfc/rfc1951.txt](http://www.ietf.org/rfc/rfc1951.txt).
		In order to decode data compressed in a format that uses the deflate
		compression algorithm, such as data in gzip or zip format, it will not
		work to simply call `inflate()` on a ByteArray containing the
		compression formation data. First, you must separate the metadata that is
		included as part of the compressed data format from the actual compressed
		data. For more information, see the `compress()` method
		description.
		@throws IOError The data is not valid compressed data; it was not
						compressed with the same compression algorithm used to
						compress.
	**/
	public inline function inflate():Void {
		this.inflate();
	}

	/**
		Reads a Boolean value from the byte stream. A single byte is read, and
		`true` is returned if the byte is nonzero, `false`
		otherwise.
		@return Returns `true` if the byte is nonzero,
				`false` otherwise.
		@throws EOFError There is not sufficient data available to read.
	**/
	public inline function readBoolean():Bool {
		return this.readBoolean();
	}

	/**
		Reads a signed byte from the byte stream.
		The returned value is in the range -128 to 127.
		@return An integer between -128 and 127.
		@throws EOFError There is not sufficient data available to read.
	**/
	public inline function readByte():Int {
		return this.readByte();
	}

	/**
		Reads the number of data bytes, specified by the `length`
		parameter, from the byte stream. The bytes are read into the ByteArray
		object specified by the `bytes` parameter, and the bytes are
		written into the destination ByteArray starting at the position specified
		by `offset`.
		@param bytes  The ByteArray object to read data into.
		@param offset The offset(position) in `bytes` at which the
					  read data should be written.
		@param length The number of bytes to read. The default value of 0 causes
					  all available data to be read.
		@throws EOFError   There is not sufficient data available to read.
		@throws RangeError The value of the supplied offset and length, combined,
						   is greater than the maximum for a uint.
	**/
	public inline function readBytes(bytes:ByteArray, offset:UInt = 0, length:UInt = 0):Void {
		this.readBytes(bytes, offset, length);
	}

	/**
		Reads an IEEE 754 double-precision(64-bit) floating-point number from the
		byte stream.
		@return A double-precision(64-bit) floating-point number.
		@throws EOFError There is not sufficient data available to read.
	**/
	public inline function readDouble():Float {
		return this.readDouble();
	}

	/**
		Reads an IEEE 754 single-precision(32-bit) floating-point number from the
		byte stream.
		@return A single-precision(32-bit) floating-point number.
		@throws EOFError There is not sufficient data available to read.
	**/
	public inline function readFloat():Float {
		return this.readFloat();
	}

	/**
		Reads a signed 32-bit integer from the byte stream.
		The returned value is in the range -2147483648 to 2147483647.
		@return A 32-bit signed integer between -2147483648 and 2147483647.
		@throws EOFError There is not sufficient data available to read.
	**/
	public inline function readInt():Int {
		return this.readInt();
	}

	/**
		Reads a signed 64-bit integer from the byte stream.
		The returned value is in the range −9223372036854775808 to 9223372036854775807.
		@return A 64-bit signed integer between −9223372036854775808 to 9223372036854775807.
		@throws EOFError There is not sufficient data available to read.
	**/
	public inline function readInt64():Int64 {
		return this.readInt64();
	}

	/**
		Reads `length` bytes and decodes them as UTF-8.

		@param length  The number of bytes to read.
		@param charSet Accepted for source compatibility and **ignored**. No
		               character set conversion happens: the bytes are decoded
		               as UTF-8, exactly as `readUTFBytes` would. Passing
		               `"shift-jis"` does not decode Shift-JIS. Transcode the
		               bytes yourself if you need another encoding.
		@return UTF-8 encoded string.
		@throws EOFError There is not sufficient data available to read.
	**/
	public inline function readMultiByte(length:UInt, charSet:String):String {
		return this.readMultiByte(length, charSet);
	}

	/**
		Reads an object from the byte array, in whichever format
		`objectEncoding` names. That is `HXSF` unless you changed it, not AMF.

		An `HXSF` or `JSON` object is read as `writeObject` frames one: the
		length in bytes of its text, as an unsigned 32-bit integer in this
		byte array's `endian`, then the text as UTF-8. `AMF0` and `AMF3` are
		their own framing.

		@return The deserialized object.
		@throws EOFError There is not sufficient data available to read.
				`position` is left where it was, so the read can be tried
				again once the rest has arrived, in `AMF0` and `AMF3` too.
		@throws RangeError An `HXSF` or `JSON` object declares 2^31 bytes or
				more, which no ByteArray holds.
		@throws IOError The object nests values within values more than 256
				levels deep (128 in `AMF0` or `AMF3`, whose levels take more
				stack), or holds more values than `maxObjectValues` allows,
				or is malformed in a way that would read the same bytes for
				ever. It is refused before reading it could exhaust the
				stack or memory: a peer's object, read through a socket's
				`readObject`, nested a few thousand deep would end the
				process, and twelve bytes of HXSF would make an array of
				800 MB. An `HXSF` or `JSON` object's bytes are consumed.
	**/
	public inline function readObject():Dynamic {
		return this.readObject();
	}

	/**
		Reads a signed 16-bit integer from the byte stream.
		The returned value is in the range -32768 to 32767.
		@return A 16-bit signed integer between -32768 and 32767.
		@throws EOFError There is not sufficient data available to read.
	**/
	public inline function readShort():Int {
		return this.readShort();
	}

	/**
		Reads a UTF-8 string from the byte stream. The string is assumed to be
		prefixed with an unsigned short indicating the length in bytes.
		@return UTF-8 encoded string.
		@throws EOFError There is not sufficient data available to read.
	**/
	public inline function readUTF():String {
		return this.readUTF();
	}

	/**
		Reads a sequence of UTF-8 bytes specified by the `length`
		parameter from the byte stream and returns a string.
		@param length An unsigned short indicating the length of the UTF-8 bytes.
		@return A string composed of the UTF-8 bytes of the specified length.
		@throws EOFError There is not sufficient data available to read.
	**/
	public inline function readUTFBytes(length:UInt):String {
		return this.readUTFBytes(length);
	}

	/**
		Reads an unsigned byte from the byte stream.
		The returned value is in the range 0 to 255.
		@return A 32-bit unsigned integer between 0 and 255.
		@throws EOFError There is not sufficient data available to read.
	**/
	public inline function readUnsignedByte():UInt {
		return this.readUnsignedByte();
	}

	/**
		Reads an unsigned 32-bit integer from the byte stream.
		The returned value is in the range 0 to 4294967295.
		@return A 32-bit unsigned integer between 0 and 4294967295.
		@throws EOFError There is not sufficient data available to read.
	**/
	public inline function readUnsignedInt():UInt {
		return this.readUnsignedInt();
	}

	/**
		Reads an unsigned 16-bit integer from the byte stream.
		The returned value is in the range 0 to 65535.
		@return A 16-bit unsigned integer between 0 and 65535.
		@throws EOFError There is not sufficient data available to read.
	**/
	public inline function readUnsignedShort():UInt {
		return this.readUnsignedShort();
	}

	/**
		Reads an **unsigned variable-length integer** that was written
		using `writeVarUInt()`: the same format as
		`ByteArrayInput.readVarUInt` and `ByteArrayOutput.writeVarUInt`.
		`ByteArray` has no signed (ZigZag) varint; those two classes do,
		as `readVarInt` and `writeVarInt`.

		@return The decoded integer (0 – 0xFFFFFFFF). As an `Int`, a value
				from 2^31 up reads as negative; check for that where the value
				is a length or a count.
		@throws EOFError If the buffer ends before the var-int terminates.
				`position` is left where it was, so the read can be tried
				again once the rest has arrived.
		@throws RangeError If the var-int does not fit in 32 bits: its fifth
				byte carries more than four bits, or asks for a sixth.
				`position` is left where it was.
	**/
	public inline function readVarUInt():UInt {
		return this.readVarUInt();
	}

	@:arrayAccess @:noCompletion private inline function set(index:Int, value:Int):Int {
		this.__resize(index + 1);
		this.set(index, value);

		return value;
	}

	@:to @:noCompletion private static function toBytes(byteArray:ByteArray):Bytes {
		return (byteArray : ByteArrayData);
	}

	/**
		Decodes the whole byte array as UTF-8, from index 0 and regardless of
		`position`.

		A leading byte order mark is data like any other and survives into the
		string as U+FEFF; strip it yourself if the source may carry one. There is
		no code page fallback.

		@return The string representation of the byte array.
	**/
	public inline function toString():String {
		return crossbyte._internal.Utf8.stringOf(this, 0, this.length);
	}

	/**
		Decompresses the byte array in place.

		After the call, `length` is the new length and `position` is 0.

		@param algorithm Which of `CompressionAlgorithm` the data was compressed
			   with. It must be the same one; these formats are not
			   self-describing enough to guess between.

		A gzip or zip file is not a raw deflate stream, so `uncompress(DEFLATE)`
		does not read one; see `compress()` for why.

		@param maxOutputSize Bytes the decoded result may reach before this
		       gives up, or `0` for no limit. Compression ratios have no
		       ceiling (a megabyte of zeros returns as roughly a gigabyte),
		       so anything decoding bytes it did not author wants to name one.
		@throws crossbyte.errors.IOError The data is not valid for
		        `algorithm`: damaged, cut short, or compressed with something
		        else. Every algorithm throws this and only this for bad data,
		        so a caller can tell a bad body from a fault in the code.
		@throws crossbyte.errors.RangeError The result would be larger than
		        `maxOutputSize`. It is thrown as the limit is reached, before
		        the rest is decoded.
	**/
	public inline function uncompress(algorithm:CompressionAlgorithm = LZ4, maxOutputSize:Int = 0):Void {
		this.uncompress(algorithm, maxOutputSize);
	}

	/**
		Writes a Boolean value. A single byte is written according to the
		`value` parameter, either 1 if `true` or 0 if
		`false`.
		@param value A Boolean value determining which byte is written. If the
					 parameter is `true`, the method writes a 1; if
					 `false`, the method writes a 0.
	**/
	public inline function writeBoolean(value:Bool):Void {
		this.writeBoolean(value);
	}

	/**
		Writes a byte to the byte stream.
		The low 8 bits of the parameter are used. The high 24 bits are ignored.
		@param value A 32-bit integer. The low 8 bits are written to the byte
					 stream.
	**/
	public inline function writeByte(value:Int):Void {
		this.writeByte(value);
	}

	/**
		Writes a sequence of `length` bytes from the specified byte
		array, `bytes`, starting `offset`(zero-based index)
		bytes into the byte stream.
		If the `length` parameter is omitted, the default length of
		0 is used; the method writes the entire buffer starting at
		`offset`. If the `offset` parameter is also omitted,
		the entire buffer is written.
		If `offset` or `length` is out of range, they are
		clamped to the beginning and end of the `bytes` array.
		@param bytes  The ByteArray object.
		@param offset A zero-based index indicating the position into the array to
					  begin writing.
		@param length An unsigned integer indicating how far into the buffer to
					  write.
	**/
	public inline function writeBytes(bytes:ByteArray, offset:UInt = 0, length:UInt = 0):Void {
		this.writeBytes(bytes, offset, length);
	}

	/**
		Writes an IEEE 754 double-precision(64-bit) floating-point number to the
		byte stream.
		@param value A double-precision(64-bit) floating-point number.
	**/
	public inline function writeDouble(value:Float):Void {
		this.writeDouble(value);
	}

	/**
		Writes an IEEE 754 single-precision(32-bit) floating-point number to the
		byte stream.
		@param value A single-precision(32-bit) floating-point number.
	**/
	public inline function writeFloat(value:Float):Void {
		this.writeFloat(value);
	}

	/**
		Writes a 32-bit signed integer to the byte stream.
		@param value An integer to write to the byte stream.
	**/
	public inline function writeInt(value:Int):Void {
		this.writeInt(value);
	}

	/**
		Writes a 64-bit signed integer to the byte stream.
		@param value An integer to write to the byte stream.
	**/
	public inline function writeInt64(value:Int64):Void {
		this.writeInt64(value);
	}

	/**
		Writes a string to the byte stream as UTF-8.

		@param value   The string value to be written.
		@param charSet Accepted for source compatibility and **ignored**. The
		               string is encoded as UTF-8, exactly as `writeUTFBytes`
		               would. Transcode the bytes yourself if you need another
		               encoding.
	**/
	public inline function writeMultiByte(value:String, charSet:String):Void {
		this.writeMultiByte(value, charSet);
	}

	/**
		Writes an object into the byte array, in whichever format
		`objectEncoding` names. That is `HXSF` unless you changed it, not AMF.

		An `HXSF` or `JSON` object is framed as the length in bytes of its
		text, an unsigned 32-bit integer in this byte array's `endian`, then
		the text as UTF-8, so it can be as large as a ByteArray. (1.0.0-rc.1
		framed it as `writeUTF` frames a string, behind a 16-bit length, and
		refused one past 65,535 bytes; the two framings do not read each
		other.) `AMF0` and `AMF3` are their own framing.

		@param object The object to serialize.
	**/
	public inline function writeObject(object:Dynamic):Void {
		this.writeObject(object);
	}

	/**
		Writes a 16-bit integer to the byte stream. The low 16 bits of the
		parameter are used. The high 16 bits are ignored.
		@param value 32-bit integer, whose low 16 bits are written to the byte
					 stream.
	**/
	public inline function writeShort(value:Int):Void {
		this.writeShort(value);
	}

	/**
		Writes a UTF-8 string to the byte stream. The length of the UTF-8 string
		in bytes is written first, as a 16-bit integer, followed by the bytes
		representing the characters of the string.
		@param value The string value to be written.
		@throws RangeError If the length is larger than 65535.
	**/
	public inline function writeUTF(value:String):Void {
		this.writeUTF(value);
	}

	/**
		Writes a UTF-8 string to the byte stream. Similar to the
		`writeUTF()` method, but `writeUTFBytes()` does not
		prefix the string with a 16-bit length word.
		@param value The string value to be written.
	**/
	public inline function writeUTFBytes(value:String):Void {
		this.writeUTFBytes(value);
	}

	/**
		Writes a 32-bit unsigned integer to the byte stream.
		@param value An unsigned integer to write to the byte stream.
	**/
	public inline function writeUnsignedInt(value:UInt):Void {
		this.writeUnsignedInt(value);
	}

	/**
		Writes an **unsigned variable-length integer** to the buffer
		in little-endian, 7-bit continuation-byte format (compatible
		with Google Protocol Buffers “varint”).

		```text
		value range                    encoded length
		0 – 127                        1 byte
		128 – 16,383                   2 bytes
		16,384 – 2,097,151             3 bytes
		2,097,152 – 268,435,455        4 bytes
		268,435,456 – 4,294,967,295    5 bytes
		```
		Each byte stores the lower 7 bits; the high bit is set to 1
		until the final byte, where it is 0.

		The same format as `ByteArrayOutput.writeVarUInt`, read back by
		`readVarUInt` here or `ByteArrayInput.readVarUInt`.

		@param value The unsigned integer to encode (0 – 0xFFFFFFFF). A
			   negative `Int` is the unsigned value it holds: -1 is written
			   as 0xFFFFFFFF, in five bytes.
	**/
	public inline function writeVarUInt(value:UInt):Void {
		this.writeVarUInt(value);
	}

	// Get & Set Methods
	@:noCompletion private inline function get_bytesAvailable():UInt {
		return this.bytesAvailable;
	}

	@:noCompletion private inline static function get_defaultEndian():Endian {
		return ByteArrayData.defaultEndian;
	}

	@:noCompletion private inline static function set_defaultEndian(value:Endian):Endian {
		return ByteArrayData.defaultEndian = value;
	}

	@:noCompletion private inline static function get_defaultObjectEncoding():ObjectEncoding {
		return ByteArrayData.defaultObjectEncoding;
	}

	@:noCompletion private inline static function set_defaultObjectEncoding(value:ObjectEncoding):ObjectEncoding {
		return ByteArrayData.defaultObjectEncoding = value;
	}

	@:noCompletion private inline static function get_maxObjectValues():Int {
		return BoundedUnserializer.maxValues;
	}

	@:noCompletion private inline static function set_maxObjectValues(value:Int):Int {
		return BoundedUnserializer.maxValues = value;
	}

	@:noCompletion private inline function get_endian():Endian {
		return this.endian;
	}

	@:noCompletion private inline function set_endian(value:Endian):Endian {
		return this.endian = value;
	}

	@:noCompletion private function get_length():UInt {
		return this == null ? 0 : this.length;
	}

	@:noCompletion private function set_length(value:Int):UInt {
		// Clamp negatives to 0 instead of assigning a negative length, which
		// would leave the ByteArray in an invalid state.
		if (value < 0) {
			value = 0;
		}

		this.__resize(value);
		if (value < this.position)
			this.position = value;

		this.length = value;

		return value;
	}

	@:noCompletion private inline function get_objectEncoding():ObjectEncoding {
		return this.objectEncoding;
	}

	@:noCompletion private inline function set_objectEncoding(value:ObjectEncoding):ObjectEncoding {
		return this.objectEncoding = value;
	}

	@:noCompletion private inline function get_position():UInt {
		return this.position;
	}

	@:noCompletion private inline function set_position(value:UInt):UInt {
		return this.position = value;
	}
}

//--------------------------------------------------------------------------------------------------------------------------
#if !debug
@:fileXml('tags="haxe,release"')
@:noDebug
#end
@SuppressWarnings("checkstyle:FieldDocComment")
@:noCompletion @:dox(hide) class ByteArrayData extends Bytes implements IDataInput implements IDataOutput {
	public static var defaultEndian(get, set):Endian;
	public static var defaultObjectEncoding:ObjectEncoding = ObjectEncoding.DEFAULT;
	@:noCompletion private static var __defaultEndian:Endian = null;
	#if !js
	@:noCompletion private static var __emptyData:BytesData = null;
	#end

	public var bytesAvailable(get, never):UInt;
	public var endian(get, set):Endian;
	public var objectEncoding:ObjectEncoding;
	public var position:Int;

	@:noCompletion private var __endian:Endian;
	@:noCompletion private var __length:Int;

	private function new(length:Int = 0) {
		#if js
		// Straight onto a new buffer, which JavaScript zeroes. Bytes.alloc made
		// a Bytes and a view of its own only for this to make another over the
		// same buffer: three objects for one, for every ByteArray, and an HTTP
		// server on Node makes several a request.
		super(new js.lib.ArrayBuffer(length));
		#else
		// An empty one shares one empty buffer: every ByteArray made from a
		// Bytes (fromBytes, every implicit conversion, per datagram, per
		// frame) starts empty and is handed the bytes' own buffer at once, so
		// a Bytes and its buffer made here would only be dropped.
		// Nothing writes into a buffer of no length; growing replaces it.
		var data:BytesData;
		if (length == 0) {
			data = __emptyData;
			if (data == null) {
				data = __emptyData = Bytes.alloc(0).getData();
			}
		} else {
			var bytes = Bytes.alloc(length);

			#if sys
			bytes.fill(0, length, 0);
			#end
			data = bytes.getData();
		}

		#if hl
		super(data, length);
		#else
		super(length, data);
		#end
		#end

		__length = length;

		endian = defaultEndian;
		objectEncoding = defaultObjectEncoding;
		position = 0;
	}

	public function clear():Void {
		length = 0;
		position = 0;
	}

	public function compress(algorithm:CompressionAlgorithm = LZ4):Void {
		/*#if lime
			#if js
			if (__length > #if lime_bytes_length_getter l #else length #end)
			{
				var cacheLength = #if lime_bytes_length_getter l #else length #end;
				#if lime_bytes_length_getter
				this.l = __length;
				#else
				this.length = __length;
				#end
				var data = Bytes.alloc(cacheLength);
				data.blit(0, this, 0, cacheLength);
				__setData(data);
				#if lime_bytes_length_getter
				this.l = cacheLength;
				#else
				this.length = cacheLength;
				#end
			}
			#end

			var limeBytes:LimeBytes = this;


			var bytes = switch (algorithm)
			{
				case CompressionAlgorithm.DEFLATE: limeBytes.compress(DEFLATE);
				case CompressionAlgorithm.LZMA: limeBytes.compress(LZMA);
				default: limeBytes.compress(ZLIB);
			}

			if (bytes != null)
			{
				__setData(bytes);

				#if lime_bytes_length_getter
				l
				#else
				length
				#end
				= __length;
				position = #if lime_bytes_length_getter l #else length #end;
			}
			#end */

		var bytes:Bytes = switch (algorithm) {
			case CompressionAlgorithm.BROTLI: Brotli.compress(this);
			case CompressionAlgorithm.DEFLATE: Deflater.apply(this);
			case CompressionAlgorithm.GZIP: GZCompressor.compress(null, this);
			case CompressionAlgorithm.LZ4: Lz4.compress(this);
			case CompressionAlgorithm.ZLIB: ZlibCompressor.compress(this);
			case CompressionAlgorithm.LZ4_FRAME: Lz4Frame.compress(this);
			default: throw new Exception("Unsupported compression algorithm: " + algorithm);
		}

		if (bytes != null) {
			__setData(bytes);
			length = __length;

			position = length;
		}
	}

	public function deflate():Void {
		compress(CompressionAlgorithm.DEFLATE);
	}

	public static function fromBytes(bytes:Bytes):ByteArrayData {
		// Made empty, then given the bytes' own buffer. Made at their length,
		// it would allocate and zero-fill a buffer that __fromBytes drops at
		// once, on every implicit conversion (every socket read among them,
		// where the bytes are a 64 KB scratch). eval copies into the buffer
		// rather than adopting one, so it is still made to size there.
		var result = new ByteArrayData(#if eval bytes.length #else 0 #end);
		result.__fromBytes(bytes);
		return result;
	}

	public function inflate():Void {
		uncompress(CompressionAlgorithm.DEFLATE);
	}

	public function readBoolean():Bool {
		if (position < length) {
			return (get(position++) != 0);
		} else {
			throw new EOFError();
			return false;
		}
	}

	public function readByte():Int {
		var value = readUnsignedByte();

		if (value & 0x80 != 0) {
			return value - 0x100;
		} else {
			return value;
		}
	}

	public function readBytes(bytes:ByteArray, offset:Int = 0, length:Int = 0):Void {
		if (length == 0)
			length = this.length - position;

		// Against the bytes remaining rather than `position + length`: that
		// sum overflows for a large length and wraps negative, which is not
		// greater than this.length, so the guard would pass and the read run
		// off the end of the buffer.
		if (offset < 0 || length < 0 || length > this.length - position) {
			throw new EOFError();
		}

		// Same shape on the destination: `offset + length` would decide both
		// the test and the size passed to __resize, so an overflow would ask
		// for a negative allocation.
		//
		// Grown with the bytes from `offset` on left to the blit below, which
		// writes all of them: only a gap before `offset` is zeroed, rather than
		// zeroing them all first (on JavaScript a byte at a time, a third of a
		// Node server's working time taking uploads).
		if ((bytes : ByteArrayData).length - offset < length) {
			(bytes : ByteArrayData).__resize(offset + length, offset);
		}

		(bytes : ByteArrayData).blit(offset, this, position, length);
		position += length;
	}

	public function readDouble():Float {
		if (endian == LITTLE_ENDIAN) {
			var low = readInt();
			var high = readInt();

			return FPHelper.i64ToDouble(low, high);
		} else {
			var high = readInt();
			var low = readInt();

			return FPHelper.i64ToDouble(low, high);
		}
	}

	public function readFloat():Float {
		return FPHelper.i32ToFloat(readInt());
	}

	public function readInt():Int {
		var at = position;

		if (at + 4 > __available()) {
			throw new EOFError();
		}

		position = at + 4;
		var value = getInt32(at);
		return __endian == LITTLE_ENDIAN ? value : __swap32(value);
	}

	public function readInt64():Int64 {
		if (position + 8 > length) {
			throw new EOFError();
		}

		var high:Int;
		var low:Int;

		if (endian == LITTLE_ENDIAN) {
			low = readUnsignedInt();
			high = readUnsignedInt();
		} else {
			high = readUnsignedInt();
			low = readUnsignedInt();
		}

		return Int64.make(high, low);
	}

	public function readMultiByte(length:Int, charSet:String):String {
		return readUTFBytes(length);
	}

	public function readObject():Dynamic {
		switch (objectEncoding) {
			#if format
			// An object that runs out is an EOFError, position left alone, as
			// one in HXSF or JSON is.
			case AMF0:
				var input = new BytesInput(this, position);
				var reader = new BoundedAMFReader(input);
				var data:Dynamic;
				try {
					data = unwrapAMFValue(reader.read());
				} catch (_:haxe.io.Eof) {
					throw new EOFError();
				}
				position = input.position;
				return data;

			case AMF3:
				var input = new BytesInput(this, position);
				var reader = new BoundedAMF3Reader(input);
				var data:Dynamic;
				try {
					data = unwrapAMF3Value(reader.read());
				} catch (_:haxe.io.Eof) {
					throw new EOFError();
				}
				position = input.position;
				return data;
			#end

			// Bounded, every encoding: an object is what a peer sends a
			// socket, and natively one nested a few thousand deep (12 KB)
			// would overflow the stack reading it and end the process.
			case HXSF:
				return BoundedUnserializer.run(__readObjectText());

			case JSON:
				return BoundedJson.parse(__readObjectText());

			default:
				throw new Exception(__unsupportedEncoding(objectEncoding));
		}
	}

	/**
		The text an HXSF or JSON object was written as: its length in bytes as
		an unsigned 32-bit integer in this stream's `endian`, then that many
		bytes of UTF-8. Not framed as `writeUTF` frames a string, behind
		sixteen bits, so an object can pass 65,535 bytes of text.

		An object only part of which is here is an EOFError that leaves
		`position` where it was, so a socket's reader can try again when the
		rest has arrived.
	**/
	@:noCompletion private function __readObjectText():String {
		var at:Int = position;
		var count:Int = readUnsignedInt();
		if (count < 0) {
			// From 2^31 up, which no ByteArray holds, so no wait would end it.
			position = at;
			throw new RangeError("An object declares 2^31 bytes or more, which no ByteArray holds.");
		}
		if (count > __available() - position) {
			position = at;
			throw new EOFError();
		}
		return readUTFBytes(count);
	}

	@:noCompletion private function __writeObjectText(text:String):Void {
		var bytes:Bytes = crossbyte._internal.Utf8.bytesOf(text);
		writeUnsignedInt(bytes.length);
		__writeAll(bytes);
	}

	// Reached when objectEncoding names a format this build cannot do (AMF
	// without the optional haxelib, or a value that is not an ObjectEncoding
	// at all, which Int can be), so that an AMF round trip on a build
	// without -lib format fails loudly rather than losing the object.
	private static function __unsupportedEncoding(encoding:ObjectEncoding):String {
		#if !format
		if (encoding == AMF0 || encoding == AMF3) {
			return "ObjectEncoding.AMF" + (encoding == AMF0 ? "0" : "3")
				+ " needs the optional \"format\" haxelib. Build with -lib format, or use HXSF or JSON.";
		}
		#end

		return "Unsupported object encoding: " + encoding;
	}

	#if format
	private static function unwrapAMFValue(val:AMFValue):Dynamic {
		switch (val) {
			case ANumber(f):
				return f;
			case ABool(b):
				return b;
			case AString(s):
				return s;
			case ADate(d):
				return d;
			case AUndefined:
				return null;
			case ANull:
				return null;
			case AArray(vals):
				return vals.map(unwrapAMFValue);

			case AObject(vmap):
				// AMF0 has no distinction between Object/Map. Most likely we want an anonymous object here.
				var obj = {};
				for (name in vmap.keys()) {
					Reflect.setField(obj, name, unwrapAMFValue(vmap.get(name)));
				}
				return obj;
		};
	}

	private static function unwrapAMF3Value(val:AMF3Value):Dynamic {
		return switch (val) {
			case ANumber(f): return f;
			case AInt(n): return n;
			case ABool(b): return b;
			case AString(s): return s;
			case ADate(d): return d;
			case AXml(xml): return xml;
			case AUndefined: return null;
			case ANull: return null;
			case AArray(vals): return vals.map(unwrapAMF3Value);
			case AVector(vals): return vals.map(unwrapAMF3Value);
			case ABytes(b): return ByteArray.fromBytes(b);

			case AObject(vmap):
				var obj = {};
				for (name in vmap.keys()) {
					Reflect.setField(obj, name, unwrapAMF3Value(vmap[name]));
				}
				return obj;

			case AMap(vmap):
				var map:IMap<Dynamic, Dynamic> = null;
				for (key in vmap.keys()) {
					// Get the map type from the type of the first key.
					if (map == null) {
						map = switch (key) {
							case AString(_): new Map<String, Dynamic>();
							case AInt(_): new Map<Int, Dynamic>();
							default: new ObjectMap<Dynamic, Dynamic>();
						}
					}
					map.set(unwrapAMF3Value(key), unwrapAMF3Value(vmap[key]));
				}

				// Default to StringMap if the map is empty.
				if (map == null) {
					map = new Map<String, Dynamic>();
				}
				return map;
		}
	}
	#end

	public function readShort():Int {
		var value = readUnsignedShort();
		return (value & 0x8000) != 0 ? value - 0x10000 : value;
	}

	public function readUnsignedByte():Int {
		if (position < #if lime_bytes_length_getter l #else length #end) {
			return get(position++);
		} else {
			throw new EOFError();
			return 0;
		}
	}

	public function readUnsignedInt():Int {
		// Identical to `readInt` on a 32-bit Int: the sign bit is the same bit
		// either way, and Haxe has no wider integer to widen it into. The two
		// names are kept because callers read differently for each.
		return readInt();
	}

	public function readUnsignedShort():Int {
		var at = position;

		if (at + 2 > __available()) {
			throw new EOFError();
		}

		position = at + 2;
		var value = getUInt16(at);
		return __endian == LITTLE_ENDIAN ? value : (((value >> 8) & 0xFF) | ((value << 8) & 0xFF00));
	}

	public function readUTF():String {
		var bytesCount = readUnsignedShort();
		return readUTFBytes(bytesCount);
	}

	public function readUTFBytes(length:Int):String {
		// Difference, not sum: see readBytes. `length` is a caller's number
		// and can be large enough to wrap the addition.
		if (length < 0 || length > (#if lime_bytes_length_getter l #else this.length #end) - position) {
			throw new EOFError();
		}

		position += length;

		// Through the platform's decoder on JavaScript; see Utf8.
		return crossbyte._internal.Utf8.stringOf(this, position - length, length);
	}

	@:keep public function readVarUInt():Int {
		// Through a cursor of its own, committed once the varint is whole: a
		// varint cut short leaves `position` where it was, as a truncated
		// readInt does, so a reader can try again when the rest arrives.
		var at:Int = position;
		var end:Int = __available();
		var result:Int = 0;
		var shift:Int = 0;
		while (true) {
			if (at >= end) {
				throw new EOFError();
			}
			var byte:Int = get(at++);
			// The fifth byte carries the last four bits of 32 and has to end
			// the varint: anything above them would be shifted off the top
			// (2^32 + 1 reading as 1), and a continuation bit here asks for a
			// sixth byte, which a 32-bit value never needs.
			if (shift == 28 && byte > 0x0F) {
				throw new RangeError("A varint does not fit in 32 bits.");
			}
			result |= (byte & 0x7F) << shift;
			if ((byte & 0x80) == 0) {
				break;
			}
			shift += 7;
		}
		position = at;
		return result;
	}

	/**
		@param maxOutputSize Bytes the decoded result may reach before this
		       gives up, or `0` for no limit. Compression ratios have no
		       ceiling (a megabyte of zeros returns as roughly a gigabyte),
		       so anything decoding bytes it did not author wants to name one.
	**/
	public function uncompress(algorithm:CompressionAlgorithm = LZ4, maxOutputSize:Int = 0):Void {
		/*#if lime
			#if js
			if (__length > #if lime_bytes_length_getter l #else length #end)
			{
				var cacheLength = #if lime_bytes_length_getter l #else length #end;
				#if lime_bytes_length_getter
				this.l = __length;
				#else
				this.length = __length;
				#end
				var data = Bytes.alloc(cacheLength);
				data.blit(0, this, 0, cacheLength);
				__setData(data);
				#if lime_bytes_length_getter
				this.l = cacheLength;
				#else
				this.length = cacheLength;
				#end
			}
			#end

			var limeBytes:LimeBytes = this;

			var bytes = switch (algorithm)
			{
				case CompressionAlgorithm.DEFLATE: limeBytes.decompress(DEFLATE);
				case CompressionAlgorithm.LZMA: limeBytes.decompress(LZMA);
				default: limeBytes.decompress(ZLIB);
			};

			if (bytes != null)
			{
				__setData(bytes);

				#if lime_bytes_length_getter
				l
				#else
				length
				#end
				= __length;
			}
			#end

			position = 0; */

		var bytes:Bytes = switch (algorithm) {
			// Every one of these takes the ceiling down into the decode itself,
			// the opt-in native Brotli and LZ4 backends included, so a stream
			// that keeps expanding is abandoned partway rather than decoded
			// whole and measured afterwards.
			case CompressionAlgorithm.BROTLI: Brotli.decompress(this, maxOutputSize);
			case CompressionAlgorithm.DEFLATE: Inflater.apply(this, maxOutputSize);
			case CompressionAlgorithm.GZIP: GZCompressor.decompress(this, maxOutputSize);
			case CompressionAlgorithm.LZ4: Lz4.decompress(this, maxOutputSize);
			case CompressionAlgorithm.ZLIB: ZlibCompressor.decompress(this, maxOutputSize);
			case CompressionAlgorithm.LZ4_FRAME: Lz4Frame.decompress(this, maxOutputSize);
			default: throw new Exception("Unsupported compression algorithm: " + algorithm);
		}

		if (bytes != null) {
			__setData(bytes);

			length = __length;
		}
		position = 0;
	}

	@:keep public inline function writeBoolean(value:Bool):Void {
		this.writeByte(value ? 1 : 0);
	}

	@:keep public inline function writeByte(value:Int):Void {
		if (!__room(1)) {
			__resize(position + 1, position);
		}

		set(position++, value & 0xFF);
	}

	@:keep public function writeBytes(bytes:ByteArray, offset:UInt = 0, length:UInt = 0):Void {
		// Clamp offset/length to the source bounds so an out-of-range request
		// cannot over-read past the end of `bytes`.
		var available:UInt = bytes.length;
		if (available == 0 || offset >= available)
			return;

		var remaining:UInt = available - offset;
		if (length == 0 || length > remaining)
			length = remaining;
		if (length == 0)
			return;

		// The blit below covers [position, position + length), so only a gap
		// left by seeking past the end needs zeroing. On an append there is
		// no gap and the fill is skipped entirely.
		__resize(position + length, position);
		blit(position, (bytes : ByteArrayData), offset, length);

		position += length;
	}

	#if js
	// Natively. Haxe's fill sets a byte at a time, and a ByteArray zeroes
	// with it whatever growing exposes.
	override public function fill(pos:Int, len:Int, value:Int):Void {
		b.fill(value, pos, pos + len);
	}

	// A view's bytes appended at the end in one copy, the position left where
	// it is. What a Node socket receives is a view of a pool Node shares,
	// copied here once rather than sliced into a buffer of its own, wrapped
	// in a ByteArray and copied again.
	@:noCompletion private function __appendView(view:js.lib.Uint8Array):Void {
		var count:Int = view.length;
		if (count > 0) {
			var at:Int = length;
			__resize(at + count, at);
			b.set(view, at);
		}
	}
	#end

	// All of `bytes` at the position, as writeBytes writes them, without
	// making the ByteArray writeBytes takes for every string written.
	@:noCompletion private inline function __writeAll(bytes:Bytes):Void {
		var count:Int = bytes.length;
		if (count > 0) {
			__resize(position + count, position);
			blit(position, bytes, 0, count);
			position += count;
		}
	}

	/**
		Makes room for `capacity` bytes without making any more of them
		readable, for a writer that knows how much is coming: growing as it
		goes, the buffer ends up to half as much again as what was written.
		What is readable, and where, does not change.
	**/
	@:noCompletion public function __reserve(capacity:Int):Void {
		if (capacity <= __length) {
			return;
		}
		var bytes = Bytes.alloc(capacity);
		var cacheLength = length;

		if (__length > 0) {
			length = __length;
			bytes.blit(0, this, 0, __length);
			length = cacheLength;
		}

		__setData(bytes);
		length = cacheLength;
	}

	/**
		Writes `length` bytes of `bytes` from `offset` at the position, as
		`writeBytes` does, from a plain `Bytes` with no ByteArray made around
		it. The range is the caller's to have checked.
	**/
	@:noCompletion public inline function __writeRange(bytes:Bytes, offset:Int, length:Int):Void {
		if (length > 0) {
			__resize(position + length, position);
			blit(position, bytes, offset, length);
			position += length;
		}
	}

	public function writeDouble(value:Float):Void {
		var int64 = FPHelper.doubleToI64(value);

		if (endian == LITTLE_ENDIAN) {
			writeInt(int64.low);
			writeInt(int64.high);
		} else {
			writeInt(int64.high);
			writeInt(int64.low);
		}
	}

	public function writeFloat(value:Float):Void {
		var int = FPHelper.floatToI32(value);
		writeInt(int);
	}

	public function writeInt(value:Int):Void {
		if (!__room(4)) {
			__resize(position + 4, position);
		}

		setInt32(position, __endian == LITTLE_ENDIAN ? value : __swap32(value));
		position += 4;
	}

	public function writeInt64(value:Int64):Void {
		if (endian == LITTLE_ENDIAN) {
			writeUnsignedInt(value.low);
			writeUnsignedInt(value.high);
		} else {
			writeUnsignedInt(value.high);
			writeUnsignedInt(value.low);
		}
	}

	public function writeMultiByte(value:String, charSet:String):Void {
		writeUTFBytes(value);
	}

	public function writeObject(object:Dynamic):Void {
		switch (objectEncoding) {
			#if format
			case AMF0:
				var value = AMFTools.encode(object);
				var output = new BytesOutput();
				var writer = new AMFWriter(output);
				writer.write(value);
				writeBytes(output.getBytes());

			case AMF3:
				var value = AMF3Tools.encode(object);
				var output = new BytesOutput();
				var writer = new AMF3Writer(output);
				writer.write(value);
				writeBytes(output.getBytes());
			#end

			case HXSF:
				__writeObjectText(Serializer.run(object));

			case JSON:
				__writeObjectText(Json.stringify(object));

			default:
				throw new Exception(__unsupportedEncoding(objectEncoding));
		}
	}

	public function writeShort(value:Int):Void {
		if (!__room(2)) {
			__resize(position + 2, position);
		}

		setUInt16(position, __endian == LITTLE_ENDIAN ? value : (((value >> 8) & 0xFF) | ((value << 8) & 0xFF00)));
		position += 2;
	}

	public function writeUnsignedInt(value:Int):Void {
		writeInt(value);
	}

	public function writeUTF(value:String):Void {
		var bytes = crossbyte._internal.Utf8.bytesOf(value);

		// The length prefix is sixteen bits: past 65535 it would wrap, and
		// the string would go out behind a length that describes some other
		// number of bytes, landing every read after it in the wrong place.
		if (bytes.length > 0xFFFF) {
			throw new RangeError('writeUTF takes at most 65535 bytes, and this string is ${bytes.length}. Use writeUTFBytes with a length of your own.');
		}

		writeShort(bytes.length);
		__writeAll(bytes);
	}

	public function writeUTFBytes(value:String):Void {
		#if cpp
		// Natively a string of a byte a character is ASCII, which is its own
		// UTF-8: copied straight in, with no Bytes made of it first.
		if (!untyped __cpp__("{0}.isUTF16Encoded()", value)) {
			var count:Int = value.length;
			if (count > 0) {
				__resize(position + count, position);
				untyped __cpp__("memcpy((char *){0}->GetBase() + {1}, {2}.raw_ptr(), {3})", getData(), position, value, count);
				position += count;
			}
			return;
		}
		#elseif (jvm || java)
		if (__writeAscii(value)) {
			return;
		}
		#end
		// Through the platform's encoder on JavaScript; see Utf8.
		__writeAll(crossbyte._internal.Utf8.bytesOf(value));
	}

	#if (jvm || java)
	/**
		A short text that is all ASCII, written a character at a time: on the
		jvm the platform's encoder makes an array and a Bytes for it, and a
		loop beats it up to a few hundred characters. False, having written
		nothing, for anything else.
	**/
	@:noCompletion private function __writeAscii(value:String):Bool {
		var count:Int = value.length;
		if (count > ASCII_DIRECT_LIMIT) {
			return false;
		}
		for (i in 0...count) {
			if (StringTools.fastCodeAt(value, i) >= 0x80) {
				return false;
			}
		}
		if (count > 0) {
			__resize(position + count, position);
			var at:Int = position;
			for (i in 0...count) {
				set(at + i, StringTools.fastCodeAt(value, i));
			}
			position += count;
		}
		return true;
	}

	private static inline var ASCII_DIRECT_LIMIT:Int = 256;
	#end

	@:keep public inline function writeVarUInt(value:Int):Void {
		// Tested and shifted as the unsigned value it is: a signed `v > 0x7F`
		// is false for anything with bit 31 set, which would go out as one
		// byte (0x80000000 reading back as 0, 0xFFFFFFFF as a varint that
		// never ends).
		var v:Int = value;
		while ((v & ~0x7F) != 0) {
			writeByte((v & 0x7F) | 0x80);
			v >>>= 7;
		}
		writeByte(v);
	}

	@:noCompletion private function explicitResize(size:Int):Void {
		#if debug
		if (size < 0)
			throw "`__explicitResize`: size < 0";
		#end

		if (size > __length) {
			var bytes = Bytes.alloc(size);
			var cacheLength = length;

			if (__length > 0) {
				length = __length;
				bytes.blit(0, this, 0, __length);
				length = cacheLength;
			}

			__setData(bytes);
			length = cacheLength;
		}

		if (length < size) {
			length = size;
		}
	}

	@:noCompletion private function __fromBytes(bytes:Bytes):Void {
		__setData(bytes);

		length = bytes.length;
	}

	/**
		Makes at least `size` bytes readable, zeroing anything newly exposed.

		That zeroing is not optional in general. A caller may seek past the
		end and write there, or simply assign `length`, and the bytes in
		between must read as zero rather than as whatever the allocator last
		left in that memory: otherwise reading a grown ByteArray discloses
		unrelated heap contents.

		@param overwriteFrom Where the caller is about to start writing. Bytes
		from the old end up to there are zeroed; bytes from there on are the
		caller's to fill and are left alone, which spares an append (the
		common case, and the whole of the bulk write path) a pass over
		everything it is about to overwrite anyway. Omitted, the whole grown
		region is zeroed, which is always safe.

		The zeroing runs against the old *logical* length and outside the
		growth branch, both deliberately: inside that branch, from the old
		capacity, a gap opened without a reallocation would not be zeroed at
		all, and the blit would carry every stale byte beneath the old
		capacity into the new buffer. Either way old contents would be
		readable through a hole the caller skipped over, which a buffer
		being reused for something else must never allow.
	**/
	@:noCompletion private function __resize(size:Int, overwriteFrom:Int = -1):Void {
		// The logical end before anything moves: everything above this is
		// either capacity nobody has been shown or bytes already given back.
		var exposedFrom:Int = length;

		if (size > __length) {
			var capacity = ((size + 1) * 3) >> 1;
			// Guard against integer overflow: if the geometric growth wraps
			// around (producing a value <= size, possibly negative), fall back
			// to exactly the requested size.
			if (capacity <= size) {
				capacity = size;
			}
			var bytes = Bytes.alloc(capacity);
			var cacheLength = length;

			if (__length > 0) {
				length = __length;
				bytes.blit(0, this, 0, __length);
				length = cacheLength;
			}

			__setData(bytes);
			length = cacheLength;
		}

		if (length < size) {
			length = size;
		}

		// Everything between the old end and where the caller takes over. An
		// append leaves nothing here, so it costs a comparison and no more.
		var exposedTo:Int = (overwriteFrom < 0 || overwriteFrom > size) ? size : overwriteFrom;

		if (exposedTo > exposedFrom) {
			fill(exposedFrom, exposedTo - exposedFrom, 0);
		}
	}

	@:noCompletion private inline function __setData(bytes:Bytes):Void {
		#if eval
		if (length < bytes.length) {
			length = bytes.length;
		}
		for (i in 0...bytes.length) {
			set(i, bytes.get(i));
		}
		__length = bytes.length;
		#elseif js
		// On js the storage lives in `b` as a Uint8Array, and getData() hands
		// back the ArrayBuffer underneath it. Adopting the buffer left `b`
		// without any of the typed-array methods that every read and write goes
		// through, so the first blit died on `b.set is not a function`.
		untyped this.b = bytes.b;
		__length = bytes.length;
		#else
		untyped this.b = bytes.getData();
		__length = bytes.length;
		#end

		#if js
		data = bytes.data;
		#end
	}

	// Get & Set Methods
	@:noCompletion private inline function get_bytesAvailable():Int {
		return length - position;
	}

	@:noCompletion private inline static function get_defaultEndian():Endian {
		if (__defaultEndian == null) {
			__defaultEndian = LITTLE_ENDIAN;
		}

		return __defaultEndian;
	}

	@:noCompletion private inline static function set_defaultEndian(value:Endian):Endian {
		return __defaultEndian = value;
	}

	@:noCompletion private inline function get_endian():Endian {
		return __endian;
	}

	/**
		How many bytes are readable, honouring lime's length getter where that
		is what backs the buffer.

		One place rather than repeated at every bounds check, which is what the
		multi-byte readers do instead of leaning on `readUnsignedByte` to
		check once per byte.
	**/
	@:noCompletion private inline function __available():Int {
		return #if lime_bytes_length_getter l #else length #end;
	}

	/**
		Reverses a 32-bit value's bytes.

		`getInt32` and `setInt32` are little-endian by definition on every
		target, so a big-endian stream (which is most network traffic, and all
		of STUN and SCTP) is one word access and this, rather than four
		bounds-checked byte accesses and a shift for each.
	**/
	/**
		Makes room for `count` bytes at the cursor, cheaply where it can.

		`__resize` handles growth, gap zeroing and the length bookkeeping, and
		none of that is needed for a write landing inside a buffer that already
		has the capacity and starts at or before the current end, which is
		every append an encoder makes, and encoding is what this class spends
		its life doing. A call out to it per field would be most of the
		difference between reading a word and writing one.

		Two conditions, both necessary. The capacity has to cover the write, or
		the buffer must grow. And the cursor must not be past the logical end,
		or there is a gap between them that has to be zeroed before the caller's
		bytes land.

		@return Whether the fast path applied; the caller falls back when not.
	**/
	@:noCompletion private inline function __room(count:Int):Bool {
		var at = position;
		var end = at + count;

		if (end > __length || at > length) {
			return false;
		}

		if (length < end) {
			length = end;
		}

		return true;
	}

	@:noCompletion private inline function __swap32(value:Int):Int {
		return ((value >>> 24) & 0xFF) | ((value >>> 8) & 0xFF00) | ((value << 8) & 0xFF0000) | (value << 24);
	}

	@:noCompletion private inline function set_endian(value:Endian):Endian {
		return __endian = value;
	}
}
