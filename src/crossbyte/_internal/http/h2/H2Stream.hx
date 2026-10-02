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

	/**
	 * Set when this side gave up on the stream for a reason of its own, a
	 * response whose header section went past the limit, so the caller can
	 * report that rather than a reset or a hang-up.
	 */
	public var failure:Null<String> = null;

	/** How much the peer will still accept from us (§6.9). */
	public var sendWindow:Int;

	/** How much we will still accept, before topping it up. */
	public var recvWindow:Int;

	/** Received but not yet acknowledged with WINDOW_UPDATE. */
	public var unacknowledged:Int = 0;

	/** True once the peer's END_STREAM has been seen. */
	public var endOfStream:Bool = false;

	/**
		True once the request's header section has arrived, on the server: a
		header block after it is the trailer section (RFC 9113 8.1).
	**/
	public var headerSectionReceived:Bool = false;

	/**
	 * Frames the peer has sent this stream: one per header block and one per
	 * DATA frame. Counted rather than timed, so the frame path pays an
	 * increment and not a clock read; a client waiting on the stream reads it
	 * to tell a response still arriving from one that has gone quiet. Only
	 * ever compared for a change, so wrapping is harmless.
	 */
	public var framesIn:Int = 0;

	/**
	 * True once the request body outgrew what the server will hold: the
	 * request has been answered, and its remaining DATA is counted for the
	 * connection's window and otherwise dropped.
	 */
	public var overflowed:Bool = false;

	/**
	 * True once the whole request has been handed to the application, so the
	 * stream is waiting on its answer rather than on the peer.
	 */
	public var delivered:Bool = false;

	/**
		On the server, `haxe.Timer.stamp()` when the request's HEADERS
		arrived: where its `requestTimeout` counts from, and where its
		duration is measured from. Fixed once set, so nothing the peer sends
		after it moves the deadline.
	**/
	public var openedAt:Float = 0;

	/**
		On the server, the request read from a header section whose body is
		still to come, as it was admitted. Delivered once the body ends.
	**/
	public var request:Null<H2ServerRequest> = null;

	/**
		On the server, set once a final response's head has been written on
		this stream: an interim `100` does not count. What a refusal is told
		apart by, answered, or failed before anything went out.
	**/
	public var answered:Bool = false;

	/** Set once the stream has been reset, by either end. */
	public var wasReset:Bool = false;

	/**
		On the server, set for a stream whose request was refused while the
		refusal was still going out, held by flow control: once that has
		ended, the stream is reset NO_ERROR to stop the rest of the body.
	**/
	public var stopBodyAtEnd:Bool = false;

	/**
	 * Response bytes accepted from the application but not yet permitted onto
	 * the wire by flow control.
	 *
	 * RFC 9113 6.9.1 forbids sending a DATA frame longer than the space left in
	 * either window, so a body larger than the peer's window cannot simply be
	 * written, it has to wait here for a WINDOW_UPDATE. A server cannot block
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

	/**
		DATA bytes sent on this stream so far: what a server's stall check
		reads to tell a response its client is taking from one it has stopped
		taking. Counted, not timed, as `framesIn` is; only ever compared for
		a change, so wrapping is harmless.
	**/
	public var dataOut:Int = 0;

	/**
		On the server, `dataOut` as the stall check last saw it, and when the
		response is given up if it is still the same (`0` while the stream is
		not being held to one). See `H2ServerConnection.expireHeld`.
	**/
	public var stallMark:Int = 0;

	public var stallDeadline:Float = 0;

	/**
		Adds `chunk` to what waits on the windows, taking it as it is, not a
		copy, when nothing is waiting: whoever hands a chunk over is done with
		it. The whole queue was copied into a new one for every chunk, so a
		response written as it goes, in small pieces, into a window its
		client keeps shut cost a copy of everything queued per piece,
		quadratic in what it held. It grows to twice what it needs now.
	**/
	public function queue(chunk:Bytes):Void {
		if (chunk == null || chunk.length == 0) {
			return;
		}

		var remaining:Int = queued;
		if (remaining == 0) {
			__queue = chunk;
			__queueOffset = 0;
			__queueLength = chunk.length;
			return;
		}

		if (__queueLength + chunk.length <= __queue.length) {
			// Room after what waits, in a queue of its own making (one taken
			// as it was handed over has none).
			__queue.blit(__queueLength, chunk, 0, chunk.length);
			__queueLength += chunk.length;
			return;
		}

		var needed:Int = remaining + chunk.length;
		var grown:Bytes = Bytes.alloc(needed > 0x3FFFFFFF ? needed : needed * 2);
		grown.blit(0, __queue, __queueOffset, remaining);
		grown.blit(remaining, chunk, 0, chunk.length);

		__queue = grown;
		__queueOffset = 0;
		__queueLength = needed;
	}

	/** Drops whatever waits, for a stream that will send no more. */
	public function dropQueue():Void {
		__queue = null;
		__queueOffset = 0;
		__queueLength = 0;
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

	/**
		A DATA frame of up to `count` queued bytes, `flags` on it, made from the
		queue where they sit: take() cut them out into a Bytes of their own and
		the frame copied them again.
	**/
	public function takeFrame(count:Int, flags:Int):Bytes {
		if (count > queued) {
			count = queued;
		}

		var frame:Bytes = H2Frame.encode(H2FrameType.DATA, flags, id, __queue, __queueOffset, count);
		__queueOffset += count;

		if (__queueOffset >= __queueLength) {
			__queue = null;
			__queueOffset = 0;
			__queueLength = 0;
		}

		return frame;
	}

	public inline function isClosed():Bool {
		return state == CLOSED;
	}

	public function close():Void {
		state = CLOSED;
	}
}
