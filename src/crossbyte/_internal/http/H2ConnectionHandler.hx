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
class H2ConnectionHandler {
	private final __socket:Socket;
	private final __config:HTTPServerConfig;
	private final __php:PHPBridge;
	private final __connection:H2ServerConnection;

	/**
	 * @param buffered Bytes already read off the socket, if this connection was
	 *        identified by looking at them. Fed to the frame layer before
	 *        anything else, since they are the start of the preface.
	 */
	public function new(socket:Socket, config:HTTPServerConfig, ?php:PHPBridge, ?buffered:ByteArray) {
		__socket = socket;
		__config = config;
		__php = php;

		__connection = new H2ServerConnection(__send);
		__connection.maxResetStreams = config.http2MaxResetStreams;
		__connection.resetWindowSeconds = config.http2ResetWindowSeconds;
		__connection.onRequest = __serve;
		__connection.onConnectionError = __onConnectionError;

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

		__connection.receive(inbound, 0, inbound.length);
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

		var headers:Map<String, String> = new Map();
		for (field in request.headers) {
			if (headers.exists(field.name)) {
				// Folded the way the HTTP/1.1 parser folds repeats, so a
				// middleware sees one shape regardless of protocol.
				headers.set(field.name, headers.get(field.name) + ", " + field.value);
			} else {
				headers.set(field.name, field.value);
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

		try {
			handler.__serveDecodedRequest(request.method, target, query, headers, body);
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
