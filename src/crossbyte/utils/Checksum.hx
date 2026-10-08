package crossbyte.utils;

import crossbyte.errors.ArgumentError;
import crossbyte.errors.RangeError;
import haxe.crypto.Adler32;
import haxe.crypto.Crc32;
import haxe.crypto.Md5;
import haxe.crypto.Sha1;
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
				var crc = new Crc32();
				crc.update(bytes, offset, length);
				__int32(crc.get());
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
