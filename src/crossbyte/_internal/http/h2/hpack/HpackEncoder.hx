package crossbyte._internal.http.h2.hpack;

import haxe.io.Bytes;

/**
 * HPACK encoder (RFC 7541 §6).
 *
 * One instance per connection per direction, paired with the peer's decoder.
 *
 * The strategy is the conservative one: name/value pairs already in either
 * table are sent as a single index, anything else is sent as a literal and
 * indexed for next time. Sensitive fields are never indexed at all, so a
 * credential cannot be recovered from the compressed size of a later request
 * that reuses it.
 *
 * A block is built in a buffer the encoder keeps (`begin`, `add` or `field`
 * for each field, then `block` and `blockLength`), good until the next
 * `begin`: a writer that copies it into its frames straight away makes
 * nothing per block. `encode` builds one and returns a copy of its own.
 */
class HpackEncoder {
	/** Capacity of our dynamic table, mirrored by the peer's decoder. */
	public var capacity(get, never):Int;

	private var __table:HpackDynamicTable;
	private var __pendingCapacity:Int = -1;

	// The block being built, and how much of it there is.
	private var __out:Bytes = Bytes.alloc(256);
	private var __outLength:Int = 0;

	public function new(capacity:Int = 4096) {
		__table = new HpackDynamicTable(capacity);
	}

	private inline function get_capacity():Int {
		return __table.capacity;
	}

	public var tableSize(get, never):Int;

	private inline function get_tableSize():Int {
		return __table.size;
	}

	/** The block built since `begin`, from its first byte: `blockLength` of it. **/
	public var block(get, never):Bytes;

	private inline function get_block():Bytes {
		return __out;
	}

	public var blockLength(get, never):Int;

	private inline function get_blockLength():Int {
		return __outLength;
	}

	/**
	 * Adopts a new table capacity, usually because the peer sent a lower
	 * SETTINGS_HEADER_TABLE_SIZE.
	 *
	 * The change applies to our table now but is only announced at the head of
	 * the next block, since a size update is only legal there. Until that
	 * block is written, the peer still decodes against the old capacity,
	 * which is safe in this direction, because shrinking early only means we
	 * reference fewer entries than the peer still holds.
	 */
	public function setCapacity(value:Int):Void {
		if (value == __table.capacity && __pendingCapacity < 0) {
			return;
		}
		__table.resize(value);
		__pendingCapacity = value;
	}

	/**
		`headers` as a header block, after `first` when one is given (a
		response's `:status`, which must lead, RFC 9113 8.3.2), so the
		caller need not build a list with it at the front.
	**/
	public function encode(headers:Array<HpackHeader>, ?first:HpackHeader):Bytes {
		begin();

		if (first != null) {
			add(first);
		}

		for (header in headers) {
			add(header);
		}

		return __out.sub(0, __outLength);
	}

	/** Starts a block, with the table size update owed to the peer, if one is. **/
	public function begin():Void {
		__outLength = 0;
		if (__pendingCapacity >= 0) {
			// 001xxxxx, 5-bit prefix.
			__writeInteger(__pendingCapacity, 5, 0x20);
			__pendingCapacity = -1;
		}
	}

	/** Adds `header` to the block. **/
	public function add(header:HpackHeader):Void {
		if (header.sensitive) {
			__writeLiteral(header.name, header.value, 4, 0x10);
			return;
		}
		if (__indexed(header.name, header.value)) {
			return;
		}
		// §6.2.1 literal with incremental indexing, 01xxxxxx.
		__writeLiteral(header.name, header.value, 6, 0x40);
		__table.add(header);
	}

	/**
		Adds the field `name: value` to the block, as `add` does, with no
		`HpackHeader` made for it unless it goes into the dynamic table: a
		field already in a table, as a response's are after the first, costs
		nothing.
	**/
	public function field(name:String, value:String, sensitive:Bool):Void {
		if (sensitive) {
			// §6.2.3 never-indexed, 0001xxxx. Not merely "without indexing":
			// this also forbids an intermediary from indexing it downstream.
			__writeLiteral(name, value, 4, 0x10);
			return;
		}
		if (__indexed(name, value)) {
			return;
		}
		__writeLiteral(name, value, 6, 0x40);
		__table.add(new HpackHeader(name, value));
	}

	/** Writes the pair as one index when a table has it, and says whether it did. **/
	private function __indexed(name:String, value:String):Bool {
		var staticPair:Int = HpackStaticTable.findPair(name, value);
		if (staticPair > 0) {
			__writeInteger(staticPair, 7, 0x80);
			return true;
		}

		var dynamicPair:Int = __table.findPair(name, value);
		if (dynamicPair >= 0) {
			__writeInteger(dynamicPair + HpackStaticTable.LENGTH + 1, 7, 0x80);
			return true;
		}
		return false;
	}

	private function __writeLiteral(name:String, value:String, prefixBits:Int, pattern:Int):Void {
		var nameIndex:Int = HpackStaticTable.findName(name);
		if (nameIndex < 0) {
			var dynamicName:Int = __table.findName(name);
			if (dynamicName >= 0) {
				nameIndex = dynamicName + HpackStaticTable.LENGTH + 1;
			}
		}

		if (nameIndex > 0) {
			__writeInteger(nameIndex, prefixBits, pattern);
		} else {
			// Index 0 means "the name follows as a literal".
			__writeInteger(0, prefixBits, pattern);
			__writeString(name);
		}

		__writeString(value);
	}

	private function __writeString(value:String):Void {
		var raw:Bytes = Bytes.ofString(value);

		// Huffman only when it actually helps. Sending a longer encoding would
		// still be legal, just worse.
		if (HpackHuffman.encodedLength(raw) < raw.length) {
			var coded:Bytes = HpackHuffman.encode(raw);
			__writeInteger(coded.length, 7, 0x80);
			__writeBytes(coded);
		} else {
			__writeInteger(raw.length, 7, 0x00);
			__writeBytes(raw);
		}
	}

	/**
	 * §5.1 prefix-coded integer. `pattern` supplies the flag bits above the
	 * prefix and must not overlap it.
	 */
	private function __writeInteger(value:Int, prefixBits:Int, pattern:Int):Void {
		var mask:Int = (1 << prefixBits) - 1;

		if (value < mask) {
			__writeByte(pattern | value);
			return;
		}

		__writeByte(pattern | mask);

		var remainder:Int = value - mask;
		while (remainder >= 0x80) {
			__writeByte((remainder & 0x7f) | 0x80);
			remainder >>>= 7;
		}
		__writeByte(remainder);
	}

	private inline function __writeByte(value:Int):Void {
		if (__outLength >= __out.length) {
			__grow(1);
		}
		__out.set(__outLength++, value);
	}

	private function __writeBytes(bytes:Bytes):Void {
		if (__outLength + bytes.length > __out.length) {
			__grow(bytes.length);
		}
		__out.blit(__outLength, bytes, 0, bytes.length);
		__outLength += bytes.length;
	}

	private function __grow(more:Int):Void {
		var size:Int = __out.length * 2;
		while (size < __outLength + more) {
			size *= 2;
		}
		var grown:Bytes = Bytes.alloc(size);
		grown.blit(0, __out, 0, __outLength);
		__out = grown;
	}
}
