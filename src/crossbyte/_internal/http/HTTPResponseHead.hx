package crossbyte._internal.http;

import crossbyte.url.URLRequestHeader;

/**
 * A response's status and header fields, before any protocol frames them.
 *
 * This is the seam between deciding a response and writing one. Everything
 * above it (routing, static files, content negotiation, CORS, PHP) works
 * in these terms; everything below turns them into either an HTTP/1.1 header
 * block or an HTTP/2 HEADERS frame.
 *
 * `headers` is already in the order it should be sent and already sanitized by
 * the caller's own rules; a writer applies whatever its protocol additionally
 * requires. `keepAlive` and `contentLength` are decisions, not headers: HTTP/1
 * renders them as `Connection` and `Content-Length`, and HTTP/2 does neither,
 * because §8.2.2 makes `Connection` malformed and DATA framing carries the
 * length implicitly.
 *
 * A class, built from the same literal, so natively its fields are read
 * directly rather than looked up by name, seven times a response.
 */
@:structInit
final class HTTPResponseHead {
	public var statusCode:Int;
	public var statusMessage:String;
	public var headers:Array<URLRequestHeader>;

	/**
	 * Body length, or `null` when the status omits a body entirely, or,
	 * with `chunked`, when the body's length is not known yet.
	 */
	public var contentLength:Null<Int>;

	/** Whether the connection should survive this response. */
	public var keepAlive:Bool;

	/**
	 * A body of unknown length follows, written as it becomes available and
	 * ended by `endResponse`: chunked transfer coding under HTTP/1.1, DATA
	 * frames on a stream left open under HTTP/2.
	 */
	public var chunked:Bool = false;
}
