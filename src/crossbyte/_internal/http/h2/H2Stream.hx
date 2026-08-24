package crossbyte._internal.http.h2;

import crossbyte._internal.http.h2.hpack.HpackHeader;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;

/**
 * One request/response exchange on a connection.
 *
 * Holds the response as it arrives and the flow-control window in each
 * direction. Windows are per-stream *and* per-connection, and both must permit
 * a write, so this tracks only its own half.
 */
class H2Stream {
	public final id:Int;

	public var state:H2StreamState = IDLE;

	/** Response header fields, populated when the header block completes. */
	public var headers:Array<HpackHeader> = [];

	/** `:status` as an Int, or `-1` until the header block arrives. */
	public var status:Int = -1;

	/** Set when the peer reset this stream, so the caller can report why. */
	public var resetCode:Null<H2ErrorCode> = null;

	/** How much the peer will still accept from us (§6.9). */
	public var sendWindow:Int;

	/** How much we will still accept, before topping it up. */
	public var recvWindow:Int;

	/** Received but not yet acknowledged with WINDOW_UPDATE. */
	public var unacknowledged:Int = 0;

	/** True once the peer's END_STREAM has been seen. */
	public var endOfStream:Bool = false;

	/**
	 * Response bytes accepted from the application but not yet permitted onto
	 * the wire by flow control.
	 *
	 * RFC 9113 6.9.1 forbids sending a DATA frame longer than the space left in
	 * either window, so a body larger than the peer's window cannot simply be
	 * written -- it has to wait here for a WINDOW_UPDATE. A server cannot block
	 * for one, because the runtime loop it would block is the same one that
	 * delivers it.
	 */
	public var pendingEndStream:Bool = false;

	private var __body:BytesBuffer = new BytesBuffer();
	private var __bodyLength:Int = 0;

	private var __queue:Bytes = null;
	private var __queueOffset:Int = 0;
	private var __queueLength:Int = 0;

	public function new(id:Int, sendWindow:Int, recvWindow:Int) {
		this.id = id;
		this.sendWindow = sendWindow;
		this.recvWindow = recvWindow;
	}

	public var bodyLength(get, never):Int;

	private inline function get_bodyLength():Int {
		return __bodyLength;
	}

	public function appendBody(chunk:Bytes):Void {
		if (chunk.length == 0) {
			return;
		}
		__body.addBytes(chunk, 0, chunk.length);
		__bodyLength += chunk.length;
	}

	/**
	 * The accumulated body. Destructive: `BytesBuffer` cannot be read without
	 * being emptied, so this may only be called once, at the end.
	 */
	public function takeBody():Bytes {
		var out:Bytes = __body.getBytes();
		__body = new BytesBuffer();
		__bodyLength = 0;
		return out;
	}

	/** Bytes waiting on a flow-control window. */
	public var queued(get, never):Int;

	private inline function get_queued():Int {
		return __queueLength - __queueOffset;
	}

	public function queue(chunk:Bytes):Void {
		if (chunk == null || chunk.length == 0) {
			return;
		}

		var remaining:Int = queued;
		var grown:Bytes = Bytes.alloc(remaining + chunk.length);
		if (remaining > 0) {
			grown.blit(0, __queue, __queueOffset, remaining);
		}
		grown.blit(remaining, chunk, 0, chunk.length);

		__queue = grown;
		__queueOffset = 0;
		__queueLength = grown.length;
	}

	/** Removes and returns up to `count` queued bytes. */
	public function take(count:Int):Bytes {
		if (count > queued) {
			count = queued;
		}

		var out:Bytes = __queue.sub(__queueOffset, count);
		__queueOffset += count;

		if (__queueOffset >= __queueLength) {
			__queue = null;
			__queueOffset = 0;
			__queueLength = 0;
		}

		return out;
	}

	public inline function isClosed():Bool {
		return state == CLOSED;
	}

	public function close():Void {
		state = CLOSED;
	}
}
