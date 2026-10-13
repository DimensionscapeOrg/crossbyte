package crossbyte.io;

import crossbyte.errors.ArgumentError;
import crossbyte.errors.EOFError;
import crossbyte.errors.RangeError;
import haxe.io.Bytes;
import crossbyte.io.ByteArray;

/**
 * A fast, bounds-checked read-only view over an underlying `ByteArrayData`/`ByteArray`
 * buffer.
 *
 * `ByteArrayInput` exposes a forward-only cursor (`position`) and convenience
 * readers for common primitive types, UTF strings, and variable-length integers.
 *
 * ### Key characteristics
 * - **Little-endian, unsigned**: every multi-byte value is read little-endian,
 *   whatever the ByteArray's `endian`, and `readByte` and `readShort` are
 *   unsigned (0–255, 0–65535), where `ByteArray`'s of the same names are
 *   signed. It reads what `ByteArrayOutput` writes.
 * - **Zero-copy reads**: uses direct getters on the backing buffer where possible.
 * - **Explicit cursoring**: all reads advance `position` by the number of bytes consumed.
 * - **Checked in every build**, `final` included: a read past `length` throws an
 *   `EOFError` and moves nothing, and `position` refuses a value outside
 *   `[0, length]`. A payload a peer sent can be shorter than it should be, and
 *   natively a read past the buffer would read whatever memory follows it.
 *   `require` checks a whole record's bytes at once.
 * - **Interop**: can be implicitly created from `ByteArrayData` or `ByteArray`.
 *
 * ### Typical usage
 * ```haxe
 * final input:ByteArrayInput = someByteArray; // implicit from ByteArray
 * final tag  = input.readInt();
 * final name = input.readVarUtf();
 * if (!input.eof()) {
 *   final flags = input.readByte();
 * }
 * ```
 */
@:access(crossbyte.io.ByteArrayData)
abstract ByteArrayInput(ByteArrayData) from ByteArrayData to ByteArrayInput from ByteArray {

	/**
	 * The current read cursor measured in **bytes** from the start of the buffer.
	 *
	 * Setting `position` allows random access reads within `[0, length]`.
	 * Assigning a value outside this range throws a `RangeError`, in every build.
	 *
	 * Each successful read advances `position` by the size of the type read.
	 */
	public var position(get, set):Int;

	/**
	 * Total number of readable bytes in this view.
	 *
	 * This is the logical size of the underlying buffer and does **not** change as you read.
	 * To know how much remains, use `bytesAvailable`.
	 */
	public var length(get, never):Int;

	/**
	 * The number of bytes remaining from the current `position` to `length`.
	 *
	 * Equivalent to `length - position`. When `bytesAvailable == 0`, the next read throws
	 * an `EOFError`.
	 */
	public var bytesAvailable(get, never):Int;

	@:noCompletion private inline function get_length():Int {
		return this.length;
	}

	@:noCompletion private inline function get_position():Int {
		return this.position;
	}

	@:noCompletion private inline function get_bytesAvailable():Int {
		return this.length - this.position;
	}

	@:noCompletion private inline function set_position(v:Int):Int {
		if (v < 0 || v > this.length)
			throw new RangeError("position out of range");
		return this.position = v;
	}

	/**
	 * Throws unless `count` bytes remain to be read, and reads nothing.
	 *
	 * Every read checks its own bytes, so this is for a record of several fields read
	 * together: one check up front says the whole record is there before any of it is
	 * taken, and `position` has not moved when it is not.
	 *
	 * ```haxe
	 * input.require(12);
	 * final id = input.readInt();
	 * final x = input.readFloat();
	 * final y = input.readFloat();
	 * ```
	 *
	 * @param count The number of bytes the next reads need.
	 * @throws EOFError If fewer than `count` bytes remain, or `count` is negative, in
	 *                every build, `final` included. The same error a read past the end
	 *                throws.
	 */
	public inline function require(count:Int):Void {
		// Against the bytes remaining rather than `position + count`: that sum
		// overflows for a large count and wraps negative, so the comparison
		// would succeed and the read go ahead, and readVarUtf can hand this a
		// length the peer chose, up to 2^31-1.
		if (count < 0 || count > this.length - this.position)
			throw new EOFError("ByteArrayInput underflow");
	}

	/**
	 * Returns `true` when there are no more bytes to read (i.e. `position >= length`).
	 *
	 * @return `true` if at or past the end of the buffer, `false` otherwise.
	 */
	public inline function eof():Bool {
		return this.position >= this.length;
	}

	/**
	 * Reads a single unsigned byte (0–255) and advances `position` by 1.
	 *
	 * @return The next byte as an `Int` in the range `[0, 255]`.
	 * @throws EOFError If reading would exceed `length`.
	 */
	public inline function readByte():Int {
		require(1);
		return this.get(this.position++);
	}

	/**
	 * Reads a byte and interprets it as a boolean.
	 *
	 * Convention: `0 == false`, any non-zero value == `true`.
	 *
	 * @return The decoded boolean value.
	 * @throws EOFError If reading would exceed `length`.
	 */
	public inline function readBoolean():Bool {
		return readByte() != 0;
	}

	/**
	 * Reads a 16-bit **unsigned** integer and advances `position` by 2.
	 *
	 * Endianness follows the backing implementation of `getUInt16`.
	 *
	 * @return The decoded 16-bit value as `Int` (0–65535).
	 * @throws EOFError If reading would exceed `length`.
	 */
	public inline function readShort():Int {
		require(2);
		var v:Int = this.getUInt16(this.position);
		this.position += 2;
		return v;
	}

	/**
	 * Reads a 32-bit **signed** integer and advances `position` by 4.
	 *
	 * Endianness follows the backing implementation of `getInt32`.
	 *
	 * @return The decoded 32-bit signed integer.
	 * @throws EOFError If reading would exceed `length`.
	 */
	public inline function readInt():Int {
		require(4);
		var v:Int = this.getInt32(this.position);
		this.position += 4;
		return v;
	}

	/**
	 * Reads a 32-bit IEEE-754 floating point number and advances `position` by 4.
	 *
	 * Endianness follows the backing implementation of `getFloat`.
	 *
	 * @return The decoded `Float`.
	 * @throws EOFError If reading would exceed `length`.
	 */
	public inline function readFloat():Float {
		require(4);
		var v:Float = this.getFloat(this.position);
		this.position += 4;
		return v;
	}

	/**
	 * Reads a 64-bit IEEE-754 floating point number and advances `position` by 8.
	 *
	 * Endianness follows the backing implementation of `getDouble`.
	 *
	 * @return The decoded `Float` (double precision).
	 * @throws EOFError If reading would exceed `length`.
	 */
	public inline function readDouble():Float {
		require(8);
		var v:Float = this.getDouble(this.position);
		this.position += 8;
		return v;
	}

	/**
	 * Copies `len` bytes from the current `position` into `dst` at `dstOffset`, then advances.
	 *
	 * If `len < 0` (default), the method copies as many bytes as fit from `dstOffset`
	 * to the end of `dst` (i.e. `dst.length - dstOffset`).
	 *
	 * @param dst       Destination `Bytes` to write into.
	 * @param dstOffset Start offset in `dst` (default `0`).
	 * @param len       Number of bytes to copy (default `-1` = fill to end of `dst`).
	 * @throws EOFError If the bytes are not there to read, and `RangeError` if the
	 *                range does not fit in `dst`.
	 */
	public inline function readBytes(dst:Bytes, dstOffset:Int = 0, len:Int = -1):Void {
		if (len < 0) {
			len = dst.length - dstOffset;
		}
		// The destination in every build: Bytes.blit checks `pos + len`,
		// which a large offset wraps negative, and natively the copy then
		// went ahead, 2 GB past the buffer.
		if (dstOffset < 0 || len < 0 || dstOffset > dst.length || len > dst.length - dstOffset) {
			throw new RangeError("ByteArrayInput.readBytes: the range does not fit the destination");
		}
		require(len);
		dst.blit(dstOffset, this, this.position, len);
		this.position += len;
	}

	/**
	 * Reads exactly `len` bytes as a UTF-8 (or backing-defined) string and advances.
	 *
	 * **Note:** No length prefix is consumed; this reads a fixed-size slice.
	 *
	 * A NUL is a character like any other, and a malformed sequence reads
	 * as U+FFFD, as `ByteArray.readUtfBytes` reads them, on every target.
	 *
	 * @param len Number of bytes to decode into a string.
	 * @return The decoded string.
	 * @throws EOFError If the read would exceed `length`, in every build: the
	 *                length is usually one a peer sent.
	 */
	public inline function readUtfBytes(len:Int):String {
		if (len < 0 || len > this.length - this.position) {
			throw new EOFError("ByteArrayInput underflow");
		}
		var s:String = crossbyte._internal.Utf8.stringOf(this, this.position, len);
		this.position += len;
		return s;
	}

	/**
	 * Reads a length-prefixed string where the length is a 16-bit unsigned integer,
	 * then consumes that many bytes as UTF data.
	 *
	 * Layout: `[u16 length][length bytes of UTF data]`
	 *
	 * @return The decoded string.
	 * @throws EOFError If the read would exceed `length`, in every build.
	 *                `position` does not move, so the read can be tried again
	 *                once the rest has arrived.
	 */
	public inline function readUtf():String {
		var at:Int = this.position;
		var len:Int = readShort();
		if (len > this.length - this.position) {
			this.position = at;
			throw new EOFError("ByteArrayInput underflow");
		}
		return readUtfBytes(len);
	}

	/**
	 * Reads a ZigZag-encoded variable-length **signed** integer and advances by 1–5 bytes.
	 *
	 * Encoding:
	 * - Raw storage is LEB128-style varint over an unsigned integer.
	 * - Values are then ZigZag mapped so that small negative and small positive numbers
	 *   both encode to small unsigned varints.
	 *
	 * @return The decoded signed `Int`.
	 * @throws RangeError If the varint is too long or overflows, and `EOFError` if
	 *                the buffer ends inside it. Checked in every build, including
	 *                `final`.
	 *
	 * @see readVarUInt For the underlying unsigned representation.
	 */
	public inline function readVarInt():Int {
		var u:UInt = readVarUInt();
		return __zzDec(u);
	}

	@:noCompletion private static inline function __zzDec(u:Int):Int {
		return (u >>> 1) ^ -(u & 1);
	}

	/**
	 * Reads a LEB128-style variable-length **unsigned** integer (0 to 0xFFFFFFFF) and advances by 1–5 bytes.
	 *
	 * Each byte contributes 7 payload bits; the high bit (0x80) indicates continuation.
	 *
	 * @return The decoded unsigned value as `UInt` (stored in an `Int` domain). Held in
	 *         an `Int`, a value from 2^31 up is negative: check for that where the value
	 *         is a length or a count.
	 * @throws RangeError If more than 5 bytes are encountered (`"varuint too long"`)
	 *                or the decoded value does not fit in 32 bits (`"varuint
	 *                overflow"`), and `EOFError` if the buffer ends mid-varint
	 *                (`"ByteArrayInput underflow"`). Checked in every build,
	 *                including `final`. `position` does not move.
	 *
	 * @example
	 * ```haxe
	 * final x = input.readVarUInt();
	 * ```
	 */
	public inline function readVarUInt():UInt {
		var at:Int = this.position;
		var end:Int = this.length;
		var shift:Int = 0;
		var result:Int = 0;
		while (true) {
			// Checked in every build, unlike the rest of this class. These
			// bytes are whatever a remote peer sent, so a truncated or hostile
			// varint has to be an error rather than a read past the buffer.
			if (at >= end) {
				throw new EOFError("ByteArrayInput underflow");
			}
			var b:Int = this.get(at++);
			if (shift == 28 && b > 0x0F) {
				// The fifth byte carries the last four bits of 32 and has to
				// end the varint: bits above those would be shifted off the top
				// (2^32 + 1 reading as 1), and a continuation bit asks for a
				// sixth byte, which a 32-bit value never needs.
				throw new RangeError((b & 0x80) != 0 ? "varuint too long" : "varuint overflow");
			}
			result |= (b & 0x7F) << shift;
			if ((b & 0x80) == 0) {
				break;
			}
			shift += 7;
		}
		this.position = at;
		return result;
	}

	/**
	 * Reads a length-prefixed UTF string, as `ByteArrayOutput.writeVarUtf` writes one:
	 * its length in bytes as a varuint (see `readVarUInt`), then that many bytes of UTF-8.
	 *
	 * Layout: `[varuint length][length bytes of UTF data]`
	 *
	 * @return The decoded string.
	 * @throws EOFError If the decoded length exceeds the bytes remaining. Checked in
	 *                every build, including `final`. `position` does not move.
	 */
	public inline function readVarUtf():String {
		var at:Int = this.position;
		var len:Int = readVarUInt();
		// The length is the peer's. Negative is a length from 2^31 up, which
		// no buffer holds.
		if (len < 0 || len > this.length - this.position) {
			this.position = at;
			throw new EOFError("ByteArrayInput underflow");
		}
		return readUtfBytes(len);
	}

	/**
	 * Reads bytes with a varuint length before them, as `ByteArrayOutput.writeVarBytes`
	 * writes them: the length, then that many bytes, copied out.
	 *
	 * Layout: `[varuint length][length bytes]`
	 *
	 * The length is what whoever wrote the bytes chose, so it is checked against
	 * `maxLength` and against the bytes remaining before anything is allocated: five
	 * bytes claiming 2 GB are refused, not made room for. `position` does not move
	 * when the read fails.
	 *
	 * @param maxLength The longest length taken (default 1 MiB).
	 * @return A copy of the bytes.
	 * @throws RangeError If the length is more than `maxLength` (a length from 2^31
	 *                up always is), or the varuint does not fit in 32 bits.
	 * @throws EOFError If fewer bytes remain than the length, or the buffer ends inside
	 *                the varuint, so the read can be tried again once the rest has
	 *                arrived.
	 * @throws ArgumentError If `maxLength` is negative.
	 */
	public inline function readVarBytes(maxLength:Int = 1 << 20):Bytes {
		if (maxLength < 0) {
			throw new ArgumentError("ByteArrayInput.readVarBytes: maxLength must not be negative");
		}
		var at:Int = this.position;
		var len:Int = readVarUInt();
		// Negative is a length from 2^31 up, more than any maxLength.
		if (len < 0 || len > maxLength) {
			this.position = at;
			throw new RangeError('ByteArrayInput.readVarBytes: a length of ${(len : UInt)} is more than maxLength ($maxLength)');
		}
		if (len > this.length - this.position) {
			this.position = at;
			throw new EOFError("ByteArrayInput underflow");
		}
		var out:Bytes = Bytes.alloc(len);
		out.blit(0, this, this.position, len);
		this.position += len;
		return out;
	}
}
