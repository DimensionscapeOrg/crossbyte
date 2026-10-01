package crossbyte._internal.http.h2.hpack;

import haxe.io.Bytes;

/**
 * One header field.
 *
 * `sensitive` marks a field that must never be entered into the dynamic table
 * and must be re-encoded as never-indexed by any intermediary (RFC 7541 §7.1).
 * It exists to keep a credential out of a table whose entries are inferable
 * from compressed sizes; `Authorization` and short `Cookie` fields are the
 * cases the RFC calls out.
 */
class HpackHeader {
	public final name:String;
	public final value:String;
	public final sensitive:Bool;

	/**
	 * The entry's cost against the dynamic table budget: its two strings plus
	 * the 32-byte overhead RFC 7541 §4.1 assigns to every entry, so a table of
	 * tiny headers cannot hold an unbounded number of them.
	 *
	 * Measured in octets, not in `String.length`. Those differ on any target
	 * whose strings are UTF-16, and a table that measured code units would
	 * evict on a different schedule than the peer encoding against it, which
	 * desynchronizes the two tables and corrupts every later block.
	 */
	public final tableSize:Int;

	public function new(name:String, value:String, sensitive:Bool = false) {
		this.name = name;
		this.value = value;
		this.sensitive = sensitive;
		this.tableSize = __octets(name) + __octets(value) + 32;
	}

	/**
		`Bytes.ofString(text).length`, without making the bytes when `text` is
		ASCII, as nearly every header is, since then it is the length. Both
		strings of every header were encoded only to be measured: on Node, a
		seventh of an HTTP/2 server's time.
	**/
	static function __octets(text:String):Int {
		for (i in 0...text.length) {
			if (StringTools.fastCodeAt(text, i) >= 0x80) {
				return Bytes.ofString(text).length;
			}
		}
		return text.length;
	}

	public function toString():String {
		return name + ": " + value;
	}
}
