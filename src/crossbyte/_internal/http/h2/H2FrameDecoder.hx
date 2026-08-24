package crossbyte._internal.http.h2;

import haxe.io.Bytes;

/**
 * Incremental frame decoder.
 *
 * The client connection reads frames with a blocking `Input`, which is fine on
 * a worker thread. A server cannot do that: `HTTPServer` runs every connection
 * on one runtime loop, so a blocking read would stall every other client.
 * This is fed whatever bytes arrive and yields whole frames as they complete,
 * holding the partial remainder until the rest turns up.
 *
 * The buffer only ever holds one frame plus whatever came after it, because
 * `maxFrameSize` bounds a frame and consumed bytes are compacted away.
 */
class H2FrameDecoder {
	/** Frames larger than this are refused rather than buffered. */
	public var maxFrameSize:Int;

	private var __buffer:Bytes;
	private var __length:Int = 0;
	private var __position:Int = 0;

	public function new(maxFrameSize:Int = H2Settings.DEFAULT_MAX_FRAME_SIZE) {
		this.maxFrameSize = maxFrameSize;
		__buffer = Bytes.alloc(H2Frame.HEADER_SIZE + maxFrameSize);
	}

	/** Unconsumed bytes still held. */
	public var buffered(get, never):Int;

	private inline function get_buffered():Int {
		return __length - __position;
	}

	public function feed(source:Bytes, offset:Int = 0, ?length:Int):Void {
		var count:Int = length != null ? length : source.length - offset;
		if (count <= 0) {
			return;
		}

		__compact();
		__reserve(__length + count);
		__buffer.blit(__length, source, offset, count);
		__length += count;
	}

	/**
	 * The next complete frame, or `null` when more bytes are needed.
	 *
	 * Call until it returns `null`: one `feed` may complete several frames,
	 * and a decoder that yielded only the first would stall behind whatever
	 * arrived in the same read.
	 */
	public function next():Null<H2Frame> {
		if (buffered < H2Frame.HEADER_SIZE) {
			return null;
		}

		var length:Int = H2Frame.lengthOf(__buffer, __position);
		if (length > maxFrameSize) {
			// Checked before waiting for the payload. A 24-bit length can ask
			// for 16 MB, and a peer ignoring our SETTINGS could otherwise make
			// us hold that much per connection just to reach the error.
			throw new H2ConnectionError(H2ErrorCode.FRAME_SIZE_ERROR, 'Frame of $length bytes exceeds SETTINGS_MAX_FRAME_SIZE of $maxFrameSize');
		}

		if (buffered < H2Frame.HEADER_SIZE + length) {
			return null;
		}

		var frame:H2Frame = H2Frame.read(__buffer, __position);
		__position += H2Frame.HEADER_SIZE + length;
		return frame;
	}

	/** Drops consumed bytes so the buffer does not grow without bound. */
	private function __compact():Void {
		if (__position == 0) {
			return;
		}

		var remaining:Int = __length - __position;
		if (remaining > 0) {
			__buffer.blit(0, __buffer, __position, remaining);
		}
		__length = remaining;
		__position = 0;
	}

	private function __reserve(capacity:Int):Void {
		if (__buffer.length >= capacity) {
			return;
		}

		var grown:Int = __buffer.length;
		while (grown < capacity) {
			grown *= 2;
		}

		var replacement:Bytes = Bytes.alloc(grown);
		replacement.blit(0, __buffer, 0, __length);
		__buffer = replacement;
	}
}
