package crossbyte._internal.http.h2;

import haxe.io.Bytes;
import haxe.io.BytesBuffer;

/**
 * One endpoint's settings, with the protocol defaults from RFC 9113 §6.5.2.
 *
 * A SETTINGS frame carries only the values a peer wants changed, so anything
 * absent keeps the default -- which makes the defaults part of the wire
 * contract rather than a local convenience.
 */
class H2Settings {
	public static inline var DEFAULT_HEADER_TABLE_SIZE:Int = 4096;
	public static inline var DEFAULT_INITIAL_WINDOW_SIZE:Int = 65535;
	public static inline var DEFAULT_MAX_FRAME_SIZE:Int = 16384;

	/** The largest legal flow-control window, and the widest a 31-bit signed increment reaches. */
	public static inline var MAX_WINDOW_SIZE:Int = 2147483647;

	public var headerTableSize:Int = DEFAULT_HEADER_TABLE_SIZE;
	public var enablePush:Bool = true;
	/** `-1` means unlimited, which is the default: §6.5.2 sets no initial cap. */
	public var maxConcurrentStreams:Int = -1;
	public var initialWindowSize:Int = DEFAULT_INITIAL_WINDOW_SIZE;
	public var maxFrameSize:Int = DEFAULT_MAX_FRAME_SIZE;
	/** `-1` means unlimited. */
	public var maxHeaderListSize:Int = -1;

	public function new() {}

	/**
	 * Serializes the values that differ from the defaults, which is all a peer
	 * needs and all §6.5 requires.
	 */
	public function toPayload():Bytes {
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
	public function applyPayload(payload:Bytes):Int {
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
