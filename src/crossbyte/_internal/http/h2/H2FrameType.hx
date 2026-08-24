package crossbyte._internal.http.h2;

/** Frame types (RFC 9113 §6). Values are fixed by the wire format. */
enum abstract H2FrameType(Int) from Int to Int {
	var DATA = 0x0;
	var HEADERS = 0x1;
	var PRIORITY = 0x2;
	var RST_STREAM = 0x3;
	var SETTINGS = 0x4;
	var PUSH_PROMISE = 0x5;
	var PING = 0x6;
	var GOAWAY = 0x7;
	var WINDOW_UPDATE = 0x8;
	var CONTINUATION = 0x9;

	public function toString():String {
		return switch (cast this : H2FrameType) {
			case DATA: "DATA";
			case HEADERS: "HEADERS";
			case PRIORITY: "PRIORITY";
			case RST_STREAM: "RST_STREAM";
			case SETTINGS: "SETTINGS";
			case PUSH_PROMISE: "PUSH_PROMISE";
			case PING: "PING";
			case GOAWAY: "GOAWAY";
			case WINDOW_UPDATE: "WINDOW_UPDATE";
			case CONTINUATION: "CONTINUATION";
			case _: "UNKNOWN(0x" + StringTools.hex(this, 2) + ")";
		}
	}
}
