package crossbyte._internal.http.h2.hpack;

import haxe.io.Bytes;

/**
 * HPACK decoder (RFC 7541 §6).
 *
 * One instance per connection per direction: the dynamic table is connection
 * state, and decoding block N depends on every block before it.
 *
 * Everything here parses bytes the peer chose, so each bound is enforced
 * rather than assumed. The decompression ratio of HPACK is unbounded in
 * principle -- a few bytes of indexed references can name arbitrarily many
 * table entries -- so `maxHeaderListSize` caps the decoded total and stops a
 * small block from expanding into an allocation the process cannot survive.
 */
class HpackDecoder {
	/**
	 * Upper bound on the decoded header list, by the §4.1 accounting.
	 * Exceeding it is fatal to the connection.
	 */
	public var maxHeaderListSize:Int;

	/**
	 * The largest table capacity the peer is allowed to select, from our
	 * SETTINGS_HEADER_TABLE_SIZE. A dynamic table size update above this is a
	 * decoding error, not a request to be honoured.
	 */
	public var maxTableCapacity(default, null):Int;

	private var __table:HpackDynamicTable;

	public function new(maxTableCapacity:Int = 4096, maxHeaderListSize:Int = 8 * 1024 * 1024) {
		this.maxTableCapacity = maxTableCapacity;
		this.maxHeaderListSize = maxHeaderListSize;
		__table = new HpackDynamicTable(maxTableCapacity);
	}

	public var tableSize(get, never):Int;

	private inline function get_tableSize():Int {
		return __table.size;
	}

	public var tableLength(get, never):Int;

	private inline function get_tableLength():Int {
		return __table.length;
	}

	/**
	 * Entry at a 0-based position in the dynamic table, newest first, or
	 * `null` when out of range.
	 *
	 * Read-only, and present because a table that has drifted out of step with
	 * the peer's produces wrong headers rather than an error -- so being able
	 * to look at it is the difference between diagnosing that and guessing.
	 */
	public function dynamicEntry(index:Int):Null<HpackHeader> {
		return __table.get(index);
	}

	/**
	 * Announces a new SETTINGS_HEADER_TABLE_SIZE we have sent. The peer is not
	 * obliged to shrink immediately, so the table is only capped when the new
	 * bound is lower than the capacity currently in use.
	 */
	public function setMaxTableCapacity(value:Int):Void {
		maxTableCapacity = value;
		if (__table.capacity > value) {
			__table.resize(value);
		}
	}

	public function decode(block:Bytes):Array<HpackHeader> {
		var out:Array<HpackHeader> = [];
		var cursor:Cursor = new Cursor(block);
		var listSize:Int = 0;
		// §4.2: a size update is only legal at the very start of a block.
		var updatesStillAllowed:Bool = true;

		while (!cursor.atEnd()) {
			var first:Int = cursor.peek();

			if ((first & 0x80) != 0) {
				// 1xxxxxxx -- indexed header field.
				var index:Int = __readInteger(cursor, 7);
				out.push(__resolve(index));
				updatesStillAllowed = false;
			} else if ((first & 0x40) != 0) {
				// 01xxxxxx -- literal, added to the dynamic table.
				var header:HpackHeader = __readLiteral(cursor, 6, false);
				__table.add(header);
				out.push(header);
				updatesStillAllowed = false;
			} else if ((first & 0x20) != 0) {
				// 001xxxxx -- dynamic table size update.
				if (!updatesStillAllowed) {
					throw new HpackError("Dynamic table size update must precede the header fields in a block");
				}
				var capacity:Int = __readInteger(cursor, 5);
				if (capacity > maxTableCapacity) {
					throw new HpackError('Dynamic table size update of $capacity exceeds the advertised maximum of $maxTableCapacity');
				}
				__table.resize(capacity);
				continue;
			} else {
				// 0000xxxx never-indexed, or 0001xxxx without indexing. Both
				// decode identically; only the never-indexed marker has to
				// survive if this list is ever re-encoded.
				var neverIndexed:Bool = (first & 0x10) != 0;
				out.push(__readLiteral(cursor, 4, neverIndexed));
				updatesStillAllowed = false;
			}

			listSize += out[out.length - 1].tableSize;
			if (listSize > maxHeaderListSize) {
				throw new HpackError('Decoded header list exceeds the $maxHeaderListSize byte limit');
			}
		}

		return out;
	}

	private function __resolve(index:Int):HpackHeader {
		if (index == 0) {
			// §6.1 reserves 0; it cannot name an entry.
			throw new HpackError("Indexed header field with index 0");
		}

		if (index <= HpackStaticTable.LENGTH) {
			var at:Int = index - 1;
			return new HpackHeader(HpackStaticTable.NAMES[at], HpackStaticTable.VALUES[at]);
		}

		var entry:Null<HpackHeader> = __table.get(index - HpackStaticTable.LENGTH - 1);
		if (entry == null) {
			throw new HpackError('Header index $index is past the end of the dynamic table');
		}
		return entry;
	}

	private function __readLiteral(cursor:Cursor, prefixBits:Int, sensitive:Bool):HpackHeader {
		var nameIndex:Int = __readInteger(cursor, prefixBits);
		var name:String = nameIndex == 0 ? __readString(cursor) : __resolve(nameIndex).name;
		return new HpackHeader(name, __readString(cursor), sensitive);
	}

	/**
	 * §5.1 prefix-coded integer. Values wider than 32 bits are rejected rather
	 * than wrapped: a continuation run can otherwise be extended indefinitely,
	 * and a silently truncated length becomes a read at the wrong offset.
	 */
	private function __readInteger(cursor:Cursor, prefixBits:Int):Int {
		var mask:Int = (1 << prefixBits) - 1;
		var value:Int = cursor.read() & mask;

		if (value < mask) {
			return value;
		}

		var shift:Int = 0;
		while (true) {
			var byte:Int = cursor.read();
			var chunk:Int = byte & 0x7f;

			if (shift > 21 || (shift == 21 && chunk > 0x0f)) {
				throw new HpackError("Prefix-coded integer does not fit in 32 bits");
			}

			value += chunk << shift;
			if (value < 0) {
				throw new HpackError("Prefix-coded integer overflowed");
			}

			if ((byte & 0x80) == 0) {
				return value;
			}
			shift += 7;
		}
	}

	private function __readString(cursor:Cursor):String {
		var first:Int = cursor.peek();
		var huffman:Bool = (first & 0x80) != 0;
		var length:Int = __readInteger(cursor, 7);

		if (length < 0 || cursor.remaining() < length) {
			throw new HpackError("String literal runs past the end of the header block");
		}

		var decoded:Bytes = huffman ? HpackHuffman.decode(cursor.bytes, cursor.position, length) : cursor.bytes.sub(cursor.position, length);
		cursor.skip(length);

		return decoded.toString();
	}
}

/**
 * A read cursor that refuses to run off the end.
 *
 * Every overrun here is a truncated or hostile block, so the check lives in
 * one place rather than at each of the dozen call sites that would otherwise
 * have to remember it.
 */
private class Cursor {
	public final bytes:Bytes;
	public var position(default, null):Int;

	public function new(bytes:Bytes) {
		this.bytes = bytes;
		this.position = 0;
	}

	public inline function atEnd():Bool {
		return position >= bytes.length;
	}

	public inline function remaining():Int {
		return bytes.length - position;
	}

	public function peek():Int {
		if (atEnd()) {
			throw new HpackError("Header block ended mid-field");
		}
		return bytes.get(position);
	}

	public function read():Int {
		var value:Int = peek();
		position++;
		return value;
	}

	public function skip(count:Int):Void {
		if (count > remaining()) {
			throw new HpackError("Header block ended mid-field");
		}
		position += count;
	}
}
