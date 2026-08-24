package crossbyte.net.rtc._internal.sctp;

import crossbyte.io.ByteArray;

/**
	CRC-32C, the checksum SCTP uses.

	Not the CRC-32 in `haxe.crypto`. That one is the Ethernet and zlib
	polynomial; this is Castagnoli's, and the two disagree on every input --
	so a packet checksummed with the wrong one is a packet every SCTP
	implementation in the world discards.

	Table driven, built once. The straightforward bit-at-a-time loop is eight
	times the work for a value computed over every packet in both directions.
**/
class Crc32c {
	/**
		The reflected form of Castagnoli's polynomial, 0x1EDC6F41.

		Reflected because the table walks the low bit first, which is what makes
		the shift a right shift and the table index the low byte.
	**/
	private static inline var POLYNOMIAL:Int = 0x82F63B78;

	private static var __table:Array<Int> = __buildTable();

	/**
		The checksum of `length` bytes from `offset`.

		@param seed Carried in when a checksum spans more than one call. Left
		alone otherwise.
	**/
	public static function of(bytes:ByteArray, offset:Int = 0, length:Int = -1, seed:Int = 0xFFFFFFFF):Int {
		if (bytes == null) {
			return seed ^ 0xFFFFFFFF;
		}

		var end:Int = length < 0 ? bytes.length : offset + length;

		if (end > bytes.length) {
			end = bytes.length;
		}

		var crc:Int = seed;
		var position:Int = bytes.position;
		bytes.position = offset;

		for (_ in offset...end) {
			crc = __table[(crc ^ bytes.readUnsignedByte()) & 0xFF] ^ (crc >>> 8);
		}

		bytes.position = position;
		return crc ^ 0xFFFFFFFF;
	}

	/** The same over a string's UTF-8 bytes, which is what the test vectors are. **/
	public static function ofString(text:String):Int {
		var bytes = new ByteArray();
		bytes.writeUTFBytes(text);
		bytes.position = 0;
		return of(bytes);
	}

	private static function __buildTable():Array<Int> {
		var table:Array<Int> = [];

		for (i in 0...256) {
			var value:Int = i;

			for (_ in 0...8) {
				value = (value & 1) != 0 ? (value >>> 1) ^ POLYNOMIAL : value >>> 1;
			}

			table.push(value);
		}

		return table;
	}
}
