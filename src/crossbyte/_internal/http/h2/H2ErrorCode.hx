package crossbyte._internal.http.h2;

/**
 * HTTP/2 error codes (RFC 9113 §7).
 *
 * The numeric values go on the wire in RST_STREAM and GOAWAY, so they are
 * fixed by the spec rather than chosen here.
 */
enum abstract H2ErrorCode(Int) from Int to Int {
	var NO_ERROR = 0x0;
	var PROTOCOL_ERROR = 0x1;
	var INTERNAL_ERROR = 0x2;
	var FLOW_CONTROL_ERROR = 0x3;
	var SETTINGS_TIMEOUT = 0x4;
	var STREAM_CLOSED = 0x5;
	var FRAME_SIZE_ERROR = 0x6;
	var REFUSED_STREAM = 0x7;
	var CANCEL = 0x8;
	var COMPRESSION_ERROR = 0x9;
	var CONNECT_ERROR = 0xa;
	var ENHANCE_YOUR_CALM = 0xb;
	var INADEQUATE_SECURITY = 0xc;
	var HTTP_1_1_REQUIRED = 0xd;

	public function toString():String {
		return switch (cast this : H2ErrorCode) {
			case NO_ERROR: "NO_ERROR";
			case PROTOCOL_ERROR: "PROTOCOL_ERROR";
			case INTERNAL_ERROR: "INTERNAL_ERROR";
			case FLOW_CONTROL_ERROR: "FLOW_CONTROL_ERROR";
			case SETTINGS_TIMEOUT: "SETTINGS_TIMEOUT";
			case STREAM_CLOSED: "STREAM_CLOSED";
			case FRAME_SIZE_ERROR: "FRAME_SIZE_ERROR";
			case REFUSED_STREAM: "REFUSED_STREAM";
			case CANCEL: "CANCEL";
			case COMPRESSION_ERROR: "COMPRESSION_ERROR";
			case CONNECT_ERROR: "CONNECT_ERROR";
			case ENHANCE_YOUR_CALM: "ENHANCE_YOUR_CALM";
			case INADEQUATE_SECURITY: "INADEQUATE_SECURITY";
			case HTTP_1_1_REQUIRED: "HTTP_1_1_REQUIRED";
			// §7: an unknown code is not an error. It must be treated as
			// INTERNAL_ERROR rather than rejected, so a peer on a later
			// revision of the protocol can still close cleanly.
			case _: "UNKNOWN(" + this + ")";
		}
	}
}
