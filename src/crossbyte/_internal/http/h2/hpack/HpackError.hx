package crossbyte._internal.http.h2.hpack;

import crossbyte.errors.Error as CBError;

/**
 * A malformed HPACK header block.
 *
 * RFC 7541 §4.2 and §6 make every case here a decoding error, and RFC 9113
 * §4.3 makes a decoding error fatal to the whole connection rather than to one
 * stream: the dynamic table is shared, so a block that failed to decode has
 * left the table in a state the peer no longer agrees with, and every later
 * block on that connection would decode against the wrong entries.
 */
class HpackError extends CBError {
	public function new(message:String) {
		super(message);
	}
}
