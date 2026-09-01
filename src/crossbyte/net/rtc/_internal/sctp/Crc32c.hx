package crossbyte.net.rtc._internal.sctp;

import crossbyte.io.ByteArray;
import haxe.ds.Vector;
import haxe.io.Bytes;

/**
	CRC-32C, the checksum SCTP uses.

	Not the CRC-32 in `haxe.crypto`. That one is the Ethernet and zlib
	polynomial; this is Castagnoli's, and the two disagree on every input --
	so a packet checksummed with the wrong one is a packet every SCTP
	implementation in the world discards.

	## Slicing-by-eight

	The textbook table walk takes one byte per step: a table lookup, a shift
	and an XOR, each depending on the last. Intel's slicing construction takes
	eight, by splitting the state across eight tables whose entries answer
	"what does this byte contribute once seven more have gone by" -- the
	lookups become independent of each other, which is what lets the processor
	overlap them, and the message is read a word at a time instead of a byte.

	The performance suite is what put this here. The single-table version,
	pulling each byte through the stream API, ran at a shade over 600 MB/s and
	was nearly the entire cost of an SCTP packet in either direction -- the
	framing around it was close to free. Same vectors before and after: the
	catalogue check value and RFC 3720's, in `SctpPacketTest`.

	Bytes are read with `Bytes.getInt32`, which is little-endian by definition
	on every target -- and little-endian is what the reflected form of the
	algorithm wants, so the packing and the arithmetic agree by construction
	rather than by luck.
**/
class Crc32c {
	/**
		The reflected form of Castagnoli's polynomial, 0x1EDC6F41.

		Reflected because the table walks the low bit first, which is what makes
		the shift a right shift and the table index the low byte.
	**/
	private static inline var POLYNOMIAL:Int = 0x82F63B78;

	/**
		Eight 256-entry tables, flat: table `k` starts at `k * 256`.

		Table 0 is the ordinary one-byte table; table `k` answers for a byte
		that will be followed by `k` more before the word is done.
	**/
	private static var __tables:Vector<Int> = __buildTables();

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

		// The ByteArray's own storage -- the conversion is a view, not a copy
		// -- read by direct index rather than through the stream API, whose
		// position bookkeeping was a real cost at one call per byte.
		var data:Bytes = bytes;
		var tables = __tables;
		var crc:Int = seed;
		var i:Int = offset;

		while (i + 8 <= end) {
			var low:Int = crc ^ data.getInt32(i);
			var high:Int = data.getInt32(i + 4);

			crc = tables[1792 + (low & 0xFF)]
				^ tables[1536 + ((low >>> 8) & 0xFF)]
				^ tables[1280 + ((low >>> 16) & 0xFF)]
				^ tables[1024 + (low >>> 24)]
				^ tables[768 + (high & 0xFF)]
				^ tables[512 + ((high >>> 8) & 0xFF)]
				^ tables[256 + ((high >>> 16) & 0xFF)]
				^ tables[high >>> 24];

			i += 8;
		}

		while (i < end) {
			crc = tables[(crc ^ data.get(i)) & 0xFF] ^ (crc >>> 8);
			i++;
		}

		return crc ^ 0xFFFFFFFF;
	}

	/** The same over a string's UTF-8 bytes, which is what the test vectors are. **/
	public static function ofString(text:String):Int {
		var bytes = new ByteArray();
		bytes.writeUTFBytes(text);
		bytes.position = 0;
		return of(bytes);
	}

	private static function __buildTables():Vector<Int> {
		var tables = new Vector<Int>(2048);

		for (i in 0...256) {
			var value:Int = i;

			for (_ in 0...8) {
				value = (value & 1) != 0 ? (value >>> 1) ^ POLYNOMIAL : value >>> 1;
			}

			tables[i] = value;
		}

		// Each further table is the previous one advanced by a byte of zeros:
		// what that entry's contribution becomes after one more byte passes.
		for (k in 1...8) {
			for (i in 0...256) {
				var previous:Int = tables[(k - 1) * 256 + i];
				tables[k * 256 + i] = (previous >>> 8) ^ tables[previous & 0xFF];
			}
		}

		return tables;
	}
}
