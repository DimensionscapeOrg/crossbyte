package crossbyte.http;

// Not built for the browser, like the HTTPRequestHandler it reads from.
#if !(js && !nodejs)
import crossbyte.core.CrossByte;
import crossbyte.io.ByteArray;

/**
 * The body of a request read as it arrives, from
 * `HTTPRequestHandler.streamRequestBody`, rather than held whole in
 * `requestBody`: an upload written to disk as it comes, or a proxy passing a
 * body on.
 *
 * ```haxe
 * // Given config:crossbyte.http.HTTPServerConfig, upstream:crossbyte.net.Socket.
 * config.onRequestHead = handler -> {
 *     var body = handler.streamRequestBody();
 *     body.onData = (data, offset, length) -> {
 *         upstream.writeBytes(data, offset, length);
 *         return upstream.bytesPending < 256 * 1024;
 *     };
 *     body.onEnd = () -> handler.respond(200, "text/plain", "stored");
 *     return true;
 * };
 * ```
 *
 * Setting a callback here takes the request: it is the application's to
 * answer, and nothing past the middleware answers it for it.
 *
 * `onData` answering `false` stops the body until `resume`: the connection
 * stops reading, or under HTTP/2 stops opening the stream's window, and the
 * client is held back by TCP's or HTTP/2's own flow control. What the server
 * holds for a paused body is what had arrived by then: under HTTP/1.1 what one
 * pass read, a megabyte at most, and under HTTP/2 the stream's window, counted
 * against `http2MaxRequestBodyBuffer`. Nothing is delivered before `onData` is
 * set, so a body waits for a decision that takes a while (a lookup, a
 * connection being opened) with the same bound.
 *
 * The bytes are as they were sent: chunked framing is taken off, and a
 * `Content-Encoding` is not undone, since nothing here holds the whole body to
 * decode it. `maxRequestBodySize` still applies, and past it the body is
 * aborted and answered `413`.
 *
 * Callbacks run on the runtime serving the connection. `pause` and `resume`
 * may be called from any thread, as `HTTPRequestHandler.respond` may.
 */
class HTTPBodyReader {
	/**
	 * Called with each piece of the body as it arrives, `length` bytes of
	 * `data` from `offset`. Answer `true` for more, or `false` to stop until
	 * `resume`.
	 *
	 * `data` is the connection's own, only for this call: read it where it
	 * lies, leave its position alone, and copy what is kept past the call.
	 *
	 * Nothing is delivered until this is set, and never before the setting of
	 * it returns. A callback that throws fails the request: the error is
	 * logged, `onAbort` is called, and the request is answered `500`.
	 */
	public var onData(default, set):Null<(data:ByteArray, offset:Int, length:Int) -> Bool> = null;

	/**
	 * Called once, when every byte of the body has been given to `onData`,
	 * and for a request with no body. Not while the body is paused: a body
	 * paused on its last piece ends when it is resumed. Set after the body
	 * ended, it is called in a later turn. What it throws fails the request
	 * as a route's does: see `HTTPServerConfig.onError`.
	 */
	public var onEnd(default, set):Null<Void->Void> = null;

	/**
	 * Called once, when the body will not finish: the client left, a stream
	 * was reset, `requestTimeout` or `requestIdleTimeout` passed, the body
	 * outgrew `maxRequestBodySize`, its chunked framing was malformed, or the
	 * response ended first. Whatever was fed from it can be let go of.
	 *
	 * The server answers the request (`408`, `413`, `400`), when nothing of
	 * a response has gone out and this has not answered it; with a response
	 * begun it closes the connection, or resets the stream, since no status
	 * can follow one. Set after the body was given up, it is called in a
	 * later turn. What it throws is logged.
	 */
	public var onAbort(default, set):Null<Void->Void> = null;

	/** Whether `onData` is waiting for `resume`. */
	public var paused(get, never):Bool;

	@:noCompletion private var __handler:Null<HTTPRequestHandler>;
	// The runtime serving the connection, for a callback set after the body
	// has finished, which nothing else would call.
	@:noCompletion private final __owner:Null<CrossByte>;
	@:noCompletion private var __ended:Bool = false;
	@:noCompletion private var __aborted:Bool = false;
	@:noCompletion private var __told:Bool = false;

	@:noCompletion private function new(handler:HTTPRequestHandler, owner:Null<CrossByte>) {
		__handler = handler;
		__owner = owner;
	}

	/** Stops the body after the piece being delivered, as `onData` answering `false` does. From any thread. */
	public function pause():Void {
		var handler:Null<HTTPRequestHandler> = __handler;
		if (handler != null) {
			@:privateAccess handler.__pauseBody(this);
		}
	}

	/** Goes on with a body that `onData` or `pause` stopped. From any thread. */
	public function resume():Void {
		var handler:Null<HTTPRequestHandler> = __handler;
		if (handler != null) {
			@:privateAccess handler.__resumeBody(this);
		}
	}

	@:noCompletion private function get_paused():Bool {
		var handler:Null<HTTPRequestHandler> = __handler;
		return handler != null && @:privateAccess handler.__bodyPaused;
	}

	@:noCompletion private function set_onData(value:Null<(data:ByteArray, offset:Int, length:Int) -> Bool>):Null<(data:ByteArray, offset:Int, length:Int) -> Bool> {
		onData = value;
		var handler:Null<HTTPRequestHandler> = __handler;
		if (handler != null && value != null) {
			@:privateAccess handler.__bodyTaken = true;
			@:privateAccess handler.__bodyReaderSet(this);
		}
		return value;
	}

	@:noCompletion private function set_onEnd(value:Null<Void->Void>):Null<Void->Void> {
		onEnd = value;
		__noteTaken(value != null);
		if (__ended && value != null) {
			__tellLater();
		}
		return value;
	}

	@:noCompletion private function set_onAbort(value:Null<Void->Void>):Null<Void->Void> {
		onAbort = value;
		__noteTaken(value != null);
		if (__aborted && value != null) {
			__tellLater();
		}
		return value;
	}

	@:noCompletion private inline function __noteTaken(taken:Bool):Void {
		var handler:Null<HTTPRequestHandler> = __handler;
		if (handler != null && taken) {
			@:privateAccess handler.__bodyTaken = true;
		}
	}

	/**
		The body is over, whole or given up, and this reader is cut loose. With
		`tell` off, its handler tells it itself, once a call of `onData` under
		way has returned.
	**/
	@:noCompletion private function __finish(whole:Bool, tell:Bool):Void {
		if (__ended || __aborted) {
			return;
		}
		__handler = null;
		if (whole) {
			__ended = true;
		} else {
			__aborted = true;
		}
		if (tell) {
			__tell();
		}
	}

	@:noCompletion private function __tell():Void {
		if (__told || (!__ended && !__aborted)) {
			return;
		}
		var callback:Null<Void->Void> = __ended ? onEnd : onAbort;
		if (callback != null) {
			__told = true;
			callback();
		}
	}

	@:noCompletion private function __tellLater():Void {
		if (__told) {
			return;
		}
		if (__owner == null || !__owner.post(__tell)) {
			__tell();
		}
	}
}
#end
