package crossbyte.io;

import haxe.io.Bytes;
import crossbyte.io.ByteArray;

/**
 * ...
 * @author Christopher Speciale
 */
/**
 * A buffered and growable binary output stream for writing primitive values into a `ByteArray`.
 *
 * `ByteArrayOutput` allows for efficient, low-level binary serialization using native Haxe types
 * with bounds-checked write methods (in debug builds) and staging via internal `Bytes` buffers.
 *
 * Data written through this abstraction is not immediately visible via `toBytes()` or `toByteArray()`
 * until `flush()` is called, at which point all internal buffers are merged into a contiguous array.
 *
 * ## Key Features
 * - Fast, low-level `Bytes`-backed writing with safety in debug builds
 * - Efficient incremental growth using internal buffer chunking
 * - Support for varint encoding, UTF strings, and fixed-size primitives
 * - Lazy flush behavior for performance
 * - Compatible with `Bytes` and `ByteArray` output conversion
 *
 * ## Example
 * ```haxe
 * var output = new ByteArrayOutput();
 * output.reserve(128);
 * output.writeInt(42);
 * output.writeVarUTF("Hello");
 *
 * final result:Bytes = output.toBytes(); // or .toByteArray()
 * ```
 *
 * @see ByteArray
 * @see Bytes
 * @see ByteArrayInput
 * @author Christopher Speciale
 */
@:access(crossbyte.io.ByteArrayDataOutput)
@:access(crossbyte.io.ByteArrayData)
@:forward(reset)
abstract ByteArrayOutput(ByteArrayDataOutput) from ByteArrayDataOutput to ByteArrayOutput {
	/**
	 * The total reserved (allocated) capacity of this output stream, in bytes.
	 *
	 * This represents the cumulative length of all backing `Bytes` chunks,
	 * including any flushed and unflushed buffers.
	 *
	 * **Note:** This is *not* the number of bytes currently written — it is the buffer size.
	 * Use `flush()` + `toBytes()` or `toByteArray()` to get the actual written contents.
	 *
	 * @example
	 * ```haxe
	 * var output = new ByteArrayOutput();
	 * output.reserve(64);
	 * trace(output.length); // -> 64
	 * ```
	 */
	public var length(get, never):Int;

	@:noCompletion private var current(get, never):Bytes;

	@:noCompletion private inline function get_length():Int {
		return this.size;
	}

	@:noCompletion private inline function get_current():Bytes {
		return this.currentBytes;
	}

	/**
	 * Creates a new `ByteArrayOutput` instance with optional initial capacity.
	 *
	 * @param length Initial buffer size in bytes (default = 0).
	 */
	public inline function new(length:Int = 0) {
		this = new ByteArrayDataOutput(length);
		this.__outputPosition = 0;
		this.size = length;
	}

	/**
	 * Finalizes the current write session by committing all
	 * intermediate buffer chunks into the underlying `ByteArray`.
	 *
	 * Must be called before converting to `Bytes` or `ByteArray`.
	 *
	 * No-op if already flushed.
	 */
	public inline function flush():Void {
		if (isFlushed()) {
			return;
		}

		var offset:Int = this.byteArray.length;

		this.byteArray.explicitResize(this.size);

		#if debug
		var total = this.byteArray.length;
		var used = offset;
		for (bytes in this.byteCache)
			used += bytes.length;
		if (this.currentBytes != null && this.currentBytes != this.byteArray)
			used += this.currentBytes.length;
		if (used != total)
			throw "flush invariant failed: used != size";
		#end

		for (i in 0...this.byteCache.length) {
			var bytes:Bytes = this.byteCache[i];
			inline this.byteArray.blit(offset, bytes, 0, bytes.length);
			offset += bytes.length;
		}

		if (this.currentBytes != null && this.currentBytes != this.byteArray) {
			inline this.byteArray.blit(offset, this.currentBytes, 0, this.currentBytes.length);
			offset += this.currentBytes.length;
		}

		this.byteCache = null;
		this.currentBytes = this.byteArray;
	}

	/**
	 * Ensures that at least `size` additional bytes can be written
	 * beyond the current write position.
	 *
	 * This method may allocate new buffer space but does not change
	 * the current position or write any data.
	 *
	 * @param size Number of bytes to reserve beyond current offset.
	 */
	public inline function reserve(size:Int):Void {
		var newSize:Int = size + length;
		if (newSize <= this.size) {
			return;
		}

		this_resize(newSize);
		this.__outputPosition = 0;
	}

	/**
	 * Validates whether `size` bytes can be written at the current position.
	 *
	 * @param size Number of bytes to validate.
	 * @return `true` if there's enough room; `false` otherwise.
	 */
	public inline function validateSize(size:Int):Bool {
		return validateSizeAt(size, this.__outputPosition);
	}

	/**
	 * Checks whether `size` bytes can be written starting at offset `pos`.
	 *
	 * @param size Number of bytes to write.
	 * @param pos  Position to begin validation at.
	 * @return `true` if valid, `false` otherwise.
	 */
	public inline function validateSizeAt(size:Int, pos:Int):Bool {
		if (pos + size > length) {
			return false;
		}
		return true;
	}

	@:noCompletion private inline function __validateSizeErr(pos, size):Void {
		throw 'ByteArrayOutput overflow (' + (pos + size) + ' > ' + length + ')';
	}

	/**
	 * Writes a boolean as a single byte: `1` for `true`, `0` for `false`.
	 *
	 * @param value Boolean to write.
	 */
	public inline function writeBoolean(value:Bool):Void {
		writeByte(value ? 1 : 0);
	}

	/**
	 * Writes a single byte (0–255) to the current position.
	 *
	 * @param v The byte value to write.
	 */
	public inline function writeByte(v:Int):Void {
		#if debug
		if (!validateSize(1))
			__validateSizeErr(this.__outputPosition, 1);
		#end
		current.set(this.__outputPosition++, v & 0xFF);
	}

	/**
	 * Writes a raw sequence of bytes from `source` into this output.
	 *
	 * @param source  The input `Bytes`.
	 * @param offset  Starting offset in `source` (default = 0).
	 * @param length  Number of bytes to write (default = remainder of source).
	 */
	public inline function writeBytes(source:Bytes, offset:Int = 0, length:Int = -1):Void {
		if (length < 0) {
			length = source.length - offset;
		}

		#if debug
		if (!validateSize(length))
			__validateSizeErr(this.__outputPosition, length);
		#end
		inline current.blit(this.__outputPosition, source, offset, length);
		this.__outputPosition += length;
	}

	/**
	 * Writes a 64-bit IEEE-754 double-precision float.
	 *
	 * @param v The `Float` value to write.
	 */
	public inline function writeDouble(v:Float):Void {
		#if debug
		if (!validateSize(8))
			__validateSizeErr(this.__outputPosition, 8);
		#end

		inline current.setDouble(this.__outputPosition, v);
		this.__outputPosition += 8;
	}

	/**
	 * Writes a 32-bit IEEE-754 floating-point number.
	 *
	 * @param v The `Float` value to write.
	 */
	public inline function writeFloat(v:Float):Void {
		#if debug
		if (!validateSize(4))
			__validateSizeErr(this.__outputPosition, 4);
		#end
		inline current.setFloat(this.__outputPosition, v);
		this.__outputPosition += 4;
	}

	/**
	 * Writes a 32-bit signed integer to the buffer.
	 *
	 * @param v The `Int` value to write.
	 */
	public inline function writeInt(v:Int):Void {
		#if debug
		if (!validateSize(4)) {
			__validateSizeErr(this.__outputPosition, 4);
		}
		#end
		current.setInt32(this.__outputPosition, v);
		this.__outputPosition += 4;
	}

	/**
	 * Writes a 16-bit unsigned integer.
	 *
	 * Haxe uses little-endian encoding by default.
	 *
	 * @param value The `UInt16` to write.
	 */
	public inline function writeShort(value:Int):Void {
		#if debug
		if (!validateSize(2))
			__validateSizeErr(this.__outputPosition, 2);
		#end
		// haxe always uses litte endian anyway
		current.setUInt16(this.__outputPosition, value);
		this.__outputPosition += 2;
	}

	/**
	 * Writes the raw UTF-8 bytes of a string (no length prefix).
	 *
	 * If `reserved = false`, space is automatically reserved.
	 *
	 * @param value    The string to write.
	 * @param reserved Whether the space has already been reserved.
	 */
	public inline function writeUTFBytes(value:String, reserved:Bool = false):Void {
		var b:Bytes = Bytes.ofString(value);
		if (!reserved) {
			reserve(b.length);
		}

		writeBytes(b, 0, b.length);
	}

	/**
	 * Writes a UTF-8 string with a 16-bit length prefix.
	 *
	 * Layout: `[u16 length][utf8 bytes]`
	 *
	 * @param value    The string to write.
	 * @param reserved Whether the space has already been reserved.
	 */
	public inline function writeUTF(value:String, reserved:Bool = false):Void {
		var b:Bytes = Bytes.ofString(value);

		if (!reserved) {
			reserve(b.length);
		}

		writeShort(b.length);
		writeBytes(b);
	}

	/**
	 * Writes a variable-length unsigned integer (varuint) using LEB128 encoding.
	 *
	 * @param value    The `UInt` to write.
	 * @param reserved Whether the space has already been reserved.
	 */
	public inline function writeVarUInt(value:Int, reserved:Bool = false):Void {
		var v:Int = value >>> 0;

		if (!reserved) {
			reserve(varUIntSize(v));
		}

		while (v > 0x7F) {
			writeByte((v & 0x7F) | 0x80);
			v >>>= 7;
		}
		writeByte(v);
	}

	/**
	 * Writes a UTF string with a varint length prefix.
	 *
	 * Layout: `[varuint length][utf8 bytes]`
	 *
	 * @param value    The string to write.
	 * @param reserved Whether the space has already been reserved.
	 */
	public inline function writeVarUTF(value:String, reserved:Bool = false):Void {
		var b:Bytes = Bytes.ofString(value);

		if (!reserved) {
			reserve(b.length);
		}

		writeVarUInt(b.length);
		writeBytes(b);
	}

	/**
	 * Writes a ZigZag-encoded variable-length signed integer.
	 *
	 * ZigZag maps negative numbers to positive values to improve varint compactness.
	 *
	 * @param value    The `Int` to write.
	 * @param reserved Whether the space has already been reserved.
	 */
	public inline function writeVarInt(value:Int, reserved:Bool = false):Void {
		var u:Int = __zzEnc(value);
		writeVarUInt(u, reserved); // uses your existing varUInt writer
	}

	@:noCompletion private static inline function __zzEnc(v:Int):Int {
		return (v << 1) ^ (v >> 31);
	}

	/**
	 * Calculates the number of bytes required to store a varuint.
	 *
	 * @param v The unsigned integer to analyze.
	 * @return 1–5 depending on value range.
	 */
	public static inline function varUIntSize(v:Int):Int {
		v >>>= 0;
		if (v < 0x80) {
			return 1;
		}

		if (v < 0x4000) {
			return 2;
		}

		if (v < 0x200000) {
			return 3;
		}

		if (v < 0x10000000) {
			return 4;
		}

		return 5;
	}

	/**
	 * Returns whether this output has already been flushed.
	 *
	 * Once flushed, data is committed and no further changes to internal
	 * buffers will occur.
	 *
	 * @return `true` if `flush()` has already been called.
	 */
	public inline function isFlushed():Bool {
		return this.byteCache == null;
	}

	@:noCompletion private inline function this_resize(length):Void {
		if (this.byteCache == null) {
			this.byteCache = [];
		} else {
			this.byteCache.push(this.currentBytes);
		}
		this.currentBytes = Bytes.alloc(length - this.size);
		this.size = length;
	}

	@:to @:noCompletion private inline function toByteArray():ByteArray {
		flush();
		return this.byteArray;
	}

	@:to @:noCompletion private inline function toBytes():Bytes {
		flush();
		return this.byteArray;
	}
}

@:noCompletion
class ByteArrayDataOutput extends ByteArrayData {
	@:noCompletion private var byteArray(get, never):ByteArrayData;
	@:noCompletion private var byteCache:Array<Bytes>;
	@:noCompletion private var currentBytes:Bytes;
	@:noCompletion private var __outputPosition:Int = 0;
	@:noCompletion private var size:Int;

	@:noCompletion private inline function get_byteArray():ByteArrayData {
		return this;
	}

	@:noCompletion private function new(length:Int):Void {
		super(length);
		this.currentBytes = byteArray;
		this.size = length;
	}

	public inline function copy():ByteArray {
		var out:ByteArrayData = new ByteArray(this.size);
		inline out.blit(0, this.byteArray, 0, this.byteArray.length);

		var offset:Int = out.length;

		if (byteCache != null) {
			for (i in 0...this.byteCache.length) {
				var bytes:Bytes = this.byteCache[i];
				inline out.blit(offset, bytes, 0, bytes.length);
				offset += bytes.length;
			}
		}

		if (this.currentBytes != null && this.currentBytes != this.byteArray) {
			inline out.blit(offset, this.currentBytes, 0, this.currentBytes.length);
		}

		return out;
	}

	public inline function reset(length:Int):Void {
		this.byteArray.clear();
		this.byteCache = null;
		this.currentBytes = this.byteArray;
		this.size = length;
		__outputPosition = 0;
	}
}
