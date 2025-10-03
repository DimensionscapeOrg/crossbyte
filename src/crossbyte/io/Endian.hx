package crossbyte.io;

/**
 * ...
 * @author Christopher Speciale
 */
enum abstract Endian(String) from String to String {
	public var BIG_ENDIAN = "bigEndian";
	public var LITTLE_ENDIAN = "littleEndian";
}
