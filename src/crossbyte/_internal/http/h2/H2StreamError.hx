package crossbyte._internal.http.h2;

import crossbyte.errors.Error as CBError;

/**
 * An error confined to one stream (RFC 9113 §5.4.2).
 *
 * The stream is reset with RST_STREAM and the connection carries on. Only
 * faults with no effect on connection-wide state qualify.
 */
class H2StreamError extends CBError {
	public final code:H2ErrorCode;
	public final streamId:Int;

	public function new(streamId:Int, code:H2ErrorCode, message:String) {
		super(message);
		this.streamId = streamId;
		this.code = code;
	}
}
