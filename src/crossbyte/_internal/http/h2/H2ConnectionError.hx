package crossbyte._internal.http.h2;

import crossbyte.errors.Error as CBError;

/**
 * An error that takes down the whole connection (RFC 9113 §5.4.1).
 *
 * The peer is told with GOAWAY and the socket closes. Anything that leaves the
 * two endpoints disagreeing about shared state belongs here rather than in
 * `H2StreamError` -- a bad frame header desynchronizes the framing itself, and
 * an HPACK failure desynchronizes the dynamic table, so in neither case can
 * later frames be trusted even on other streams.
 */
class H2ConnectionError extends CBError {
	public final code:H2ErrorCode;

	public function new(code:H2ErrorCode, message:String) {
		super(message);
		this.code = code;
	}
}
