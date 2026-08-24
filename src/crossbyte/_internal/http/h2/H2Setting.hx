package crossbyte._internal.http.h2;

/** Settings identifiers (RFC 9113 §6.5.2). */
enum abstract H2Setting(Int) from Int to Int {
	var HEADER_TABLE_SIZE = 0x1;
	var ENABLE_PUSH = 0x2;
	var MAX_CONCURRENT_STREAMS = 0x3;
	var INITIAL_WINDOW_SIZE = 0x4;
	var MAX_FRAME_SIZE = 0x5;
	var MAX_HEADER_LIST_SIZE = 0x6;
}
