package crossbyte.http;

import haxe.io.Bytes;

/**
 * Immutable request data and callbacks passed to an HTTPBackend.
 *
 * A backend receives one of these per request and reports back through the
 * callbacks, in this order:
 *
 * 1. `onStatus`, once the response code is known.
 * 2. `onHeaders`, once the response header block is complete.
 * 3. `onProgress`, zero or more times as the body arrives.
 * 4. `onComplete` with the whole body, or `onError`, exactly one of the two,
 *    exactly once.
 *
 * A `1xx` response is informational and is not reported: the status and header
 * block that follow it are. When `followRedirects` is set and the backend
 * follows one, steps 1 to 3 repeat for each hop, so a caller watching
 * `onStatus` sees the redirect chain; only the final response reaches
 * `onComplete`.
 *
 * A class built from an object literal (`@:structInit`), as the anonymous
 * structure it was is built: the fields marked optional below may be left
 * out of one. Its fields are read directly natively, where a structure's
 * were looked up by name.
 */
@:structInit
final class HTTPRequestContext {
	/** Absolute request URL, including any query string already on it. */
	public var url:String;

	/** Uppercase HTTP method, such as `"GET"` or `"POST"`. */
	public var method:String;

	/**
	 * Additional request headers, each already formatted as `"Name: value"`.
	 *
	 * A backend supplies its own `Host`, `User-Agent` and framing headers;
	 * these are sent on top of that set.
	 */
	public var headers:Array<String>;

	/**
	 * Structured request parameters, or `null`.
	 *
	 * Distinct from `data`, which is a body to send verbatim. This is an
	 * anonymous object of key/value pairs, appended to the URL as a query
	 * string on `GET` and `HEAD` and sent as a form-encoded body otherwise.
	 * It is ignored when `data` is set, and dropped when a redirect rewrites
	 * the request to `GET`.
	 */
	public var requestData:Dynamic;

	/** `Content-Type` for the request body, or `null` when there is no body. */
	public var contentType:Null<String>;

	/**
	 * A request body to send as-is, text, sent as UTF-8, or bytes, or
	 * `null`. Takes precedence over `requestData`. Assigned from a `String`
	 * or `haxe.io.Bytes` as before; see `HTTPRequestBody`.
	 */
	public var data:Null<HTTPRequestBody>;

	/** The version this backend was resolved for. */
	public var version:HTTPVersion;

	/**
	 * Idle timeout in milliseconds: the longest the request may go with
	 * nothing arriving for it. `0` or less is none; see
	 * `URLRequest.idleTimeout`.
	 */
	public var timeout:Int;

	/** Value to send as the `User-Agent` request header. */
	public var userAgent:String;

	/** Whether the backend should follow `3xx` responses itself. */
	public var followRedirects:Bool;

	/**
	 * Whether a redirect from `https` to plain `http` may be followed. Absent
	 * means it may not; see `URLRequest.followInsecureRedirects`.
	 */
	public var followInsecureRedirects:Bool = false;

	/**
	 * Whether a cookie a redirect sets goes back on the hops after it, within
	 * this one request. Absent means it does not; see
	 * `URLRequest.manageCookies`.
	 */
	public var manageCookies:Bool = false;

	/**
	 * Told the absolute URL of each redirect the backend follows, before it
	 * asks for it, so the caller can say where the response came from.
	 */
	public var onRedirect:Null<(url:String) -> Void> = null;

	/**
	 * The most bytes a compressed response may decode to before the request
	 * fails; `<= 0` removes the limit. Absent means the built-in client's own
	 * default, 64 MB. See `URLRequest.maxDecompressedSize`.
	 */
	public var maxDecompressedSize:Int = 64 * 1024 * 1024;

	#if !(js && !nodejs)
	/**
	 * The TLS an `https` request asks for, or absent for the defaults: see
	 * `HTTPTLSOptions`. A backend applies it to the connection it opens,
	 * checks its pins once the handshake is done, and reuses a connection only
	 * for a request whose options are `HTTPTLSOptions.same` as the ones it was
	 * opened under.
	 */
	public var tls:Null<HTTPTLSOptions> = null;
	#end

	/**
	 * Signals that the caller has abandoned this request.
	 *
	 * A backend should register through `onCancel` and stop whatever it can:
	 * over HTTP/2 that means resetting the stream, which frees the slot it
	 * holds against the peer's concurrent-stream limit and stops the response
	 * body arriving. A backend that ignores the token is not wrong, only
	 * wasteful, the request still ends through `onError`.
	 *
	 * Cancellation arrives from another thread, since `load()` is blocking.
	 */
	public var cancelToken:HTTPCancelToken;

	/**
	 * Body bytes received so far, and the total when the response declares
	 * one. `bytesTotal` is `0` for a response of unknown length.
	 */
	public var onProgress:(bytesLoaded:Int, bytesTotal:Int) -> Void;

	/**
	 * Ends the request unsuccessfully. `data` optionally carries whatever body
	 * had been received before the failure.
	 */
	public var onError:(message:String, ?data:Bytes) -> Void;

	/** Ends the request with the complete response body. */
	public var onComplete:(data:Bytes) -> Void;

	/** Reports the response status code. */
	public var onStatus:(status:Int) -> Void;

	/**
	 * Reports the complete response header block.
	 *
	 * Field names are lowercased, since HTTP/1 header names are
	 * case-insensitive and HTTP/2 requires them lowercase on the wire.
	 * Repeated fields are joined with `", "`, except `set-cookie`, which is
	 * joined with `"\n"`: its values may contain commas of their own, so
	 * comma-joining them cannot be undone by the caller.
	 */
	public var onHeaders:(headers:Map<String, String>) -> Void;
}
