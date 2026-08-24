package crossbyte._internal.http.h2;

/** Stream lifecycle (RFC 9113 §5.1), narrowed to the states a client reaches. */
enum abstract H2StreamState(Int) {
	/** Created locally, request not yet written. */
	var IDLE = 0;

	/** Request sent, response outstanding. */
	var OPEN = 1;

	/** We sent END_STREAM; the peer may still be sending. */
	var HALF_CLOSED_LOCAL = 2;

	/** Finished, whether by END_STREAM or by RST_STREAM. */
	var CLOSED = 3;
}
