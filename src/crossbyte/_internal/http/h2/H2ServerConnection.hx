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
	 * What one request's header section may decode to, by RFC 7541 4.1's
	 * accounting (each field's two strings and 32 more), before it is
	 * answered `431`. Advertised as SETTINGS_MAX_HEADER_LIST_SIZE.
	 *
	 * The limit an HTTP/1.1 request's header block is held to. The decoder
	 * allowed eight megabytes and nothing said so, and a block of 200,000
	 * one-byte references to a single cookie crumb -- about 200 KB on the
	 * wire -- decoded under it and then held the runtime's thread for 23.5
	 * seconds while the crumbs were joined.
	 */
	public static inline var DEFAULT_MAX_HEADER_LIST_SIZE:Int = 64 * 1024;

	/**
		The most window a stream receiving a body is opened to at once, as
		far as `requestBodyBudget` allows: enough that an upload over a long
		path is not held to a window a round trip. The protocol's 64 KB was
		all any stream had, so one upload over a 50 ms path went at about a
		megabyte a second.
	**/
	public static inline var STREAM_WINDOW_GOAL:Int = 1024 * 1024;

	// The least window worth a WINDOW_UPDATE of its own, short of all a stream
	// needs: one frame at the default size.
	private static inline var MIN_WINDOW_GRANT:Int = 16384;

	// Bytes let go are given back to the connection's window this many at a
	// time, or at once while it has less than this left.
	private static inline var CONNECTION_REFRESH:Int = 32768;

	// The first window each stream may be given, largest first: see
	// __fixBudget.
	private static final PREREAD_WINDOWS:Array<Int> = [H2Settings.DEFAULT_INITIAL_WINDOW_SIZE, 32768, 16384];

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

	/**
	 * Seconds both `maxResetStreams` and `maxControlReplies` are counted
	 * over. Zero or below ends every window as it starts, so nothing
	 * accumulates and neither budget can trip.
	 */
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

	/**
	 * Bytes one request body may reach before the request is refused.
	 * Negative disables the check, leaving the body held only to
	 * `requestBodyBudget`. Read as the preface ends.
	 *
	 * DATA was appended with no limit while window kept being granted, so one
	 * stream could make the server hold as much as it cared to send: a 3 MB
	 * upload reached a route the HTTP/1.1 path would have refused. Past this,
	 * the request is delivered at once with `tooLarge` set and no body, so it
	 * can be answered `413`; once that has gone out the stream is reset with
	 * NO_ERROR, which is §8.1's way of asking a client to stop sending, its
	 * window is never topped up again, and what still arrives is counted for
	 * the connection's window and dropped.
	 */
	public var maxRequestBodySize:Int = -1;

	/**
		Bytes of request body this connection holds at once, across every
		stream whose body is still arriving, or `0` and below for no limit.
		Never less than `maxRequestBodySize` and a byte, so one body of the
		largest size taken always fits, with room to tell one past it. Read
		as the preface ends.

		Held to it by flow control, not by refusing what arrives. The
		connection's window is opened to the budget and given back only for
		bytes let go -- a body handed over, dropped or reset -- so a client
		that keeps to its windows never sends more, and one that does not
		is a FLOW_CONTROL_ERROR. Each stream's first window, which a client
		may use unasked, is made small enough that every stream's fits with
		one whole body besides (see `__fixBudget`), and a stream's window is
		opened past it only from what is left once those first windows and
		every older stream's remaining body are set aside: the oldest can
		always finish, and the others wait for window rather than each
		taking a share and none of them finishing.

		Every stream let its body grow to `maxRequestBodySize` and both
		windows were opened again as each byte arrived, so a client
		uploading slowly on all 128 streams made the server hold 128 bodies,
		and nothing checked that a client kept to its windows at all.

		A stream left waiting for window ends rather than waits for good:
		once `stallSeconds` pass with no body arriving and none let go on
		the connection, it is reset with REFUSED_STREAM -- never handed to
		the application, so safe to send again (`expireWaiting`). And when
		the oldest stream cannot go on at all, which a client that keeps to
		the SETTINGS never brings about, the newest gives way the same way
		(`__unblockOldest`).

		The header sections of those streams are held to a quarter of it as
		well, by HPACK's accounting, and one past that is refused the same
		way as it arrives (see `__headerAllowance`).
	**/
	public var requestBodyBudget:Int = 0;

	/**
		Called when a stream starts waiting for window its connection has no
		budget to give: the owner then has `expireWaiting` asked a few times
		a second until `waitingStreams` is back to `0`.
	**/
	public var onWaiting:Void->Void = () -> {};

	/** Streams waiting for window the budget has no room for. See `requestBodyBudget`. */
	public var waitingStreams(get, never):Int;

	/** Request body held by the streams still receiving one. See `requestBodyBudget`. */
	public var heldRequestBytes(get, never):Int;

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
	 * `false` returned. Once the answer has gone out the stream is reset with
	 * NO_ERROR, which asks the client to stop sending the body, as for a body
	 * past `maxRequestBodySize`; with no answer written at all it is reset
	 * INTERNAL_ERROR. `true` lets the body come, and the request reaches
	 * `onRequest` once it has, carrying whatever this put in its `context`.
	 *
	 * HTTP/1.1 refuses a request on its headers -- too large by its
	 * `Content-Length`, or turned away by `Expect: 100-continue` -- before a
	 * byte of the body is read. HTTP/2 had no such moment: a request was seen
	 * only once its body was in.
	 */
	public var onRequestHead:H2ServerRequest->Bool = _ -> true;

	/**
	 * Called once the connection is going away and the last stream it let
	 * finish has ended, so its owner can close it. Called from inside
	 * whatever ended that stream -- a response's last write, a reset -- so
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

	/**
		How many more bytes the transport should be handed now, or `null` for
		no limit: asked once each time a stream's queue is written out, and a
		DATA frame goes only while there is room, the rest waiting in the
		queue for `notifyWritable`.

		The owner's socket buffer, held to a watermark. Without one, whatever
		the client's window allowed went straight into the socket's buffer: a
		client granting large windows over a slow network piled responses up
		there past the socket's output cap, which closes the connection, and
		what was queued could not be told from what had been sent.
	**/
	public var outputRoom:Null<Void->Int> = null;

	/**
		Called when a stream is left with bytes its windows will not let go
		yet and nothing was held before: the owner then holds the connection
		to `expireHeld` until `queuedBytes` is back to `0`.
	**/
	public var onHolding:Void->Void = () -> {};

	/**
		Seconds a response may wait on its client's window with none of it
		taken before `expireHeld` gives it up.
	**/
	public var stallSeconds:Float = 30;

	/** Response bytes this connection's streams hold that their windows have not let go. */
	public var queuedBytes(get, never):Int;

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
	private var __openStreams:Int = 0;

	// The request-body budget in force and the size a body is refused past,
	// both fixed as the preface ends: see requestBodyBudget.
	private var __budget:Int = 0;
	private var __bodyLimit:Int = 0;
	// What the client may still send on the connection: the window this side
	// opened, less what has arrived. Given back only for bytes let go.
	private var __recvWindow:Int = H2Settings.DEFAULT_INITIAL_WINDOW_SIZE;
	// Across the streams still receiving a body (H2Stream.budgeted): how many,
	// what they hold, and the windows they have open. Kept as they change.
	private var __budgeted:Int = 0;
	private var __bodyHeld:Int = 0;
	private var __promised:Int = 0;
	// Set once the client has acknowledged this side's SETTINGS: until then
	// it may still be using the protocol's first window on every stream.
	private var __settingsAcked:Bool = false;
	// The header sections of streams still receiving a body, by HPACK's
	// accounting, and what they are held to. A quarter of the budget, and
	// never less than one section at the list limit, fixed with it.
	//
	// A section with a body to come is held until the body has arrived, and
	// HPACK makes one cheap to send: 128 streams, each a 4 KB cookie fifteen
	// times over, grew the heap by 9.3 MB from 318 KB on the wire, and with
	// requestTimeout off for good. Flow control cannot hold back a HEADERS,
	// so one past this is refused, REFUSED_STREAM, never having reached the
	// application. Answered and bodiless requests are not counted: they are
	// handed over at once.
	private var __headersHeld:Int = 0;
	private var __headerAllowance:Int = 0x7FFFFFFF;
	// Streams marked waiting, and set when a stream let go of what it held,
	// for __settle.
	private var __waiting:Int = 0;
	private var __released:Bool = false;
	private var __settling:Bool = false;
	// Counts every byte of body taken in and every stream let go of, and the
	// stall check's view of it: see expireWaiting.
	private var __budgetMoves:Int = 0;
	private var __waitMark:Int = 0;
	private var __waitDeadline:Float = 0;
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

	// Every stream's queued bytes, kept as they change: see queuedBytes.
	private var __queuedTotal:Int = 0;
	// Set while something is queued, from when onHolding was called.
	private var __holding:Bool = false;
	// DATA bytes sent on the connection, and the stall check's view of them:
	// see expireHeld.
	private var __dataOut:Int = 0;
	private var __stallMark:Int = 0;
	private var __stallDeadline:Float = 0;

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

	private inline function get_queuedBytes():Int {
		return __queuedTotal;
	}

	private inline function get_receivingStreams():Int {
		return __openStreams - __answering;
	}

	private inline function get_waitingStreams():Int {
		return __waiting;
	}

	private inline function get_heldRequestBytes():Int {
		return __bodyHeld;
	}

	/** Marks a stream's request handed over, before the handler can answer it. */
	private inline function __markDelivered(target:H2Stream):Void {
		__release(target);
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

			// Once per read, not per frame: what the read let go of is given
			// out again, oldest stream first.
			__settle();
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
	 * come first and to be the only pseudo-header on a response. `body` is
	 * kept as it is until sent, as `sendData` keeps it.
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

		if (status >= 200) {
			target.answered = true;
		}
		__writeHeaderBlock(streamId, __encoder.encode(block), endStream);

		if (endStream) {
			// Through __finishStream, which releases the stream's concurrency
			// slot. This removed the stream from the map without it, so every
			// response with no body -- a 204, a 304, any HEAD -- kept its slot
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
	 * that they were accepted -- `queuedFor` is how a caller applying
	 * backpressure finds out the difference.
	 *
	 * `body` is kept as it is until it has been sent, not copied, so it must
	 * not be changed after this.
	 */
	public function sendData(streamId:Int, body:Null<Bytes>, endStream:Bool):Void {
		if (closed) {
			return;
		}

		var target:Null<H2Stream> = __streams.get(streamId);
		if (target == null || target.isClosed()) {
			return;
		}

		if (body != null && body.length > 0) {
			// Kept as it is until sent, not copied: the caller hands it over.
			target.queue(body);
			__queuedTotal += body.length;
		}
		if (endStream) {
			target.pendingEndStream = true;
		}

		__flushStream(target);

		if (target.queued > 0) {
			__nowHolding(target);
		}
	}

	/**
		`target` is left with bytes waiting: its stall clock starts if it had
		none running, and if the connection held nothing before, the owner
		hears so (`onHolding`) and the connection's clock starts too. A clock
		read only here, never on a response its windows let go at once.
	**/
	private function __nowHolding(target:H2Stream):Void {
		if (target.stallDeadline == 0) {
			target.stallMark = target.dataOut;
			target.stallDeadline = haxe.Timer.stamp() + stallSeconds;
		}
		if (!__holding) {
			__holding = true;
			__stallMark = __dataOut;
			__stallDeadline = haxe.Timer.stamp() + stallSeconds;
			onHolding();
		}
	}

	/**
		Gives up what the client is taking none of, as the server's sweep
		asks a few times a second while `queuedBytes` is above `0`.

		A stream whose own window has kept its response from moving for
		`stallSeconds` is reset, INTERNAL_ERROR, and what it held let go; the
		connection carries on. A response written whole waited on its client's
		WINDOW_UPDATE with no deadline at all, so a client that paused a stream
		-- or opened one and never meant to read it -- held its response here
		for as long as the connection lasted. When it is the connection's
		window that has been spent, with nothing sent on the connection for
		`stallSeconds`, nothing on it can move until the client gives more,
		and every stream waiting is reset the same way. A stream waiting only
		on the transport is not held to this: its client takes what the socket
		gives it, and a socket nobody reads is the owner's to time.

		@param now `haxe.Timer.stamp()`.
		@return Whether the connection's window was what stalled: the owner
		        then has no reason to hand the application more requests for
		        this client.
	**/
	public function expireHeld(now:Float):Bool {
		if (closed) {
			return false;
		}
		if (__queuedTotal <= 0) {
			__holding = false;
			return false;
		}

		var connectionStalled:Bool = false;
		if (__dataOut != __stallMark || __stallDeadline == 0) {
			__stallMark = __dataOut;
			__stallDeadline = now + stallSeconds;
		} else if (now >= __stallDeadline && __connectionSendWindow <= 0) {
			connectionStalled = true;
		}

		// Gathered first: a reset removes the stream from the map being walked.
		var stalled:Null<Array<H2Stream>> = null;
		for (target in __streams) {
			if (target.queued <= 0) {
				target.stallDeadline = 0;
				continue;
			}
			if (connectionStalled) {
				if (stalled == null) {
					stalled = [];
				}
				stalled.push(target);
				continue;
			}
			if (target.sendWindow > 0 || target.dataOut != target.stallMark || target.stallDeadline == 0) {
				// Moving, or waiting on something other than its own window:
				// its clock runs from now.
				target.stallMark = target.dataOut;
				target.stallDeadline = now + stallSeconds;
				continue;
			}
			if (now >= target.stallDeadline) {
				if (stalled == null) {
					stalled = [];
				}
				stalled.push(target);
			}
		}

		if (stalled != null) {
			for (target in stalled) {
				if (__streams.get(target.id) == target) {
					resetStream(target.id, H2ErrorCode.INTERNAL_ERROR);
				}
			}
		}
		return connectionStalled;
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
	 * Calls `callback` if `streamId` is reset before it ends, by the peer --
	 * the client abandoning a response -- or by this side with `resetStream`:
	 * either way the response is over, which a producer writing one as it
	 * goes has to hear about. Called once; dropped, uncalled, when the stream
	 * ends normally.
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
	 * Writes as much of a stream's queue as both windows allow, and the
	 * transport has room for (`outputRoom`).
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
		// Asked once, not per frame.
		var room:Int = outputRoom == null ? 0x7FFFFFFF : outputRoom();

		while (target.queued > 0) {
			var allowed:Int = target.sendWindow < __connectionSendWindow ? target.sendWindow : __connectionSendWindow;
			if (allowed <= 0) {
				// Blocked. The remainder stays queued until a WINDOW_UPDATE
				// brings us back through notifyWritable.
				return;
			}

			// The frame's header goes with it.
			var fits:Int = room - H2Frame.HEADER_SIZE;
			if (fits <= 0) {
				// The transport has its fill. The remainder stays queued until
				// it drains, which brings us back through notifyWritable.
				return;
			}

			var chunk:Int = target.queued;
			if (chunk > limit) {
				chunk = limit;
			}
			if (chunk > allowed) {
				chunk = allowed;
			}
			if (chunk > fits) {
				chunk = fits;
			}

			var last:Bool = target.queued == chunk && target.pendingEndStream;

			__write(target.takeFrame(chunk, last ? H2Flags.END_STREAM : 0));
			target.sendWindow -= chunk;
			__connectionSendWindow -= chunk;
			__queuedTotal -= chunk;
			target.dataOut += chunk;
			__dataOut += chunk;
			room = fits - chunk;

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

		if (target.stopBodyAtEnd) {
			// A refusal, now all gone: see __stopBody.
			resetStream(target.id, H2ErrorCode.NO_ERROR);
		}
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
		var target:Null<H2Stream> = __streams.get(streamId);
		if (target != null && __streams.remove(streamId)) {
			// What a stream reset with its body still arriving held goes back
			// to the budget.
			__release(target);
			__openStreams--;
			if (target.delivered) {
				__answering--;
			}
			__abandoned.remove(streamId);
			// What a reset stream still held goes with it, and out of the count.
			__queuedTotal -= target.queued;
			target.dropQueue();

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
		// What the late ones held goes to those still arriving.
		__settle();
		return true;
	}

	private function __refuseLate(target:H2Stream):Void {
		__release(target);
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

		// As for a body past the limit: the client is asked to stop sending
		// the rest.
		__stopBody(target);
	}

	/**
	 * Resets one stream, leaving the connection running, and calls what
	 * `setAbandonedCallback` registered for it, as a reset from the peer does.
	 *
	 * Whoever resets it, the response being written on it is over. Only the
	 * peer's reset said so, so a stream this side reset -- the peer sending
	 * DATA after ending it, a WINDOW_UPDATE of nothing -- left its producer
	 * writing into a stream that refused it, and a file being pumped out on
	 * it open, its pump waiting on a window that could no longer come.
	 */
	public function resetStream(streamId:Int, code:H2ErrorCode):Void {
		var payload:Bytes = Bytes.alloc(4);
		__writeUInt32(payload, 0, cast code);
		__writeFrame(H2FrameType.RST_STREAM, 0, streamId, payload);

		var target:Null<H2Stream> = __streams.get(streamId);
		if (target != null) {
			// Taken before __forget drops it.
			var abandoned:Null<Void->Void> = __abandoned.get(streamId);
			target.wasReset = true;
			target.close();
			__forget(streamId);
			__writable.remove(streamId);

			if (abandoned != null) {
				abandoned();
			}
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

	/** Whether `goAwayGracefully` has been called, or the client has sent a GOAWAY of its own. */
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
			// The budget decides the first window each stream is given, which
			// the SETTINGS carries.
			__fixBudget();
			__writeFrame(H2FrameType.SETTINGS, 0, 0, localSettings.toPayload());
			if (__budget > __recvWindow) {
				// Opened to the budget with the SETTINGS, so the client has the
				// room before its first DATA: the protocol's 64 KB would hold
				// every body arriving at once to that.
				__writeWindowUpdate(0, __budget - __recvWindow);
				__recvWindow = __budget;
			}
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
					__onGoAway(frame);
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
		// decoded -- __completeHeaders decodes and discards a block for a
		// stream it does not hold -- before the reset goes out. HPACK is
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
				// Until the client has acknowledged the SETTINGS that made it
				// smaller, it may be using the protocol's first window (6.9.2).
				if (!__settingsAcked && opened.recvWindow < H2Settings.DEFAULT_INITIAL_WINDOW_SIZE) {
					opened.recvWindow = H2Settings.DEFAULT_INITIAL_WINDOW_SIZE;
				}
				// Its first window is the client's to use unasked, so it is
				// counted against the budget from here.
				opened.budgeted = true;
				__budgeted++;
				__promised += opened.recvWindow;
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

		// Held until its body has arrived, and held to an allowance across
		// the connection: see __headerAllowance.
		var size:Int = __decoder.listSize;
		if (__headersHeld + size > __headerAllowance) {
			resetStream(streamId, H2ErrorCode.REFUSED_STREAM);
			return;
		}
		target.heldHeaders = size;
		__headersHeld += size;

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

		if (!onRequestHead(request)) {
			// Answered, or turned away, before its body. What arrives of it is
			// counted and dropped.
			__stopBody(target);
			return;
		}

		// Its window opened now to what its body needs, as far as the budget
		// goes, rather than a round trip into it.
		if (target.budgeted) {
			__offerWindow(target);
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
		__release(target);
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
			__stopBody(target);
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
		// An empty DATA may be sent into no window at all (6.9.1): it is how a
		// stream whose window the SETTINGS shrank below nothing still ends.
		if (counted > 0 && counted > __recvWindow) {
			// 6.9.1: a sender keeps to both windows. Nothing checked, so a
			// client that ignored them sent as much as it liked whatever
			// the windows said, and the budget they keep meant nothing.
			throw new H2ConnectionError(H2ErrorCode.FLOW_CONTROL_ERROR, 'DATA of $counted bytes on stream ${frame.streamId} past the $__recvWindow the connection window had left');
		}
		__recvWindow -= counted;

		var target:Null<H2Stream> = __streams.get(frame.streamId);
		if (target != null) {
			if (counted > 0 && counted > target.recvWindow) {
				// The stream alone ends; what it held goes back to the budget
				// with it, and this frame was never held.
				throw new H2StreamError(frame.streamId, H2ErrorCode.FLOW_CONTROL_ERROR,
					'DATA of $counted bytes past the ${target.recvWindow} the stream window had left');
			}
			target.recvWindow -= counted;
			if (target.budgeted) {
				__promised -= counted;
			}
		}

		var content:Bytes = frame.has(H2Flags.PADDED) ? H2Frame.stripPadding(frame.payload, frame.streamId) : frame.payload;

		if (target != null && target.endOfStream) {
			// 5.1: the peer ended this stream, so it is half-closed on its
			// side and DATA on it is a stream error. It was appended, and a
			// second END_STREAM delivered the request again -- a second
			// handler answering a stream the first was answering.
			throw new H2StreamError(frame.streamId, H2ErrorCode.STREAM_CLOSED, "DATA after the end of the stream");
		}
		if (target != null && !target.overflowed) {
			if (target.bodyLength + content.length > __bodyLimit) {
				__refuseOversized(target);
			} else {
				target.appendBody(content);
				if (target.budgeted) {
					__bodyHeld += content.length;
					__budgetMoves++;
				}

				if (frame.has(H2Flags.END_STREAM)) {
					target.endOfStream = true;
					__deliver(frame.streamId, target);
				} else if (target.budgeted) {
					__offerWindow(target);
				}
			}
		}

		// Padding, and DATA for a stream refused or gone, was never held.
		__topUpConnection();
	}

	/**
	 * Answers a request whose body outgrew `maxRequestBodySize`, and asks the
	 * client to stop sending it. See that field.
	 */
	private function __refuseOversized(target:H2Stream):Void {
		__release(target);
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

		// This tells the client the rest of its body is not wanted, without
		// calling it an error.
		__stopBody(target);
	}

	/**
		Asks the client to stop sending the body of a request refused before
		it all arrived, once the refusal has been answered: a reset, NO_ERROR,
		which §8.1 allows after a complete response. What arrives for the
		stream meanwhile is counted for the connection's window and dropped.

		Sent the moment the refusal was handed over, the reset ended the
		stream there, and with it whatever of the answer flow control was
		still holding: an error page past the client's window was cut off
		after its first 64 KB. It now waits for the answer to end. And a
		refusal whose answer threw before anything went out -- its `500`
		too -- was reset NO_ERROR all the same, telling the client a response
		was complete that never began: that is INTERNAL_ERROR, as for a
		request whose serving throws after its body is in.
	**/
	private function __stopBody(target:H2Stream):Void {
		__release(target);
		if (target.wasReset) {
			// The answer failed partway, or the client gave up first.
			return;
		}

		if (!target.answered) {
			resetStream(target.id, H2ErrorCode.INTERNAL_ERROR);
			return;
		}

		if (__streams.get(target.id) == target) {
			// Still going out. Its end resets the stream (__finishStream), and
			// until then it waits on its answer, not on the client's request.
			target.overflowed = true;
			target.takeBody();
			__markDelivered(target);
			target.stopBodyAtEnd = true;
			return;
		}

		resetStream(target.id, H2ErrorCode.NO_ERROR);
	}

	private function __deliver(streamId:Int, target:H2Stream):Void {
		// Before takeBody: what it held is counted out as it was.
		__release(target);
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

		target.wasReset = true;
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

	/**
		The client has applied this side's SETTINGS. A first window smaller
		than the protocol's holds from here on, and the streams it opened
		before had their windows shrunk by the difference as it did (6.9.2):
		they were counted at the protocol's, and what the budget counted for
		them comes back. Each still receiving a body is offered its window
		again, oldest first, since the shrinking can leave one with less than
		nothing, short of a body it was opened enough for: an upload sent
		before the client had read the SETTINGS stopped a byte short, its
		window below zero, and nothing opened it again.
	**/
	private function __acknowledged():Void {
		__settingsAcked = true;
		var delta:Int = localSettings.initialWindowSize - H2Settings.DEFAULT_INITIAL_WINDOW_SIZE;
		if (delta >= 0) {
			return;
		}
		var shrunk:Array<H2Stream> = [for (target in __streams) target];
		shrunk.sort((a, b) -> a.id - b.id);
		for (target in shrunk) {
			target.recvWindow += delta;
			if (target.budgeted) {
				__promised += delta;
			}
		}
		for (target in shrunk) {
			if (target.budgeted) {
				__offerWindow(target);
			}
		}
		__released = true;
	}

	private function __onSettings(frame:H2Frame):Void {
		if (frame.has(H2Flags.ACK)) {
			if (frame.payload.length != 0) {
				throw new H2ConnectionError(H2ErrorCode.FRAME_SIZE_ERROR, "SETTINGS ACK must have an empty payload");
			}
			if (!__settingsAcked) {
				__acknowledged();
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

	/**
		The client's GOAWAY (§6.8). Its last stream id names the last stream
		*this* side opened that the client will process -- a push, which this
		never sends -- so it says nothing about the streams the client opened:
		those are still answered, and what the client sends on them still
		read. It opens no more, one it opens anyway is refused as after a
		GOAWAY of this side's, and once the last open one has ended
		`onDrained` is called for the owner to close the connection. A GOAWAY
		carrying an error says the client is closing the connection now
		(§5.4.1), and it fails at once.

		It was read as the end of the connection: `closed` was set, so nothing
		the client sent after it was read and no response went out after it
		-- not one being worked on, nor one whose body was still arriving --
		while the socket itself was kept, for as long as a stream stayed open.
	**/
	private function __onGoAway(frame:H2Frame):Void {
		if (frame.streamId != 0) {
			throw new H2ConnectionError(H2ErrorCode.PROTOCOL_ERROR, 'GOAWAY on stream ${frame.streamId}');
		}
		if (frame.payload.length < 8) {
			throw new H2ConnectionError(H2ErrorCode.FRAME_SIZE_ERROR, 'GOAWAY payload is ${frame.payload.length} bytes, under 8');
		}

		var code:H2ErrorCode = __readUInt32(frame.payload, 4);
		if (code != H2ErrorCode.NO_ERROR) {
			// Answered with a GOAWAY of this side's own, which has no error to
			// report, and the connection ends.
			goAway(H2ErrorCode.NO_ERROR);
			onConnectionError(new H2ConnectionError(code, 'The client ended the connection: ${code.toString()}'));
			return;
		}

		// As after goAwayGracefully, without sending one: the client knows.
		if (!__goingAway) {
			__goingAway = true;
			__goAwayLastStreamId = __highestStreamId;
		}
		if (__openStreams == 0) {
			onDrained();
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

	/**
		Fixes the request-body budget, the size a body is refused past, and
		the first window every stream is given (SETTINGS_INITIAL_WINDOW_SIZE),
		before the SETTINGS that carries it goes out.

		That first window is the client's to use on every stream it opens,
		unasked, and nothing can take it back. Left at the protocol's 64 KB,
		128 streams' worth was 8 MB: a client opening a few more uploads than
		the budget held spent the connection's window on their first 64 KB
		each and left the oldest unable to finish. So it is the largest of
		64, 32 or 16 KB for which every stream's first window, and one whole
		body besides, fits the budget -- 16 KB at the defaults -- and a budget
		too small even for that is raised until it fits. A body past it is
		opened the rest of its way as its HEADERS arrive, so it costs a round
		trip only between 16 and 64 KB, and a large one far fewer than the
		64 KB a round trip it was held to.
	**/
	private function __fixBudget():Void {
		var budget:Float = requestBodyBudget > 0 ? requestBodyBudget : H2Settings.MAX_WINDOW_SIZE;
		if (maxRequestBodySize >= budget) {
			// One body of the largest size taken always fits, and the byte
			// past it, which is how a body over the limit is told.
			budget = maxRequestBodySize + 1.0;
		}
		if (budget < H2Settings.DEFAULT_INITIAL_WINDOW_SIZE) {
			// The client may send this much before it hears anything.
			budget = H2Settings.DEFAULT_INITIAL_WINDOW_SIZE;
		}
		if (budget > H2Settings.MAX_WINDOW_SIZE) {
			budget = H2Settings.MAX_WINDOW_SIZE;
		}
		__bodyLimit = maxRequestBodySize >= 0 && maxRequestBodySize < budget ? maxRequestBodySize : Std.int(budget) - 1;

		var streams:Int = localSettings.maxConcurrentStreams;
		if (requestBodyBudget > 0 && streams > 0) {
			// Every first window and the oldest body whole: see above.
			var whole:Float = __bodyLimit + 1.0;
			var first:Int = PREREAD_WINDOWS[PREREAD_WINDOWS.length - 1];
			for (candidate in PREREAD_WINDOWS) {
				if (whole + streams * (candidate : Float) <= budget) {
					first = candidate;
					break;
				}
			}
			if (whole + streams * (first : Float) > budget) {
				budget = whole + streams * (first : Float);
				if (budget > H2Settings.MAX_WINDOW_SIZE) {
					budget = H2Settings.MAX_WINDOW_SIZE;
				}
			}
			if (first < localSettings.initialWindowSize) {
				localSettings.initialWindowSize = first;
			}
		}
		__budget = Std.int(budget);

		// What a header section may decode to, as the decoder holds it.
		var section:Int = localSettings.maxHeaderListSize >= 0 ? localSettings.maxHeaderListSize : 8 * 1024 * 1024;
		__headerAllowance = (__budget >> 2) > section ? (__budget >> 2) : section;
	}

	/** Gives the connection's window back what is no longer held, a few kilobytes at a time unless it is running low. */
	private function __topUpConnection():Void {
		var returnable:Int = __budget - __bodyHeld - __recvWindow;
		if (returnable <= 0) {
			return;
		}
		if (returnable < CONNECTION_REFRESH && __recvWindow >= CONNECTION_REFRESH) {
			return;
		}
		__recvWindow += returnable;
		__writeWindowUpdate(0, returnable);
	}

	/**
		What `target` may yet send of its body: up to its `content-length`,
		or else to the byte past the limit, which is how a body over it is
		told.
	**/
	private function __need(target:H2Stream):Int {
		var whole:Int = __bodyLimit + 1;
		var declared:Int = target.request != null ? target.request.declaredLength : -1;
		if (declared >= 0 && declared < whole) {
			whole = declared;
		}
		var need:Int = whole - target.bodyLength;
		return need > 0 ? need : 0;
	}

	/** What `target` may need beyond the window it has open. */
	private inline function __reserve(target:H2Stream):Int {
		var reserve:Int = __need(target) - target.recvWindow;
		return reserve > 0 ? reserve : 0;
	}

	/**
		Opens `target`'s window toward what its body needs, up to
		`STREAM_WINDOW_GOAL`, once half of what it has is spent -- as far as
		the budget goes after every older stream's remaining body. Marks it
		waiting when that was not all the way, so what is let go later
		reaches it.
	**/
	private function __offerWindow(target:H2Stream):Void {
		var want:Int = __wanted(target);
		if (want <= 0) {
			__stopWaiting(target);
			return;
		}
		if (!target.waiting && target.recvWindow > ((want + target.recvWindow) >> 1)) {
			// More than half of what it would be opened to is still open.
			return;
		}
		if (__grant(target, want) == want) {
			__stopWaiting(target);
			return;
		}
		__startWaiting(target);
	}

	/**
		What `target`'s window would be opened by to reach what its body
		needs, up to `STREAM_WINDOW_GOAL`: `0` when it has that already, and
		when its body is in, since what is left is END_STREAM, which an empty
		DATA carries into no window at all (6.9.1).
	**/
	private function __wanted(target:H2Stream):Int {
		var need:Int = __need(target);
		if (need <= 0) {
			return 0;
		}
		var goal:Int = need < STREAM_WINDOW_GOAL ? need : STREAM_WINDOW_GOAL;
		var want:Int = goal - target.recvWindow;
		return want > 0 ? want : 0;
	}

	private function __startWaiting(target:H2Stream):Void {
		if (!target.waiting) {
			target.waiting = true;
			if (__waiting++ == 0) {
				// The stall clock starts with the first stream to wait, and is
				// moved on by whatever moves after: see expireWaiting.
				__waitMark = __budgetMoves;
				__waitDeadline = haxe.Timer.stamp() + stallSeconds;
			}
			onWaiting();
		}
	}

	private inline function __stopWaiting(target:H2Stream):Void {
		if (target.waiting) {
			target.waiting = false;
			if (--__waiting == 0) {
				__waitDeadline = 0;
			}
		}
	}

	/**
		Opens up to `want` more of `target`'s window from what the budget has
		left, and says how much it did. Set aside first: the first window of
		every stream the client may yet open, which it may use unasked, and
		every older stream's remaining body, so the oldest can always finish.
		Less than `want` is opened when that is all there is, and nothing when
		that is under a frame's worth.
	**/
	private function __grant(target:H2Stream, want:Int):Int {
		var room:Float = (__budget : Float) - __bodyHeld - __promised;
		var streams:Int = localSettings.maxConcurrentStreams;
		if (streams > __budgeted) {
			room -= (streams - __budgeted) * (localSettings.initialWindowSize : Float);
		}
		if (room > 0) {
			for (other in __streams) {
				if (other.budgeted && other.id < target.id) {
					room -= __reserve(other);
					if (room <= 0) {
						break;
					}
				}
			}
		}
		if (room < want && room < MIN_WINDOW_GRANT) {
			return 0;
		}
		var given:Int = room < want ? Std.int(room) : want;
		target.recvWindow += given;
		__promised += given;
		__writeWindowUpdate(target.id, given);
		return given;
	}

	/**
		Counts `target`'s body and window out of the budget, once: it has been
		handed over, refused, or reset. Before its body is taken, so what it
		held is counted out as it was.
	**/
	private function __release(target:H2Stream):Void {
		if (!target.budgeted) {
			return;
		}
		target.budgeted = false;
		__budgeted--;
		__bodyHeld -= target.bodyLength;
		__promised -= target.recvWindow;
		__headersHeld -= target.heldHeaders;
		target.heldHeaders = 0;
		__stopWaiting(target);
		__released = true;
		__budgetMoves++;
	}

	/**
		After whatever let budget go: the streams waiting for window are
		offered it, oldest first; the connection's window is given back what
		is no longer held; and if the oldest stream still receiving can go no
		further, newer ones give way (`__unblockOldest`).
	**/
	private function __settle():Void {
		if (closed || __settling) {
			return;
		}
		__settling = true;
		__offerReleased();
		__topUpConnection();
		if (__waiting > 0 || __recvWindow <= 0) {
			__unblockOldest();
			// What the streams that gave way held.
			__offerReleased();
			__topUpConnection();
		}
		__settling = false;
	}

	private inline function __offerReleased():Void {
		if (__released) {
			__released = false;
			if (__waiting > 0) {
				__offerWaiting();
			}
		}
	}

	/** Offers window to the waiting streams in the order they opened, stopping at the first the budget cannot serve whole. */
	private function __offerWaiting():Void {
		var waiting:Array<H2Stream> = [for (target in __streams) if (target.waiting) target];
		waiting.sort((a, b) -> a.id - b.id);
		for (target in waiting) {
			var want:Int = __wanted(target);
			if (want > 0 && __grant(target, want) < want) {
				return;
			}
			__stopWaiting(target);
		}
	}

	/**
		Lets the oldest stream still receiving a body go on when nothing else
		will: its own window spent with no budget to open it, or the
		connection's spent with every byte of the budget held. The newest
		stream gives way, with REFUSED_STREAM -- its request never reached
		the application, so the client may send it again -- and the next
		newest, until the oldest can move.

		A client that keeps to the SETTINGS never comes here: every first
		window is set aside before anything is opened beyond one, and every
		older body before a newer one. It is what is left for one that does
		not -- concurrency without a limit, say -- and is not asked before
		the client has acknowledged the SETTINGS: until then each stream is
		counted at the protocol's 64 KB, more than it can have, and the
		acknowledgement is on its way.
	**/
	private function __unblockOldest():Void {
		// A header block still arriving holds every other frame back (6.10);
		// once it ends this is asked again.
		if (__continuationStreamId >= 0 || !__settingsAcked) {
			return;
		}
		while (!closed) {
			var oldest:Null<H2Stream> = null;
			for (target in __streams) {
				if (target.budgeted && (oldest == null || target.id < oldest.id)) {
					oldest = target;
				}
			}
			if (oldest == null || __need(oldest) <= 0) {
				// Nothing receiving, or the oldest has its body and only has
				// END_STREAM to send, which costs no window.
				return;
			}

			var connectionSpent:Bool = __recvWindow <= 0;
			if (!connectionSpent) {
				if (oldest.recvWindow > 0) {
					return;
				}
				var want:Int = __wanted(oldest);
				var given:Int = __grant(oldest, want);
				if (given > 0) {
					if (given == want) {
						__stopWaiting(oldest);
					} else {
						__startWaiting(oldest);
					}
					return;
				}
			}

			// The newest other stream gives way: one holding body bytes when it
			// is the connection's window that is spent, since only those give
			// it back.
			var newest:Null<H2Stream> = null;
			for (target in __streams) {
				if (target.budgeted && target != oldest && (!connectionSpent || target.bodyLength > 0)
					&& (newest == null || target.id > newest.id)) {
					newest = target;
				}
			}
			if (newest == null) {
				return;
			}
			resetStream(newest.id, H2ErrorCode.REFUSED_STREAM);
			__topUpConnection();
		}
	}

	/**
		Refuses the streams waiting for window, with REFUSED_STREAM, once
		`stallSeconds` have passed with no body arriving and none let go on
		this connection: nothing is moving that could give them any, so they
		would wait for good. A stream that still has window to send into is
		left be; its client is the one keeping it, and `requestTimeout` is
		its deadline. The owner asks a few times a second while
		`waitingStreams` is above `0` (`onWaiting`).

		@param now `haxe.Timer.stamp()`.
	**/
	public function expireWaiting(now:Float):Void {
		if (closed || __waiting <= 0) {
			return;
		}
		if (__budgetMoves != __waitMark || __waitDeadline == 0) {
			// Something moved: the clock runs from now.
			__waitMark = __budgetMoves;
			__waitDeadline = now + stallSeconds;
			return;
		}
		if (now < __waitDeadline) {
			return;
		}

		// Gathered first: a reset removes the stream from the map being walked.
		var stuck:Array<H2Stream> = [for (target in __streams) if (target.waiting && target.recvWindow <= 0) target];
		for (target in stuck) {
			if (__streams.get(target.id) == target) {
				resetStream(target.id, H2ErrorCode.REFUSED_STREAM);
			}
		}
		// Those still waiting have window to send into; theirs runs anew.
		if (__waiting > 0) {
			__waitMark = __budgetMoves;
			__waitDeadline = now + stallSeconds;
		}
		__settle();
	}

	private function __writeWindowUpdate(streamId:Int, increment:Int):Void {
		var payload:Bytes = Bytes.alloc(4);
		__writeUInt32(payload, 0, increment);
		__writeFrame(H2FrameType.WINDOW_UPDATE, 0, streamId, payload);
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
		// without limit -- and each one costs a handler and a buffer. A client
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
