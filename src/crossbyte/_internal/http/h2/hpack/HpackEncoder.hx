package crossbyte._internal.http.h2.hpack;

import haxe.io.Bytes;
import haxe.io.BytesBuffer;

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
 */
class HpackEncoder {
	/** Capacity of our dynamic table, mirrored by the peer's decoder. */
	public var capacity(get, never):Int;

	private var __table:HpackDynamicTable;
	private var __pendingCapacity:Int = -1;

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

	/**
	 * Adopts a new table capacity, usually because the peer sent a lower
	 * SETTINGS_HEADER_TABLE_SIZE.
	 *
	 * The change applies to our table now but is only announced at the head of
	 * the next block, since a size update is only legal there. Until that
	 * block is written, the peer still decodes against the old capacity --
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

	public function encode(headers:Array<HpackHeader>):Bytes {
		var out:BytesBuffer = new BytesBuffer();

		if (__pendingCapacity >= 0) {
			// 001xxxxx, 5-bit prefix.
			__writeInteger(out, __pendingCapacity, 5, 0x20);
			__pendingCapacity = -1;
		}

		for (header in headers) {
			__encodeOne(out, header);
		}

		return out.getBytes();
	}

	private function __encodeOne(out:BytesBuffer, header:HpackHeader):Void {
		if (header.sensitive) {
			// §6.2.3 never-indexed, 0001xxxx. Not merely "without indexing":
			// this also forbids an intermediary from indexing it downstream.
			__writeLiteral(out, header, 4, 0x10, false);
			return;
		}

		var staticPair:Int = HpackStaticTable.findPair(header.name, header.value);
		if (staticPair > 0) {
			__writeInteger(out, staticPair, 7, 0x80);
			return;
		}

		var dynamicPair:Int = __table.findPair(header.name, header.value);
		if (dynamicPair >= 0) {
			__writeInteger(out, dynamicPair + HpackStaticTable.LENGTH + 1, 7, 0x80);
			return;
		}

		// §6.2.1 literal with incremental indexing, 01xxxxxx.
		__writeLiteral(out, header, 6, 0x40, true);
		__table.add(header);
	}

	private function __writeLiteral(out:BytesBuffer, header:HpackHeader, prefixBits:Int, pattern:Int, indexed:Bool):Void {
		var nameIndex:Int = HpackStaticTable.findName(header.name);
		if (nameIndex < 0) {
			var dynamicName:Int = __table.findName(header.name);
			if (dynamicName >= 0) {
				nameIndex = dynamicName + HpackStaticTable.LENGTH + 1;
			}
		}

		if (nameIndex > 0) {
			__writeInteger(out, nameIndex, prefixBits, pattern);
		} else {
			// Index 0 means "the name follows as a literal".
			__writeInteger(out, 0, prefixBits, pattern);
			__writeString(out, header.name);
		}

		__writeString(out, header.value);
	}

	private function __writeString(out:BytesBuffer, value:String):Void {
		var raw:Bytes = Bytes.ofString(value);

		// Huffman only when it actually helps. Sending a longer encoding would
		// still be legal, just worse.
		if (HpackHuffman.encodedLength(raw) < raw.length) {
			var coded:Bytes = HpackHuffman.encode(raw);
			__writeInteger(out, coded.length, 7, 0x80);
			out.addBytes(coded, 0, coded.length);
		} else {
			__writeInteger(out, raw.length, 7, 0x00);
			out.addBytes(raw, 0, raw.length);
		}
	}

	/**
	 * §5.1 prefix-coded integer. `pattern` supplies the flag bits above the
	 * prefix and must not overlap it.
	 */
	private function __writeInteger(out:BytesBuffer, value:Int, prefixBits:Int, pattern:Int):Void {
		var mask:Int = (1 << prefixBits) - 1;

		if (value < mask) {
			out.addByte(pattern | value);
			return;
		}

		out.addByte(pattern | mask);

		var remainder:Int = value - mask;
		while (remainder >= 0x80) {
			out.addByte((remainder & 0x7f) | 0x80);
			remainder >>>= 7;
		}
		out.addByte(remainder);
	}
}
