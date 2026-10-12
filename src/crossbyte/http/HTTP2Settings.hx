package crossbyte.http;

import crossbyte._internal.http.h2.H2ConnectionError;
import crossbyte._internal.http.h2.H2ErrorCode;
import crossbyte._internal.http.h2.H2Frame;
import crossbyte._internal.http.h2.H2Setting;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;

/**
	The settings one end of an HTTP/2 connection advertises in its SETTINGS
	frame, each starting at the protocol's default (RFC 9113 section 6.5.2).

	`HTTP2Backend.settings` holds the HTTP client's, sent at the head of
	every connection it makes:

	```haxe
	var settings = new HTTP2Settings();
	settings.initialWindowSize = 1024 * 1024;
	HTTPBackendRegistry.register(new HTTP2Backend(settings));
	```

	A SETTINGS frame carries only the values that differ from the defaults,
	so anything left alone is what a peer assumes anyway.
**/
class HTTP2Settings {
	/** The protocol's `headerTableSize`: 4,096 bytes. **/
	public static inline var DEFAULT_HEADER_TABLE_SIZE:Int = 4096;

	/** The protocol's `initialWindowSize`: 65,535 bytes. **/
	public static inline var DEFAULT_INITIAL_WINDOW_SIZE:Int = 65535;

	/** The protocol's `maxFrameSize`: 16,384 bytes. **/
	public static inline var DEFAULT_MAX_FRAME_SIZE:Int = 16384;

	/** The largest legal flow-control window, and the widest a 31-bit signed increment reaches. **/
	public static inline var MAX_WINDOW_SIZE:Int = 2147483647;

	/**
		The largest HPACK table, in bytes, this end lets its peer's encoder
		use for the headers it sends here. 4,096 unless changed.
	**/
	public var headerTableSize:Int = DEFAULT_HEADER_TABLE_SIZE;

	/**
		Whether this end takes pushed streams. `true` is the protocol's
		default; the HTTP client sends `false`, and refuses a push whatever
		this says.
	**/
	public var enablePush:Bool = true;

	/** The most streams the peer may open at once; `-1`, the default, for no limit (section 6.5.2 sets none). **/
	public var maxConcurrentStreams:Int = -1;

	/** The flow-control window, in bytes, each new stream starts with for what the peer sends: 65,535 unless changed. **/
	public var initialWindowSize:Int = DEFAULT_INITIAL_WINDOW_SIZE;

	/**
		The largest frame payload, in bytes, this end takes: 16,384 to
		16,777,215, and 16,384 unless changed.
	**/
	public var maxFrameSize:Int = DEFAULT_MAX_FRAME_SIZE;

	/** The most header bytes this end takes in one block, as HPACK counts them; `-1`, the default, for no limit. **/
	public var maxHeaderListSize:Int = -1;

	public function new() {}

	/**
	 * Serializes the values that differ from the defaults, which is all a peer
	 * needs and all §6.5 requires.
	 */
	@:allow(crossbyte._internal.http.h2)
	private function toPayload():Bytes {
		var out:BytesBuffer = new BytesBuffer();

		if (headerTableSize != DEFAULT_HEADER_TABLE_SIZE) {
			__write(out, H2Setting.HEADER_TABLE_SIZE, headerTableSize);
		}
		if (!enablePush) {
			__write(out, H2Setting.ENABLE_PUSH, 0);
		}
		if (maxConcurrentStreams >= 0) {
			__write(out, H2Setting.MAX_CONCURRENT_STREAMS, maxConcurrentStreams);
		}
		if (initialWindowSize != DEFAULT_INITIAL_WINDOW_SIZE) {
			__write(out, H2Setting.INITIAL_WINDOW_SIZE, initialWindowSize);
		}
		if (maxFrameSize != DEFAULT_MAX_FRAME_SIZE) {
			__write(out, H2Setting.MAX_FRAME_SIZE, maxFrameSize);
		}
		if (maxHeaderListSize >= 0) {
			__write(out, H2Setting.MAX_HEADER_LIST_SIZE, maxHeaderListSize);
		}

		return out.getBytes();
	}

	/**
	 * Applies a received SETTINGS payload, returning the previous
	 * INITIAL_WINDOW_SIZE so the caller can adjust every open stream's window
	 * by the delta, as §6.9.2 requires.
	 *
	 * Unknown identifiers are skipped rather than rejected: §6.5.2 requires a
	 * receiver to ignore them, which is what lets the protocol be extended.
	 */
	@:allow(crossbyte._internal.http.h2)
	private function applyPayload(payload:Bytes):Int {
		if (payload.length % 6 != 0) {
			throw new H2ConnectionError(H2ErrorCode.FRAME_SIZE_ERROR, 'SETTINGS payload of ${payload.length} bytes is not a multiple of 6');
		}

		var previousWindow:Int = initialWindowSize;
		var offset:Int = 0;

		while (offset < payload.length) {
			var id:Int = (payload.get(offset) << 8) | payload.get(offset + 1);
			var value:Int = __readUInt32(payload, offset + 2);
			offset += 6;

			switch ((id : H2Setting)) {
				case HEADER_TABLE_SIZE:
					headerTableSize = value;

				case ENABLE_PUSH:
					if (value != 0 && value != 1) {
						throw new H2ConnectionError(H2ErrorCode.PROTOCOL_ERROR, 'ENABLE_PUSH must be 0 or 1, got $value');
					}
					enablePush = value == 1;

				case MAX_CONCURRENT_STREAMS:
					maxConcurrentStreams = value;

				case INITIAL_WINDOW_SIZE:
					// §6.5.2: above 2^31-1 is a flow-control error, not a
					// protocol error, and the distinction is observable.
					if (value < 0 || value > MAX_WINDOW_SIZE) {
						throw new H2ConnectionError(H2ErrorCode.FLOW_CONTROL_ERROR, 'INITIAL_WINDOW_SIZE $value is above the maximum window');
					}
					initialWindowSize = value;

				case MAX_FRAME_SIZE:
					if (value < H2Frame.MIN_MAX_FRAME_SIZE || value > H2Frame.MAX_MAX_FRAME_SIZE) {
						throw new H2ConnectionError(H2ErrorCode.PROTOCOL_ERROR, 'MAX_FRAME_SIZE $value is outside the permitted range');
					}
					maxFrameSize = value;

				case MAX_HEADER_LIST_SIZE:
					maxHeaderListSize = value;

				case _:
					// Ignored on purpose, per §6.5.2.
			}
		}

		return previousWindow;
	}

	private static inline function __write(out:BytesBuffer, id:H2Setting, value:Int):Void {
		out.addByte(((cast id : Int) >> 8) & 0xff);
		out.addByte((cast id : Int) & 0xff);
		out.addByte((value >> 24) & 0xff);
		out.addByte((value >> 16) & 0xff);
		out.addByte((value >> 8) & 0xff);
		out.addByte(value & 0xff);
	}

	/**
	 * A settings value is an unsigned 32-bit integer, which does not fit a
	 * signed Int. Anything with the high bit set is returned negative and the
	 * callers above reject it where the spec bounds the value; the two that do
	 * not bound it (table size, header list size) are clamped by their own
	 * consumers.
	 */
	private static inline function __readUInt32(payload:Bytes, offset:Int):Int {
		return (payload.get(offset) << 24) | (payload.get(offset + 1) << 16) | (payload.get(offset + 2) << 8) | payload.get(offset + 3);
	}
}
