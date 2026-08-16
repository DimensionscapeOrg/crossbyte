package crossbyte.net;

/**
 * What a `Socket` does when its outgoing buffer exceeds
 * `maxOutputBufferSize`.
 */
enum abstract OutputOverflowPolicy(Int) from Int to Int {
	/**
	 * Dispatch `IOErrorEvent.IO_ERROR` (when anyone is listening) and close
	 * the connection.
	 *
	 * The right default for a server: a peer that has stopped reading is
	 * not going to recover on its own, and dropping it reclaims the memory
	 * without every write site needing error handling.
	 */
	var CLOSE:Int = 0;

	/**
	 * Throw `IOError` from `flush()` and leave the connection open.
	 *
	 * For callers that can respond meaningfully — shedding optional
	 * traffic, or pausing a producer until the peer catches up.
	 */
	var THROW:Int = 1;
}
