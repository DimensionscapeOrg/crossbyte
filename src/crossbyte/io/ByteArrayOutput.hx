package crossbyte.io;

import haxe.io.Bytes;
import crossbyte.io.ByteArray;
import crossbyte.errors.RangeError;

/**
 * A buffered and growable binary output stream for writing primitive values into a `ByteArray`.
 *
 * `ByteArrayOutput` allows for efficient, low-level binary serialization using native Haxe types,
 * staging what is written in internal `Bytes` chunks.
 *
 * Every writer makes room for what it writes, in every build, `final` included. When the active
 * chunk cannot hold a value a new one is taken, at least as large as everything written so far,
 * so writing value after value takes a handful of chunks. `reserve()` ahead of a run of writes
 * makes room for the run at once, the same way: a chunk of at least what it asks for.
 *
 * Converting the output to `Bytes` or a `ByteArray`, by assigning it to one, merges the chunks
 * into one contiguous array (`flush()`). What it converts to is the output's own storage, not a
 * copy: a later write or `reset()` changes a ByteArray already handed out (one queued for an
 * asynchronous send, say). Take `copy()` for one that stays as it was.
 *
 * Every value is written little-endian, and the ByteArray it becomes says so in its `endian`.
 *
 * ## Key Features
 * - Fast, low-level `Bytes`-backed writing, never past the end of a chunk
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
 * final result:Bytes = output; // or a ByteArray
 * ```
 *
 * @see ByteArray
 * @see Bytes
 * @see ByteArrayInput
 * @author Christopher Speciale
 */
@:access(crossbyte.io.ByteArrayDataOutput)
@:access(crossbyte.io.ByteArrayData)
@:forward(reset, copy)
abstract ByteArrayOutput(ByteArrayDataOutput) from ByteArrayDataOutput to ByteArrayOutput {
	/**
	 * The total reserved (allocated) capacity of this output stream, in bytes.
	 *
	 * This represents the cumulative length of all backing `Bytes` chunks,
	 * including any flushed and unflushed buffers.
	 *
	 * **Note:** This is *not* the number of bytes currently written; it is the buffer size.
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
	public var bytesWritten(get, never):Int;

	@:noCompletion private var current(get, never):Bytes;

	@:noCompletion private inline function get_length():Int {
		return this.size;
	}

	@:noCompletion private inline function get_bytesWritten():Int {
		var used:Int = this.__outputPosition;
		if (this.byteCache != null) {
			for (bytes in this.byteCache) {
				used += bytes.length;
			}
		}
		return used;
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
	 * Converting to `Bytes` or `ByteArray` calls it; call it yourself only to
	 * merge the chunks ahead of that.
	 *
	 * No-op if already flushed.
	 */
	public inline function flush():Void {
		if (isFlushed()) {
			return;
		}

		var used:Int = this.__outputPosition;
		if (this.byteCache != null) {
			for (bytes in this.byteCache) {
				used += bytes.length;
			}
		}

		this.byteArray.explicitResize(used);
		this.byteArray.length = used;
		var offset:Int = 0;

		#if !final
		var total = this.byteArray.length;
		var expected = 0;
		if (this.byteCache != null) {
			for (bytes in this.byteCache)
				expected += bytes.length;
		}
		expected += this.__outputPosition;
		if (expected != total)
			throw new crossbyte.errors.Error("flush invariant failed: used != size");
		#end

		if (this.byteCache != null) {
			for (i in 0...this.byteCache.length) {
				var bytes:Bytes = this.byteCache[i];
				inline this.byteArray.blit(offset, bytes, 0, bytes.length);
				offset += bytes.length;
			}
		}

		if (this.__outputPosition > 0) {
			inline this.byteArray.blit(offset, this.currentBytes, 0, this.__outputPosition);
			offset += this.__outputPosition;
		}

		this.byteCache = null;
		this.currentBytes = this.byteArray;
		this.__outputPosition = used;
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
		// Against the room left in the active chunk, and grown as a write
		// grows it: a chunk at least as large as everything written so far.
		// so a codec reserving per value (every varint and string writer
		// here does, through `reserved = false`) does not make a chunk, and
		// copy the last one's used bytes out, for each value it writes.
		__room(size);
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
		// Difference, not sum: `pos + size` overflows for a large size and
		// wraps negative, so a write that could never fit would be reported
		// as valid.
		if (size < 0 || size > current.length - pos) {
			return false;
		}
		return true;
	}

	/**
		Makes room for `count` bytes at the write position: a comparison, and a
		new chunk when the active one cannot hold them.

		Every writer comes through here, so a `new ByteArrayOutput()` takes
		`writeInt(1)` without `reserve(4)` first, and a `final` build never
		writes past the end of a chunk.
	**/
	@:noCompletion private inline function __room(count:Int):Void {
		if (count > current.length - this.__outputPosition) {
			__grow(count);
		}
	}

	/**
		A new chunk of at least `count` bytes, and at least as large as the
		output already holds, so that writing value after value with no
		`reserve()` takes a handful of chunks rather than one apiece.
	**/
	@:noCompletion private function __grow(count:Int):Void {
		var chunk:Int = this.size < MIN_GROWTH ? MIN_GROWTH : this.size;
		if (chunk < count) {
			chunk = count;
		}
		var total:Int = this.size + chunk;
		if (total < this.size) {
			// Doubling past 2^31 would wrap: only what was asked for.
			total = this.size + count;
		}
		this_resize(total);
		this.__outputPosition = 0;
	}

	@:noCompletion private static inline var MIN_GROWTH:Int = 64;

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
		__room(1);
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
		// The source range first, so a bad one is refused before room is
		// made for it: a length of 2^31 asked for a 2 GB chunk before the
		// copy found it out.
		if (offset < 0 || length < 0 || offset > source.length || length > source.length - offset) {
			throw new RangeError('ByteArrayOutput.writeBytes: $length bytes from $offset is outside the source');
		}

		__room(length);
		inline current.blit(this.__outputPosition, source, offset, length);
		this.__outputPosition += length;
	}

	/**
	 * Writes a 64-bit IEEE-754 double-precision float.
	 *
	 * @param v The `Float` value to write.
	 */
	public inline function writeDouble(v:Float):Void {
		__room(8);
		inline current.setDouble(this.__outputPosition, v);
		this.__outputPosition += 8;
	}

	/**
	 * Writes a 32-bit IEEE-754 floating-point number.
	 *
	 * @param v The `Float` value to write.
	 */
	public inline function writeFloat(v:Float):Void {
		__room(4);
		inline current.setFloat(this.__outputPosition, v);
		this.__outputPosition += 4;
	}

	/**
	 * Writes a 32-bit signed integer to the buffer.
	 *
	 * @param v The `Int` value to write.
	 */
	public inline function writeInt(v:Int):Void {
		__room(4);
		current.setInt32(this.__outputPosition, v);
		this.__outputPosition += 4;
	}

	public function writeIntAt(position:Int, value:Int):Void {
		// In every build, and against what is written rather than
		// `position + 4`, which wraps: past it natively the chunk grew by up
		// to 2 GB, and in `final` a near miss wrote into the unused part of
		// the chunk, which nothing copies, and the patch was lost.
		if (position < 0 || position > bytesWritten - 4) {
			throw new RangeError('ByteArrayOutput position out of range (' + position + ' + 4 > ' + bytesWritten + ')');
		}

		var chunkStart:Int = 0;
		if (this.byteCache != null) {
			for (bytes in this.byteCache) {
				if (position < chunkStart + bytes.length) {
					// Only when all four bytes are inside this chunk. A cached
					// chunk is allocated to exactly the number of bytes that
					// were written into it, so one can end in the middle of the
					// integer being patched, and setInt32 on the chunk that
					// merely holds the first byte would write the other three
					// past the end of it.
					if (position + 4 <= chunkStart + bytes.length) {
						bytes.setInt32(position - chunkStart, value);
					} else {
						__writeIntAcrossChunks(position, value);
					}
					return;
				}
				chunkStart += bytes.length;
			}
		}

		current.setInt32(position - chunkStart, value);
	}

	/**
	 * Patches a 32-bit integer that straddles the seam between two chunks.
	 *
	 * Encoded through a four byte scratch so the bytes land in whatever order
	 * `setInt32` would have written them, rather than an order assumed here.
	 */
	@:noCompletion private function __writeIntAcrossChunks(position:Int, value:Int):Void {
		var scratch:Bytes = Bytes.alloc(4);
		scratch.setInt32(0, value);

		for (i in 0...4) {
			__setByteAt(position + i, scratch.get(i));
		}
	}

	@:noCompletion private function __setByteAt(position:Int, value:Int):Void {
		var chunkStart:Int = 0;
		if (this.byteCache != null) {
			for (bytes in this.byteCache) {
				if (position < chunkStart + bytes.length) {
					bytes.set(position - chunkStart, value);
					return;
				}
				chunkStart += bytes.length;
			}
		}

		current.set(position - chunkStart, value);
	}

	/**
	 * Writes a 16-bit unsigned integer.
	 *
	 * Haxe uses little-endian encoding by default.
	 *
	 * @param value The `UInt16` to write.
	 */
	public inline function writeShort(value:Int):Void {
		__room(2);
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
		#if (js || cpp)
		if (__writeText(value, 0)) {
			return;
		}
		#end
		var b:Bytes = crossbyte._internal.Utf8.bytesOf(value);
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
	 * @throws RangeError If the string is more than 65535 bytes as UTF-8.
	 */
	public inline function writeUTF(value:String, reserved:Bool = false):Void {
		#if (js || cpp)
		if (__writeText(value, 2)) {
			return;
		}
		#end
		var b:Bytes = crossbyte._internal.Utf8.bytesOf(value);

		// A sixteen-bit prefix cannot describe more, and past it the length
		// wrapped and every later read landed in the wrong place.
		if (b.length > 0xFFFF) {
			throw new RangeError('writeUTF takes at most 65535 bytes, and this string is ${b.length}.');
		}

		if (!reserved) {
			reserve(2 + b.length);
		}

		writeShort(b.length);
		writeBytes(b);
	}

	/**
	 * Writes a variable-length unsigned integer (varuint) using LEB128 encoding.
	 *
	 * @param value    The `UInt` to write, 0 to 0xFFFFFFFF, in one to five bytes.
	 *                 A negative `Int` is the unsigned value it holds: -1 is
	 *                 written as 0xFFFFFFFF.
	 * @param reserved Whether the space has already been reserved.
	 */
	public inline function writeVarUInt(value:Int, reserved:Bool = false):Void {
		var v:Int = value;

		if (!reserved) {
			reserve(varUIntSize(v));
		}

		// Tested as the unsigned value it is: a signed `v > 0x7F` is false
		// for anything with bit 31 set, which would go out as a single byte,
		// as would a ZigZag value from 2^30 up in magnitude.
		while ((v & ~0x7F) != 0) {
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
		#if (js || cpp)
		if (__writeText(value, 1)) {
			return;
		}
		#end
		var b:Bytes = crossbyte._internal.Utf8.bytesOf(value);

		if (!reserved) {
			reserve(varUIntSize(b.length) + b.length);
		}

		writeVarUInt(b.length, true);
		writeBytes(b);
	}

	#if js
	/**
		`value` in UTF-8 written straight into the output (see
		Utf8.writeView), after its length when `head` asks for one (1 a
		varint, 2 sixteen bits), where the platform's encoder made a buffer of
		it to copy in: on Node twelve characters in about 43 ns rather than
		715. Room is made for the most it can take, three bytes a unit, so it
		goes into one chunk with its length, a varint as wide as that most and
		narrowed after if the text took less. Past IN_PLACE_LIMIT units that
		would make a chunk far larger than the text, and it is false, having
		written nothing.
	**/
	@:noCompletion private function __writeText(value:String, head:Int):Bool {
		var units:Int = value.length;
		if (units > IN_PLACE_LIMIT) {
			return false;
		}
		var most:Int = units * crossbyte._internal.Utf8.MAX_BYTES_PER_UNIT;
		var width:Int = head == 2 ? 2 : (head == 1 ? varUIntSize(most) : 0);
		__room(width + most);
		var view:js.lib.Uint8Array = @:privateAccess current.b;
		var at:Int = this.__outputPosition;
		var size:Int = crossbyte._internal.Utf8.writeView(value, view, at + width, at + width + most);
		if (head == 2) {
			// Little-endian, as writeShort writes it.
			view[at] = size & 0xFF;
			view[at + 1] = (size >> 8) & 0xFF;
		} else if (head == 1) {
			var used:Int = varUIntSize(size);
			if (used < width) {
				view.copyWithin(at + used, at + width, at + width + size);
				width = used;
			}
			var v:Int = size;
			var p:Int = at;
			while ((v & ~0x7F) != 0) {
				view[p++] = (v & 0x7F) | 0x80;
				v >>>= 7;
			}
			view[p] = v;
		}
		this.__outputPosition = at + width + size;
		return true;
	}

	// The longest text written in place: at most 12 KB of room for it.
	private static inline var IN_PLACE_LIMIT:Int = 4096;
	#end

	#if cpp
	/**
		`value` in UTF-8 written straight into the output after its length
		when `head` asks for one (1 a varint, 2 sixteen bits): a string held
		a byte a character copied as it stands, its bytes being its UTF-8,
		and one held as UTF-16 sized and encoded in place (see
		Utf8.encodeNative), where `Bytes.ofString` made a buffer of it to copy
		in. False, having written nothing, for one past the 16-bit prefix,
		which writeUTF refuses.
	**/
	@:noCompletion private function __writeText(value:String, head:Int):Bool {
		var narrow:Bool = !(untyped __cpp__("{0}.isUTF16Encoded()", value));
		var size:Int = narrow ? value.length : crossbyte._internal.Utf8.sizeOf(value);
		if (head == 2) {
			if (size > 0xFFFF) {
				return false;
			}
			writeShort(size);
		} else if (head == 1) {
			writeVarUInt(size);
		}
		if (size > 0) {
			__room(size);
			var at:Int = this.__outputPosition;
			if (narrow) {
				untyped __cpp__("memcpy((char *){0}->GetBase() + {1}, {2}.raw_ptr(), {3})", current.getData(), at, value, size);
			} else {
				crossbyte._internal.Utf8.encodeNative(value, current.getData(), at);
			}
			this.__outputPosition = at + size;
		}
		return true;
	}
	#end

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
		// Masks, not `<`: `v >>>= 0` makes a value unsigned on JavaScript
		// alone, and everywhere else a value with bit 31 set compares as
		// negative and would be sized at one byte.
		if ((v & ~0x7F) == 0) {
			return 1;
		}

		if ((v & ~0x3FFF) == 0) {
			return 2;
		}

		if ((v & ~0x1FFFFF) == 0) {
			return 3;
		}

		if ((v & ~0xFFFFFFF) == 0) {
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
	 * @return `true` when everything written is in one contiguous array: after
	 *         `flush()`, and for an output nothing has been written to. A write
	 *         after a flush makes it false again.
	 */
	public inline function isFlushed():Bool {
		return this.byteCache == null && this.currentBytes == this.byteArray && this.__outputPosition == this.byteArray.length;
	}

	@:noCompletion private inline function this_resize(length):Void {
		if (this.byteCache == null) {
			this.byteCache = [];
		}

		if (this.__outputPosition > 0) {
			var used = Bytes.alloc(this.__outputPosition);
			used.blit(0, this.currentBytes, 0, this.__outputPosition);
			this.byteCache.push(used);
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
		// What every writer here writes, so the ByteArray it becomes reads
		// its integers back as they were, whatever `defaultEndian` is.
		this.endian = LITTLE_ENDIAN;
		this.currentBytes = byteArray;
		this.size = length;
	}

	public inline function copy():ByteArray {
		var used:Int = this.__outputPosition;
		if (byteCache != null) {
			for (bytes in this.byteCache) {
				used += bytes.length;
			}
		}

		var out:ByteArrayData = new ByteArray(used);
		out.endian = LITTLE_ENDIAN;
		var offset:Int = 0;

		if (byteCache != null) {
			for (i in 0...this.byteCache.length) {
				var bytes:Bytes = this.byteCache[i];
				inline out.blit(offset, bytes, 0, bytes.length);
				offset += bytes.length;
			}
		}

		if (this.__outputPosition > 0) {
			inline out.blit(offset, this.currentBytes, 0, this.__outputPosition);
		}

		return out;
	}

	public inline function reset(length:Int):Void {
		this.byteArray.explicitResize(length);
		if (length > 0) {
			this.byteArray.fill(0, length, 0);
		}
		this.byteArray.length = length;
		this.byteArray.position = 0;
		this.byteCache = null;
		this.currentBytes = this.byteArray;
		this.size = length;
		__outputPosition = 0;
	}
}
