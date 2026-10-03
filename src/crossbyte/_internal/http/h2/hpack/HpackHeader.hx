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
	public var tableSize(get, never):Int;

	// Measured when first asked for: a field the encoder finds in a table,
	// as most response fields are after the first response, never is.
	private var __tableSize:Int = -1;

	/**
		Set once the field has been found well-formed (RFC 9113 8.2.1) on a
		request: a field the decoder hands out again from its table, a
		browser's same User-Agent and Accept on every request, is not read
		character by character again. The check reads only the two strings,
		so its answer holds for the field's life.
	**/
	public var lawful:Bool = false;

	public function new(name:String, value:String, sensitive:Bool = false) {
		this.name = name;
		this.value = value;
		this.sensitive = sensitive;
	}

	private inline function get_tableSize():Int {
		if (__tableSize < 0) {
			__tableSize = __octets(name) + __octets(value) + 32;
		}
		return __tableSize;
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
