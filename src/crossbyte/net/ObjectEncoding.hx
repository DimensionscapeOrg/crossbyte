package crossbyte.net;

/** Wire-level object encoding identifiers used by higher-level transport code. */
enum abstract ObjectEncoding(Int) from Int to Int from UInt to UInt {
	/** AMF0 object encoding. */
	public var AMF0 = 0;

	/** AMF3 object encoding. */
	public var AMF3 = 3;

	/**
		CrossByte's HXSF object encoding: Haxe's serialization format. Read
		bounded, as every encoding is: 256 levels deep at most, and
		`ByteArray.maxObjectValues` values.
	**/
	public var HXSF = 10;

	/** JSON object encoding. */
	public var JSON = 12;

	/** Default encoding used by CrossByte APIs. */
	public var DEFAULT = 10;
}
