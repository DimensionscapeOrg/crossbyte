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
 * desynchronizes shared state -- framing, or the HPACK table -- is a
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
	 * Streams the peer may abandon before their response within
	 * `resetWindowSeconds`, after which the connection is closed with
	 * ENHANCE_YOUR_CALM. Negative disables the check.
	 *
	 * This is the Rapid Reset defence (CVE-2023-44487), and it exists because
	 * SETTINGS_MAX_CONCURRENT_STREAMS does not provide one: a stream that is
	 * reset is closed, so it frees its slot immediately. A peer that opens a
	 * stream and resets it at once therefore never approaches the limit while
	 * still making the server do the work of every request -- routing,
	 * allocation, a handler each -- without bound. Counting the abandonments
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
	 * grew. SETTINGS_MAX_HEADER_LIST_SIZE does not help either -- it limits
	 * what the block decodes to, and this never reaches the decoder.
	 */
	public var maxHeaderBlockSize:Int = DEFAULT_MAX_HEADER_BLOCK;

	/**
	 * PING and SETTINGS frames the peer may oblige a reply to within
	 * `resetWindowSeconds`, after which the connection is closed with
	 * ENHANCE_YOUR_CALM. Negative disables the check.
	 *
	 * Both are answered the moment they arrive -- 6.5.3 requires a SETTINGS
	 * ACK and 6.7 a PING ACK -- so a peer sending them faster than this side
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

	/** Called once per complete request. */
	public var onRequest:H2ServerRequest->Void = _ -> {};

	/** Called when the connection fails fatally; the caller closes the socket. */
	public var onConnectionError:H2ConnectionError->Void = _ -> {};

	public final localSettings:H2Settings;
	public final remoteSettings:H2Settings;

	/** True once a GOAWAY has been written and the connection is finished. */
	public var closed(default, null):Bool = false;

	/** Streams open right now, which is what makes a connection busy rather than idle. */
	public var openStreams(get, never):Int;

	private final __write:Bytes->Void;
	private final __decoder:HpackDecoder;
	private final __encoder:HpackEncoder;
	private final __frames:H2FrameDecoder;
	private final __streams:Map<Int, H2Stream>;
	private final __writable:Map<Int, Void->Void>;

	private var __prefaceRemaining:Int;
	private var __settingsSent:Bool = false;
	private var __highestStreamId:Int = 0;
	private var __connectionSendWindow:Int;
	private var __connectionUnacknowledged:Int = 0;
	private var __openStreams:Int = 0;
	private var __resetCount:Int = 0;
	private var __resetWindowStart:Float = -1;
	private var __controlReplyCount:Int = 0;
	private var __controlReplyWindowStart:Float = -1;

	// A header block spans HEADERS plus any CONTINUATION frames, and §6.10
	// forbids any other frame in between, on any stream.
	private var __continuationStreamId:Int = -1;
	private var __continuationEndsStream:Bool = false;
	private var __continuationBuffer:BytesBuffer = null;
	private var __continuationLength:Int = 0;

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

		__prefaceRemaining = H2Connection.PREFACE.length;
		__connectionSendWindow = H2Settings.DEFAULT_INITIAL_WINDOW_SIZE;
	}

	private inline function get_openStreams():Int {
		return __openStreams;
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
			// happened to arrive -- which, for the last request on a
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
			target.close();
			__streams.remove(streamId);
		}
	}

	/**
	 * Offers body bytes, closing the stream when `endStream` is set.
	 *
	 * Whatever flow control permits goes out now; the rest waits for a
	 * WINDOW_UPDATE. So this returning does not mean the bytes were sent, only
	 * that they were accepted -- `queuedFor` is how a caller applying
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

			var data:Bytes = target.take(chunk);
			var last:Bool = target.queued == 0 && target.pendingEndStream;

			__writeFrame(H2FrameType.DATA, last ? H2Flags.END_STREAM : 0, target.id, data);
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
	 * concurrency limit tighten permanently -- a connection that serves fewer
	 * and fewer requests until it serves none.
	 */
	private function __forget(streamId:Int):Void {
		if (__streams.remove(streamId)) {
			__openStreams--;
		}
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

	public function goAway(code:H2ErrorCode, ?debug:String):Void {
		if (closed) {
			return;
		}
		closed = true;

		var message:Bytes = debug == null ? Bytes.alloc(0) : Bytes.ofString(debug);
		var payload:Bytes = Bytes.alloc(8 + message.length);
		__writeUInt32(payload, 0, __highestStreamId);
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

		if (!__streams.exists(frame.streamId)) {
			var limit:Int = localSettings.maxConcurrentStreams;
			if (limit >= 0 && __openStreams >= limit) {
				// §5.1.2 makes exceeding the advertised limit a stream error,
				// and REFUSED_STREAM rather than PROTOCOL_ERROR because it
				// tells the client the request was never processed and is safe
				// to retry. Without this a peer can open streams without bound
				// and every one of them costs a handler and a buffer.
				throw new H2StreamError(frame.streamId, H2ErrorCode.REFUSED_STREAM,
					'Stream ${frame.streamId} would exceed SETTINGS_MAX_CONCURRENT_STREAMS of $limit');
			}

			__streams.set(frame.streamId, new H2Stream(frame.streamId, remoteSettings.initialWindowSize, localSettings.initialWindowSize));
			__openStreams++;
		}

		if (frame.has(H2Flags.END_HEADERS)) {
			__completeHeaders(frame.streamId, payload, frame.has(H2Flags.END_STREAM));
			return;
		}

		__continuationStreamId = frame.streamId;
		__continuationEndsStream = frame.has(H2Flags.END_STREAM);
		__continuationBuffer = new BytesBuffer();
		__continuationLength = 0;
		__appendHeaderFragment(payload);
	}

	/**
	 * Adds a fragment to the open header block, refusing one that has grown
	 * past what any real request needs.
	 *
	 * A connection error rather than a stream error: the frames are still
	 * arriving, the block cannot be decoded, and HPACK is connection state --
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
		var block:Bytes = __continuationBuffer.getBytes();

		__continuationStreamId = -1;
		__continuationBuffer = null;
		__continuationLength = 0;

		try {
			__completeHeaders(streamId, block, endsStream);
		} catch (e:H2StreamError) {
			resetStream(e.streamId, e.code);
		}
	}

	private function __completeHeaders(streamId:Int, block:Bytes, endStream:Bool):Void {
		// Decoded before any validation, and outside the stream-error path on
		// purpose: the table must advance even for a message we are about to
		// reject, or the peer's encoder and our decoder diverge from here on.
		var decoded:Array<HpackHeader> = __decoder.decode(block);

		var target:Null<H2Stream> = __streams.get(streamId);
		if (target == null) {
			return;
		}

		target.headers = decoded;

		if (endStream) {
			target.endOfStream = true;
			__deliver(streamId, target);
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
		if (target != null) {
			target.unacknowledged += counted;
			target.appendBody(content);

			if (frame.has(H2Flags.END_STREAM)) {
				target.endOfStream = true;
				__deliver(frame.streamId, target);
			} else {
				__topUpStreamWindow(target);
			}
		}

		__topUpConnectionWindow();
	}

	private function __deliver(streamId:Int, target:H2Stream):Void {
		var request:H2ServerRequest;
		try {
			request = H2ServerRequest.fromHeaders(streamId, target.headers, target.takeBody());
		} catch (e:H2StreamError) {
			resetStream(e.streamId, e.code);
			return;
		}

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

		target.close();
		__forget(frame.streamId);
		__writable.remove(frame.streamId);

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
		// makes a window of zero mean what it reads like -- every reset starts
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

			__writeFrame(first ? H2FrameType.HEADERS : H2FrameType.CONTINUATION, flags, streamId, block.sub(offset, chunk));

			offset += chunk;
			first = false;
			if (last) {
				break;
			}
		}
	}

	private function __writeFrame(type:H2FrameType, flags:Int, streamId:Int, payload:Bytes):Void {
		var out:BytesBuffer = new BytesBuffer();
		H2Frame.writeHeader(out, payload.length, type, flags, streamId);
		if (payload.length > 0) {
			out.addBytes(payload, 0, payload.length);
		}
		__write(out.getBytes());
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
		// without limit -- and each one costs a handler and a buffer. A client
		// that knows the number paces itself instead of being refused.
		settings.maxConcurrentStreams = DEFAULT_MAX_CONCURRENT_STREAMS;
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
