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

		It may be past the end: a read there is an EOFError, and a write
		there zero-fills the gap. It may not be 2^31 or more, past the largest
		ByteArray, which is a RangeError.
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

	// Outside the bytes, 0: past `length` the buffer may still hold what
	// was there before the ByteArray was shortened, and past the buffer
	// each target did something of its own.
	@:arrayAccess @:noCompletion private inline function get(index:Int):Int {
		return index >= 0 && index < this.length ? this.__rawGetU8(index) : 0;
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
		this.__readBytes(bytes, offset, length);
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
		// Inside the bytes, the common case, written in place.
		if (index >= 0 && index < this.length) {
			this.__rawSetU8(index, value);
			return value;
		}
		if (index < 0) {
			throw new RangeError('A ByteArray has no index $index.');
		}
		this.__resize(index + 1, -1);
		this.__rawSetU8(index, value);

		return value;
	}

	@:to @:noCompletion private static inline function toBytes(byteArray:ByteArray):Bytes {
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
		this.__writeBytes(bytes, offset, length);
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

	@:noCompletion private inline function get_length():UInt {
		return this == null ? 0 : this.length;
	}

	@:noCompletion private function set_length(value:Int):UInt {
		// Clamp negatives to 0 instead of assigning a negative length, which
		// would leave the ByteArray in an invalid state.
		if (value < 0) {
			value = 0;
		}

		this.__resize(value, -1);
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
		// From 2^31 up a UInt is a negative Int, and every read and write
		// went wrong from there, each target its own way. The throw is out of
		// line, keeping what is inlined at every assignment small.
		if ((value : Int) < 0) {
			__refusePosition(value);
		}
		return this.position = value;
	}

	@:noCompletion private static function __refusePosition(value:UInt):Void {
		throw new RangeError('A ByteArray position is below 2^31, and $value is not.');
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
	// `__endian == LITTLE_ENDIAN`, kept by `set_endian`: Endian is a String,
	// and comparing it was a call natively and on the jvm for every
	// multi-byte read and write.
	@:noCompletion private var __little:Bool;
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

			// Zeroed where Bytes.alloc does not promise to: the jvm's arrays
			// are zero by definition, and HashLink's alloc fills them.
			#if (sys && !(jvm || java || hl))
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
			return (__rawGetU8(position++) != 0);
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
		__readBytes(bytes, offset, length);
	}

	// What readBytes does, with no defaults: on the jvm an argument with one
	// is an Integer, boxed at every call from 128 up.
	@:noCompletion private function __readBytes(bytes:ByteArray, offset:Int, length:Int):Void {
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
			(bytes : ByteArrayData).__sizeForCopy(offset + length);
			(bytes : ByteArrayData).__resize(offset + length, offset);
		}

		(bytes : ByteArrayData).blit(offset, this, position, length);
		position += length;
	}

	public function readDouble():Float {
		// All eight bytes checked first: read as two Ints, the first moved the
		// position before the second found the stream cut short.
		var at = position;
		if (at > __available() - 8) {
			throw new EOFError();
		}
		position = at + 8;
		// One native read where there is one: the DataView takes the byte
		// order, and natively and on HashLink a little-endian double is
		// read in place.
		#if js
		initData();
		return __little ? data.getFloat64(at, true) : data.getFloat64(at, false);
		#elseif cpp
		if (__little) {
			return untyped __global__.__hxcpp_memory_get_double(b, at);
		}
		#elseif hl
		if (__little) {
			return b.getF64(at);
		}
		#end
		if (__little) {
			return FPHelper.i64ToDouble(__rawGetI32(at), __rawGetI32(at + 4));
		}
		return FPHelper.i64ToDouble(__swap32(__rawGetI32(at + 4)), __swap32(__rawGetI32(at)));
	}

	public function readFloat():Float {
		#if js
		// As readInt reads it, reinterpreted: anything else measured slower
		// on Node, DataView's getFloat32 included.
		return FPHelper.i32ToFloat(readInt());
		#else
		var at = position;
		if (at > __available() - 4) {
			throw new EOFError();
		}
		position = at + 4;
		#if cpp
		if (__little) {
			return untyped __global__.__hxcpp_memory_get_float(b, at);
		}
		#elseif hl
		if (__little) {
			return b.getF32(at);
		}
		#end
		var value = __rawGetI32(at);
		return FPHelper.i32ToFloat(__little ? value : __swap32(value));
		#end
	}

	public function readInt():Int {
		var at = position;

		// Against what is left, not `at + 4`, which a position near 2^31
		// wraps negative, passing the check.
		if (at > __available() - 4) {
			throw new EOFError();
		}

		position = at + 4;
		#if js
		initData();
		return data.getInt32(at, __little);
		#else
		var value = __rawGetI32(at);
		return __little ? value : __swap32(value);
		#end
	}

	public function readInt64():Int64 {
		// One check and two words, where it was three of each through readInt.
		var at = position;
		if (at > __available() - 8) {
			throw new EOFError();
		}
		position = at + 8;
		if (__little) {
			return Int64.make(__rawGetI32(at + 4), __rawGetI32(at));
		}
		return Int64.make(__swap32(__rawGetI32(at)), __swap32(__rawGetI32(at + 4)));
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
			return __rawGetU8(position++);
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

		if (at > __available() - 2) {
			throw new EOFError();
		}

		position = at + 2;
		#if js
		initData();
		return data.getUint16(at, __little);
		#else
		var value = __rawGetU16(at);
		return __little ? value : __swap16(value);
		#end
	}

	public function readUTF():String {
		// The text checked before anything moves, so a string cut short
		// leaves the position at its length, for a reader to try again.
		var at = position;
		var bytesCount = readUnsignedShort();
		if (bytesCount > __available() - position) {
			position = at;
			throw new EOFError();
		}
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
			var byte:Int = __rawGetU8(at++);
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

		__rawSetU8(position++, value & 0xFF);
	}

	@:keep public function writeBytes(bytes:ByteArray, offset:UInt = 0, length:UInt = 0):Void {
		__writeBytes(bytes, offset, length);
	}

	// What writeBytes does, with no defaults, as __readBytes.
	@:noCompletion private function __writeBytes(bytes:ByteArray, offset:UInt, length:UInt):Void {
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
		__sizeForCopy(position + length);
		__resize(position + length, position);
		blit(position, (bytes : ByteArrayData), offset, length);

		position += length;
	}

	#if ((jvm || java) && !macro)
	// Natively, as on JavaScript below: Haxe's fill sets a byte at a time.
	override public function fill(pos:Int, len:Int, value:Int):Void {
		java.util.Arrays.fill(b, pos, pos + len, cast value);
	}
	#end

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

		// What is readable, and no more: past `length` nothing is live (the
		// bytes there are zeroed as they are exposed), so copying all the
		// old capacity carried dead bytes, up to 16 KB of them after a clear.
		if (cacheLength > 0) {
			bytes.blit(0, this, 0, cacheLength);
		}

		__setData(bytes);
		length = cacheLength;
	}

	#if ((cpp || jvm) && !macro)
	/**
		Takes `storage` for its own in place of what it has, and answers the
		storage it had: the bytes from `from` to `length` are copied to its
		front, and the length and position are what they were less `from`
		(0 keeps them). `storage` must hold at least `length - from` bytes;
		what lies past them is never read before it is written or zeroed, as
		`__resize` exposes it. For storage kept in a pool (see
		`crossbyte._internal.socket.StoragePool`).
	**/
	@:noCompletion public function __adoptStorage(storage:haxe.io.BytesData, from:Int):haxe.io.BytesData {
		var old:haxe.io.BytesData = getData();
		var count:Int = length - from;
		if (count > 0) {
			#if cpp
			untyped storage.blit(0, old, from, count);
			#else
			java.lang.System.arraycopy(old, from, storage, 0, count);
			#end
		}
		untyped this.b = storage;
		__length = storage.length;
		if (from > 0) {
			length = count > 0 ? count : 0;
			position = position > from ? position - from : 0;
		}
		return old;
	}
	#end

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
		// One native write where there is one, as readDouble reads.
		#if (js || cpp || hl)
		if (!__room(8)) {
			__resize(position + 8, position);
		}
		var at = position;
		#if js
		initData();
		data.setFloat64(at, value, __little);
		position = at + 8;
		return;
		#elseif cpp
		if (__little) {
			untyped __global__.__hxcpp_memory_set_double(b, at, value);
			position = at + 8;
			return;
		}
		#elseif hl
		if (__little) {
			b.setF64(at, value);
			position = at + 8;
			return;
		}
		#end
		#end
		var int64 = FPHelper.doubleToI64(value);
		__writeInt32Pair(int64.low, int64.high);
	}

	/**
		Two Ints as one 64-bit value, low word first in little-endian and high
		first in big: room made for all eight bytes at once, so a write that
		cannot fit leaves nothing half written.
	**/
	@:noCompletion private inline function __writeInt32Pair(low:Int, high:Int):Void {
		if (!__room(8)) {
			__resize(position + 8, position);
		}
		if (__little) {
			__rawSetI32(position, low);
			__rawSetI32(position + 4, high);
		} else {
			__rawSetI32(position, __swap32(high));
			__rawSetI32(position + 4, __swap32(low));
		}
		position += 8;
	}

	public function writeFloat(value:Float):Void {
		#if (js || cpp || hl)
		if (!__room(4)) {
			__resize(position + 4, position);
		}
		var at = position;
		#if js
		initData();
		data.setFloat32(at, value, __little);
		position = at + 4;
		return;
		#elseif cpp
		if (__little) {
			untyped __global__.__hxcpp_memory_set_float(b, at, value);
			position = at + 4;
			return;
		}
		#elseif hl
		if (__little) {
			b.setF32(at, value);
			position = at + 4;
			return;
		}
		#end
		#end
		writeInt(FPHelper.floatToI32(value));
	}

	public function writeInt(value:Int):Void {
		if (!__room(4)) {
			__resize(position + 4, position);
		}

		#if js
		initData();
		data.setInt32(position, value, __little);
		#else
		__rawSetI32(position, __little ? value : __swap32(value));
		#end
		position += 4;
	}

	public function writeInt64(value:Int64):Void {
		__writeInt32Pair(value.low, value.high);
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

		#if js
		initData();
		data.setUint16(position, value & 0xFFFF, __little);
		#else
		__rawSetU16(position, __little ? value & 0xFFFF : __swap16(value));
		#end
		position += 2;
	}

	public function writeUnsignedInt(value:Int):Void {
		writeInt(value);
	}

	public function writeUTF(value:String):Void {
		// ASCII is its own UTF-8, a byte a character: the length is known and
		// the text written as writeUTFBytes writes it, with no Bytes made of
		// it to count. Each way refuses a string that would end past the
		// largest ByteArray before its length goes in (see __refusePast).
		#if cpp
		// Parenthesized: `untyped` takes everything after it, and unbracketed
		// the length test went inside the negation, so a narrow string past
		// 65535 bytes was written behind a wrapped length instead of refused.
		if (!(untyped __cpp__("{0}.isUTF16Encoded()", value)) && value.length <= 0xFFFF) {
			__refusePast(2 + value.length);
			writeShort(value.length);
			writeUTFBytes(value);
			return;
		}
		if (untyped __cpp__("{0}.isUTF16Encoded()", value)) {
			// Sized, refused or prefixed, then encoded in place: see Utf8.encodeNative.
			var size:Int = crossbyte._internal.Utf8.sizeOf(value);
			if (size > 0xFFFF) {
				throw new RangeError('writeUTF takes at most 65535 bytes, and this string is ${size}. Use writeUTFBytes with a length of your own.');
			}
			__refusePast(2 + size);
			writeShort(size);
			__writeNative(value, size);
			return;
		}
		#elseif ((jvm || java) && !macro)
		if (__writeAsciiNative(value, true)) {
			return;
		}
		#elseif js
		// Up to 21,845 units, which cannot pass the prefix's 65535 bytes, as
		// writeUTFBytes writes them, the length patched in after.
		if (value.length <= 0xFFFF / crossbyte._internal.Utf8.MAX_BYTES_PER_UNIT) {
			var start:Int = position;
			// Sized only near the end, where the most it could take does not fit.
			if (start > 0x7FFFFFFF - 2 - value.length * crossbyte._internal.Utf8.MAX_BYTES_PER_UNIT) {
				__refusePast(2 + crossbyte._internal.Utf8.sizeOf(value));
			}
			writeShort(0);
			var size:Int = __writeText(value);
			initData();
			data.setUint16(start, size, __little);
			return;
		}
		#elseif hl
		// As on JavaScript: up to 21,845 units, which cannot pass the
		// prefix's 65535 bytes, written as writeUTFBytes writes them, the
		// length put in after. More are sized first, and refused or prefixed.
		var units:hl.Bytes = @:privateAccess value.bytes;
		if (value.length <= 0xFFFF / crossbyte._internal.Utf8.MAX_BYTES_PER_UNIT) {
			var start:Int = position;
			if (start > 0x7FFFFFFF - 2 - value.length * crossbyte._internal.Utf8.MAX_BYTES_PER_UNIT) {
				__refusePast(2 + crossbyte._internal.Utf8.sizeOfUnits(units, value.length, 0));
			}
			writeShort(0);
			var size:Int = __writeTextHl(value);
			__rawSetU16(start, __little ? size : __swap16(size));
			return;
		}
		var size:Int = crossbyte._internal.Utf8.sizeOfUnits(units, value.length, 0);
		if (size > 0xFFFF) {
			throw new RangeError('writeUTF takes at most 65535 bytes, and this string is ${size}. Use writeUTFBytes with a length of your own.');
		}
		__refusePast(2 + size);
		writeShort(size);
		__writeTextHl(value);
		return;
		#end
		var bytes = crossbyte._internal.Utf8.bytesOf(value);

		// The length prefix is sixteen bits: past 65535 it would wrap, and
		// the string would go out behind a length that describes some other
		// number of bytes, landing every read after it in the wrong place.
		if (bytes.length > 0xFFFF) {
			throw new RangeError('writeUTF takes at most 65535 bytes, and this string is ${bytes.length}. Use writeUTFBytes with a length of your own.');
		}

		__refusePast(2 + bytes.length);
		writeShort(bytes.length);
		__writeAll(bytes);
	}

	/**
		Refuses a write of `count` bytes at the position whose end would pass
		2^31 - 1, the largest ByteArray, before anything of it is written or
		room is made for it. For a write of two parts, a length and its text:
		the text's own write refuses its end, but only after the length has
		gone in, and room made for that, toward 2 GB.
	**/
	@:noCompletion private inline function __refusePast(count:Int):Void {
		if (position > 0x7FFFFFFF - count) {
			__tooLarge();
		}
	}

	@:noCompletion private static function __tooLarge():Void {
		throw new RangeError("A ByteArray holds at most 2^31 - 1 bytes.");
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
		__writeNative(value, crossbyte._internal.Utf8.sizeOf(value));
		return;
		#elseif ((jvm || java) && !macro)
		if (__writeAsciiNative(value, false)) {
			return;
		}
		#elseif js
		__writeText(value);
		return;
		#elseif hl
		__writeTextHl(value);
		return;
		#end
		// Through the platform's encoder; see Utf8.
		__writeAll(crossbyte._internal.Utf8.bytesOf(value));
	}

	#if hl
	/**
		`value` in UTF-8 at the position, from the string's own UTF-16 straight
		into the buffer. HashLink's encoder made a buffer and a Bytes of every
		string to copy in, and took the character after an unpaired surrogate
		into it: written here, twelve characters take 15 ns rather than 62,
		and an unpaired surrogate is U+FFFD, as TextEncoder writes it. ASCII,
		which text mostly is, goes in a byte a unit, into room made for that;
		anything after the first unit that is not is sized, and room made for
		it, first. The bytes written.
	**/
	@:noCompletion private function __writeTextHl(value:String):Int {
		var count:Int = value.length;
		if (count == 0) {
			return 0;
		}
		var units:hl.Bytes = @:privateAccess value.bytes;
		var at:Int = position;
		// The end checked before anything is written or grown, sized only near
		// it: the room made for the ASCII would otherwise already be readable
		// when the rest was refused.
		if (at > 0x7FFFFFFF - count * crossbyte._internal.Utf8.MAX_BYTES_PER_UNIT) {
			__refusePast(crossbyte._internal.Utf8.sizeOfUnits(units, count, 0));
		}
		__resize(at + count, at);
		var out:hl.Bytes = b;
		var i:Int = 0;
		while (i < count) {
			var unit:Int = units.getUI16(i << 1);
			if (unit >= 0x80) {
				break;
			}
			out[at + i] = unit;
			i++;
		}
		var end:Int = at + count;
		if (i < count) {
			var from:Int = at + i;
			end = from + crossbyte._internal.Utf8.sizeOfUnits(units, count, i);
			__resize(end, from);
			crossbyte._internal.Utf8.encodeUnits(units, count, i, b, from);
		}
		position = end;
		return end - at;
	}
	#end

	#if ((jvm || java) && !macro)
	/**
		Up to 256 characters of ASCII copied straight into the buffer by
		`String.getBytes(int, int, byte[], int)`, behind a 16-bit length when
		`prefixed` (up to 64 then): the platform's encoder made an array and a
		Bytes of every string, garbage a server pays for at every header it
		writes (an HTTP GET allocated 768 bytes rather than 240). False,
		having written nothing, for anything else.

		Measured against the encoder: twelve characters 12.9 ns rather than
		15.2, and 200 characters 83 rather than 57, the price of finding
		them all ASCII first; behind a length no faster even short, so only
		as far as it is no slower there.
	**/
	@:haxe.warning("-WDeprecated")
	@:noCompletion private function __writeAsciiNative(value:String, prefixed:Bool):Bool {
		var count:Int = value.length;
		if (count > (prefixed ? 64 : 256)) {
			return false;
		}
		for (i in 0...count) {
			if (StringTools.fastCodeAt(value, i) >= 0x80) {
				return false;
			}
		}
		if (prefixed) {
			__refusePast(2 + count);
			writeShort(count);
		}
		if (count > 0) {
			__resize(position + count, position);
			(cast value : java.NativeString).getBytes(0, count, b, position);
			position += count;
		}
		return true;
	}
	#end

	#if cpp
	// `value`, `size` bytes in UTF-8, encoded at the position: no buffer of
	// it made and copied in, nor a pass looking for a lone surrogate.
	@:noCompletion private function __writeNative(value:String, size:Int):Void {
		if (size > 0) {
			__resize(position + size, position);
			crossbyte._internal.Utf8.encodeNative(value, b, position);
			position += size;
		}
	}
	#end

	#if js
	/**
		`value` in UTF-8 at the position, written straight into the buffer
		(see Utf8.writeView), where TextEncoder made a buffer of it to copy
		in: 200 characters on Node in about 130 ns rather than 1,400. Into the
		room there is first, and only past it into more, so a ByteArray made
		to the size of what it will hold does not grow. The bytes written.
	**/
	@:noCompletion private function __writeText(value:String):Int {
		var at:Int = position;
		// The end checked before anything is written or grown, sized only near
		// it: past the largest ByteArray, the room made for the rest (Int does
		// not wrap here) was a buffer of 2 GB or more, which a browser refuses
		// with an allocation error of its own, and the RangeError came after.
		if (at > 0x7FFFFFFF - value.length * crossbyte._internal.Utf8.MAX_BYTES_PER_UNIT) {
			__refusePast(crossbyte._internal.Utf8.sizeOf(value));
		}
		var size:Int = crossbyte._internal.Utf8.writeView(value, b, at, __length);
		var read:Int = crossbyte._internal.Utf8.read;
		if (read < value.length) {
			// What is written so far made readable first: growing copies what
			// is readable, and no more.
			if (size > 0) {
				__resize(at + size, at);
			}
			var rest:String = value.substring(read);
			// The most the rest can take, held to the largest ByteArray, which
			// it fits, as checked above.
			var end:Int = at + size + rest.length * crossbyte._internal.Utf8.MAX_BYTES_PER_UNIT;
			var room:Int = __grown(end);
			__reserve(room > 0x7FFFFFFF ? 0x7FFFFFFF : room);
			size += crossbyte._internal.Utf8.writeView(rest, b, at + size, __length);
		}
		// Readable to its end, and any gap before it zeroed, as a write is;
		// nothing written past the end leaves the length where it was.
		if (size > 0) {
			__resize(at + size, at);
			position = at + size;
		}
		return size;
	}
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
			throw new RangeError("`__explicitResize`: size < 0");
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
		everything it is about to overwrite anyway. -1 zeroes the whole grown
		region, which is always safe. It has no default: on the jvm an
		argument with one is an object, boxed on every write past the 127th
		byte.

		The zeroing runs against the old *logical* length and outside the
		growth branch, both deliberately: inside that branch, from the old
		capacity, a gap opened without a reallocation would not be zeroed at
		all, and the blit would carry every stale byte beneath the old
		capacity into the new buffer. Either way old contents would be
		readable through a hole the caller skipped over, which a buffer
		being reused for something else must never allow.
	**/
	@:noCompletion private function __resize(size:Int, overwriteFrom:Int):Void {
		// A write's end past 2^31 - 1 wraps negative, and nothing would grow:
		// natively the bytes then asked the buffer to grow itself to 2 GB, a
		// byte at a time, and the jvm threw an index error of its own.
		// Past it on JavaScript too, whose Int does not wrap: there the sum
		// stays positive, and Node would grow the buffer to 3 GB.
		if (size < 0 || size > 0x7FFFFFFF) {
			throw new RangeError("A ByteArray holds at most 2^31 - 1 bytes.");
		}

		// The logical end before anything moves: everything above this is
		// either capacity nobody has been shown or bytes already given back.
		var exposedFrom:Int = length;

		if (size > __length) {
			// Half as much again as the buffer had, what was asked for if
			// that is more, and never under MIN_CAPACITY. Grown from what was
			// asked, a ByteArray filled to an exact size was made half as big
			// again, and a 98-byte message written into a new one grew six
			// times. Half again of a buffer past 1.4 GB wraps negative, and
			// is then what was asked for.
			var bytes = Bytes.alloc(__grown(size));
			var cacheLength = length;

			// What is readable, and no more, as __reserve copies.
			if (exposedFrom > 0) {
				bytes.blit(0, this, 0, exposedFrom);
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

	// The capacity to grow to for `size` bytes: half as much again as the
	// buffer had, `size` if that is more, and never under MIN_CAPACITY.
	@:noCompletion private inline function __grown(size:Int):Int {
		var capacity:Int = __length + (__length >> 1);
		if (capacity < size) {
			capacity = size;
		}
		return capacity < MIN_CAPACITY ? MIN_CAPACITY : capacity;
	}

	// The least a ByteArray grows to: a few fields' worth, so a message
	// written into a new one grows once or twice rather than at every field.
	// A copy into a new one is made its exact size instead (__sizeForCopy).
	private static inline var MIN_CAPACITY:Int = 64;

	/**
		Before bytes are copied in up to `end`: a ByteArray with no storage
		yet is made exactly that big. A copy into a new ByteArray (a frame
		read off a socket, a message kept or forwarded) is mostly all it will
		ever hold, where the least a buffer grows to, MIN_CAPACITY, is for a
		message written field by field. Anything appended later grows it as
		usual. Past the largest ByteArray nothing is made here, and `__resize`
		refuses it.
	**/
	@:noCompletion private inline function __sizeForCopy(end:Int):Void {
		if (__length == 0 && end > 0 && end <= 0x7FFFFFFF) {
			__reserve(end);
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
		// None with the position past the end, not a negative count a UInt
		// shows as about four billion.
		var available:Int = length - position;
		return available > 0 ? available : 0;
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
		__little = value == LITTLE_ENDIAN;
		return __endian = value;
	}

	// Bytes, halves, words and floats at a position the caller has already
	// checked lies within `length`, and so within the buffer: hxcpp's
	// Bytes.getInt32 and setInt32 are four bytes, each checked again (and a
	// byte set past the end grows the array), and HashLink's are calls that
	// check again. Little-endian natively and on HashLink, as every machine
	// they run on is; elsewhere Bytes' own.
	@:noCompletion private inline function __rawGetU8(at:Int):Int {
		#if cpp
		return untyped __global__.__hxcpp_memory_get_byte(b, at) & 0xFF;
		#elseif hl
		return b[at];
		#else
		return get(at);
		#end
	}

	@:noCompletion private inline function __rawSetU8(at:Int, value:Int):Void {
		#if cpp
		untyped __global__.__hxcpp_memory_set_byte(b, at, value);
		#elseif hl
		b[at] = value;
		#else
		set(at, value);
		#end
	}

	@:noCompletion private inline function __rawGetI32(at:Int):Int {
		#if cpp
		return untyped __global__.__hxcpp_memory_get_i32(b, at);
		#elseif hl
		return b.getI32(at);
		#else
		return getInt32(at);
		#end
	}

	@:noCompletion private inline function __rawSetI32(at:Int, value:Int):Void {
		#if cpp
		untyped __global__.__hxcpp_memory_set_i32(b, at, value);
		#elseif hl
		b.setI32(at, value);
		#else
		setInt32(at, value);
		#end
	}

	@:noCompletion private inline function __rawGetU16(at:Int):Int {
		#if cpp
		return untyped __global__.__hxcpp_memory_get_ui16(b, at);
		#elseif hl
		return b.getUI16(at);
		#else
		return getUInt16(at);
		#end
	}

	@:noCompletion private inline function __rawSetU16(at:Int, value:Int):Void {
		#if cpp
		untyped __global__.__hxcpp_memory_set_ui16(b, at, value);
		#elseif hl
		b.setUI16(at, value);
		#else
		setUInt16(at, value);
		#end
	}

	@:noCompletion private inline function __swap16(value:Int):Int {
		return ((value >> 8) & 0xFF) | ((value << 8) & 0xFF00);
	}
}
