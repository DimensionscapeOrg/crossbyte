package crossbyte._internal.deflatex;

import haxe.io.Bytes;

/**
 * Implements a 32-bit cyclic redundancy checker.
 */
class CRC32 {
	private static final CRC_TABLE:Array<Int> = createTable();

	/**
	 * Create a new checksum.
	 */
	private static function createTable():Array<Int> {
		var table:Array<Int> = new Array<Int>();
		for (n in 0...256) {
			var c:Int = n;
			for (k in 0...8) {
				if ((c & 1) == 1) {
					c = (c >>> 1) ^ 0xedb88320;
				} else {
					c >>>= 1;
				}
			}
			table[n] = c;
		}
		return table;
	}

	private var crc:Int = 0xffffffff;

	public function new() {}

	/**
	 * Return the current value of the checksum.
	 * @return The current CRC value
	 */
	public var value(get, never):Int;

	function get_value():Int {
		return ~crc;
	}

	/**
	 * Update the current checksum with the given byte.
	 * @param byte The byte
	 */
	public function updateByte(byte:Int) {
		byte = byte & 0xff;
		crc = (crc >>> 8) ^ CRC_TABLE[(crc ^ byte) & 0xff];
	}

	/**
	 * Update the current checksum with the given bytes.
	 * @param bytes The byte array
	 */
	public function updateAllBytes(bytes:Bytes) {
		updateBytes(bytes, 0, bytes.length);
	}

	/**
	 * Update the current checksum with the given bytes.
	 * @param bytes The byte array
	 * @param off The starting offset
	 * @param len The number of bytes
	 */
	public function updateBytes(bytes:Bytes, off:Int, len:Int) {
		for (i in off...off + len) {
			var byte:Int = bytes.get(i);
			crc = (crc >>> 8) ^ CRC_TABLE[(crc ^ byte) & 0xff];
		}
	}
}
