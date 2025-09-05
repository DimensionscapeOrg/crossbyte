package crossbyte.io;

import haxe.io.Bytes;
import crossbyte.io.ByteArray;

/**
 * A fast, bounds-checked (in `#if debug`) read-only view over an underlying
 * `ByteArrayData`/`ByteArray` buffer.
 *
 * `ByteArrayInput` exposes a forward-only cursor (`position`) and convenience
 * readers for common primitive types, UTF strings, and variable-length integers.
 *
 * ### Key characteristics
 * - **Zero-copy reads**: uses direct getters on the backing buffer where possible.
 * - **Explicit cursoring**: all reads advance `position` by the number of bytes consumed.
 * - **Safety in debug**: out-of-range accesses throw helpful errors in debug builds.
 * - **Interop**: can be implicitly created from `ByteArrayData` or `ByteArray`.
 *
 * ### Typical usage
 * ```haxe
 * final input:ByteArrayInput = someByteArray; // implicit from ByteArray
 * final tag  = input.readInt();
 * final name = input.readVarUTF();
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
	 * In debug builds, assigning a value outside this range throws `"position out of range"`.
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
	 * Equivalent to `length - position`. When `bytesAvailable == 0`, subsequent reads will
	 * throw in debug builds or produce undefined behavior in release builds if forced.
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
		#if debug
		if (v < 0 || v > this.length)
			throw "position out of range";
		#end
		return this.position = v;
	}

	@:noCompletion private inline function __need(n:Int):Void {
		#if debug
		if (this.position + n > this.length)
			throw "ByteArrayInput underflow";
		#end
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
	 * @throws String In debug builds if reading would exceed `length`.
	 */
	public inline function readByte():Int {
		__need(1);
		return this.get(this.position++);
	}

	/**
	 * Reads a byte and interprets it as a boolean.
	 *
	 * Convention: `0 == false`, any non-zero value == `true`.
	 *
	 * @return The decoded boolean value.
	 * @throws String In debug builds if reading would exceed `length`.
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
	 * @throws String In debug builds if reading would exceed `length`.
	 */
	public inline function readShort():Int {
		__need(2);
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
	 * @throws String In debug builds if reading would exceed `length`.
	 */
	public inline function readInt():Int {
		__need(4);
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
	 * @throws String In debug builds if reading would exceed `length`.
	 */
	public inline function readFloat():Float {
		__need(4);
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
	 * @throws String In debug builds if reading would exceed `length`.
	 */
	public inline function readDouble():Float {
		__need(8);
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
	 * @throws String In debug builds if the read would exceed `length`.
	 */
	public inline function readBytes(dst:Bytes, dstOffset:Int = 0, len:Int = -1):Void {
		if (len < 0){
			len = dst.length - dstOffset;
		}			
		__need(len);
		dst.blit(dstOffset, this, this.position, len);
		this.position += len;
	}

	/**
	 * Reads exactly `len` bytes as a UTF-8 (or backing-defined) string and advances.
	 *
	 * **Note:** No length prefix is consumed; this reads a fixed-size slice.
	 *
	 * @param len Number of bytes to decode into a string.
	 * @return The decoded string.
	 * @throws String In debug builds if the read would exceed `length`.
	 */
	public inline function readUTFBytes(len:Int):String {
		__need(len);
		var s:String = this.getString(this.position, len);
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
	 * @throws String In debug builds if the read would exceed `length`.
	 */
	public inline function readUTF():String {
		var len:Int = readShort();
		return readUTFBytes(len);
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
	 * @throws String In debug builds if the varint is malformed/too long or overflows.
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
	 * Reads a LEB128-style variable-length **unsigned** integer (0 to 2^31-1) and advances by 1–5 bytes.
	 *
	 * Each byte contributes 7 payload bits; the high bit (0x80) indicates continuation.
	 *
	 * @return The decoded unsigned value as `UInt` (stored in an `Int` domain).
	 * @throws String In debug builds if more than 5 bytes are encountered (`"varuint too long"`)
	 *                or if the decoded value does not fit (`"varuint overflow"`).
	 *
	 * @example
	 * ```haxe
	 * final x = input.readVarUInt();
	 * ```
	 */
	public inline function readVarUInt():UInt {
		var shift:Int = 0;
		var result:Int = 0;
		while (true) {
			__need(1);
			var b:Int = this.get(this.position++);
			result |= (b & 0x7F) << shift;
			if ((b & 0x80) == 0){
				break;
			}				
			shift += 7;
			#if debug
			if (shift > 35)
				throw "varuint too long";
			#end
		}
		#if debug
		if (result < 0)
			throw "varuint overflow";
		#end
		return result;
	}

	/**
	 * Reads a length-prefixed UTF string where the length is stored as a ZigZag-encoded
	 * variable-length **signed** integer, then consumes that many bytes of UTF data.
	 *
	 * Layout: `[varint length][length bytes of UTF data]`
	 *
	 * This is compact for short strings and supports negative sentinel semantics upstream
	 * (though this implementation expects a non-negative decoded length).
	 *
	 * @return The decoded string.
	 * @throws String In debug builds if reading would exceed `length` or if the length is invalid.
	 */
	public inline function readVarUTF():String {
		var len:Int = readVarInt();
		return readUTFBytes(len);
	}
}
