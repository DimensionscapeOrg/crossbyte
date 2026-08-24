package crossbyte._internal.http.h2.hpack;

/**
 * The HPACK dynamic table (RFC 7541 §2.3.2).
 *
 * A FIFO of recently seen headers addressed by index, newest first, continuing
 * where the static table stops: wire index 62 is the newest entry. Insertion
 * evicts from the old end until the new entry fits.
 *
 * Both peers maintain a copy and they must agree exactly. Any divergence -- a
 * missed eviction, a size counted differently -- makes every later block
 * decode into the wrong headers rather than fail cleanly, which is why the
 * decoder treats every table error as fatal to the connection.
 */
class HpackDynamicTable {
	/** Live byte total, by the §4.1 accounting. */
	public var size(default, null):Int = 0;

	/** The cap this table currently evicts against. */
	public var capacity(default, null):Int;

	public var length(get, never):Int;

	// Newest first, so wire index 62 is entry 0 and no arithmetic is needed to
	// find the most recent addition -- the common case for a repeated header.
	private var __entries:Array<HpackHeader>;

	public function new(capacity:Int) {
		this.capacity = capacity;
		__entries = [];
	}

	private inline function get_length():Int {
		return __entries.length;
	}

	/**
	 * Entry at a 0-based position, newest first, or `null` when out of range.
	 */
	public inline function get(index:Int):Null<HpackHeader> {
		return (index < 0 || index >= __entries.length) ? null : __entries[index];
	}

	public function add(header:HpackHeader):Void {
		var entrySize:Int = header.tableSize;

		// §4.4: an entry larger than the whole table is not an error. It
		// empties the table and is then simply not added -- a peer may
		// reference it in the same block, which is why this must not throw.
		if (entrySize > capacity) {
			clear();
			return;
		}

		while (size + entrySize > capacity) {
			__evictOldest();
		}

		__entries.unshift(header);
		size += entrySize;
	}

	/**
	 * Applies a dynamic table size update. The new capacity is chosen by the
	 * encoder but bounded by the decoder's SETTINGS_HEADER_TABLE_SIZE; the
	 * caller checks that bound, because only it knows the setting.
	 */
	public function resize(newCapacity:Int):Void {
		capacity = newCapacity;
		while (size > capacity) {
			__evictOldest();
		}
	}

	public function clear():Void {
		__entries = [];
		size = 0;
	}

	/** 0-based position of an exact name/value match, or `-1`. */
	public function findPair(name:String, value:String):Int {
		for (i in 0...__entries.length) {
			var entry:HpackHeader = __entries[i];
			if (entry.name == name && entry.value == value) {
				return i;
			}
		}
		return -1;
	}

	/** 0-based position of the newest entry with this name, or `-1`. */
	public function findName(name:String):Int {
		for (i in 0...__entries.length) {
			if (__entries[i].name == name) {
				return i;
			}
		}
		return -1;
	}

	private function __evictOldest():Void {
		if (__entries.length == 0) {
			// Cannot happen while size accounting is right, and if it ever is
			// wrong, looping forever here is worse than carrying on with a
			// size of zero.
			size = 0;
			return;
		}

		var removed:HpackHeader = __entries.pop();
		size -= removed.tableSize;
	}
}
