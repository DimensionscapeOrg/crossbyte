package crossbyte._internal.http;

// Not built for the browser, for the same reason as the rest of the server.
#if !(js && !nodejs)
import crossbyte._internal.http.H2ResponseWriter;
import crossbyte.http.HTTPRequestHandler;
import crossbyte.http.HTTPServerConfig;
import crossbyte._internal.http.h2.H2ErrorCode;
import crossbyte._internal.http.h2.H2ServerConnection;
import crossbyte._internal.http.h2.H2ServerRequest;
import crossbyte._internal.php.PHPBridge;
import crossbyte.core.CrossByte;
import crossbyte.core._internal.PassFlush;
import crossbyte.events.Event;
import crossbyte.events.HTTPStatusEvent;
import crossbyte.events.ProgressEvent;
import crossbyte.io.ByteArray;
import crossbyte.net.Socket;
import crossbyte.utils.Logger;
import haxe.io.Bytes;

/**
 * Serves one HTTP/2 connection through the ordinary request pipeline.
 *
 * The counterpart to `HTTPRequestHandler`, which owns a socket and parses
 * HTTP/1.1 off it. This owns a socket and runs frames off it instead, then
 * hands each decoded request to a `HTTPRequestHandler` that has been given an
 * `H2ResponseWriter` rather than a socket to write to. Routing, middleware,
 * static files, CORS and PHP are reached unchanged -- that is what the writer
 * split bought.
 *
 * One handler per stream, not per connection. `HTTPRequestHandler` holds the
 * state of exactly one request/response, and HTTP/2 can have many in flight at
 * once on a single socket; sharing one would interleave them.
 */
@:access(crossbyte.http.HTTPRequestHandler)
class H2ConnectionHandler implements PassFlush {
	private final __socket:Socket;
	private final __config:HTTPServerConfig;
	private final __php:PHPBridge;
	private final __connection:H2ServerConnection;

	// The server's per-response hook, which is where metrics are recorded.
	// HTTP/1.1 handlers were hooked to it and these were not, so no HTTP/2
	// response was ever counted.
	private final __onResponse:Null<(HTTPStatusEvent, HTTPRequestHandler) -> Void>;

	// Set while a close is waiting for the end of the pass: see __onDrained.
	private var __closeQueued:Bool = false;

	// The server's sweep, which each stream's writer registers a body it is
	// pumping out with (see HTTPResponseWriter.sweepWith), and this its check
	// of what it holds for the client (see __hold).
	private final __sweepWith:Null<({}, Null<Float->Void>) -> Void>;

	// maxOutputBufferSize: the bytes this connection may hold for its client,
	// across its streams, before its next requests wait. 0 for no limit.
	private final __budget:Int;

	// What the socket's buffer is held to: see __outputRoom.
	private final __watermark:Int;

	// Requests waiting for the connection to hold less than __budget, in the
	// order they arrived, or null: see __serve.
	private var __parked:Null<Array<H2ServerRequest>> = null;

	// Set while __checkHeld is registered with the sweep.
	private var __holding:Bool = false;

	// The socket's progress as __checkHeld last saw it -- bytes the system has
	// taken -- and when what it holds is given up if that has not moved.
	private var __socketMark:Float = 0;
	private var __socketDeadline:Float = 0;

	// When the socket last finished sending what it held: an idle connection is
	// idle from then, not from when its last stream ended. 0 for never.
	private var __outputDrainedAt:Float = 0;

	/**
	 * @param buffered Bytes already read off the socket, if this connection was
	 *        identified by looking at them. Fed to the frame layer before
	 *        anything else, since they are the start of the preface.
	 * @param sweepWith The server's sweep, for its streams' writers and for
	 *        this.
	 */
	public function new(socket:Socket, config:HTTPServerConfig, ?php:PHPBridge, ?buffered:ByteArray,
			?onResponse:(HTTPStatusEvent, HTTPRequestHandler) -> Void, ?sweepWith:({}, Null<Float->Void>) -> Void) {
		__socket = socket;
		__config = config;
		__php = php;
		__onResponse = onResponse;
		__sweepWith = sweepWith;
		__budget = config.maxOutputBufferSize > 0 ? config.maxOutputBufferSize : 0;
		__watermark = (__budget > 0 && __budget < HTTPRequestHandler.STREAM_WATERMARK) ? __budget : HTTPRequestHandler.STREAM_WATERMARK;

		__connection = new H2ServerConnection(__send);
		__connection.maxResetStreams = config.http2MaxResetStreams;
		__connection.resetWindowSeconds = config.http2ResetWindowSeconds;
		// The limit an HTTP/1.1 body is held to. Without it DATA piled up for
		// as long as a client sent it.
		__connection.maxRequestBodySize = config.maxRequestBodySize;
		// What HTTP/1.1 closes after: keepAliveMaxRequests responses, or one
		// with keepAlive off. A GOAWAY says so here.
		__connection.maxRequests = config.keepAlive ? config.keepAliveMaxRequests : 1;
		__connection.onRequest = __serve;
		__connection.onRequestHead = __admit;
		__connection.onDrained = __onDrained;
		__connection.onConnectionError = __onConnectionError;
		__connection.outputRoom = __outputRoom;
		__connection.onHolding = __hold;
		__connection.stallSeconds = HTTPRequestHandler.STREAM_STALL_SECONDS;

		__socket.addEventListener(ProgressEvent.SOCKET_DATA, __onData);
		__socket.addEventListener(Event.CLOSE, __onClosed);

		// One drain slot on the socket, many streams behind it. The connection
		// owns the fan-out, so a streaming response on one stream cannot
		// silence another's resume.
		__socket.__onWritableDrain = __onWritable;

		if (buffered != null && buffered.length > 0) {
			__receive(buffered);
		}
	}

	private function __send(bytes:Bytes):Void {
		if (!__socket.connected) {
			return;
		}

		__socket.writeBytes(bytes, 0, bytes.length);

		// While a read is being taken apart, what it answers at once goes out
		// together when it is done (see __receive). Every frame was flushed
		// on its own -- SETTINGS, its acknowledgement, each response's HEADERS
		// and DATA -- a system call apiece: two a request, where HTTP/1.1
		// pays one. A frame sent at any other time, an answer that came later,
		// still goes at once.
		if (!__receiving) {
			__flushOut();
		}
	}

	// Set while __receive hands a read to the frame layer.
	private var __receiving:Bool = false;

	private function __onData(_:ProgressEvent):Void {
		var inbound:ByteArray = new ByteArray();
		__socket.readBytes(inbound, 0);
		if (inbound.length == 0) {
			return;
		}

		__receive(inbound);
	}

	/** Hands `inbound` to the frame layer, and sends what it answered with in one write. **/
	private function __receive(inbound:ByteArray):Void {
		__receiving = true;
		try {
			__connection.receive(inbound, 0, inbound.length);
			// What it gave room for -- a WINDOW_UPDATE, a reset -- goes with
			// the rest of its answers.
			if (__parked != null) {
				__serveParked();
			}
		} catch (error:Dynamic) {
			__receiving = false;
			__flushOut();
			throw error;
		}
		__receiving = false;
		__flushOut();
	}

	private function __flushOut():Void {
		if (__socket.connected) {
			__socket.flush();
			// What the system would not take yet is held to a deadline.
			if (!__holding && __socket.outputBufferLength > 0) {
				__hold();
			}
		}
	}

	/** A writer's flush: at once, unless a read is being answered, which flushes when it is done. **/
	private function __flushUnlessReceiving():Void {
		if (!__receiving) {
			__flushOut();
		}
	}

	/**
	 * The socket's drain, which this connection's streams share: they are
	 * offered the room it has made, then waiting requests theirs.
	 */
	private function __onWritable():Void {
		__connection.notifyWritable();
		if (__parked != null) {
			__serveParked();
		}
	}

	/**
	 * Bytes the socket's buffer may still be given before the rest waits in
	 * the streams' queues (`H2ServerConnection.outputRoom`): what keeps the
	 * queue, not the socket, holding what the network has not taken, and the
	 * socket under its output cap.
	 */
	private function __outputRoom():Int {
		return __watermark - __socket.outputBufferLength;
	}

	/**
	 * What this connection holds for its client: what its streams have
	 * queued behind flow control, and what its socket has not sent.
	 */
	public var heldBytes(get, never):Int;

	private inline function get_heldBytes():Int {
		return __held();
	}

	private inline function __held():Int {
		return __connection.queuedBytes + __socket.outputBufferLength;
	}

	/** Whether a drain has started here, every stream it let finish has, and all they sent has gone. */
	public var drained(get, never):Bool;

	private inline function get_drained():Bool {
		return __connection.goingAway && __connection.openStreams == 0 && __socket.connected && __socket.outputBufferLength == 0;
	}

	/**
	 * Holds this connection to the stall deadline while it holds anything for
	 * its client: the server's sweep runs `__checkHeld` until it holds
	 * nothing. Called when a stream is left with bytes waiting, and when a
	 * flush leaves bytes in the socket. Whatever the timeouts are, as for a
	 * body being pumped out: a response written whole and held -- by flow
	 * control, or by a socket its client stopped reading -- had no deadline
	 * at all, and with `keepAliveTimeout` at `0` was held for good.
	 */
	private function __hold():Void {
		if (__holding || __sweepWith == null || !__socket.connected) {
			return;
		}
		__holding = true;
		if (__socket.outputBufferLength > 0) {
			__socketMark = HTTPRequestHandler.__outputTaken(__socket);
			__socketDeadline = haxe.Timer.stamp() + HTTPRequestHandler.STREAM_STALL_SECONDS;
		} else {
			__socketDeadline = 0;
		}
		__sweepWith(this, __checkHeld);
	}

	private function __release():Void {
		if (!__holding) {
			return;
		}
		__holding = false;
		if (__sweepWith != null) {
			__sweepWith(this, null);
		}
	}

	/**
	 * The sweep's visit while this connection holds anything, at `now`
	 * (`haxe.Timer.stamp()`). A socket whose buffer its client has taken
	 * nothing of for the stall period is closed, as an HTTP/1.1 one is: it
	 * is not reading the connection at all. Otherwise the streams are held
	 * to it (`H2ServerConnection.expireHeld`): a stream whose window held
	 * its response that long is reset. When it was the connection's window,
	 * the requests waiting for room are refused as well, with
	 * REFUSED_STREAM -- never handed to the application, so safe for the
	 * client to send again -- rather than answered into a window it is not
	 * opening. Otherwise they go on as room is made.
	 */
	private function __checkHeld(now:Float):Void {
		if (!__socket.connected) {
			__release();
			return;
		}

		if (__socket.outputBufferLength > 0) {
			var taken:Float = HTTPRequestHandler.__outputTaken(__socket);
			if (__socketDeadline == 0 || taken != __socketMark) {
				__socketMark = taken;
				__socketDeadline = now + HTTPRequestHandler.STREAM_STALL_SECONDS;
			} else if (now >= __socketDeadline) {
				Logger.info('HTTP/2 client took nothing it was sent for ${HTTPRequestHandler.STREAM_STALL_SECONDS}s; closing.');
				close();
				return;
			}
		} else {
			if (__socketDeadline > 0) {
				// Gone, all of it: what an idle connection counts from.
				__outputDrainedAt = now;
			}
			__socketDeadline = 0;
		}

		if (__connection.expireHeld(now)) {
			Logger.info('HTTP/2 client opened no window for ${HTTPRequestHandler.STREAM_STALL_SECONDS}s with responses waiting; they are given up.');
			var refused:Null<Array<H2ServerRequest>> = __parked;
			__parked = null;
			if (refused != null) {
				for (request in refused) {
					if (__connection.hasStream(request.streamId)) {
						__connection.resetStream(request.streamId, H2ErrorCode.REFUSED_STREAM);
					}
				}
			}
			__flushOut();
		}

		if (__parked != null) {
			__serveParked();
		}

		if (drained) {
			close();
			return;
		}

		if (__connection.queuedBytes <= 0 && __socket.outputBufferLength <= 0) {
			__release();
		}
	}

	/**
	 * Holds the connection to its deadlines.
	 *
	 * Two, because they bound different things. A request still arriving
	 * owes the rest of itself within `requestTimeout` of its own HEADERS:
	 * one that has not is answered `408` on its stream, and the connection
	 * carries on with the rest. One that has arrived is the application's to
	 * answer, for as long as that takes -- a long poll, a slow upstream -- as
	 * an HTTP/1.1 request stops its clock once read. And a connection with no
	 * stream open is between requests, which HTTP/2 is designed for, so it
	 * has the keep-alive allowance, counted from when its last stream ended.
	 *
	 * Neither is moved by what does not advance a request. Every frame read
	 * or written set one clock back, so a client trickling a byte of body
	 * every 0.4 s, or sending nothing but PINGs, held a connection open past
	 * both for as long as it cared to. A request late under that clock took
	 * the whole connection with it, and every other stream on it.
	 *
	 * Without this an HTTP/2 connection was never reaped at all: the sweep
	 * only walked HTTP/1.1 handlers, so a peer could open connections and go
	 * silent, and each one lived until the process did.
	 *
	 * @param now `haxe.Timer.stamp()`, as the server's sweep reads it once
	 *        for every handler it visits, HTTP/1.1 and HTTP/2 alike.
	 */
	public function checkDeadline(now:Float):Void {
		// A draining connection ends when its last stream does.
		if (drained) {
			close();
			return;
		}

		var timeout:Float = __config.requestTimeout;
		if (timeout > 0 && __connection.receivingStreams > 0) {
			// The 408s it writes go out together, as answers to a read do.
			__receiving = true;
			var going:Bool;
			try {
				going = __connection.expireRequests(now - timeout);
			} catch (error:Dynamic) {
				__receiving = false;
				__flushOut();
				throw error;
			}
			__receiving = false;
			__flushOut();

			if (!going) {
				// A header block stalled partway: nothing else can be read
				// until it ends, and it is not ending.
				Logger.info('HTTP/2 header block still unfinished after ${timeout}s; closing.');
				close();
				return;
			}
		}

		// Not idle while a stream is open. A body being pumped out on one has
		// a deadline of its own, its stall check, which the server's sweep
		// calls through the stream's writer whatever the timeouts are.
		if (__connection.openStreams > 0) {
			return;
		}

		// Nor while what the last of them sent is still going out, which has
		// the stall deadline of its own (__checkHeld). Counted from when its
		// last stream ended, a slow client still taking the end of a response
		// had it cut off as idle.
		if (__socket.outputBufferLength > 0) {
			return;
		}

		var limit:Float = __config.keepAliveTimeout;
		var since:Float = __connection.idleSince > __outputDrainedAt ? __connection.idleSince : __outputDrainedAt;
		var idle:Float = now - since;
		if (limit <= 0 || idle < limit) {
			return;
		}

		Logger.info('HTTP/2 connection idle for ${Math.round(idle)}s; closing.');
		close();
	}

	/**
	 * The connection has said it will take no more streams and the last it
	 * took has ended, which `keepAliveMaxRequests` and `keepAlive` off are
	 * how it comes to say. Closed at the end of the pass, once what that
	 * stream wrote has gone, rather than from inside the write that ended
	 * it. Left to the sweep, it waited a quarter second, and with both
	 * timeouts off, which leaves no sweep, for the client.
	 */
	private function __onDrained():Void {
		if (__closeQueued || !__socket.connected) {
			return;
		}

		var runtime:Null<CrossByte> = #if nodejs @:privateAccess __socket.__nodeRuntime #else @:privateAccess __socket.__cbInstance #end;
		if (runtime == null) {
			runtime = CrossByte.current();
		}
		if (runtime == null) {
			return;
		}

		__closeQueued = true;
		runtime.__queuePassFlush(this);
	}

	@:noCompletion public function __flushPass():Void {
		__closeQueued = false;
		if (drained) {
			close();
		}
	}

	/**
	 * Starts a graceful shutdown: a GOAWAY now, so the peer opens no more
	 * streams here, while the ones it has run to their end. The connection
	 * closes at once when none are open, and otherwise when the last one
	 * finishes, which the server's sweep checks -- once what they sent has
	 * gone: closed with it still in the socket, it was cut off.
	 */
	public function beginDrain():Void {
		__connection.goAwayGracefully();
		if (drained) {
			close();
		}
	}

	/** Ends the connection, telling the peer why before the socket goes. */
	public function close():Void {
		try {
			__connection.goAway(H2ErrorCode.NO_ERROR);
		} catch (_:Dynamic) {}

		if (__socket.connected) {
			// The GOAWAY, and anything else held for the end of a read this
			// close came in the middle of.
			try {
				__socket.flush();
			} catch (_:Dynamic) {}
			__socket.close();
		}
	}

	/**
	 * Weighs a request whose body is still to come, as `onRequestHead`: a
	 * handler is made for it now, and it carries the request on once the
	 * body has arrived.
	 */
	private function __admit(request:H2ServerRequest):Bool {
		var handler:HTTPRequestHandler = __handlerFor(request);
		var mark:Int = request.path.indexOf("?");
		var admitted:Bool = false;
		try {
			admitted = handler.__admitDecodedRequest(request.method, mark >= 0 ? request.path.substr(0, mark) : request.path,
				mark >= 0 ? request.path.substr(mark + 1) : "", __fieldsOf(request), request.startedAt, true, request.declaredLength);
		} catch (error:Dynamic) {
			// As the HTTP/1.1 parser answers what serving a request threw.
			Logger.error("HTTP/2 request handling failed: " + error);
			if (!handler.__responded) {
				try {
					handler.__sendErrorResponse(500, "Internal Server Error");
				} catch (_:Dynamic) {}
			}
			admitted = false;
		}

		if (admitted) {
			request.context = handler;
		}
		return admitted;
	}

	/**
	 * Hands a request whose body has arrived to the application -- or, while
	 * this connection holds `maxOutputBufferSize` for its client, keeps it
	 * until the client has taken enough of that (`__serveParked`), in the
	 * order requests came.
	 *
	 * Each stream's response waited whole on its client's window, so a
	 * client that opened 128 streams and no window held 128 responses here,
	 * up to the cap apiece: a gigabyte at the default. Its requests now wait
	 * instead, as an HTTP/1.1 connection's next request waits behind the
	 * response going out, so what one connection holds stays near its cap,
	 * however many streams it opens. They wait rather than being refused:
	 * REFUSED_STREAM would turn a slow reader's page into errors or retries,
	 * and resetting a stream already answered would throw the answer away.
	 * A refusal of the server's own -- a `413`, `408` or `431` -- is a few
	 * bytes, answered at once.
	 */
	private function __serve(request:H2ServerRequest):Void {
		if (!request.tooLarge && !request.timedOut && !request.headersTooLarge && (__parked != null || __overBudget())) {
			if (__parked == null) {
				__parked = [];
			}
			__parked.push(request);
			return;
		}
		__serveNow(request);
	}

	private inline function __overBudget():Bool {
		return __budget > 0 && __held() >= __budget;
	}

	/** Serves the requests `__serve` kept, in order, while there is room. */
	private function __serveParked():Void {
		while (__parked != null && !__overBudget()) {
			var request:H2ServerRequest = __parked.shift();
			if (__parked.length == 0) {
				__parked = null;
			}
			// Its client may have reset it while it waited: there is no one
			// to answer.
			if (__connection.hasStream(request.streamId)) {
				__serveNow(request);
			}
		}
	}

	private function __serveNow(request:H2ServerRequest):Void {
		var body:ByteArray = new ByteArray();
		if (request.body.length > 0) {
			body.writeBytes(request.body, 0, request.body.length);
			body.position = 0;
		}

		// Admitted at its headers, so only the body is left to give it.
		var admitted:Null<HTTPRequestHandler> = request.context;
		if (admitted != null) {
			request.context = null;
			try {
				admitted.__continueDecodedRequest(body, request.tooLarge, request.timedOut);
			} catch (error:Dynamic) {
				__serveFailed(admitted, request.streamId, error);
			}
			return;
		}

		// :path carries the query string; the pipeline below wants them apart,
		// the same way the HTTP/1.1 parser splits a request target.
		var target:String = request.path;
		var query:String = "";
		var mark:Int = target.indexOf("?");
		if (mark >= 0) {
			query = target.substr(mark + 1);
			target = target.substr(0, mark);
		}

		var handler:HTTPRequestHandler = __handlerFor(request);
		try {
			handler.__serveDecodedRequest(request.method, target, query, __fieldsOf(request), body, request.tooLarge, request.headersTooLarge,
				request.timedOut, request.startedAt);
		} catch (error:Dynamic) {
			__serveFailed(handler, request.streamId, error);
		}
	}

	/**
	 * Answers what serving a request threw outside any middleware -- the rate
	 * limiter, a status listener, the static files -- as the HTTP/1.1 parser
	 * answers it: `500`, while nothing of the response has gone out, and the
	 * stream reset once a head has, since no status can follow one (see
	 * `HTTPRequestHandler.__sendError`). A response already finished, or
	 * still being written, is left be.
	 *
	 * Every such throw reset the stream, `INTERNAL_ERROR`, so a request that
	 * could still have been answered got no status at all -- where one
	 * refused at its headers, through `__admit`, was answered `500`.
	 */
	private function __serveFailed(handler:HTTPRequestHandler, streamId:Int, error:Dynamic):Void {
		Logger.error("HTTP/2 request handling failed: " + error);
		try {
			handler.__sendErrorResponse(500, "Internal Server Error");
		} catch (_:Dynamic) {}

		if (!handler.__responded && __connection.hasStream(streamId)) {
			// The answer threw as well. The stream still ends, or its client
			// waits on it for as long as the connection lasts.
			__connection.resetStream(streamId, H2ErrorCode.INTERNAL_ERROR);
		}
	}

	/** A handler answering on `request`'s stream, hooked to the server's per-response hook. */
	private function __handlerFor(request:H2ServerRequest):HTTPRequestHandler {
		var writer = new H2ResponseWriter(__connection, __socket, request.streamId, __flushUnlessReceiving, __sweepWith);
		var handler = new HTTPRequestHandler(__socket, __config, __php, writer);
		if (__onResponse != null) {
			var onResponse = __onResponse;
			handler.addEventListener(HTTPStatusEvent.HTTP_RESPONSE_STATUS, e -> onResponse(e, handler));
		}
		return handler;
	}

	/** `request`'s fields by name, as the pipeline reads them. */
	private function __fieldsOf(request:H2ServerRequest):Map<String, String> {
		// Folded the way the HTTP/1.1 parser folds repeats, so a middleware
		// sees one shape regardless of protocol -- and cookie with "; ", which
		// is how §8.2.3 says its split crumbs join. A comma made
		// getCookie("sid") answer "abc123, theme=dark" for the cookies
		// browsers send as separate fields.
		//
		// Collected, then joined once per name. Each repeat was appended to
		// the whole value so far, which is quadratic in the repeats: 200,000
		// one-byte cookie crumbs, a block of about 200 KB, held the runtime's
		// thread for 23.5 seconds.
		var headers:Map<String, String> = new Map();
		var repeats:Null<Map<String, Array<String>>> = null;
		for (field in request.headers) {
			var first:Null<String> = headers.get(field.name);
			if (first == null) {
				headers.set(field.name, field.value);
				continue;
			}
			if (repeats == null) {
				repeats = new Map();
			}
			var values:Null<Array<String>> = repeats.get(field.name);
			if (values == null) {
				values = [first];
				repeats.set(field.name, values);
			}
			values.push(field.value);
		}
		if (repeats != null) {
			for (name => values in repeats) {
				headers.set(name, values.join(name == "cookie" ? "; " : ", "));
			}
		}

		// :authority is HTTP/2's Host. Middleware and rewrites still look for
		// host, so it is presented under that name.
		if (request.authority.length > 0 && !headers.exists("host")) {
			headers.set("host", request.authority);
		}

		return headers;
	}

	private function __onConnectionError(error:crossbyte._internal.http.h2.H2ConnectionError):Void {
		Logger.error("HTTP/2 connection error: " + error.message);
		if (__socket.connected) {
			// Found partway through a read, so its GOAWAY is still held.
			try {
				__socket.flush();
			} catch (_:Dynamic) {}
			__socket.close();
		}
	}

	private function __onClosed(_:Event):Void {
		__socket.removeEventListener(ProgressEvent.SOCKET_DATA, __onData);
		__socket.removeEventListener(Event.CLOSE, __onClosed);
		// No one is left to answer what waited.
		__parked = null;
		__release();
	}
}
#end
