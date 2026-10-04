package crossbyte.io;

import crossbyte.net.ObjectEncoding;

/**
	The IDataInput interface provides a set of methods for reading binary data. This
	interface is the I/O counterpart to the IDataOutput interface, which writes binary data.
	`ByteArray`, `FileStream`, `Socket` (and so `WebSocket`) and `ReliableDatagramSocket`
	implement it.

	Multi-byte values are read in the implementing object's `endian`. A `ByteArray` and
	the sockets start in `ByteArray.defaultEndian`, which is little-endian on every target
	unless you change it, not big-endian, as in AIR. Set `endian` to `Endian.BIG_ENDIAN`
	for network byte order.

	Reads never wait for data. If insufficient data is available, an `EOFError` exception
	is thrown. Use the `IDataInput.bytesAvailable` property to determine how much data is
	available to read.
	Sign extension matters only when you read data, not when you write it. Therefore you
	do not need separate write methods to work with `IDataInput.readUnsignedByte()` and
	`IDataInput.readUnsignedShort()`. In other words:
	* Use `IDataOutput.writeByte()` with `IDataInput.readUnsignedByte()` and
	`IDataInput.readByte()`.
	* Use `IDataOutput.writeShort()` with `IDataInput.readUnsignedShort()` and
	`IDataInput.readShort()`.
**/
interface IDataInput {
	/**
		Returns the number of bytes of data available for reading in the input buffer.
		User code must call `bytesAvailable` to ensure that sufficient data is available
		before trying to read it with one of the read methods.
	**/
	public var bytesAvailable(get, never):UInt;

	/**
		The byte order for the data, either the `BIG_ENDIAN` or `LITTLE_ENDIAN` constant
		from the Endian class.
	**/
	public var endian(get, set):Endian;

	/**
		Which format `readObject()` reads, a constant from the ObjectEncoding class. It is
		`HXSF` unless changed, not AMF, as in AIR; a `ByteArray` starts in
		`ByteArray.defaultObjectEncoding`. `JSON` is always available. `AMF0` and `AMF3`
		need the optional `format` haxelib (`-lib format`), and asking for one without it
		throws.
	**/
	public var objectEncoding:ObjectEncoding;

	/**
		Reads a Boolean value from the file stream, byte stream, or byte array. A single
		byte is read and `true` is returned if the byte is nonzero, `false` otherwise.
		@returns	A Boolean value, `true` if the byte is nonzero, `false` otherwise.
		@throws	EOFError	There is not sufficient data available to read.
	**/
	public function readBoolean():Bool;

	/**
		Reads a signed byte from the file stream, byte stream, or byte array.
		@returns	The returned value is in the range -128 to 127.
		@throws	EOFError	There is not sufficient data available to read.
	**/
	public function readByte():Int;

	/**
		Reads the number of data bytes, specified by the `length` parameter, from the file
		stream, byte stream, or byte array. The bytes are read into the ByteArray object
		specified by the `bytes` parameter, starting at the position specified by `offset`.
		@param	bytes	The ByteArray object to read data into.
		@param	offset	The offset into the `bytes` parameter at which data read should
		begin.
		@param	length	The number of bytes to read. The default value of 0 causes all
		available data to be read.
		@throws	EOFError	There is not sufficient data available to read.
	**/
	public function readBytes(bytes:ByteArray, offset:UInt = 0, length:Int = 0):Void;

	/**
		Reads an IEEE 754 double-precision floating point number from the file stream, byte
		stream, or byte array.
		@returns	An IEEE 754 double-precision floating point number.
		@throws	EOFError	There is not sufficient data available to read.
	**/
	public function readDouble():Float;

	/**
		Reads an IEEE 754 single-precision floating point number from the file stream, byte
		stream, or byte array.
		@returns	An IEEE 754 single-precision floating point number.
		@throws	EOFError	There is not sufficient data available to read.
	**/
	public function readFloat():Float;

	/**
		Reads a signed 32-bit integer from the file stream, byte stream, or byte array.
		@returns	The returned value is in the range -2147483648 to 2147483647.
		@throws	EOFError	There is not sufficient data available to read.
	**/
	public function readInt():Int;

	/**
		Reads `length` bytes and decodes them as UTF-8.

		@param	length	The number of bytes from the byte stream to read.
		@param	charSet	Accepted for source compatibility and **ignored**. No
		character set conversion happens: the bytes are decoded as UTF-8, exactly
		as `readUTFBytes` would. Passing "shift-jis" does not decode Shift-JIS.
		Transcode the bytes yourself if you need another encoding.
		@returns	UTF-8 encoded string.
		@throws	EOFError	There is not sufficient data available to read.
	**/
	public function readMultiByte(length:UInt, charSet:String):String;

	/**
		Reads an object from the file stream, byte stream, or byte array, in the format
		`objectEncoding` names: `HXSF` unless changed, not AMF.
		@returns	The deserialized object
		@throws	EOFError	There is not sufficient data available to read.
		@throws	IOError	The object is refused unread: it nests too deep, or holds more
		values than `ByteArray.maxObjectValues` allows. See `ByteArray.readObject`.
	**/
	public function readObject():Dynamic;

	/**
		Reads a signed 16-bit integer from the file stream, byte stream, or byte array.
		@returns	The returned value is in the range -32768 to 32767.
		@throws	EOFError	There is not sufficient data available to read.
	**/
	public function readShort():Int;

	/**
		Reads an unsigned byte from the file stream, byte stream, or byte array.
		@returns	The returned value is in the range 0 to 255.
		@throws	EOFError	There is not sufficient data available to read.
	**/
	public function readUnsignedByte():Int;

	/**
		Reads an unsigned 32-bit integer from the file stream, byte stream, or byte array.
		@returns	The 32 bits as an `Int`, which is as wide as a Haxe integer goes, so a
		value from 2^31 up is negative here. Assign it to a `UInt` to compare it as the 0
		to 4294967295 it stands for. (`ByteArray.readUnsignedInt` returns a `UInt`.)
		@throws	EOFError	There is not sufficient data available to read.
	**/
	public function readUnsignedInt():Int;

	/**
		Reads an unsigned 16-bit integer from the file stream, byte stream, or byte array.
		@returns	The returned value is in the range 0 to 65535.
		@throws	EOFError	There is not sufficient data available to read.
	**/
	public function readUnsignedShort():Int;

	/**
		Reads a UTF-8 string from the file stream, byte stream, or byte array. The string
		is assumed to be prefixed with an unsigned short indicating the length in bytes.
		This method is similar to the `readUTF()` method in the Java® IDataInput interface.
		@returns	A UTF-8 string produced by the byte representation of characters.
		@throws	EOFError	There is not sufficient data available to read.
	**/
	public function readUTF():String;

	/**
		Reads a sequence of UTF-8 bytes from the byte stream or byte array and returns a
		string.
		@param	length	The number of bytes to read.
		@returns	A UTF-8 string produced by the byte representation of characters of
		the specified length.
		@throws	EOFError	There is not sufficient data available to read.
	**/
	public function readUTFBytes(length:Int):String;
}
