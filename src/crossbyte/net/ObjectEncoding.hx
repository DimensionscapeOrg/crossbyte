package crossbyte.net;

enum abstract ObjectEncoding(Int) from Int to Int from UInt to UInt {
	public var AMF0 = 0;

	public var AMF3 = 3;

	public var HXSF = 10;

	public var JSON = 12;

	public var DEFAULT = 10;
}
