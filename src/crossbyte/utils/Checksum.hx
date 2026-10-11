package crossbyte.utils;

import crossbyte.errors.ArgumentError;
import crossbyte.errors.RangeError;
import haxe.crypto.Adler32;
import haxe.crypto.Md5;
import haxe.crypto.Sha1;
import haxe.ds.Vector;
import haxe.io.Bytes;

/**
	Computes a checksum of some bytes with a `ChecksumAlgorithm`: to check
	that what arrived, or what was read back, is what was sent or written.

	```haxe
	var sent:String = Checksum.hex(SHA1, payload);

	// At the other end, beside the payload:
	if (Checksum.hex(SHA1, received) != sent) {
		throw "the payload was damaged on the way";
	}
	```

	None of these stands up to someone changing the data on purpose: a CRC,
	an Adler-32 or an XOR can be made to come out as anything, and MD5 and
	SHA-1 collisions can be manufactured. Against that, sign the data, or
	use an authenticated cipher, from `crossbyte.crypto`.

	On HashLink, `MD5` and `SHA1` come from `fmt.hdll`; see the README.
**/
final class Checksum {
	/**
		The checksum of `bytes`, from `offset` for `length` bytes, as the bytes
		of its value, most significant first (the order it prints in): four
		for `CRC32` and `ADLER32`, one for `XOR`, sixteen for `MD5` and twenty
		for `SHA1`.

		Most significant first is how zlib stores its Adler-32 and PNG its
		CRC-32; gzip and zip store their CRC-32 the other way round.

		@param offset Where in `bytes` to start.
		@param length How many bytes to sum; a negative number, the default,
			   sums the rest of `bytes` from `offset`.
		@throws ArgumentError If `bytes` is null.
		@throws RangeError If the range falls outside `bytes`.
	**/
	public static function compute(algorithm:ChecksumAlgorithm, bytes:Bytes, offset:Int = 0, length:Int = -1):Bytes {
		if (bytes == null) {
			throw new ArgumentError("Checksum.compute needs bytes to sum, and was given null.");
		}
		if (length < 0) {
			length = bytes.length - offset;
		}
		// Each against what is left, not by adding them, so no sum can wrap
		// into a range that passes.
		if (offset < 0 || offset > bytes.length || length < 0 || length > bytes.length - offset) {
			throw new RangeError('Checksum.compute was asked for $length bytes from $offset of ${bytes.length}.');
		}

		return switch (algorithm) {
			case CRC32:
				__int32(__crc32(bytes, offset, length));
			case ADLER32:
				var adler = new Adler32();
				adler.update(bytes, offset, length);
				__int32(adler.get());
			case MD5:
				Md5.make(__range(bytes, offset, length));
			case SHA1:
				Sha1.make(__range(bytes, offset, length));
			case XOR:
				var sum:Int = 0;
				for (i in offset...offset + length) {
					sum ^= bytes.get(i);
				}
				var out = Bytes.alloc(1);
				out.set(0, sum);
				out;
		}
	}

	/**
		The checksum as lowercase hexadecimal, as `crc32`, `md5sum` and
		`sha1sum` print it: `compute`'s bytes, written out.

		@throws ArgumentError If `bytes` is null.
		@throws RangeError If the range falls outside `bytes`.
	**/
	public static function hex(algorithm:ChecksumAlgorithm, bytes:Bytes, offset:Int = 0, length:Int = -1):String {
		return compute(algorithm, bytes, offset, length).toHex();
	}

	/**
		Eight 256-entry tables for CRC-32, flat: table `k` starts at `k * 256`
		and answers for a byte with `k` more to follow before the word is
		done. Built on first use; two threads that both build it build the
		same.
	**/
	private static var __crcTables:Vector<Int> = null;

	/**
		CRC-32 as zlib and PNG have it, eight bytes a step: Intel's slicing,
		as `Crc32c` does for SCTP's polynomial. `haxe.crypto.Crc32` works out
		each of a byte's eight bits in turn, a branchless step per bit, and
		over a megabyte this is several times faster on every target.

		Bytes are read with `Bytes.getInt32`, little-endian on every target,
		which is what the reflected form of the algorithm wants.
	**/
	private static function __crc32(bytes:Bytes, offset:Int, length:Int):Int {
		var tables:Vector<Int> = __crcTables;
		if (tables == null) {
			tables = __crcTables = __buildCrcTables();
		}
		var crc:Int = 0xFFFFFFFF;
		var i:Int = offset;
		var end:Int = offset + length;
		while (i + 8 <= end) {
			var low:Int = crc ^ bytes.getInt32(i);
			var high:Int = bytes.getInt32(i + 4);
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
			crc = tables[(crc ^ bytes.get(i)) & 0xFF] ^ (crc >>> 8);
			i++;
		}
		return crc ^ 0xFFFFFFFF;
	}

	private static function __buildCrcTables():Vector<Int> {
		var tables = new Vector<Int>(2048);
		for (i in 0...256) {
			var value:Int = i;
			for (_ in 0...8) {
				value = (value & 1) != 0 ? (value >>> 1) ^ 0xEDB88320 : value >>> 1;
			}
			tables[i] = value;
		}
		// Each further table is the one before advanced by a byte of zeros.
		for (k in 1...8) {
			for (i in 0...256) {
				var previous:Int = tables[(k - 1) * 256 + i];
				tables[k * 256 + i] = (previous >>> 8) ^ tables[previous & 0xFF];
			}
		}
		return tables;
	}

	// MD5 and SHA-1 hash whole Bytes; a range is copied out for them, and
	// the whole of `bytes` is not.
	private static inline function __range(bytes:Bytes, offset:Int, length:Int):Bytes {
		return offset == 0 && length == bytes.length ? bytes : bytes.sub(offset, length);
	}

	private static function __int32(value:Int):Bytes {
		var out = Bytes.alloc(4);
		out.set(0, (value >>> 24) & 0xFF);
		out.set(1, (value >>> 16) & 0xFF);
		out.set(2, (value >>> 8) & 0xFF);
		out.set(3, value & 0xFF);
		return out;
	}
}
