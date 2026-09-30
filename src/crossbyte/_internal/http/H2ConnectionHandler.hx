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
 * static files, CORS and PHP are reached unchanged, that is what the writer
 * split bought.
 *
 * One handler per stream, not per connection. `HTTPRequestHandler` holds the
 * state of exactly one request/response, and HTTP/2 can have many in flight at
 * once on a single socket; sharing one would interleave them.
 */
@:access(crossbyte.http.HTTPRequestHandler)
class H2ConnectionHandler {
	private final __socket:Socket;
	private final __config:HTTPServerConfig;
	private final __php:PHPBridge;
	private final __connection:H2ServerConnection;

	// The server's per-response hook, which is where metrics are recorded.
	// HTTP/1.1 handlers were hooked to it and these were not, so no HTTP/2
	// response was ever counted.
	private final __onResponse:Null<(HTTPStatusEvent, HTTPRequestHandler) -> Void>;

	// Advanced on every read. An HTTP/2 connection is idle between requests
	// by design, so silence alone means nothing, what matters is silence
	// for longer than the configuration allows.
	//
	// On haxe.Timer.stamp(), the clock checkDeadline is handed. The sweep once
	// handed it Sys.time() while this was stamped, and on cpp and Node, where
	// those are different clocks, every connection read as idle since 1970
	// and was closed at the first sweep, a request in flight or not.
	private var __lastActivity:Float;

	/**
	 * @param buffered Bytes already read off the socket, if this connection was
	 *        identified by looking at them. Fed to the frame layer before
	 *        anything else, since they are the start of the preface.
	 */
	public function new(socket:Socket, config:HTTPServerConfig, ?php:PHPBridge, ?buffered:ByteArray,
			?onResponse:(HTTPStatusEvent, HTTPRequestHandler) -> Void) {
		__socket = socket;
		__config = config;
		__php = php;
		__onResponse = onResponse;

		__connection = new H2ServerConnection(__send);
		__connection.maxResetStreams = config.http2MaxResetStreams;
		__connection.resetWindowSeconds = config.http2ResetWindowSeconds;
		// The limit an HTTP/1.1 body is held to. Without it DATA piled up for
		// as long as a client sent it.
		__connection.maxRequestBodySize = config.maxRequestBodySize;
		__connection.onRequest = __serve;
		__connection.onConnectionError = __onConnectionError;

		__lastActivity = haxe.Timer.stamp();

		__socket.addEventListener(ProgressEvent.SOCKET_DATA, __onData);
		__socket.addEventListener(Event.CLOSE, __onClosed);

		// One drain slot on the socket, many streams behind it. The connection
		// owns the fan-out, so a streaming response on one stream cannot
		// silence another's resume.
		__socket.__onWritableDrain = __connection.notifyWritable;

		if (buffered != null && buffered.length > 0) {
			__connection.receive(buffered, 0, buffered.length);
		}
	}

	private function __send(bytes:Bytes):Void {
		if (!__socket.connected) {
			return;
		}

		// A response going out is activity too: idle time counts from the
		// last frame either way, so a connection that has just answered a
		// long poll is not taken for one silent since the request came in.
		__lastActivity = haxe.Timer.stamp();

		var out:ByteArray = new ByteArray();
		out.writeBytes(bytes, 0, bytes.length);
		__socket.writeBytes(out, 0, out.length);
		__socket.flush();
	}

	private function __onData(_:ProgressEvent):Void {
		var inbound:ByteArray = new ByteArray();
		__socket.readBytes(inbound, 0);
		if (inbound.length == 0) {
			return;
		}

		__lastActivity = haxe.Timer.stamp();
		__connection.receive(inbound, 0, inbound.length);
	}

	/** Whether a drain has started here and every stream it let finish has. */
	public var drained(get, never):Bool;

	private inline function get_drained():Bool {
		return __connection.goingAway && __connection.openStreams == 0 && __socket.connected;
	}

	/**
	 * Closes the connection if it has gone quiet for longer than allowed.
	 *
	 * Two deadlines, because silence means different things. With no stream
	 * open the peer is simply between requests, which HTTP/2 is designed for,
	 * so it gets the keep-alive idle allowance. With a request still arriving
	 * it owes a body that never came, and that is the request timeout. With
	 * every open stream's request in hand the wait is the application's, and
	 * there is no deadline.
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

		// A request still arriving owes its bytes within requestTimeout. One
		// that has arrived is the application's to answer, for as long as that
		// takes, a long poll, a slow upstream, as an HTTP/1.1 request stops
		// its clock once read. Open streams all counted as arriving, so a long
		// poll answering after requestTimeout found its connection gone, and
		// every other stream on it with it.
		var limit:Float;
		if (__connection.receivingStreams > 0) {
			limit = __config.requestTimeout;
		} else if (__connection.openStreams > 0) {
			return;
		} else {
			limit = __config.keepAliveTimeout;
		}

		var idle:Float = now - __lastActivity;
		if (limit <= 0 || idle < limit) {
			return;
		}

		Logger.info('HTTP/2 connection idle for ${Math.round(idle)}s; closing.');
		close();
	}

	/**
	 * Starts a graceful shutdown: a GOAWAY now, so the peer opens no more
	 * streams here, while the ones it has run to their end. The connection
	 * closes at once when none are open, and otherwise when the last one
	 * finishes, which the server's sweep checks.
	 */
	public function beginDrain():Void {
		__connection.goAwayGracefully();
		if (__connection.openStreams == 0) {
			close();
		}
	}

	/** Ends the connection, telling the peer why before the socket goes. */
	public function close():Void {
		try {
			__connection.goAway(H2ErrorCode.NO_ERROR);
		} catch (_:Dynamic) {}

		if (__socket.connected) {
			__socket.close();
		}
	}

	private function __serve(request:H2ServerRequest):Void {
		// :path carries the query string; the pipeline below wants them apart,
		// the same way the HTTP/1.1 parser splits a request target.
		var target:String = request.path;
		var query:String = "";
		var mark:Int = target.indexOf("?");
		if (mark >= 0) {
			query = target.substr(mark + 1);
			target = target.substr(0, mark);
		}

		// Folded the way the HTTP/1.1 parser folds repeats, so a middleware
		// sees one shape regardless of protocol, and cookie with "; ", which
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

		var body:ByteArray = new ByteArray();
		if (request.body.length > 0) {
			body.writeBytes(request.body, 0, request.body.length);
			body.position = 0;
		}

		var writer = new H2ResponseWriter(__connection, __socket, request.streamId);
		var handler = new HTTPRequestHandler(__socket, __config, __php, writer);
		if (__onResponse != null) {
			var onResponse = __onResponse;
			handler.addEventListener(HTTPStatusEvent.HTTP_RESPONSE_STATUS, e -> onResponse(e, handler));
		}

		try {
			handler.__serveDecodedRequest(request.method, target, query, headers, body, request.tooLarge, request.headersTooLarge);
		} catch (error:Dynamic) {
			Logger.error("HTTP/2 request handling failed: " + error);
			__connection.resetStream(request.streamId, H2ErrorCode.INTERNAL_ERROR);
		}
	}

	private function __onConnectionError(error:crossbyte._internal.http.h2.H2ConnectionError):Void {
		Logger.error("HTTP/2 connection error: " + error.message);
		if (__socket.connected) {
			__socket.close();
		}
	}

	private function __onClosed(_:Event):Void {
		__socket.removeEventListener(ProgressEvent.SOCKET_DATA, __onData);
		__socket.removeEventListener(Event.CLOSE, __onClosed);
	}
}
#end
