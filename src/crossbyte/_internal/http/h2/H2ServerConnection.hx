package crossbyte._internal.http.h2;

import crossbyte._internal.http.h2.hpack.HpackDecoder;
import crossbyte._internal.http.h2.hpack.HpackEncoder;
import crossbyte._internal.http.h2.hpack.HpackError;
import crossbyte._internal.http.h2.hpack.HpackHeader;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;

/**
 * The server half of an HTTP/2 connection.
 *
 * Push-driven: bytes go in through `receive()` as they arrive and completed
 * requests come out through `onRequest`. Nothing here blocks, because
 * `HTTPServer` runs every connection on one runtime loop and a blocking read
 * would stall all of them.
 *
 * Written as its own class rather than a role flag on `H2Connection`. The two
 * share the frame vocabulary but almost none of their behaviour: a client
 * writes the preface and this validates it, a client opens streams and this
 * accepts them, and the flow-control and header-validation rules run in
 * opposite directions. `H2Connection` could be moved onto `H2FrameDecoder`
 * later to share the framing; nothing above that layer would collapse
 * usefully.
 *
 * Errors follow the split in §5.4. A malformed *message* is a stream error, so
 * the offending stream is reset and the connection carries on. Anything that
 * desynchronizes shared state, framing, or the HPACK table, is a
 * connection error and takes everything down, because no later frame on any
 * stream could be trusted.
 */
class H2ServerConnection {
	/**
	 * Concurrent streams a client may have open on one connection.
	 *
	 * A ceiling on what one peer can make this process hold at once. The value
	 * is a common one; what matters is that there is one.
	 */
	public static inline var DEFAULT_MAX_CONCURRENT_STREAMS:Int = 128;

	/** Streams abandoned before their response, per window, before this gives up. */
	public static inline var DEFAULT_MAX_RESET_STREAMS:Int = 200;

	/** Seconds the reset budget is measured over. */
	public static inline var DEFAULT_RESET_WINDOW:Float = 30.0;

	/** Replies the peer may oblige, per window, before this gives up. */
	public static inline var DEFAULT_MAX_CONTROL_REPLIES:Int = 100;

	/** Compressed bytes one header block may span, across every CONTINUATION. */
	public static inline var DEFAULT_MAX_HEADER_BLOCK:Int = 256 * 1024;

	/**
	 * What one request's header section may decode to, by RFC 7541 4.1's
	 * accounting (each field's two strings and 32 more), before it is
	 * answered `431`. Advertised as SETTINGS_MAX_HEADER_LIST_SIZE.
	 *
	 * The limit an HTTP/1.1 request's header block is held to. The decoder
	 * allowed eight megabytes and nothing said so, and a block of 200,000
	 * one-byte references to a single cookie crumb, about 200 KB on the
	 * wire, decoded under it and then held the runtime's thread for 23.5
	 * seconds while the crumbs were joined.
	 */
	public static inline var DEFAULT_MAX_HEADER_LIST_SIZE:Int = 64 * 1024;

	/**
	 * Streams the peer may abandon before their response within
	 * `resetWindowSeconds`, after which the connection is closed with
	 * ENHANCE_YOUR_CALM. Negative disables the check.
	 *
	 * This is the Rapid Reset defence (CVE-2023-44487), and it exists because
	 * SETTINGS_MAX_CONCURRENT_STREAMS does not provide one: a stream that is
	 * reset is closed, so it frees its slot immediately. A peer that opens a
	 * stream and resets it at once therefore never approaches the limit while
	 * still making the server do the work of every request, routing,
	 * allocation, a handler each, without bound. Counting the abandonments
	 * is what the concurrency limit cannot see.
	 */
	public var maxResetStreams:Int = DEFAULT_MAX_RESET_STREAMS;

	public var resetWindowSeconds:Float = DEFAULT_RESET_WINDOW;

	/**
	 * Compressed bytes a single header block may occupy across all of its
	 * CONTINUATION frames. Negative disables the check.
	 *
	 * SETTINGS_MAX_FRAME_SIZE bounds each frame and nothing bounded the run:
	 * a peer could send a HEADERS without END_HEADERS and then CONTINUATION
	 * frames forever, and every one of them was appended to a buffer that only
	 * grew. SETTINGS_MAX_HEADER_LIST_SIZE does not help either, it limits
	 * what the block decodes to, and this never reaches the decoder.
	 */
	public var maxHeaderBlockSize:Int = DEFAULT_MAX_HEADER_BLOCK;

	/**
	 * PING and SETTINGS frames the peer may oblige a reply to within
	 * `resetWindowSeconds`, after which the connection is closed with
	 * ENHANCE_YOUR_CALM. Negative disables the check.
	 *
	 * Both are answered the moment they arrive, 6.5.3 requires a SETTINGS
	 * ACK and 6.7 a PING ACK, so a peer sending them faster than this side
	 * drains its socket grows the outgoing buffer with nothing to stop it.
	 * Neither frame opens a stream, so none of the limits above can see it:
	 * MAX_CONCURRENT_STREAMS counts streams, the reset budget counts
	 * abandoned ones, and a flood of these opens none. This is the settings
	 * and ping flood pair, CVE-2019-9515 and CVE-2019-9512.
	 *
	 * The budget shares `resetWindowSeconds` rather than adding a second
	 * window to tune; both measure the same thing, a peer asking for more
	 * work than a conversation needs.
	 */
	public var maxControlReplies:Int = DEFAULT_MAX_CONTROL_REPLIES;

	/**
	 * Bytes one request body may reach before the request is refused.
	 * Negative disables the check.
	 *
	 * DATA was appended with no limit while window kept being granted, so one
	 * stream could make the server hold as much as it cared to send: a 3 MB
	 * upload reached a route the HTTP/1.1 path would have refused. Past this,
	 * the request is delivered at once with `tooLarge` set and no body, so it
	 * can be answered `413`; the stream is then reset with NO_ERROR, which is
	 * §8.1's way of asking a client to stop sending, its window is never
	 * topped up again, and what still arrives is counted for the connection's
	 * window and dropped.
	 */
	public var maxRequestBodySize:Int = -1;

	/**
	 * Streams this connection takes before it says it will take no more, or
	 * `0` and below for no limit. The stream that reaches it is answered as
	 * any other; a GOAWAY naming it goes out as it opens, any the peer opens
	 * after are refused with REFUSED_STREAM, which tells it they are safe to
	 * send elsewhere, and `onDrained` is called once the last open one ends.
	 *
	 * `HTTPServerConfig.keepAliveMaxRequests`, and `1` for `keepAlive` off:
	 * HTTP/2 took no notice of either, so a connection lived for as long as
	 * its client kept it.
	 */
	public var maxRequests:Int = 0;

	/** Called once per complete request. */
	public var onRequest:H2ServerRequest->Void = _ -> {};

	/**
	 * Called when a request's header section has arrived and its body has
	 * not, so it can be refused before the body is sent: answered, and
	 * `false` returned. The stream is then reset with NO_ERROR, which asks the
	 * client to stop sending it, as for a body past `maxRequestBodySize`.
	 * `true` lets the body come, and the request reaches `onRequest` once it
	 * has, carrying whatever this put in its `context`.
	 *
	 * HTTP/1.1 refuses a request on its headers, too large by its
	 * `Content-Length`, or turned away by `Expect: 100-continue`, before a
	 * byte of the body is read. HTTP/2 had no such moment: a request was seen
	 * only once its body was in.
	 */
	public var onRequestHead:H2ServerRequest->Bool = _ -> true;

	/**
	 * Called once the connection is going away and the last stream it let
	 * finish has ended, so its owner can close it. Called from inside
	 * whatever ended that stream, a response's last write, a reset, so
	 * the owner closes it later rather than there.
	 */
	public var onDrained:Void->Void = () -> {};

	/**
	 * `haxe.Timer.stamp()` when the connection last had no stream open: when
	 * it was made, or when the last open stream ended. Only streams count.
	 * A PING, a SETTINGS or a WINDOW_UPDATE asks nothing of the server, and a
	 * peer sending only those is as idle as one sending nothing; counting
	 * them let one hold a connection past its idle allowance for as long as
	 * it kept pinging.
	 */
	public var idleSince(default, null):Float;

	/** Called when the connection fails fatally; the caller closes the socket. */
	public var onConnectionError:H2ConnectionError->Void = _ -> {};

	public final localSettings:H2Settings;
	public final remoteSettings:H2Settings;

	/** True once a GOAWAY has been written and the connection is finished. */
	public var closed(default, null):Bool = false;

	/** Streams open right now, which is what makes a connection busy rather than idle. */
	public var openStreams(get, never):Int;

	/**
	 * Open streams whose request is still arriving. The rest have been handed
	 * to the application and wait on its answer, however long that takes.
	 */
	public var receivingStreams(get, never):Int;

	private final __write:Bytes->Void;
	private final __decoder:HpackDecoder;
	private final __encoder:HpackEncoder;
	private final __frames:H2FrameDecoder;
	private final __streams:Map<Int, H2Stream>;
	private final __writable:Map<Int, Void->Void>;
	private final __abandoned:Map<Int, Void->Void>;

	private var __prefaceRemaining:Int;
	private var __settingsSent:Bool = false;
	private var __highestStreamId:Int = 0;
	private var __connectionSendWindow:Int;
	private var __connectionUnacknowledged:Int = 0;
	private var __openStreams:Int = 0;
	// Every stream opened, for maxRequests.
	private var __streamsTaken:Int = 0;
	// Open streams already delivered: `openStreams - receivingStreams`.
	private var __answering:Int = 0;
	private var __resetCount:Int = 0;
	private var __resetWindowStart:Float = -1;
	private var __controlReplyCount:Int = 0;
	private var __controlReplyWindowStart:Float = -1;

	// A header block spans HEADERS plus any CONTINUATION frames, and §6.10
	// forbids any other frame in between, on any stream.
	private var __continuationStreamId:Int = -1;
	private var __continuationEndsStream:Bool = false;
	private var __continuationRefusal:Null<H2ErrorCode> = null;
	private var __continuationBuffer:BytesBuffer = null;
	private var __continuationLength:Int = 0;

	// Set by goAwayGracefully: streams already open run to their end, and any
	// the peer opens after it are refused. The id is the last stream the GOAWAY
	// promised to process, which a later final GOAWAY must not raise.
	private var __goingAway:Bool = false;
	private var __goAwayLastStreamId:Int = 0;

	/**
	 * @param write Sink for outbound bytes. A function rather than an
	 *        `Output` so a caller can hand over a non-blocking socket's
	 *        buffered write without this needing to know about it.
	 */
	public function new(write:Bytes->Void, ?settings:H2Settings) {
		__write = write;
		localSettings = settings != null ? settings : __defaultSettings();
		remoteSettings = new H2Settings();

		__decoder = new HpackDecoder(localSettings.headerTableSize,
			localSettings.maxHeaderListSize >= 0 ? localSettings.maxHeaderListSize : 8 * 1024 * 1024);
		__encoder = new HpackEncoder(remoteSettings.headerTableSize);
		__frames = new H2FrameDecoder(localSettings.maxFrameSize);
		__streams = new Map();
		__writable = new Map();
		__abandoned = new Map();

		__prefaceRemaining = H2Connection.PREFACE.length;
		__connectionSendWindow = H2Settings.DEFAULT_INITIAL_WINDOW_SIZE;
		idleSince = haxe.Timer.stamp();
	}

	private inline function get_openStreams():Int {
		return __openStreams;
	}

	private inline function get_receivingStreams():Int {
		return __openStreams - __answering;
	}

	/** Marks a stream's request handed over, before the handler can answer it. */
	private inline function __markDelivered(target:H2Stream):Void {
		if (!target.delivered) {
			target.delivered = true;
			__answering++;
		}
	}

	/**
	 * Feeds inbound bytes. Safe to call with any split: the preface and every
	 * frame are reassembled across calls.
	 */
	public function receive(source:Bytes, offset:Int = 0, ?length:Int):Void {
		if (closed) {
			return;
		}

		var count:Int = length != null ? length : source.length - offset;

		try {
			if (__prefaceRemaining > 0) {
				var taken:Int = __consumePreface(source, offset, count);
				offset += taken;
				count -= taken;
				if (__prefaceRemaining > 0) {
					return;
				}
			}

			if (count > 0) {
				__frames.feed(source, offset, count);
			}

			// Drained fully: one read can complete several frames, and
			// stopping at the first would leave the rest until more bytes
			// happened to arrive, which, for the last request on a
			// connection, is never.
			var frame:Null<H2Frame> = __frames.next();
			while (frame != null) {
				__dispatch(frame);
				if (closed) {
					return;
				}
				frame = __frames.next();
			}
		} catch (e:H2ConnectionError) {
			__fail(e);
		} catch (e:HpackError) {
			// §4.3: the dynamic table is shared, so a decoding failure leaves
			// both ends disagreeing about every later block.
			__fail(new H2ConnectionError(H2ErrorCode.COMPRESSION_ERROR, "HPACK decoding failed: " + e.message));
		}
	}

	/**
	 * Sends a complete response and closes the stream.
	 *
	 * `status` becomes the `:status` pseudo-header, which §8.3.2 requires to
	 * come first and to be the only pseudo-header on a response.
	 */
	public function respond(streamId:Int, status:Int, headers:Array<HpackHeader>, ?body:Bytes):Void {
		if (closed) {
			return;
		}

		var target:Null<H2Stream> = __streams.get(streamId);
		if (target == null || target.isClosed()) {
			// The peer reset it, or it was never opened. Writing anyway would
			// be a frame on a closed stream.
			return;
		}

		var hasBody:Bool = body != null && body.length > 0;
		sendHeaders(streamId, status, headers, !hasBody);

		if (hasBody) {
			sendData(streamId, body, true);
		}
	}

	/**
	 * Writes the response header block.
	 *
	 * Separate from `sendData` so a caller streaming a body can send the head
	 * first and the body in pieces, which is the shape `HTTPRequestHandler`
	 * needs: it writes a head, then pumps a file in bounded slices.
	 */
	public function sendHeaders(streamId:Int, status:Int, headers:Array<HpackHeader>, endStream:Bool):Void {
		if (closed) {
			return;
		}

		var target:Null<H2Stream> = __streams.get(streamId);
		if (target == null || target.isClosed()) {
			return;
		}

		// §8.3.2: :status comes first and is the only pseudo-header on a
		// response.
		var block:Array<HpackHeader> = [new HpackHeader(":status", Std.string(status))];
		for (header in headers) {
			block.push(header);
		}

		__writeHeaderBlock(streamId, __encoder.encode(block), endStream);

		if (endStream) {
			// Through __finishStream, which releases the stream's concurrency
			// slot. This removed the stream from the map without it, so every
			// response with no body, a 204, a 304, any HEAD, kept its slot
			// for good, and a connection that had answered 128 of them refused
			// every stream after.
			__finishStream(target);
		}
	}

	/**
	 * Offers body bytes, closing the stream when `endStream` is set.
	 *
	 * Whatever flow control permits goes out now; the rest waits for a
	 * WINDOW_UPDATE. So this returning does not mean the bytes were sent, only
	 * that they were accepted, `queuedFor` is how a caller applying
	 * backpressure finds out the difference.
	 */
	public function sendData(streamId:Int, body:Null<Bytes>, endStream:Bool):Void {
		if (closed) {
			return;
		}

		var target:Null<H2Stream> = __streams.get(streamId);
		if (target == null || target.isClosed()) {
			return;
		}

		target.queue(body);
		if (endStream) {
			target.pendingEndStream = true;
		}

		__flushStream(target);
	}

	/** Bytes accepted for this stream that flow control has not yet released. */
	public function queuedFor(streamId:Int):Int {
		var target:Null<H2Stream> = __streams.get(streamId);
		return target == null ? 0 : target.queued;
	}

	/**
	 * Registers a callback for when this stream can take more bytes.
	 *
	 * A writer feeding a large body needs to know when to resume, and neither
	 * the socket draining nor a timer answers that: the gate is a
	 * WINDOW_UPDATE from the peer. Passing `null` clears it.
	 */
	public function setWritableCallback(streamId:Int, callback:Null<Void->Void>):Void {
		if (callback == null) {
			__writable.remove(streamId);
		} else {
			__writable.set(streamId, callback);
		}
	}

	/**
	 * Calls `callback` if the peer resets `streamId` before it ends: the
	 * client abandoning a response, which a producer writing one as it goes
	 * has to hear about. Dropped, uncalled, when the stream ends normally.
	 */
	public function setAbandonedCallback(streamId:Int, callback:Null<Void->Void>):Void {
		if (callback == null) {
			__abandoned.remove(streamId);
		} else if (__streams.exists(streamId)) {
			__abandoned.set(streamId, callback);
		}
	}

	/** Whether `streamId` is still open, neither ended nor reset. */
	public inline function hasStream(streamId:Int):Bool {
		return __streams.exists(streamId);
	}

	/**
	 * Re-offers every blocked stream, then tells each it may write more.
	 *
	 * Called when the socket drains as well as when a window opens: the two
	 * are different reasons a stream might be stuck, and a caller watching
	 * only one of them stalls on the other.
	 */
	public function notifyWritable():Void {
		for (target in __streams) {
			if (target.queued > 0 || target.pendingEndStream) {
				__flushStream(target);
			}
		}

		for (streamId in __writable.keys()) {
			var callback:Null<Void->Void> = __writable.get(streamId);
			if (callback != null) {
				callback();
			}
		}
	}

	/**
	 * Writes as much of a stream's queue as both windows allow.
	 *
	 * Bounded by three things at once: the peer's frame size, the stream
	 * window and the connection window. Missing any one of them is a
	 * FLOW_CONTROL_ERROR from a conforming peer rather than a slow transfer.
	 */
	private function __flushStream(target:H2Stream):Void {
		if (target.isClosed()) {
			return;
		}

		var limit:Int = remoteSettings.maxFrameSize;

		while (target.queued > 0) {
			var allowed:Int = target.sendWindow < __connectionSendWindow ? target.sendWindow : __connectionSendWindow;
			if (allowed <= 0) {
				// Blocked. The remainder stays queued until a WINDOW_UPDATE
				// brings us back through notifyWritable.
				return;
			}

			var chunk:Int = target.queued;
			if (chunk > limit) {
				chunk = limit;
			}
			if (chunk > allowed) {
				chunk = allowed;
			}

			var last:Bool = target.queued == chunk && target.pendingEndStream;

			__write(target.takeFrame(chunk, last ? H2Flags.END_STREAM : 0));
			target.sendWindow -= chunk;
			__connectionSendWindow -= chunk;

			if (last) {
				__finishStream(target);
				return;
			}
		}

		if (target.pendingEndStream) {
			// Nothing left to send but the stream still has to end. An empty
			// DATA costs no flow control, so this can never be blocked.
			__writeFrame(H2FrameType.DATA, H2Flags.END_STREAM, target.id, Bytes.alloc(0));
			__finishStream(target);
		}
	}

	private function __finishStream(target:H2Stream):Void {
		target.close();
		__forget(target.id);
		__writable.remove(target.id);
	}

	/**
	 * Drops a stream and releases its slot.
	 *
	 * Counted rather than derived from the map, which has no size, and routed
	 * through one place because a removal that forgets to decrement makes the
	 * concurrency limit tighten permanently, a connection that serves fewer
	 * and fewer requests until it serves none.
	 */
	private function __forget(streamId:Int):Void {
		var target:Null<H2Stream> = __streams.get(streamId);
		if (target != null && __streams.remove(streamId)) {
			__openStreams--;
			if (target.delivered) {
				__answering--;
			}
			__abandoned.remove(streamId);

			if (__openStreams == 0) {
				// Between requests from here, which is what the idle
				// allowance measures.
				idleSince = haxe.Timer.stamp();
				if (__goingAway) {
					onDrained();
				}
			}
		}
	}

	/**
	 * Answers every request whose HEADERS arrived at or before `cutoff` and
	 * whose body has still not all arrived: each is delivered marked
	 * `timedOut`, with no body, to be answered `408`, and its stream is then
	 * reset with NO_ERROR to stop the rest of it. The connection and its
	 * other streams carry on.
	 *
	 * The deadline is the stream's own, fixed when it opened. The connection
	 * had one clock, which every frame read or written set back, so a client
	 * sending a byte of body every 0.4 s held a request open under a
	 * `requestTimeout` of one second for as long as it liked, where HTTP/1.1
	 * answered it 408.
	 *
	 * @return false when one of them is a header block still arriving: no
	 *         other frame may be read until it ends (6.10), so the connection
	 *         can go no further, and its owner closes it.
	 */
	public function expireRequests(cutoff:Float):Bool {
		if (closed || __openStreams == __answering) {
			return true;
		}

		// Gathered first: answering one removes it from the map being walked.
		var late:Null<Array<H2Stream>> = null;
		for (target in __streams) {
			if (!target.delivered && target.openedAt <= cutoff) {
				if (late == null) {
					late = [];
				}
				late.push(target);
			}
		}
		if (late == null) {
			return true;
		}

		for (target in late) {
			if (!target.headerSectionReceived) {
				return false;
			}
			if (target.delivered || !__streams.exists(target.id)) {
				continue;
			}
			__refuseLate(target);
			if (closed) {
				break;
			}
		}
		return true;
	}

	private function __refuseLate(target:H2Stream):Void {
		target.overflowed = true;
		target.takeBody();

		var request:Null<H2ServerRequest> = target.request;
		if (request == null) {
			try {
				request = H2ServerRequest.fromHeaders(target.id, target.headers, null, true);
			} catch (e:H2StreamError) {
				resetStream(e.streamId, e.code);
				return;
			}
			request.startedAt = target.openedAt;
		}

		request.timedOut = true;
		request.body = Bytes.alloc(0);
		__markDelivered(target);
		onRequest(request);

		// As for a body past the limit: the answer has ended the stream on
		// this side, and this asks the client to stop sending the rest.
		resetStream(target.id, H2ErrorCode.NO_ERROR);
	}

	/** Resets one stream, leaving the connection running. */
	public function resetStream(streamId:Int, code:H2ErrorCode):Void {
		var payload:Bytes = Bytes.alloc(4);
		__writeUInt32(payload, 0, cast code);
		__writeFrame(H2FrameType.RST_STREAM, 0, streamId, payload);

		var target:Null<H2Stream> = __streams.get(streamId);
		if (target != null) {
			target.close();
			__forget(streamId);
			__writable.remove(streamId);
		}
	}

	/**
	 * Tells the peer no new streams will be taken, while those already open
	 * run to their end (§6.8). The connection stays up; the owner closes it
	 * once `openStreams` reaches zero, or with `goAway` at a deadline.
	 *
	 * What a server shutting down owes its HTTP/2 clients up front. They saw a
	 * GOAWAY only at the drain's deadline, so for the whole drain they kept
	 * opening streams on a connection about to go, and whatever was in flight
	 * at the deadline was cut off without warning.
	 */
	public function goAwayGracefully():Void {
		if (closed || __goingAway) {
			return;
		}
		__goingAway = true;
		__goAwayLastStreamId = __highestStreamId;

		var payload:Bytes = Bytes.alloc(8);
		__writeUInt32(payload, 0, __goAwayLastStreamId);
		__writeUInt32(payload, 4, cast H2ErrorCode.NO_ERROR);
		try {
			__writeFrame(H2FrameType.GOAWAY, 0, 0, payload);
		} catch (_:Dynamic) {}
	}

	/** Whether `goAwayGracefully` has been called. */
	public var goingAway(get, never):Bool;

	private inline function get_goingAway():Bool {
		return __goingAway;
	}

	public function goAway(code:H2ErrorCode, ?debug:String):Void {
		if (closed) {
			return;
		}
		closed = true;

		var message:Bytes = debug == null ? Bytes.alloc(0) : Bytes.ofString(debug);
		var payload:Bytes = Bytes.alloc(8 + message.length);
		__writeUInt32(payload, 0, __goingAway ? __goAwayLastStreamId : __highestStreamId);
		__writeUInt32(payload, 4, cast code);
		if (message.length > 0) {
			payload.blit(8, message, 0, message.length);
		}

		try {
			__writeFrame(H2FrameType.GOAWAY, 0, 0, payload);
		} catch (_:Dynamic) {
			// The socket is often already gone by the time we decide to say
			// so; the connection is closed either way.
		}
	}

	// -------------------------------------------------------------- preface

	private function __consumePreface(source:Bytes, offset:Int, count:Int):Int {
		var expected:String = H2Connection.PREFACE;
		var start:Int = expected.length - __prefaceRemaining;
		var taken:Int = count < __prefaceRemaining ? count : __prefaceRemaining;

		for (i in 0...taken) {
			if (source.get(offset + i) != expected.charCodeAt(start + i)) {
				// §3.4: an invalid preface is a connection error. In practice
				// it is an HTTP/1.1 client that reached an h2c-only port.
				throw new H2ConnectionError(H2ErrorCode.PROTOCOL_ERROR, "Client connection preface is invalid");
			}
		}

		__prefaceRemaining -= taken;

		if (__prefaceRemaining == 0 && !__settingsSent) {
			// §3.4 requires our SETTINGS to be the first frame we send, and it
			// must follow the preface rather than precede it.
			__settingsSent = true;
			__writeFrame(H2FrameType.SETTINGS, 0, 0, localSettings.toPayload());
		}

		return taken;
	}

	// ------------------------------------------------------------- dispatch

	private function __dispatch(frame:H2Frame):Void {
		if (__continuationStreamId >= 0) {
			if (frame.type != H2FrameType.CONTINUATION || frame.streamId != __continuationStreamId) {
				throw new H2ConnectionError(H2ErrorCode.PROTOCOL_ERROR,
					'Expected CONTINUATION on stream $__continuationStreamId, got ${frame.toString()}');
			}
			__continueHeaders(frame);
			return;
		}

		try {
			switch (frame.type) {
				case HEADERS:
					__onHeaders(frame);
				case DATA:
					__onData(frame);
				case RST_STREAM:
					__onRstStream(frame);
				case SETTINGS:
					__onSettings(frame);
				case PING:
					__onPing(frame);
				case WINDOW_UPDATE:
					__onWindowUpdate(frame);
				case GOAWAY:
					closed = true;
				case PRIORITY:
					// Deprecated by §5.3.2; still legal, still meaningless.
				case PUSH_PROMISE:
					// §8.4: a client may never promise. Only servers push.
					throw new H2ConnectionError(H2ErrorCode.PROTOCOL_ERROR, "PUSH_PROMISE received from a client");
				case CONTINUATION:
					throw new H2ConnectionError(H2ErrorCode.PROTOCOL_ERROR, "CONTINUATION with no preceding HEADERS");
				case _:
					// §4.1: unknown types are discarded so the protocol stays
					// extensible.
			}
		} catch (e:H2StreamError) {
			// One malformed message. The connection is unaffected, so the
			// stream is reset and every other request keeps running.
			resetStream(e.streamId, e.code);
		}
	}

	private function __onHeaders(frame:H2Frame):Void {
		if (frame.streamId == 0) {
			throw new H2ConnectionError(H2ErrorCode.PROTOCOL_ERROR, "HEADERS on stream 0");
		}

		// §5.1.1: client streams are odd, and a new one must exceed every id
		// used so far. An even or reused id is a connection error because
		// stream identity itself is then ambiguous.
		if ((frame.streamId & 1) == 0) {
			throw new H2ConnectionError(H2ErrorCode.PROTOCOL_ERROR, 'Client opened even-numbered stream ${frame.streamId}');
		}
		if (frame.streamId <= __highestStreamId && !__streams.exists(frame.streamId)) {
			throw new H2ConnectionError(H2ErrorCode.PROTOCOL_ERROR, 'Stream ${frame.streamId} is not greater than the highest already seen');
		}
		if (frame.streamId > __highestStreamId) {
			__highestStreamId = frame.streamId;
		}

		var payload:Bytes = frame.payload;
		if (frame.has(H2Flags.PADDED)) {
			payload = H2Frame.stripPadding(payload, frame.streamId);
		}
		if (frame.has(H2Flags.PRIORITY)) {
			if (payload.length < 5) {
				throw new H2ConnectionError(H2ErrorCode.FRAME_SIZE_ERROR, "HEADERS with PRIORITY is too short for the priority fields");
			}
			payload = payload.sub(5, payload.length - 5);
		}

		// A refused stream is never opened, but its header block is still
		// decoded, __completeHeaders decodes and discards a block for a
		// stream it does not hold, before the reset goes out. HPACK is
		// connection state: a block skipped leaves every later one decoded
		// against the wrong table. The concurrency refusal used to throw before
		// the block was read, which did exactly that.
		var refusal:Null<H2ErrorCode> = null;
		if (!__streams.exists(frame.streamId)) {
			var limit:Int = localSettings.maxConcurrentStreams;
			if (__goingAway) {
				// §6.8: after GOAWAY, streams the peer opens are not processed.
				// REFUSED_STREAM tells it this one is safe to send elsewhere.
				refusal = H2ErrorCode.REFUSED_STREAM;
			} else if (limit >= 0 && __openStreams >= limit) {
				// §5.1.2 makes exceeding the advertised limit a stream error,
				// and REFUSED_STREAM rather than PROTOCOL_ERROR because it
				// tells the client the request was never processed and is safe
				// to retry. Without this a peer can open streams without bound
				// and every one of them costs a handler and a buffer.
				refusal = H2ErrorCode.REFUSED_STREAM;
			} else {
				var opened:H2Stream = new H2Stream(frame.streamId, remoteSettings.initialWindowSize, localSettings.initialWindowSize);
				opened.openedAt = haxe.Timer.stamp();
				__streams.set(frame.streamId, opened);
				__openStreams++;
				__streamsTaken++;

				if (maxRequests > 0 && __streamsTaken >= maxRequests) {
					// The last this connection takes. Said now, as it opens,
					// so the client sends what comes next elsewhere instead of
					// learning it from a refusal.
					goAwayGracefully();
				}
			}
		}

		if (frame.has(H2Flags.END_HEADERS)) {
			__completeHeaders(frame.streamId, payload, frame.has(H2Flags.END_STREAM));
			if (refusal != null) {
				resetStream(frame.streamId, refusal);
			}
			return;
		}

		__continuationStreamId = frame.streamId;
		__continuationEndsStream = frame.has(H2Flags.END_STREAM);
		__continuationRefusal = refusal;
		__continuationBuffer = new BytesBuffer();
		__continuationLength = 0;
		__appendHeaderFragment(payload);
	}

	/**
	 * Adds a fragment to the open header block, refusing one that has grown
	 * past what any real request needs.
	 *
	 * A connection error rather than a stream error: the frames are still
	 * arriving, the block cannot be decoded, and HPACK is connection state,
	 * so there is no way to resynchronise the dynamic table with the peer and
	 * carry on. Resetting the stream would leave the rest of the run to be
	 * read as though it were new frames.
	 */
	private function __appendHeaderFragment(payload:Bytes):Void {
		if (maxHeaderBlockSize >= 0 && (__continuationLength + payload.length) > maxHeaderBlockSize) {
			throw new H2ConnectionError(H2ErrorCode.ENHANCE_YOUR_CALM,
				'Header block exceeded $maxHeaderBlockSize bytes across its CONTINUATION frames');
		}

		__continuationBuffer.addBytes(payload, 0, payload.length);
		__continuationLength += payload.length;
	}

	private function __continueHeaders(frame:H2Frame):Void {
		__appendHeaderFragment(frame.payload);

		if (!frame.has(H2Flags.END_HEADERS)) {
			return;
		}

		var streamId:Int = __continuationStreamId;
		var endsStream:Bool = __continuationEndsStream;
		var refusal:Null<H2ErrorCode> = __continuationRefusal;
		var block:Bytes = __continuationBuffer.getBytes();

		__continuationStreamId = -1;
		__continuationRefusal = null;
		__continuationBuffer = null;
		__continuationLength = 0;

		try {
			__completeHeaders(streamId, block, endsStream);
		} catch (e:H2StreamError) {
			resetStream(e.streamId, e.code);
		}

		if (refusal != null) {
			resetStream(streamId, refusal);
		}
	}

	private function __completeHeaders(streamId:Int, block:Bytes, endStream:Bool):Void {
		// Decoded before any validation, and outside the stream-error path on
		// purpose: the table must advance even for a message we are about to
		// reject, or the peer's encoder and our decoder diverge from here on.
		var decoded:Array<HpackHeader> = __decoder.decode(block);
		var tooLarge:Bool = __decoder.truncated;

		var target:Null<H2Stream> = __streams.get(streamId);
		if (target == null) {
			return;
		}

		if (target.headerSectionReceived) {
			__completeTrailers(target, decoded, endStream);
			return;
		}
		target.headerSectionReceived = true;
		target.headers = decoded;

		if (tooLarge) {
			__refuseHeaders(target, endStream);
			return;
		}

		if (endStream) {
			target.endOfStream = true;
			__deliver(streamId, target);
			return;
		}

		__admit(target);
	}

	/**
	 * Reads a request whose body is still to come, and asks `onRequestHead`
	 * whether it may come. Read here rather than when the body ends, so a
	 * malformed one is refused before its body is sent as well.
	 */
	private function __admit(target:H2Stream):Void {
		var request:H2ServerRequest;
		try {
			request = H2ServerRequest.fromHeaders(target.id, target.headers, null, true);
		} catch (e:H2StreamError) {
			resetStream(e.streamId, e.code);
			return;
		}
		request.startedAt = target.openedAt;
		target.request = request;
		// Read into the request; nothing reads them from here again.
		target.headers = [];

		if (!onRequestHead(request)) {
			// Answered, or turned away, before its body. What arrives of it is
			// counted and dropped once the stream is gone.
			resetStream(target.id, H2ErrorCode.NO_ERROR);
		}
	}

	/**
		A second header block on a stream: its trailer section (RFC 9113 8.1),
		checked and dropped, as the HTTP/1.1 server drops a chunked body's.

		It used to replace the request's header section. The request was then
		read from the trailers, found to have no `:method`, and reset, so a
		request sent with trailers never reached a handler. A trailer section
		must end the stream and carry no pseudo-header, and its fields are held
		to 8.2.1 as any are; one that fails is malformed, a stream error. One
		after the stream has ended is on a stream half-closed to the peer
		(5.1).
	**/
	private function __completeTrailers(target:H2Stream, decoded:Array<HpackHeader>, endStream:Bool):Void {
		if (target.endOfStream) {
			resetStream(target.id, H2ErrorCode.STREAM_CLOSED);
			return;
		}
		var malformed:Bool = !endStream;
		for (field in decoded) {
			if (malformed) {
				break;
			}
			malformed = StringTools.startsWith(field.name, ":") || H2FieldRules.violation(field.name, field.value) != null;
		}
		if (malformed) {
			resetStream(target.id, H2ErrorCode.PROTOCOL_ERROR);
			return;
		}

		target.endOfStream = true;
		if (!target.overflowed && !target.delivered) {
			__deliver(target.id, target);
		}
	}

	/**
	 * Answers a request whose header section decoded past the list limit:
	 * delivered at once, marked, to be answered `431`, as an HTTP/1.1 header
	 * block past its limit is. The block was decoded to its end all the same,
	 * so the connection and every other stream on it carry on. A body still
	 * to come is refused as an oversized one is: the stream is reset with
	 * NO_ERROR, and what arrives for it is counted and dropped.
	 */
	private function __refuseHeaders(target:H2Stream, endStream:Bool):Void {
		target.overflowed = true;
		if (endStream) {
			target.endOfStream = true;
		}

		var request:H2ServerRequest = H2ServerRequest.withHeadersTooLarge(target.id, target.headers);
		request.startedAt = target.openedAt;
		target.headers = [];
		__markDelivered(target);
		onRequest(request);

		if (!endStream) {
			resetStream(target.id, H2ErrorCode.NO_ERROR);
		}
	}

	private function __onData(frame:H2Frame):Void {
		if (frame.streamId == 0) {
			throw new H2ConnectionError(H2ErrorCode.PROTOCOL_ERROR, "DATA on stream 0");
		}

		// Counted whole, padding included, and counted even for a stream we no
		// longer have (§6.9.1). Skipping it on an unknown stream drifts the
		// connection window down until everything stalls.
		var counted:Int = frame.payload.length;
		__connectionUnacknowledged += counted;

		var content:Bytes = frame.has(H2Flags.PADDED) ? H2Frame.stripPadding(frame.payload, frame.streamId) : frame.payload;

		var target:Null<H2Stream> = __streams.get(frame.streamId);
		if (target != null && !target.overflowed) {
			if (maxRequestBodySize >= 0 && target.bodyLength + content.length > maxRequestBodySize) {
				__refuseOversized(target);
			} else {
				target.unacknowledged += counted;
				target.appendBody(content);

				if (frame.has(H2Flags.END_STREAM)) {
					target.endOfStream = true;
					__deliver(frame.streamId, target);
				} else {
					__topUpStreamWindow(target);
				}
			}
		}

		__topUpConnectionWindow();
	}

	/**
	 * Answers a request whose body outgrew `maxRequestBodySize`, and asks the
	 * client to stop sending it. See that field.
	 */
	private function __refuseOversized(target:H2Stream):Void {
		target.overflowed = true;
		// Released now rather than kept for a request that will never use it.
		target.takeBody();

		var request:Null<H2ServerRequest> = target.request;
		if (request == null) {
			try {
				request = H2ServerRequest.fromHeaders(target.id, target.headers, null, true);
			} catch (e:H2StreamError) {
				resetStream(e.streamId, e.code);
				return;
			}
			request.startedAt = target.openedAt;
		}

		request.tooLarge = true;
		request.body = Bytes.alloc(0);
		__markDelivered(target);
		onRequest(request);

		// The answer has ended the stream on this side; this tells the client
		// the rest of its body is not wanted, without calling it an error.
		resetStream(target.id, H2ErrorCode.NO_ERROR);
	}

	private function __deliver(streamId:Int, target:H2Stream):Void {
		var request:H2ServerRequest;
		try {
			if (target.request != null) {
				// Read and admitted at its headers; only the body is new.
				request = target.request;
				request.attachBody(target.takeBody());
			} else {
				request = H2ServerRequest.fromHeaders(streamId, target.headers, target.takeBody());
				request.startedAt = target.openedAt;
			}
		} catch (e:H2StreamError) {
			resetStream(e.streamId, e.code);
			return;
		}

		__markDelivered(target);
		onRequest(request);
	}

	private function __onRstStream(frame:H2Frame):Void {
		if (frame.payload.length != 4) {
			throw new H2ConnectionError(H2ErrorCode.FRAME_SIZE_ERROR, 'RST_STREAM payload is ${frame.payload.length} bytes, not 4');
		}

		var target:Null<H2Stream> = __streams.get(frame.streamId);
		if (target == null) {
			// Already finished, so the reset costs nothing and means nothing.
			// A client that cancels a download it has already read enough of
			// does exactly this, and must not be counted against anyone.
			return;
		}

		var abandoned:Null<Void->Void> = __abandoned.get(frame.streamId);

		target.close();
		__forget(frame.streamId);
		__writable.remove(frame.streamId);

		if (abandoned != null) {
			abandoned();
		}

		__noteAbandonedStream();
	}

	/**
	 * Records a stream abandoned before it was answered, and gives up on the
	 * connection if they arrive faster than any client would need.
	 *
	 * A sliding count rather than a rate: the window restarts once it has
	 * elapsed, so a burst is what trips this and a steady trickle of genuine
	 * cancellations never does.
	 */
	private function __noteAbandonedStream():Void {
		if (maxResetStreams < 0) {
			return;
		}

		var now:Float = haxe.Timer.stamp();
		// >= rather than >: a window of W seconds has elapsed *at* W, and it
		// makes a window of zero mean what it reads like, every reset starts
		// its own, so nothing accumulates. With > that depended on whether the
		// clock had ticked between two calls, which it does natively and does
		// not on the interpreter.
		if (__resetWindowStart < 0 || (now - __resetWindowStart) >= resetWindowSeconds) {
			__resetWindowStart = now;
			__resetCount = 0;
		}

		__resetCount++;

		if (__resetCount > maxResetStreams) {
			// ENHANCE_YOUR_CALM rather than PROTOCOL_ERROR: nothing the peer
			// sent was malformed, there was simply too much of it, and §7 has
			// a code that says exactly that.
			throw new H2ConnectionError(H2ErrorCode.ENHANCE_YOUR_CALM,
				'Peer abandoned $__resetCount streams before their responses within ${resetWindowSeconds}s');
		}
	}

	/**
	 * Counts a control frame this side must answer, and gives up when a
	 * peer asks for more answers than a conversation has reason to.
	 */
	private function __noteControlReply():Void {
		if (maxControlReplies < 0) {
			return;
		}

		var now:Float = haxe.Timer.stamp();
		// >= rather than >, for the reason given on the reset window above.
		if (__controlReplyWindowStart < 0 || (now - __controlReplyWindowStart) >= resetWindowSeconds) {
			__controlReplyWindowStart = now;
			__controlReplyCount = 0;
		}

		__controlReplyCount++;

		if (__controlReplyCount > maxControlReplies) {
			// ENHANCE_YOUR_CALM for the same reason the reset budget uses it:
			// every frame was well formed, there was simply too much of it.
			throw new H2ConnectionError(H2ErrorCode.ENHANCE_YOUR_CALM,
				'Peer obliged $__controlReplyCount control-frame replies within ${resetWindowSeconds}s');
		}
	}

	private function __onSettings(frame:H2Frame):Void {
		if (frame.has(H2Flags.ACK)) {
			if (frame.payload.length != 0) {
				throw new H2ConnectionError(H2ErrorCode.FRAME_SIZE_ERROR, "SETTINGS ACK must have an empty payload");
			}
			return;
		}

		var previousWindow:Int = remoteSettings.applyPayload(frame.payload);

		// §6.9.2: retune every open stream by the delta rather than resetting
		// it, and leave the connection window alone.
		var delta:Int = remoteSettings.initialWindowSize - previousWindow;
		if (delta != 0) {
			for (target in __streams) {
				var adjusted:Float = target.sendWindow + delta;
				if (adjusted > H2Settings.MAX_WINDOW_SIZE) {
					throw new H2ConnectionError(H2ErrorCode.FLOW_CONTROL_ERROR, 'INITIAL_WINDOW_SIZE change overflows stream ${target.id}');
				}
				target.sendWindow += delta;
			}
		}

		__encoder.setCapacity(remoteSettings.headerTableSize);
		__noteControlReply();
		__writeFrame(H2FrameType.SETTINGS, H2Flags.ACK, 0, Bytes.alloc(0));

		if (delta > 0) {
			// A raised INITIAL_WINDOW_SIZE is as much a release as a
			// WINDOW_UPDATE, and a stream sitting on a queue will not move
			// again on its own.
			notifyWritable();
		}
	}

	private function __onPing(frame:H2Frame):Void {
		if (frame.payload.length != 8) {
			throw new H2ConnectionError(H2ErrorCode.FRAME_SIZE_ERROR, 'PING payload is ${frame.payload.length} bytes, not 8');
		}
		if (frame.has(H2Flags.ACK)) {
			return;
		}
		__noteControlReply();
		__writeFrame(H2FrameType.PING, H2Flags.ACK, 0, frame.payload);
	}

	private function __onWindowUpdate(frame:H2Frame):Void {
		if (frame.payload.length != 4) {
			throw new H2ConnectionError(H2ErrorCode.FRAME_SIZE_ERROR, 'WINDOW_UPDATE payload is ${frame.payload.length} bytes, not 4');
		}

		var increment:Int = __readUInt32(frame.payload, 0) & 0x7fffffff;
		if (increment == 0) {
			if (frame.streamId == 0) {
				throw new H2ConnectionError(H2ErrorCode.PROTOCOL_ERROR, "WINDOW_UPDATE increment of 0 on the connection");
			}
			throw new H2StreamError(frame.streamId, H2ErrorCode.PROTOCOL_ERROR, "WINDOW_UPDATE increment of 0");
		}

		if (frame.streamId == 0) {
			var updated:Float = __connectionSendWindow + increment;
			if (updated > H2Settings.MAX_WINDOW_SIZE) {
				throw new H2ConnectionError(H2ErrorCode.FLOW_CONTROL_ERROR, "Connection send window overflowed");
			}
			__connectionSendWindow += increment;
			// The connection window gates every stream, so opening it can
			// unblock any of them.
			notifyWritable();
			return;
		}

		var target:Null<H2Stream> = __streams.get(frame.streamId);
		if (target == null) {
			return;
		}

		var updated:Float = target.sendWindow + increment;
		if (updated > H2Settings.MAX_WINDOW_SIZE) {
			throw new H2StreamError(frame.streamId, H2ErrorCode.FLOW_CONTROL_ERROR, "Stream send window overflowed");
		}
		target.sendWindow += increment;

		__flushStream(target);
		var callback:Null<Void->Void> = __writable.get(frame.streamId);
		if (callback != null) {
			callback();
		}
	}

	// -------------------------------------------------------- flow control

	private function __topUpStreamWindow(target:H2Stream):Void {
		var initial:Int = localSettings.initialWindowSize;
		if (target.unacknowledged < (initial >> 1)) {
			return;
		}

		var increment:Int = target.unacknowledged;
		target.unacknowledged = 0;

		var payload:Bytes = Bytes.alloc(4);
		__writeUInt32(payload, 0, increment);
		__writeFrame(H2FrameType.WINDOW_UPDATE, 0, target.id, payload);
	}

	private function __topUpConnectionWindow():Void {
		if (__connectionUnacknowledged < (H2Settings.DEFAULT_INITIAL_WINDOW_SIZE >> 1)) {
			return;
		}

		var increment:Int = __connectionUnacknowledged;
		__connectionUnacknowledged = 0;

		var payload:Bytes = Bytes.alloc(4);
		__writeUInt32(payload, 0, increment);
		__writeFrame(H2FrameType.WINDOW_UPDATE, 0, 0, payload);
	}

	// ---------------------------------------------------------------- write

	private function __writeHeaderBlock(streamId:Int, block:Bytes, endStream:Bool):Void {
		var limit:Int = remoteSettings.maxFrameSize;
		var offset:Int = 0;
		var first:Bool = true;

		while (true) {
			var chunk:Int = block.length - offset;
			if (chunk > limit) {
				chunk = limit;
			}

			var last:Bool = (offset + chunk) >= block.length;
			var flags:Int = last ? H2Flags.END_HEADERS : 0;
			if (first && endStream) {
				flags |= H2Flags.END_STREAM;
			}

			__writeFrameOf(first ? H2FrameType.HEADERS : H2FrameType.CONTINUATION, flags, streamId, block, offset, chunk);

			offset += chunk;
			first = false;
			if (last) {
				break;
			}
		}
	}

	private inline function __writeFrame(type:H2FrameType, flags:Int, streamId:Int, payload:Bytes):Void {
		__write(H2Frame.encode(type, flags, streamId, payload));
	}

	/** A frame of `length` bytes of `source` from `offset`, without cutting them out first. **/
	private inline function __writeFrameOf(type:H2FrameType, flags:Int, streamId:Int, source:Bytes, offset:Int, length:Int):Void {
		__write(H2Frame.encode(type, flags, streamId, source, offset, length));
	}

	private function __fail(e:H2ConnectionError):Void {
		goAway(e.code, e.message);
		onConnectionError(e);
	}

	private static function __defaultSettings():H2Settings {
		var settings = new H2Settings();
		// Nothing here pushes, and saying so lets a client stop reserving for
		// promises it will never receive.
		settings.enablePush = false;

		// Advertised, not merely enforced. §6.5.2 sets no default cap, so a
		// server that stays quiet is telling clients it will accept streams
		// without limit, and each one costs a handler and a buffer. A client
		// that knows the number paces itself instead of being refused.
		settings.maxConcurrentStreams = DEFAULT_MAX_CONCURRENT_STREAMS;

		// Advertised for the same reason, and enforced by the decoder: a
		// client told the limit keeps under it, and one that does not is
		// answered 431 rather than holding the thread.
		settings.maxHeaderListSize = DEFAULT_MAX_HEADER_LIST_SIZE;
		return settings;
	}

	private static inline function __writeUInt32(target:Bytes, offset:Int, value:Int):Void {
		target.set(offset, (value >> 24) & 0xff);
		target.set(offset + 1, (value >> 16) & 0xff);
		target.set(offset + 2, (value >> 8) & 0xff);
		target.set(offset + 3, value & 0xff);
	}

	private static inline function __readUInt32(source:Bytes, offset:Int):Int {
		return (source.get(offset) << 24) | (source.get(offset + 1) << 16) | (source.get(offset + 2) << 8) | source.get(offset + 3);
	}
}
