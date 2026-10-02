package crossbyte._internal.http.h2;

import crossbyte._internal.http.h2.hpack.HpackDecoder;
import crossbyte._internal.http.h2.hpack.HpackEncoder;
import crossbyte._internal.http.h2.hpack.HpackError;
import crossbyte._internal.http.h2.hpack.HpackHeader;
import crossbyte.utils.IntParse;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import haxe.io.Eof;
import haxe.io.Input;
import haxe.io.Output;

/**
 * A client-side HTTP/2 connection over an already-established byte stream.
 *
 * This is the `h2c` shape: prior knowledge, no `Upgrade:` dance. RFC 9113
 * §3.1 retired the upgrade token, and the negotiated-over-TLS case is the same
 * code with ALPN in front of it, so nothing here is cleartext-specific beyond
 * the scheme the caller puts in `:scheme`.
 *
 * Blocking, driven by whoever calls `pump()`. That matches the existing HTTP/1
 * client, which runs on a worker thread under `URLLoader`, and it keeps the
 * state machine free of an event loop it would otherwise have to own.
 *
 * Multiplexing is supported by the data structures -- streams are a map and
 * flow control is tracked per stream -- but nothing here schedules across
 * them; a caller drives whichever streams it opened.
 */
class H2Connection {
	/** RFC 9113 §3.4. Sent by a client before anything else. */
	public static inline var PREFACE:String = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

	/**
	 * What a response's header section may decode to, by RFC 7541 4.1's
	 * accounting, before it is refused, when the settings name no limit of
	 * their own. The HTTP/1.1 client's limit on a response's header block.
	 */
	public static inline var DEFAULT_MAX_HEADER_LIST_SIZE:Int = 64 * 1024;

	/**
	 * Compressed bytes one header block may span across its CONTINUATION
	 * frames, past which the connection is ended with ENHANCE_YOUR_CALM.
	 * Negative disables the check.
	 *
	 * The server has held a client to this since it was shown that a HEADERS
	 * with no END_HEADERS, and CONTINUATION frames after it for ever, grew a
	 * buffer without end; a server could do the same to this client.
	 */
	public var maxHeaderBlockSize:Int = 256 * 1024;

	/**
		The HTTP/1.1 client's limit on a response body, 64 MB: what a stream
		opened from here holds before it is given up, unless its opener says
		otherwise (`H2Stream.maxBodyLength`).
	**/
	public static inline var DEFAULT_MAX_RESPONSE_BODY_SIZE:Int = 64 * 1024 * 1024;

	/**
		The most response body each stream opened from here holds, in bytes;
		`0` or less for no limit. A stream whose body goes past it is reset
		with CANCEL, its body let go and `failure` saying why, and the
		connection carries on.

		Flow control did not bound it: the stream's window is opened again as
		each half of it arrives, so the client can never fall behind, and a
		server sending without end grew the body without end.
	**/
	public var maxResponseBodySize:Int = DEFAULT_MAX_RESPONSE_BODY_SIZE;

	/** Our settings, sent at startup. */
	public final localSettings:H2Settings;

	/** The peer's settings, as most recently received. */
	public final remoteSettings:H2Settings;

	/** Set when the peer sent GOAWAY, with the code it gave. */
	public var goAwayCode(default, null):Null<H2ErrorCode> = null;

	/** Highest stream the peer said it processed, from GOAWAY. */
	public var goAwayLastStreamId(default, null):Int = -1;

	/**
	 * Called whenever a stream reaches its end, for any reason.
	 *
	 * One caller per stream may be waiting on a different thread, and this is
	 * how it is woken. Polling `isClosed` instead would mean either a spin or
	 * a latency floor, and there is no third option that does not involve
	 * this callback.
	 */
	public var onStreamClosed:H2Stream->Void = _ -> {};

	/**
	 * Called when a request body cannot proceed because a flow-control window
	 * is closed, with the stream it is for and how many seconds this stall
	 * has lasted. Returns `false` to abandon the write. Called again after
	 * every return while the window stays closed, and the stall's clock only
	 * starts over once a byte of the body has gone out.
	 *
	 * The default reads a frame here, which is right when the caller owns the
	 * connection outright. It is wrong the moment a reader thread owns the
	 * reads instead -- two readers on one socket lose frames -- so an owner
	 * that has one replaces this with a wait.
	 *
	 * Resetting the stream from here, or from anywhere while this waits, ends
	 * the write: the body stops as soon as its stream is closed.
	 */
	public var onWindowBlocked:(target:H2Stream, stalledSeconds:Float) -> Bool = null;

	private final __input:Input;
	private final __output:Output;
	private final __encoder:HpackEncoder;
	private final __decoder:HpackDecoder;
	private final __streams:Map<Int, H2Stream>;

	private var __nextStreamId:Int = 1;
	private var __connectionSendWindow:Int;
	private var __connectionRecvWindow:Int;
	private var __connectionUnacknowledged:Int = 0;
	private var __started:Bool = false;
	private var __closed:Bool = false;

	// A header block may span HEADERS/PUSH_PROMISE plus any number of
	// CONTINUATION frames, and §6.2 forbids anything at all in between -- on
	// any stream, not just this one. Holding the stream id here is what makes
	// that enforceable.
	private var __continuationStreamId:Int = -1;
	private var __continuationEndsStream:Bool = false;
	private var __continuationBuffer:BytesBuffer = null;
	private var __continuationLength:Int = 0;

	public function new(input:Input, output:Output, ?settings:H2Settings) {
		__input = input;
		__output = output;

		localSettings = settings != null ? settings : new H2Settings();
		remoteSettings = new H2Settings();
		__streams = new Map();

		__encoder = new HpackEncoder(remoteSettings.headerTableSize);
		// Settings that name no limit get the HTTP/1.1 client's: the decoder
		// used to allow eight megabytes, under which a server could send a
		// header section that took seconds to join.
		__decoder = new HpackDecoder(localSettings.headerTableSize,
			localSettings.maxHeaderListSize >= 0 ? localSettings.maxHeaderListSize : DEFAULT_MAX_HEADER_LIST_SIZE);

		// The connection window is not affected by SETTINGS_INITIAL_WINDOW_SIZE
		// (§6.9.2); it starts at the fixed default and only WINDOW_UPDATE
		// moves it. Conflating the two is a classic stall.
		__connectionSendWindow = H2Settings.DEFAULT_INITIAL_WINDOW_SIZE;
		__connectionRecvWindow = H2Settings.DEFAULT_INITIAL_WINDOW_SIZE;
	}

	/** Writes the preface and our SETTINGS. Must precede any request. */
	public function start():Void {
		if (__started) {
			return;
		}
		__started = true;

		var out:BytesBuffer = new BytesBuffer();
		out.addString(PREFACE);

		var payload:Bytes = localSettings.toPayload();
		H2Frame.writeHeader(out, payload.length, H2FrameType.SETTINGS, 0, 0);
		out.addBytes(payload, 0, payload.length);

		__write(out.getBytes());
	}

	/** A stream still open, or `null`: a stream is forgotten as it closes. */
	public function stream(id:Int):Null<H2Stream> {
		return __streams.get(id);
	}

	/**
	 * Opens a stream and sends the request.
	 *
	 * Pseudo-header fields go first and in the order §8.3 lists them; a peer
	 * is entitled to reject a block that puts a regular field before one.
	 */
	public function request(method:String, scheme:String, authority:String, path:String, headers:Array<HpackHeader>, ?body:Bytes):H2Stream {
		var hasBody:Bool = body != null && body.length > 0;
		var target:H2Stream = openStream(method, scheme, authority, path, headers, hasBody);
		if (hasBody) {
			sendBody(target, body);
		}
		return target;
	}

	/**
	 * The first half of `request`: opens a stream and sends its header
	 * block, ending the request there unless `hasBody`.
	 *
	 * Separate so an owner can take note of the stream -- register whoever
	 * waits on it, and whatever would cancel it -- before `sendBody`, which
	 * may wait on a window for as long as the peer likes.
	 */
	public function openStream(method:String, scheme:String, authority:String, path:String, headers:Array<HpackHeader>, hasBody:Bool):H2Stream {
		start();

		if (goAwayCode != null) {
			throw new H2ConnectionError(H2ErrorCode.REFUSED_STREAM, "Peer has sent GOAWAY; no new streams may be opened");
		}

		var id:Int = __nextStreamId;
		// Client streams are odd (§5.1.1), so ids advance by two.
		__nextStreamId += 2;

		var target:H2Stream = new H2Stream(id, remoteSettings.initialWindowSize, localSettings.initialWindowSize);
		target.maxBodyLength = maxResponseBodySize;
		__streams.set(id, target);

		var block:Array<HpackHeader> = [
			new HpackHeader(":method", method),
			new HpackHeader(":scheme", scheme),
			new HpackHeader(":authority", authority),
			new HpackHeader(":path", path)
		];
		for (header in headers) {
			block.push(header);
		}

		__writeHeaderBlock(id, __encoder.encode(block), !hasBody);

		target.state = hasBody ? H2StreamState.OPEN : H2StreamState.HALF_CLOSED_LOCAL;
		return target;
	}

	/**
	 * The second half of `request`: sends the body of a stream `openStream`
	 * left open, and with it the end of the request.
	 *
	 * Stops early, the rest unsent, once the stream closes -- answered or
	 * reset by the peer, or reset here, by a cancel or a timeout -- and sends
	 * nothing at all for a stream closed before it began.
	 */
	public function sendBody(target:H2Stream, body:Bytes):Void {
		if (target.isClosed()) {
			return;
		}

		__writeData(target, body);
		// Unless the stream ended while the body was going out. Reopening it
		// hid that from the caller, who then waited out its whole timeout for
		// a stream that was already over.
		if (!target.isClosed()) {
			target.state = H2StreamState.HALF_CLOSED_LOCAL;
		}
	}

	/**
	 * Reads and processes one frame. Returns `false` once the peer has closed
	 * the connection.
	 */
	public function pump():Bool {
		var frame:Null<H2Frame> = readFrame();
		if (frame == null) {
			return false;
		}

		processFrame(frame);
		return true;
	}

	/**
	 * Reads one frame, blocking until it arrives. `null` means the peer closed.
	 *
	 * Separate from `processFrame` so an owner holding a lock over the
	 * connection can release it across the read. Blocking with the lock held
	 * would stop every other stream on the connection for as long as the peer
	 * stays quiet, which is the opposite of what multiplexing is for.
	 */
	public function readFrame():Null<H2Frame> {
		if (__closed) {
			return null;
		}

		var header:Bytes = Bytes.alloc(H2Frame.HEADER_SIZE);
		var payload:Bytes;

		try {
			__input.readFullBytes(header, 0, H2Frame.HEADER_SIZE);

			var length:Int = H2Frame.lengthOf(header);
			if (length > localSettings.maxFrameSize) {
				// §4.2. Refusing here matters: the length is 24 bits, so a peer
				// that ignores our limit could otherwise make us allocate 16 MB
				// per frame.
				throw new H2ConnectionError(H2ErrorCode.FRAME_SIZE_ERROR,
					'Frame of $length bytes exceeds our SETTINGS_MAX_FRAME_SIZE of ${localSettings.maxFrameSize}');
			}

			payload = Bytes.alloc(length);
			if (length > 0) {
				__input.readFullBytes(payload, 0, length);
			}
		} catch (_:Eof) {
			// A clean FIN. Legitimate between requests; a caller waiting on an
			// unfinished stream discovers the truncation from the stream, not
			// from here, because only it knows what it was waiting for.
			__closed = true;
			return null;
		} catch (e:haxe.io.Error) {
			if (e == haxe.io.Error.Blocked) {
				throw e;
			}
			// Anything else is an abnormal termination -- a reset, typically.
			// Reporting it as a clean close would surface downstream as
			// "the response had no status", blaming the peer's message for
			// what was actually a dead socket.
			__closed = true;
			throw new H2ConnectionError(H2ErrorCode.INTERNAL_ERROR, "Connection failed while reading a frame: " + Std.string(e));
		}

		return new H2Frame(header.get(3), header.get(4),
			((header.get(5) & 0x7f) << 24) | (header.get(6) << 16) | (header.get(7) << 8) | header.get(8), payload);
	}

	/** Applies one frame that `readFrame` returned. */
	public function processFrame(frame:H2Frame):Void {
		__dispatch(frame);
	}

	/** Pumps until `target` closes, or the connection does. */
	public function pumpUntilClosed(target:H2Stream):Void {
		while (!target.isClosed() && pump()) {}
	}

	public function goAway(code:H2ErrorCode, ?debug:String):Void {
		if (__closed) {
			return;
		}

		var message:Bytes = debug == null ? Bytes.alloc(0) : Bytes.ofString(debug);
		var payload:Bytes = Bytes.alloc(8 + message.length);
		var lastId:Int = __nextStreamId - 2;
		if (lastId < 0) {
			lastId = 0;
		}

		__writeUInt32(payload, 0, lastId & 0x7fffffff);
		__writeUInt32(payload, 4, cast code);
		if (message.length > 0) {
			payload.blit(8, message, 0, message.length);
		}

		__writeFrame(H2FrameType.GOAWAY, 0, 0, payload);
	}

	/**
	 * Abandons one stream: closes it here, then tells the peer.
	 *
	 * Closed first, so that whatever the peer already has in flight for it is
	 * discarded when it arrives (RFC 9113, 5.1) -- including when the
	 * RST_STREAM itself cannot be written. A stream no longer open is left
	 * alone. One that has closed is over on both sides, and one closed by the
	 * peer's own RST_STREAM must not be answered with another (5.4.2); closed
	 * streams are forgotten, so either way it is not found here. Nor is an id
	 * never opened, and a RST_STREAM on an idle stream is itself an error (5.1).
	 */
	public function resetStream(id:Int, code:H2ErrorCode):Void {
		var target:Null<H2Stream> = __streams.get(id);
		if (target == null || target.isClosed()) {
			return;
		}
		__closeStream(target);
		__writeReset(id, code);
	}

	private function __writeReset(id:Int, code:H2ErrorCode):Void {
		var payload:Bytes = Bytes.alloc(4);
		__writeUInt32(payload, 0, cast code);
		__writeFrame(H2FrameType.RST_STREAM, 0, id, payload);
	}

	/**
	 * Ends a stream and tells anyone waiting on it.
	 *
	 * Every close routes through here. A stream that closed without the
	 * notification leaves its caller blocked until a timeout, which reads as a
	 * hung server rather than as a finished request.
	 */
	private function __closeStream(target:H2Stream):Void {
		if (target.isClosed()) {
			return;
		}

		target.close();
		// Forgotten as it closes. A pooled connection carries requests for as
		// long as it is used, and keeping every stream it had opened grew it
		// by one stream and its header list per request, and made every
		// SETTINGS walk all of them. Nothing needs a closed stream by id:
		// whoever waits on it holds the stream itself, and a frame arriving
		// for it later is discarded as one for an unknown id, which is what
		// 5.1 asks for a closed stream.
		__streams.remove(target.id);
		onStreamClosed(target);
	}

	// ------------------------------------------------------------- dispatch

	private function __dispatch(frame:H2Frame):Void {
		// §6.10: once a header block is open, the only legal next frame is a
		// CONTINUATION on the same stream. Anything else -- even a PING, which
		// is otherwise always allowed -- is a connection error, because the
		// fragments would no longer be contiguous.
		if (__continuationStreamId >= 0) {
			if (frame.type != H2FrameType.CONTINUATION || frame.streamId != __continuationStreamId) {
				throw new H2ConnectionError(H2ErrorCode.PROTOCOL_ERROR,
					'Expected CONTINUATION on stream $__continuationStreamId, got ${frame.toString()}');
			}
			__continueHeaders(frame);
			return;
		}

		switch (frame.type) {
			case DATA:
				__onData(frame);
			case HEADERS:
				__onHeaders(frame);
			case RST_STREAM:
				__onRstStream(frame);
			case SETTINGS:
				__onSettings(frame);
			case PING:
				__onPing(frame);
			case GOAWAY:
				__onGoAway(frame);
			case WINDOW_UPDATE:
				__onWindowUpdate(frame);
			case PRIORITY:
				// §5.3.2 deprecates priority signalling; the frame stays legal
				// and carries no meaning we act on.
			case PUSH_PROMISE:
				// We advertise ENABLE_PUSH=0 by default, and §8.4 makes a
				// promise against that setting a connection error.
				throw new H2ConnectionError(H2ErrorCode.PROTOCOL_ERROR, "PUSH_PROMISE received after ENABLE_PUSH was disabled");
			case CONTINUATION:
				// Unreachable through the guard above, so this is a
				// CONTINUATION with no header block open.
				throw new H2ConnectionError(H2ErrorCode.PROTOCOL_ERROR, "CONTINUATION with no preceding HEADERS");
			case _:
				// §4.1: an unknown frame type must be discarded, which is what
				// lets the protocol be extended without breaking us.
		}
	}

	private function __onHeaders(frame:H2Frame):Void {
		if (frame.streamId == 0) {
			throw new H2ConnectionError(H2ErrorCode.PROTOCOL_ERROR, "HEADERS on stream 0");
		}

		var payload:Bytes = frame.payload;
		if (frame.has(H2Flags.PADDED)) {
			payload = H2Frame.stripPadding(payload, frame.streamId);
		}
		if (frame.has(H2Flags.PRIORITY)) {
			// 4 octets of stream dependency plus one of weight, all of it
			// deprecated but still occupying space ahead of the fragment.
			if (payload.length < 5) {
				throw new H2ConnectionError(H2ErrorCode.FRAME_SIZE_ERROR, "HEADERS with PRIORITY is too short for the priority fields");
			}
			payload = payload.sub(5, payload.length - 5);
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

		__completeHeaders(streamId, block, endsStream);
	}

	/**
	 * Adds a fragment to the open header block, refusing a block grown past
	 * `maxHeaderBlockSize`. A connection error, as on the server: the block
	 * cannot be decoded, and HPACK is connection state.
	 */
	private function __appendHeaderFragment(payload:Bytes):Void {
		if (maxHeaderBlockSize >= 0 && __continuationLength + payload.length > maxHeaderBlockSize) {
			throw new H2ConnectionError(H2ErrorCode.ENHANCE_YOUR_CALM, 'Header block exceeded $maxHeaderBlockSize bytes across its CONTINUATION frames');
		}
		__continuationBuffer.addBytes(payload, 0, payload.length);
		__continuationLength += payload.length;
	}

	private function __completeHeaders(streamId:Int, block:Bytes, endStream:Bool):Void {
		var decoded:Array<HpackHeader>;
		try {
			decoded = __decoder.decode(block);
		} catch (e:HpackError) {
			// §4.3: a decoding failure is fatal to the connection, not the
			// stream. The dynamic table is shared, so every later block would
			// decode against a table the peer no longer agrees with.
			throw new H2ConnectionError(H2ErrorCode.COMPRESSION_ERROR, "HPACK decoding failed: " + e.message);
		}

		var target:Null<H2Stream> = __streams.get(streamId);
		if (target == null) {
			// A response for a stream we already finished with -- closed
			// streams are forgotten as they close. Discarding is correct; the
			// peer may simply not have seen our RST_STREAM yet. Filling it in
			// instead let a response arriving after a cancel complete the
			// request it was for. The block is still decoded above: 5.1
			// requires the HPACK state to advance even for a frame that is
			// then dropped.
			return;
		}
		target.framesIn++;

		if (__decoder.truncated) {
			// Decoded to its end, so the table is still the peer's, but past
			// the limit. RFC 9113 10.5.1 lets a client discard a response it
			// cannot process; the stream is given up, and the connection and
			// every other request on it carry on.
			target.failure = 'Response header section exceeded the ${__decoder.maxHeaderListSize} byte limit';
			resetStream(target.id, H2ErrorCode.CANCEL);
			return;
		}

		// RFC 9113 8.2.1 holds a response to the rules a request is held to:
		// a CR, LF or NUL in a value, or a name that is not visible lowercase
		// ASCII, is a malformed response, a stream error (8.1.1). It reached
		// the caller's headers, and a program passing them on over HTTP/1.1
		// wrote the line break with them. Checked before any field is kept.
		for (header in decoded) {
			var problem:Null<String> = H2FieldRules.violation(header.name, header.value);
			if (problem != null) {
				target.failure = "Malformed response: " + problem;
				resetStream(target.id, H2ErrorCode.PROTOCOL_ERROR);
				return;
			}
		}

		if (target.headerSectionReceived) {
			// After the final response's header block, a HEADERS is the
			// trailer section (RFC 9113 8.1): it ends the stream and carries
			// no pseudo-header. Any other was taken as more of the response --
			// its fields added, its status over the last -- so a server that
			// repeated a block grew the stream by a block's fields each time,
			// for as long as it went on. Each is held to the limit on its own,
			// as the HTTP/1.1 client holds trailers apart from the header.
			var problem:Null<String> = !endStream ? "a header block after the response's did not end the stream" : null;
			for (header in decoded) {
				if (problem == null && StringTools.startsWith(header.name, ":")) {
					problem = "a pseudo-header field in the trailers";
				}
			}
			if (problem != null) {
				target.failure = "Malformed response: " + problem;
				resetStream(target.id, H2ErrorCode.PROTOCOL_ERROR);
				return;
			}
			for (header in decoded) {
				target.headers.push(header);
			}
			target.endOfStream = true;
			__closeStream(target);
			return;
		}

		// The response's header section is one allowance, its interim
		// responses included, as the HTTP/1.1 client's is: each 1xx was held
		// to the limit on its own and dropped, so 103s could come for as long
		// as a server liked, each a frame of the stream that kept it from its
		// idle timeout.
		target.sectionBytes += __decoder.listSize;
		if (target.sectionBytes > __decoder.maxHeaderListSize) {
			target.failure = 'Response header section exceeded the ${__decoder.maxHeaderListSize} byte limit';
			resetStream(target.id, H2ErrorCode.CANCEL);
			return;
		}

		// An interim response -- 100 Continue, 103 Early Hints -- is a header
		// block of its own ahead of the final one (RFC 9113 8.1). Its fields
		// are not the response's and its status is not the response's, so the
		// block is dropped and the final one waited for. Every block's fields
		// were added to the stream's, so a 200 after a 103 carried the 103's
		// link. One that ends the stream is malformed: the response it
		// promises cannot follow.
		for (header in decoded) {
			if (header.name == ":status") {
				if (__informational(header.value)) {
					if (endStream) {
						target.failure = "Malformed response: an informational status ended the stream";
						resetStream(target.id, H2ErrorCode.PROTOCOL_ERROR);
					}
					return;
				}
				break;
			}
		}

		for (header in decoded) {
			if (header.name == ":status") {
				// Three digits (§8.3.2), read the same on every target. Past
				// an Int, Std.parseInt made "4294967496" a 200 on Linux native.
				var parsed:Int = header.value.length == 3 ? IntParse.decimal(header.value) : -1;
				target.status = parsed < 100 ? -1 : parsed;
			} else {
				target.headers.push(header);
			}
		}
		target.headerSectionReceived = true;

		if (endStream) {
			target.endOfStream = true;
			__closeStream(target);
		}
	}

	private function __onData(frame:H2Frame):Void {
		if (frame.streamId == 0) {
			throw new H2ConnectionError(H2ErrorCode.PROTOCOL_ERROR, "DATA on stream 0");
		}

		// Flow control counts the whole payload, padding included (§6.9.1),
		// even for a stream we have already discarded -- otherwise the
		// connection window drifts and eventually stalls every other stream.
		var counted:Int = frame.payload.length;
		__connectionRecvWindow -= counted;
		__connectionUnacknowledged += counted;

		var content:Bytes = frame.has(H2Flags.PADDED) ? H2Frame.stripPadding(frame.payload, frame.streamId) : frame.payload;

		var target:Null<H2Stream> = __streams.get(frame.streamId);
		if (target != null) {
			// What lets a client's timeout be time without progress on this
			// stream rather than a deadline on the whole response.
			target.framesIn++;
			target.recvWindow -= counted;
			target.unacknowledged += counted;

			if (target.maxBodyLength > 0 && content.length > target.maxBodyLength - target.bodyLength) {
				// Given up, as the HTTP/1.1 client gives up a body past its
				// limit, and let go of at once: the caller is told why, and
				// what the server sends the stream from here is counted for
				// the connection's window and dropped.
				target.failure = 'Response body exceeded ${target.maxBodyLength} bytes';
				target.dropBody();
				resetStream(target.id, H2ErrorCode.CANCEL);
				__topUpConnectionWindow();
				return;
			}
			target.appendBody(content);

			if (frame.has(H2Flags.END_STREAM)) {
				target.endOfStream = true;
				__closeStream(target);
			} else {
				__topUpStreamWindow(target);
			}
		}

		__topUpConnectionWindow();
	}

	private function __onRstStream(frame:H2Frame):Void {
		if (frame.payload.length != 4) {
			throw new H2ConnectionError(H2ErrorCode.FRAME_SIZE_ERROR, 'RST_STREAM payload is ${frame.payload.length} bytes, not 4');
		}

		// Not on a stream already closed, which is no longer in the map:
		// after our own reset, the peer's crossing RST_STREAM would otherwise
		// rewrite why this one ended.
		var target:Null<H2Stream> = __streams.get(frame.streamId);
		if (target != null) {
			target.resetCode = __readUInt32(frame.payload, 0);
			__closeStream(target);
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

		// §6.9.2: a change to INITIAL_WINDOW_SIZE retunes every open stream by
		// the delta. It does not reset them to the new value, and it does not
		// touch the connection window.
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
		__writeFrame(H2FrameType.SETTINGS, H2Flags.ACK, 0, Bytes.alloc(0));
	}

	private function __onPing(frame:H2Frame):Void {
		if (frame.payload.length != 8) {
			throw new H2ConnectionError(H2ErrorCode.FRAME_SIZE_ERROR, 'PING payload is ${frame.payload.length} bytes, not 8');
		}
		if (frame.has(H2Flags.ACK)) {
			return;
		}
		// §6.7: echo the payload exactly.
		__writeFrame(H2FrameType.PING, H2Flags.ACK, 0, frame.payload);
	}

	private function __onGoAway(frame:H2Frame):Void {
		if (frame.payload.length < 8) {
			throw new H2ConnectionError(H2ErrorCode.FRAME_SIZE_ERROR, "GOAWAY payload is shorter than 8 bytes");
		}

		goAwayLastStreamId = __readUInt32(frame.payload, 0) & 0x7fffffff;
		goAwayCode = __readUInt32(frame.payload, 4);

		// Streams above the peer's last-processed id were never handled, so
		// they are safe to retry elsewhere; §6.8 exists to make that
		// distinction possible.
		var refused:Array<H2Stream> = [];
		for (target in __streams) {
			if (target.id > goAwayLastStreamId) {
				refused.push(target);
			}
		}
		// Closed once the walk is over: closing a stream takes it out of the
		// map being walked.
		for (target in refused) {
			target.resetCode = H2ErrorCode.REFUSED_STREAM;
			__closeStream(target);
		}
	}

	private function __onWindowUpdate(frame:H2Frame):Void {
		if (frame.payload.length != 4) {
			throw new H2ConnectionError(H2ErrorCode.FRAME_SIZE_ERROR, 'WINDOW_UPDATE payload is ${frame.payload.length} bytes, not 4');
		}

		var increment:Int = __readUInt32(frame.payload, 0) & 0x7fffffff;
		if (increment == 0) {
			// §6.9: a zero increment is an error, on the connection or the
			// stream depending on where it arrived.
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
	}

	// -------------------------------------------------------- flow control

	/**
	 * Returns credit once half the window is spent.
	 *
	 * Per-frame updates would double the frame count on a download; waiting
	 * for the window to empty stalls the peer. Half is the usual compromise.
	 */
	private function __topUpStreamWindow(target:H2Stream):Void {
		var initial:Int = localSettings.initialWindowSize;
		if (target.unacknowledged < (initial >> 1)) {
			return;
		}

		var increment:Int = target.unacknowledged;
		target.unacknowledged = 0;
		target.recvWindow += increment;

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
		__connectionRecvWindow += increment;

		var payload:Bytes = Bytes.alloc(4);
		__writeUInt32(payload, 0, increment);
		__writeFrame(H2FrameType.WINDOW_UPDATE, 0, 0, payload);
	}

	// ---------------------------------------------------------------- write

	private function __writeHeaderBlock(streamId:Int, block:Bytes, endStream:Bool):Void {
		var limit:Int = remoteSettings.maxFrameSize;
		var offset:Int = 0;
		var first:Bool = true;

		// A block longer than the peer's max frame size has to be split across
		// CONTINUATION frames rather than sent oversized.
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

	/**
	 * Writes a request body, splitting on both the peer's frame size and the
	 * two flow-control windows.
	 *
	 * When a window closes, the only way it reopens is a WINDOW_UPDATE from
	 * the peer, so this pumps to find one. That is also why a caller must not
	 * hold a lock across a large body.
	 */
	private function __writeData(target:H2Stream, body:Bytes):Void {
		var offset:Int = 0;

		while (offset < body.length) {
			// When this stall began. Frames that leave the window shut do not
			// restart it; sending part of the body does.
			var stalledSince:Float = -1;
			while (target.sendWindow <= 0 || __connectionSendWindow <= 0) {
				if (stalledSince < 0) {
					stalledSince = haxe.Timer.stamp();
				}
				var proceed:Bool = onWindowBlocked != null ? onWindowBlocked(target, haxe.Timer.stamp() - stalledSince) : pump();

				// The peer may end the stream while the body waits here: with
				// a response sent before it read the whole request (RFC 9113,
				// 8.1), or with a reset -- and so may a cancel or a timeout,
				// which reset it here. Frames are processed, and a cancel can
				// take the lock, only while this waits, so this is the one
				// place to notice. The rest of the
				// body has nowhere to go, and a closed stream's window never
				// reopens -- a WINDOW_UPDATE for it is discarded -- so waiting
				// on went on until the connection was quiet long enough to be
				// given up on, and every other request on it went too.
				//
				// Tested before `proceed`, so a stream that ended keeps its
				// outcome even when the connection fails straight after.
				if (target.isClosed()) {
					if (target.endOfStream) {
						// Ended with a response rather than a reset. The peer's
						// half is over but ours is not, and it would hold the
						// stream open, counted against its concurrency limit,
						// for an END_STREAM that is not coming. A write that
						// fails here must not cost the response already
						// received; the connection's own reader reports the
						// connection.
						try {
							__writeReset(target.id, H2ErrorCode.CANCEL);
						} catch (_:Dynamic) {}
					}
					return;
				}

				if (!proceed) {
					throw new H2ConnectionError(H2ErrorCode.FLOW_CONTROL_ERROR, "Connection closed while waiting for a flow-control window");
				}
			}

			var chunk:Int = body.length - offset;
			if (chunk > remoteSettings.maxFrameSize) {
				chunk = remoteSettings.maxFrameSize;
			}
			if (chunk > target.sendWindow) {
				chunk = target.sendWindow;
			}
			if (chunk > __connectionSendWindow) {
				chunk = __connectionSendWindow;
			}

			var last:Bool = (offset + chunk) >= body.length;
			__writeFrame(H2FrameType.DATA, last ? H2Flags.END_STREAM : 0, target.id, body.sub(offset, chunk));

			target.sendWindow -= chunk;
			__connectionSendWindow -= chunk;
			offset += chunk;
		}
	}

	private function __writeFrame(type:H2FrameType, flags:Int, streamId:Int, payload:Bytes):Void {
		__write(H2Frame.encode(type, flags, streamId, payload));
	}

	private function __write(bytes:Bytes):Void {
		// Full, not writeBytes, which may write only part and says how much.
		// Over TLS it takes at most one 16 KB record, and a DATA frame of the
		// default largest size is 16 KB and nine: the frame's last nine bytes
		// were dropped, and the peer read the next frame's header out of the
		// middle of this one's payload.
		__output.writeFullBytes(bytes, 0, bytes.length);
		__output.flush();
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

	/** Whether a `:status` value is a 1xx: three digits, the first a 1. */
	private static function __informational(status:String):Bool {
		if (status.length != 3) {
			return false;
		}
		var parsed:Int = IntParse.decimal(status);
		return parsed >= 100 && parsed < 200;
	}
}
