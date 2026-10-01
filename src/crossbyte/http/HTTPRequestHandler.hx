package crossbyte.http;

// Not built for the browser: it answers requests on an accepted connection and streams files from disk.
#if !(js && !nodejs)

import haxe.ds.StringMap;
import haxe.io.BytesBuffer;
import haxe.io.Path;
import crossbyte.events.Event;
import crossbyte.events.EventDispatcher;
import crossbyte.events.HTTPStatusEvent;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ProgressEvent;
import crossbyte.io.ByteArray;
import crossbyte.io.File;
import crossbyte.io.FileMode;
import crossbyte.io.FileStream;
import crossbyte.net.RateLimiter;
import crossbyte.net.Socket;
import crossbyte.http.HTTPContentCoding;
import crossbyte.url.URL;
import crossbyte.url.URLRequestHeader;
import crossbyte.utils.CompressionAlgorithm;
import crossbyte.utils.IntParse;
import crossbyte.utils.LogCategory;
import crossbyte.utils.Logger;
import crossbyte.utils.LogLevel;
import crossbyte._internal.http.headers.AcceptEncoding;
import crossbyte._internal.http.headers.Connection;
import crossbyte._internal.http.DirectoryListings;
import crossbyte._internal.http.HttpSyntax;
import crossbyte._internal.php.PHPBridge;
import crossbyte._internal.php.PHPRequest;
import crossbyte._internal.php.PHPResponse;
import crossbyte._internal.php.PHPTimeout;
import crossbyte._internal.http.Http;
import crossbyte._internal.http.RewriteEngine;
import crossbyte._internal.http.HTTP1ResponseWriter;
import crossbyte._internal.http.HTTPResponseWriter;

/**
 * Incrementally parses and responds to HTTP requests over a `Socket`.
 *
 * The handler buffers incoming bytes until a complete request is available,
 * normalizes headers and request metadata, decodes supported request body
 * encodings before middleware/PHP routing, and dispatches
 * `HTTPStatusEvent.HTTP_RESPONSE_STATUS` whenever it sends a response.
 *
 * One handler serves a connection's whole life, not a single request.
 * The phases are encoded by fields rather than an enum: receiving
 * (request bytes arriving, `__awaitingBody` the body sub-state, deadline
 * armed with `requestTimeout`), dispatching (request fully consumed,
 * response being produced, deadline zeroed), idle (`__idle`, response
 * finished and kept alive, the same deadline field re-armed with
 * `keepAliveTimeout`), closed. With `keepAlive` off every response
 * closes and the handler collapses back to one-shot behavior.
 */
final class HTTPRequestHandler extends EventDispatcher {
	/**
	 * The access log's own category, one line per response at `INFO`. An
	 * operator quiets it with `Logger.setLevel("http.access", WARN)` and keeps
	 * everything else at `INFO`, where it used to share the one global level.
	 */
	@:noCompletion private static final ACCESS_LOG:LogCategory = Logger.category("http.access");

	/**
	 * Bytes a request's header block may take before it is answered `431`.
	 * The body has its own limit, `HTTPServerConfig.maxRequestBodySize`; the
	 * two used to share one megabyte, fixed.
	 */
	@:noCompletion private static inline var MAX_HEADER_BYTES:Int = 64 * 1024;

	/** The largest chunk-size read at all: seven hex digits' worth. */
	@:noCompletion private static inline var MAX_CHUNK_SIZE:Int = 0xFFFFFFF;

	/** Content codings one request body may stack. */
	@:noCompletion private static inline var MAX_REQUEST_CODINGS:Int = 2;
	@:noCompletion private static final ALLOWED_METHODS:Array<String> = ["GET", "HEAD", "OPTIONS", "POST"];

	/**
	 * Files at or below this size keep the buffered single-write path: the
	 * per-tick pump only pays for itself once a body is large enough that
	 * holding it whole is the greater cost.
	 */
	@:noCompletion private static inline var STREAM_THRESHOLD:Int = 256 * 1024;

	/**
	 * Bytes read from disk per pump iteration. Kept small because a partial
	 * socket flush re-copies the entire unsent tail on every retry; slices
	 * this size keep that recopy cheap where one huge write would price it
	 * at the whole body per attempt.
	 */
	@:noCompletion private static inline var STREAM_SLICE:Int = 64 * 1024;

	/**
	 * Stop feeding slices while at least this much is already buffered on
	 * the socket. This is the bound that makes streaming streaming: peak
	 * per-transfer memory is the watermark plus one slice, not the file.
	 */
	@:noCompletion private static inline var STREAM_WATERMARK:Int = 256 * 1024;

	/**
	 * Most one pump invocation will write before returning to the runtime.
	 * The watermark alone does not bound work: a peer fast enough to take
	 * everything offered keeps the buffer below the watermark forever, so
	 * without a budget a single burst would sit in the loop until the whole
	 * file was written, starving every other connection the runtime owns.
	 */
	@:noCompletion private static inline var STREAM_BURST:Int = 512 * 1024;

	/**
	 * How long a transfer may make no progress before it is closed. The
	 * pump is drain-driven, so a peer that stops reading produces no drains
	 * and would otherwise hold its file handle and connection forever.
	 */
	@:noCompletion private static inline var STREAM_STALL_SECONDS:Float = 30;

	@:noCompletion private var __origin:Socket;
	@:noCompletion private var __writer:HTTPResponseWriter;
	@:noCompletion private var __incomingBuffer:ByteArray;
	@:noCompletion private var __config:HTTPServerConfig;
	@:noCompletion private var __headers:Map<String, String>;
	@:noCompletion private var __method:String;
	@:noCompletion private var __filePath:String;
	@:noCompletion private var __httpVersion:String;
	@:noCompletion private var __php:PHPBridge;
	@:noCompletion private var __queryString:String = "";
	@:noCompletion private var __requestPath:String = "/";
	@:noCompletion private var __requestContentEncodings:Array<CompressionAlgorithm> = null;
	@:noCompletion private var __awaitingBody:Bool = false;
	@:noCompletion private var __expectBody:Int = 0;
	@:noCompletion private var __bodyBuf:ByteArray = null;
	@:noCompletion private var __bodyComplete:Void->Void = null;
	@:noCompletion private var __bodyIsChunked:Bool = false;
	@:noCompletion private var __chunkBytesRemaining:Int = -1;
	@:noCompletion private var __requestBody:ByteArray;
	@:noCompletion private var __scanA:Int = -1;
	@:noCompletion private var __scanB:Int = -1;
	@:noCompletion private var __scanC:Int = -1;
	@:noCompletion private var __scanned:UInt = 0;
	@:noCompletion private var __receiveDeadline:Float = 0;
	// Waiting between requests on a kept-alive connection. While set,
	// __receiveDeadline means "how long may this connection sit idle".
	@:noCompletion private var __idle:Bool = false;
	// True once the current request's framing, headers AND body, has
	// been fully read out of __incomingBuffer. The load-bearing safety
	// bit: a response written before this is set left unread request
	// bytes behind, and keeping the connection would parse them as the
	// next request.
	@:noCompletion private var __requestConsumed:Bool = false;
	// A response has been written for the current request slot; a second
	// one would corrupt the stream. Cleared only where a new slot opens.
	@:noCompletion private var __responded:Bool = false;
	// The keep/close decision, made once at header-write time and acted
	// on at finish, so the Connection header and the socket action can
	// never disagree.
	@:noCompletion private var __responseKeepAlive:Bool = false;
	@:noCompletion private var __requestsServed:Int = 0;
	@:noCompletion private var __processing:Bool = false;
	@:noCompletion private var __reprocess:Bool = false;
	// Which request slot the connection is on; bumped by every reset. A
	// middleware continuation carries the value it was created under, so
	// a stale next() from an already-answered request, even one that
	// fires asynchronously, ticks after its slot was reset, cannot
	// route its dispatch into a later request's state.
	@:noCompletion private var __requestGeneration:Int = 0;
	// When the current request's first byte arrived; the duration metric
	// measures from here, never from connection accept, so request N is
	// not billed for the idle time since request N-1.
	@:noCompletion private var __requestStartedAt:Float;
	// Pushed in by the server's drain(): the in-flight response goes out
	// with Connection: close so shutdown does not sever it mid-work.
	@:noCompletion private var __closeAfterResponse:Bool = false;
	// Whether this connection has sent a single byte. One that has not, a
	// browser's preconnect, has nothing in flight, and drain() closes it at
	// once rather than waiting out its requestTimeout.
	@:noCompletion private var __receivedAny:Bool = false;
	@:noCompletion private var __streamSource:FileStream;
	// A body already in memory, fed by the same pump as a file: one too large
	// for the socket's output buffer, which writing whole overflowed.
	@:noCompletion private var __streamBytes:ByteArray;
	@:noCompletion private var __streamOffset:Int = 0;
	@:noCompletion private var __streamRemaining:Int = 0;
	@:noCompletion private var __streamSlice:ByteArray;
	@:noCompletion private var __streamLastBuffered:Int = 0;
	@:noCompletion private var __streamStallDeadline:Float = 0;
	@:noCompletion private var __streamPending:Bool = false;

	// The body begun with beginResponse and not yet ended. An object of its
	// own because a handler serves every request on its connection: a
	// producer still writing after its response ended must reach nothing, not
	// the next request's.
	@:noCompletion private var __openStream:Null<HTTPResponseStream> = null;
	// What the open stream's body is compressed through, when it is.
	@:noCompletion private var __openEncoder:Null<crossbyte._internal.deflatex.StreamEncoder> = null;
	@:noCompletion private var __watchingClient:Bool = false;
	// Set once this handler has heard its client go. On Node a socket the
	// peer has closed can still read as connected.
	@:noCompletion private var __clientLeft:Bool = false;

	/**
	 * Largest socket output-buffer size observed while pumping a streamed
	 * response; zero when nothing streamed. Exists for tests: the
	 * bounded-memory guarantee, peak buffering near the watermark no
	 * matter the file size, is otherwise unobservable from outside, and a
	 * regression back to whole-file buffering would pass every
	 * byte-equality assertion while defeating the point.
	 */
	@:noCompletion private var __streamPeakBuffered(default, null):Int = 0;
	/** Uppercased request method, for example `GET` or `POST`. */
	public var method(get, null):String;
	/**
	 * The request path without the query string, percent-decoded once and
	 * settled: repeated `/` collapsed, `.` and `..` steps applied, and a
	 * backslash read as `/`. `//private/a`, `/./private/a` and
	 * `/x/../private/a` all read `/private/a`.
	 *
	 * It is the path static files are served under, so a middleware guard
	 * that checks it checks what would be served. A request whose `..` steps
	 * climb above the root is answered `400` before middleware sees it.
	 */
	public var requestPath(get, null):String;
	/** Raw query string without the leading `?`. */
	public var queryString(get, null):String;
	/** Fully buffered request body after supported content decoding. */
	public var requestBody(get, null):ByteArray;
	/** Convenience UTF-8 string view of `requestBody`. */
	public var requestText(get, null):String;

	/**
	 * The address the request came from, as the connection's socket reports
	 * it: the client's, or a proxy's when one sits in front. What the rate
	 * limiter keys on unless `HTTPServerConfig.rateLimitKey` says otherwise.
	 * The socket was private, so a route limiting logins per client needed
	 * `@:privateAccess` to learn who was logging in.
	 */
	public var remoteAddress(get, never):String;

	/**
	 * Creates a request handler for one accepted client socket.
	 *
	 * @param socket Connected client socket supplying request bytes.
	 * @param config Server configuration used for routing and response behavior.
	 * @param php Optional PHP bridge used when routing requests into PHP handlers.
	 */
	public function new(socket:Socket, config:HTTPServerConfig, ?php:PHPBridge, ?writer:HTTPResponseWriter) {
		super();
		__origin = socket;
		__writer = writer != null ? writer : new HTTP1ResponseWriter(socket);
		__config = config;
		__incomingBuffer = new ByteArray();
		__headers = new Map<String, String>();
		__requestBody = new ByteArray();

		// Only the HTTP/1.1 path parses this socket. Under HTTP/2 the frame
		// layer owns every read and hands whole requests over already decoded,
		// so subscribing here would have two readers racing one socket.
		if (writer == null) {
			__setup();
		}
		__php = php;
		__requestStartedAt = haxe.Timer.stamp();
		__receiveDeadline = config.requestTimeout > 0 ? haxe.Timer.stamp() + config.requestTimeout : 0;
	}

	/** Returns the named cookie value, or `null` when the cookie is absent. */
	public function getCookie(name:String):String {
		var h:String = __getCookieHeader();
		if (h == null) {
			return null;
		}

		var parts:Array<String> = h.split(";");
		for (p in parts) {
			var kv:String = StringTools.trim(p);
			var eq:Int = kv.indexOf("=");
			if (eq > 0) {
				var k:String = StringTools.trim(kv.substr(0, eq));
				var v:String = StringTools.trim(kv.substr(eq + 1));
				if (k == name) {
					return v;
				}
			}
		}
		return null;
	}

	/** Returns a request header by case-insensitive name, or `null` when absent. */
	public function getHeader(name:String):String {
		if (name == null) {
			return null;
		}

		var key:String = StringTools.trim(name.toLowerCase());
		return __headers.exists(key) ? __headers.get(key) : null;
	}

	/** Returns `true` when a request header exists. */
	public function hasHeader(name:String):Bool {
		return getHeader(name) != null;
	}

	@:noCompletion private function get_remoteAddress():String {
		return __origin.remoteAddress;
	}

	public function get_method():String {
		return __method;
	}

	public function get_requestPath():String {
		return __requestPath;
	}

	public function get_queryString():String {
		return __queryString;
	}

	public function get_requestBody():ByteArray {
		return __requestBody;
	}

	public function get_requestText():String {
		return __requestBody != null ? __requestBody.toString() : "";
	}

	/** Returns all parsed cookies keyed by cookie name. */
	public function getAllCookies():StringMap<String> {
		var out:StringMap<String> = new StringMap();
		var h:String = __getCookieHeader();
		if (h == null)
			return out;
		var parts:Array<String> = h.split(";");
		for (p in parts) {
			var kv:String = StringTools.trim(p);
			var eq:Int = kv.indexOf("=");
			if (eq > 0) {
				var k:String = StringTools.trim(kv.substr(0, eq));
				var v:String = StringTools.trim(kv.substr(eq + 1));
				out.set(k, v);
			}
		}
		return out;
	}

	@:noCompletion private function __setup():Void {
		__origin.addEventListener(ProgressEvent.SOCKET_DATA, __onData);
	}

	@:noCompletion private inline function __getCookieHeader():String {
		return __headers.exists("cookie") ? __headers.get("cookie") : null;
	}

	@:noCompletion private function __onData(e:ProgressEvent):Void {
		__receivedAny = true;
		try {
			__origin.readBytes(__incomingBuffer, __incomingBuffer.length);

			// A response body is streaming out. Bytes arriving now are the
			// next request on a kept-alive connection, and they are kept
			// rather than parsed: answering one now would interleave a second
			// response into the body going out. They are picked up when the
			// transfer finishes and the connection settles, through the same
			// surplus path a pipelined request takes after a buffered
			// response.
			if (__streaming || __openStream != null) {
				if (__incomingBuffer.length > __bufferLimit()) {
					// No status can be sent to explain this: the status line
					// left with the head and the body is mid-flight. Dropping
					// the connection is the only honest end.
					Logger.error("Request buffer exceeded " + __bufferLimit() + " bytes while a response was streaming; closing.");
					__stopStream();
					if (__origin.connected) {
						__origin.close();
					}
				}

				return;
			}

			if (__idle) {
				// Any data while idle is by definition the first byte of
				// the next request: leave the idle phase, stamp the
				// request's start, and swap the deadline back to meaning
				// "how long may this request take to arrive".
				__idle = false;
				__requestStartedAt = haxe.Timer.stamp();
				__receiveDeadline = __config.requestTimeout > 0 ? haxe.Timer.stamp() + __config.requestTimeout : 0;
				// This edge is a request-slot boundary just like a driver
				// iteration, and must clear the previous slot's flag
				// itself: a flood tripping the size check below never
				// reaches __processBuffer, and a still-set __responded
				// would swallow the 413, leaving the connection wedged
				// with an over-limit buffer nothing will ever reclaim.
				__responded = false;
			}

			if (__incomingBuffer.length > __bufferLimit()) {
				__sendErrorResponse(413, "Payload Too Large");
				return;
			}

			if (__awaitingBody) {
				if (__readRequestBodyFromBuffer()) {
					__finishRequestBody();
				}

				return;
			}

			__processBuffer();
		} catch (error:Dynamic) {
			Logger.error("Error reading data: " + error);
			__sendErrorResponse(500, "Internal Server Error");
		}
	}

	/**
	 * Drives request parsing as a flat loop rather than recursion.
	 *
	 * A response tail that re-parsed pipelined surplus directly would
	 * recurse request->response->request and overflow the stack on a
	 * pipelined flood; and a re-parse starting before request N's
	 * dispatch stack unwinds would let a contract-violating middleware
	 * (respond() followed by next()) route its stale continuation
	 * through request N+1's freshly reset state. So the funnel only
	 * requests another pass, and the pass runs here, after the previous
	 * iteration's stack has unwound. The iteration boundary is the guard
	 * boundary: __responded opens a new request slot at the top of each
	 * pass. Bounded because each iteration either consumes a complete
	 * request from the buffer or returns without asking to go again.
	 */
	/**
	 * Adopts bytes read before this handler existed.
	 *
	 * A cleartext listener serving both versions has to look at the first
	 * bytes to tell them apart, so by the time the right handler is chosen
	 * those bytes are already off the socket. Dropping them would corrupt the
	 * first request on every connection.
	 */
	@:noCompletion private function __adoptBuffered(data:ByteArray):Void {
		if (data == null || data.length == 0) {
			return;
		}
		__receivedAny = true;

		// Appended at the end without moving the read cursor, exactly as
		// __onData does. writeBytes writes at the current position and
		// advances it, so doing this the obvious way leaves the parser looking
		// past everything it was just given.
		var resume:Int = __incomingBuffer.position;
		__incomingBuffer.position = __incomingBuffer.length;
		__incomingBuffer.writeBytes(data, 0, data.length);
		__incomingBuffer.position = resume;

		// Behind the same catch as __onData. Without it, whatever serving the
		// first request on a cleartext HTTP/2 listener threw went up through
		// the socket's data dispatch into the runtime's pump, not to a 500.
		try {
			__processBuffer();
		} catch (error:Dynamic) {
			Logger.error("Error reading data: " + error);
			__sendErrorResponse(500, "Internal Server Error");
		}
	}

	@:noCompletion private function __processBuffer():Void {
		if (__processing) {
			__reprocess = true;
			return;
		}

		__processing = true;
		do {
			__reprocess = false;
			if (__requestConsumed && !__responded) {
				// A fully consumed request is mid-dispatch, an
				// asynchronous middleware still holds the continuation.
				// Parsing now would overwrite the in-flight request's
				// state with the next request's; the bytes stay buffered
				// and the response funnel collects them as pipelined
				// surplus once the dispatch completes.
				break;
			}
			__responded = false;
			__parseRequest();
		} while (__reprocess && __origin.connected);
		__processing = false;
	}

	@:noCompletion private inline function __sendMethodNotAllowed():Void {
		var hdrs:Array<URLRequestHeader> = [new URLRequestHeader("Allow", ALLOWED_METHODS.join(", "))];
		__dispatchResponse(405, "Method Not Allowed", hdrs, "text/plain", "405 Method Not Allowed");
	}

	/**
	 * Enforces whichever deadline the connection's phase gave
	 * `__receiveDeadline`: mid-request expiry answers `408 Request
	 * Timeout`, idle expiry just closes.
	 *
	 * Called from the owning server's sweep rather than from a data event,
	 * because the clients this exists for are precisely the ones that stop
	 * sending: a data-driven check never fires on a connection that has
	 * gone quiet holding a slot. Receipt of the full request clears the
	 * deadline, so a request the server is still busy answering is never
	 * timed out here.
	 */
	@:noCompletion private function __checkReceiveDeadline(now:Float):Void {
		// A streamed body owns this sweep while it is in flight. It must not
		// reach the 408 below: that path writes a whole response, and the
		// status line for this one left with the head, a second one would
		// land inside the body as though it were file content. The stall
		// check closes instead, which is the only signal left.
		//
		// The sweep is the one periodic visit both cases already share, so
		// they ride it together rather than arming a second timer. When
		// keep-alive lands and responses end at a single __finishResponse
		// funnel (keep-alive integration), this dispatch belongs there.
		// A response the application is writing as it goes has no deadline
		// here: how long it takes is the producer's, and a client that stops
		// reading is caught by write() at the output cap.
		if (__openStream != null) {
			return;
		}

		if (__streaming) {
			__checkStreamStall(now);
			return;
		}

		if (__receiveDeadline <= 0 || now < __receiveDeadline) {
			return;
		}

		__receiveDeadline = 0;

		if (__idle) {
			// An idle keep-alive connection reaching its deadline is the
			// normal end of its life, not a client fault: close without
			// a 408.
			if (__origin.connected) {
				__origin.close();
			}
			return;
		}

		__sendErrorResponse(408, "Request Timeout");
	}

	/**
	 * What the connection's buffer may hold before it is refused outright:
	 * one request's header block and body at their limits. The body and the
	 * headers are each held to their own limit as they are read; this is the
	 * backstop for bytes arriving faster than they can be.
	 *
	 * Held at `Int` max rather than wrapped past it. A body limit raised that
	 * far made the sum negative, which HashLink compares with the buffer's
	 * UInt length as a signed number: every request was refused there.
	 */
	@:noCompletion private inline function __bufferLimit():Int {
		var body:Int = __config.maxRequestBodySize;
		if (body < 0) {
			body = 0;
		}
		return body > 0x7FFFFFFF - MAX_HEADER_BYTES ? 0x7FFFFFFF : body + MAX_HEADER_BYTES;
	}

	@:noCompletion private function __parseRequest():Void {
		if (!__hasCompleteHeaderBlock(__incomingBuffer)) {
			// No header block has ended in what is waiting, so all of it is
			// one request's headers. They get a limit of their own, rather than
			// a share of the body's.
			if (__incomingBuffer.length - __incomingBuffer.position > MAX_HEADER_BYTES) {
				__sendErrorResponse(431, "Request Header Fields Too Large");
			}
			return;
		}

		var headerStart:Int = __incomingBuffer.position;
		var requestLine:Null<String> = __readLine(__incomingBuffer);
		if (requestLine == null) {
			return;
		}
		__headers.clear();

		requestLine = StringTools.trim(requestLine);
		var parts:Array<String> = requestLine.split(" ");
		if (parts.length < 3) {
			__sendErrorResponse(400, "Bad Request");
			return;
		}

		__method = parts[0].toUpperCase();
		var rawTarget:String = parts[1];
		__httpVersion = parts[2];

		if (!HttpSyntax.validateHttpVersion(__httpVersion)) {
			__sendErrorResponse(505, "HTTP Version Not Supported");
			return;
		}

		if (__hasAbsoluteScheme(rawTarget)) {
			try {
				var absoluteUrl = new URL(rawTarget);
				rawTarget = absoluteUrl.path + (absoluteUrl.query.length > 0 ? "?" + absoluteUrl.query : "");
			} catch (_:Dynamic) {
				__sendErrorResponse(400, "Bad Request");
				return;
			}
		}

		var qPos:Int = rawTarget.indexOf("?");
		if (qPos >= 0) {
			__queryString = rawTarget.substr(qPos + 1);
		} else {
			__queryString = "";
		}

		var pathOnly:String = (qPos >= 0) ? rawTarget.substr(0, qPos) : rawTarget;
		var h:Int = pathOnly.indexOf("#");
		if (h >= 0)
			pathOnly = pathOnly.substr(0, h);

		// Settled here, once, before any middleware runs, and nothing touches
		// the filesystem until the chain has let the request through.
		var settled:Null<String> = __settlePath(pathOnly);
		if (settled == null) {
			__sendErrorResponse(400, "Bad Request");
			return;
		}
		__requestPath = settled;
		__filePath = null;

		// Repeats of one name, collected and joined once the block has ended.
		// Appending each to the whole value so far is quadratic in the
		// repeats: the sixty-four kilobytes a block may take hold some
		// thirteen thousand "a:b" lines, each copying everything before it.
		var repeats:Null<Map<String, Array<String>>> = null;

		while (true) {
			var headerLine:Null<String> = __readLine(__incomingBuffer);
			if (headerLine == null) {
				return;
			}

			// Read before trimming, because trimming is what hid it. A line
			// opening with SP or HTAB is an obs-fold: a continuation of the
			// header above it rather than a header of its own. RFC 9112 5.2
			// requires a server to reject the message or replace the fold with
			// spaces, and reading it as a fresh header is how a framing header
			// written on a folded line takes effect here and nowhere upstream.
			var lead:Int = headerLine.charCodeAt(0);
			if (lead == 32 || lead == 9) {
				__sendErrorResponse(400, "Bad Request");
				return;
			}

			headerLine = StringTools.trim(headerLine);
			if (headerLine.length == 0) {
				break;
			}

			var sep:Int = headerLine.indexOf(":");
			if (sep <= 0) {
				// No field name at all. Skipping the line left this server and
				// anything in front of it disagreeing about what the message
				// contained, which is the same desync by a quieter route.
				__sendErrorResponse(400, "Bad Request");
				return;
			}

			var name:String = headerLine.substr(0, sep);
			// RFC 9112 5.1: no whitespace sits between a field name and its
			// colon, and a server MUST answer 400 rather than trim it away.
			// Accepting `Content-Length : 5` where a proxy rejects it is the
			// same disagreement that obs-fold produces.
			if (StringTools.rtrim(name) != name) {
				__sendErrorResponse(400, "Bad Request");
				return;
			}

			var key:String = name.toLowerCase();
			var value:String = StringTools.trim(headerLine.substr(sep + 1));

			var first:Null<String> = __headers.get(key);
			if (first == null) {
				__headers.set(key, value);
				continue;
			}
			if (repeats == null) {
				repeats = new Map();
			}
			var values:Null<Array<String>> = repeats.get(key);
			if (values == null) {
				values = [first];
				repeats.set(key, values);
			}
			values.push(value);
		}

		if (repeats != null) {
			for (key => values in repeats) {
				__headers.set(key, values.join(key == "cookie" ? "; " : ", "));
			}
		}

		// A block that did end is held to the same limit as one still arriving.
		if (__incomingBuffer.position - headerStart > MAX_HEADER_BYTES) {
			__sendErrorResponse(431, "Request Header Fields Too Large");
			return;
		}

		if (__httpVersion == "HTTP/1.1" && !__headers.exists("host")) {
			__sendErrorResponse(400, "Bad Request");
			return;
		}

		// Once the headers are read, so the key can come from them, and before
		// any of the body is: a refused request closes, and what is left of it
		// goes with the connection.
		if (__refusedByLimiter()) {
			return;
		}

		__requestContentEncodings = __parseContentEncodingHeader();
		if (__requestContentEncodings == null) {
			return;
		}

		var continueDispatch = function():Void {
			__dispatchParsedRequest();
		}

		if (__beginRequestBodyRead(continueDispatch)) {
			return;
		}

		continueDispatch();
	}

	/**
	 * Runs middleware, then the server's own handling, for a request whose
	 * method, path, query, headers and body are already populated.
	 *
	 * Extracted from the HTTP/1.1 parser so the HTTP/2 path can reach it too.
	 * Everything from here down is protocol-agnostic; everything above it is
	 * how the request was framed.
	 */
	@:noCompletion private function __dispatchParsedRequest():Void {
		// The request is fully here; whatever time the response takes
		// is the server's own and must not be billed to the client.
		__receiveDeadline = 0;
		// The one place consumption is recorded, because reaching here
		// is the one guarantee the request's framing, headers and
		// body both, has been read out of the buffer. Every response
		// sent earlier (parse errors, the 429 sent before the body is
		// read, a body cut short) must close, or the leftover bytes would
		// be parsed as the next request.
		__requestConsumed = true;

		// Files and rewrites are resolved only once the chain lets the request
		// through. They were resolved first, so a request a route answered
		// paid for three filesystem lookups, on the runtime's own thread, and
		// threw the answer away.
		if (__config.middleware != null && __config.middleware.length > 0) {
			__runMiddleware(0, __serveUnrouted);
			return;
		}

		__serveUnrouted();
	}

	/**
	 * The request path as middleware and the static resolver both read it,
	 * percent-decoded, then settled by `HttpSyntax.normalizePath`, or null
	 * when it is malformed or climbs above the root.
	 */
	@:noCompletion private static function __settlePath(raw:String):Null<String> {
		var decoded:String;
		try {
			decoded = __percentDecodePath(raw);
		} catch (_:Dynamic) {
			return null;
		}

		return HttpSyntax.normalizePath(decoded);
	}

	/**
	 * Serves a request the HTTP/2 layer already decoded.
	 *
	 * The HTTP/1.1 entry point is `__parseRequest`, which reaches the same
	 * dispatch after turning bytes into these same fields. This one starts
	 * where that finishes.
	 */
	@:noCompletion private function __serveDecodedRequest(method:String, requestPath:String, queryString:String, headers:Map<String, String>,
			body:ByteArray, tooLarge:Bool = false, headersTooLarge:Bool = false):Void {
		__method = method;
		__queryString = queryString;
		__headers = headers;
		__requestBody = body != null ? body : new ByteArray();
		// HTTP/2 carries no version token; the value only reaches logging and
		// the HTTP/1.1 keep-alive rules, neither of which applies here.
		__httpVersion = "HTTP/2";

		// A header section past the limit, answered as the HTTP/1.1 parser
		// answers one: before anything reads the headers, since they are not
		// all here.
		if (headersTooLarge) {
			__sendErrorResponse(431, "Request Header Fields Too Large");
			return;
		}

		// The same settling the HTTP/1.1 parser applies, and for the same
		// reasons: it is what keeps a request target inside the document
		// root, and what makes the path a guard sees the path served. Without
		// it the traversal check would live on one protocol's path only.
		var settled:Null<String> = __settlePath(requestPath);
		if (settled == null) {
			__sendErrorResponse(400, "Bad Request");
			return;
		}
		__requestPath = settled;
		__filePath = null;

		// What the HTTP/1.1 parser applies as it reads a request, applied here
		// to one that arrived as frames. HTTP/2 used to skip all of it: six
		// requests on one connection were all answered 200 where HTTP/1.1
		// refused the fourth, and a gzip body reached middleware compressed.
		if (__refusedByLimiter()) {
			return;
		}

		if (tooLarge) {
			__sendErrorResponse(413, "Payload Too Large");
			return;
		}

		__requestContentEncodings = __parseContentEncodingHeader();
		if (__requestContentEncodings == null || !__decodeRequestBody()) {
			return;
		}

		__dispatchParsedRequest();
	}

	@:noCompletion private function __runMiddleware(index:Int, onComplete:Void->Void):Void {
		if (index >= __config.middleware.length) {
			onComplete();
			return;
		}

		var alreadyCalled:Bool = false;
		// The slot this continuation belongs to. A middleware that breaks
		// the respond-xor-next contract and still calls next() after its
		// response finished the slot finds the generation moved on and is
		// ignored, including the asynchronous case, where the __responded
		// guard alone cannot help because a later slot has already opened.
		var slot:Int = __requestGeneration;
		var next = function(?error:Dynamic):Void {
			if (alreadyCalled || slot != __requestGeneration) {
				return;
			}
			alreadyCalled = true;

			if (error == null) {
				__runMiddleware(index + 1, onComplete);
			} else {
				__dispatchMiddlewareError(error);
			}
		}

		try {
			__config.middleware[index](this, next);
		} catch (error:Dynamic) {
			__dispatchMiddlewareError(error, haxe.CallStack.exceptionStack());
		}
	}

	/**
	 * Answers a request whose middleware or route failed: through
	 * `HTTPServerConfig.onError` if it answers, and otherwise with the status
	 * an `Int` error names, or `500`.
	 *
	 * An error that is not an `Int` is logged first, at ERROR, with the method,
	 * the path and the stack. It was not logged at all, so a route that threw
	 * "database connection refused" left only an INFO line reading
	 * `Status: 500`, and nothing said why. The client still hears only the
	 * status: the error's text is the operator's, not the caller's.
	 */
	@:noCompletion private function __dispatchMiddlewareError(error:Dynamic, ?stack:Array<haxe.CallStack.StackItem>):Void {
		var status:Int = 500;
		if (Std.isOfType(error, Int)) {
			status = cast error;
		} else {
			var fields:Map<String, String> = ["method" => __method, "path" => __requestPath];
			if (stack != null && stack.length > 0) {
				// One line, so a text log keeps one record per line.
				fields.set("stack", StringTools.trim(haxe.CallStack.toString(stack)).split("\n").join(" | "));
			}
			Logger.error("Request failed: " + Std.string(error), fields);
		}

		if (__config.onError != null && !__responded) {
			try {
				__config.onError(this, error);
			} catch (hookError:Dynamic) {
				Logger.error("HTTPServerConfig.onError threw: " + Std.string(hookError), ["method" => __method, "path" => __requestPath]);
			}

			if (__responded) {
				return;
			}
		}

		__sendErrorResponse(status, __statusMessage(status));
	}

	/**
	 * What the server does with a request no middleware answered: a CORS
	 * preflight, or a file, directory index, rewrite or PHP script under
	 * `rootDirectory`.
	 *
	 * The only place a request reaches the filesystem, and it runs only once
	 * every middleware has passed the request on.
	 */
	@:noCompletion private function __serveUnrouted():Void {
		switch (__method) {
			case "GET" | "HEAD" | "POST":
			case "OPTIONS":
				if (__config.corsEnabled) {
					__handleOptionsRequest();
				} else {
					__sendMethodNotAllowed();
				}
				return;
			case _:
				__sendMethodNotAllowed();
				return;
		}

		if (__config.rootDirectory == null) {
			__sendNotFound();
			return;
		}

		var decision:Decision = RewriteEngine.decide(__config, __requestPath, __queryString, __method, __headers);

		// A path the configuration keeps back is answered as one that is not
		// there. Asked of the path a file would be served under, so a rewrite
		// onto a dotfile is refused as well as a request naming one. Spelling
		// is checked for a file the resolver found, not for a PHP rewrite's
		// script, which the configuration names rather than the request.
		var served:Null<String> = decision != null ? HttpSyntax.normalizePath(decision.finalPath) : __requestPath;
		if (served == null || !__servesStaticPath(served, decision != null && decision.isStatic)) {
			__sendNotFound();
			return;
		}

		__filePath = __nativePathFor(__requestPath);
		var target:Null<String> = decision != null ? __nativePathFor(served) : __filePath;
		if (__filePath == null || target == null) {
			__sendNotFound();
			return;
		}

		if (decision != null) {
			if (decision.toPHP) {
				__queryString = decision.query;
				__servePhp(target, __method == "HEAD", __method == "POST" ? __requestBody : null, served);
			} else if (__method == "POST") {
				__handlePost(__filePath);
			} else if (decision.isStatic) {
				__serveFile(target, __method == "HEAD");
			} else {
				__sendMethodNotAllowed();
			}
			return;
		}

		if (__method == "POST") {
			__handlePost(__filePath);
		} else {
			__serveFile(__filePath, __method == "HEAD");
		}
	}

	@:noCompletion private inline function __sendNotFound():Void {
		__dispatchResponse(404, "Not Found", null, "text/plain", "404 Not Found");
	}

	/**
	 * Answers a CORS preflight.
	 *
	 * Only the preflight-specific headers are built here. Everything a
	 * response has in common with every other response, date, server,
	 * nosniff, the connection decision, the configured custom headers, the
	 * origin and credentials headers, the log line and the status event,
	 * comes from the shared builder, which is the point of routing through it.
	 *
	 * This wrote its own response and closed the connection by hand. That was
	 * deliberate, to keep a wire-format change out of the commit that
	 * introduced keep-alive, but it left preflights outside every guarantee
	 * the builder makes: no `__responded` suppression, so a middleware that had
	 * already answered could be followed by a second response on the same
	 * connection; no check that the socket was still connected; no log line, so
	 * preflights were invisible to an operator; no custom headers; and an
	 * unconditional close, costing a fresh connection, and a full TLS
	 * handshake where enabled, ahead of a great many ordinary requests.
	 *
	 * `Vary` is contributed twice: `Origin` by the builder, the two
	 * request-header tokens here. Repeated field-lines combine, so the result
	 * is the single line this used to write by hand.
	 */
	@:noCompletion private function __handleOptionsRequest():Void {
		var headers:Array<URLRequestHeader> = [];

		// The configured lists, whatever the preflight asked for. This echoed
		// Access-Control-Request-Method and -Headers back, approving any method
		// and any header a page cared to name, so the lists meant nothing. The
		// browser compares its request against these and refuses what is not
		// on them, which is the whole of what a preflight is for.
		headers.push(new URLRequestHeader("Access-Control-Allow-Methods", __config.corsAllowedMethods.join(", ")));
		headers.push(new URLRequestHeader("Access-Control-Allow-Headers", __config.corsAllowedHeaders.join(", ")));

		if (__config.corsMaxAge > 0) {
			headers.push(new URLRequestHeader("Access-Control-Max-Age", Std.string(__config.corsMaxAge)));
		}

		headers.push(new URLRequestHeader("Vary", "Access-Control-Request-Method, Access-Control-Request-Headers"));
		headers.push(new URLRequestHeader("Allow", ALLOWED_METHODS.join(", ")));

		__dispatchResponse(204, "No Content", headers, "text/plain", "");
	}


	@:noCompletion private function __serveFile(filePath:String, headOnly:Bool = false):Void {
		var file:File = new File(filePath);

		if (__config.blacklist.indexOf(file.nativePath) != -1) {
			__dispatchResponse(403, "Forbidden", null, "text/plain", "403 Forbidden");
			return;
		}
		if (__config.whitelist.length > 0 && __config.whitelist.indexOf(file.nativePath) == -1) {
			__dispatchResponse(403, "Forbidden", null, "text/plain", "403 Forbidden");
			return;
		}

		if (!file.exists) {
			// Keeps the connection: a routine 404, a page fetching a
			// missing favicon, must not cost the client a new handshake.
			__dispatchResponse(404, "Not Found", null, "text/plain", "404 Not Found");
			return;
		}

		if (file.isDirectory) {
			var indexFile:String = __findIndexFile(file);
			if (indexFile != null) {
				__serveFile(indexFile, headOnly);
			} else {
				__dispatchResponse(404, "Not Found", null, "text/plain", "404 Not Found");
			}
			return;
		} else {
			// Tested with `__isPhp` alone rather than with the bridge, because
			// the answer to "would this have been executed" and the answer to
			// "may this be sent as bytes" have to come from the same question.
			// They did not: a source file was executed when a bridge existed
			// and fell through to the static path when one did not, so a
			// server with PHP off, the default, answered GET /config.php
			// with 200 and the file, credentials and all. Source disclosure
			// on a default configuration.
			//
			// 404 rather than 403: this server cannot serve the file in any
			// form, and saying so without confirming it is there keeps the
			// reply identical to one for a path that does not exist. The
			// operator is told through the log instead, which is the half of
			// the story an anonymous client should not get.
			if (__isPhp(file.nativePath)) {
				if (__php == null) {
					Logger.warn("Refusing to serve PHP source with no bridge configured; set phpEnabled to execute it, or move it out of the web root.",
						["path" => __requestPath]);
					__dispatchResponse(404, "Not Found", null, "text/plain", "404 Not Found");
					return;
				}

				__servePhp(file.nativePath, headOnly);
				return;
			}
		}

		// Past 2 GB `File.size`, an Int, cannot state the length, and throws
		// an IOError rather than answer with a wrong one: `stat`'s own Int size
		// wrapped on some targets and read as 0 on Windows native, where a
		// 3 GB file and an empty one looked the same. The throw is this
		// refusal. Uncaught, it was a 500 on HTTP/1.1 only by way of the
		// catch-all, and on HTTP/2 a reset stream. It replaces this handler's
		// own check, an open, seek and read of every file it served.
		var total:Int;
		try {
			total = file.size;
		} catch (error:crossbyte.errors.IOError) {
			// Its message says which: too large, or not readable at all.
			Logger.error('Refusing to serve ${file.nativePath}: ${error.message}');
			__sendErrorResponse(500, "Internal Server Error");
			return;
		}

		if (total < 0) {
			Logger.error('Refusing to serve ${file.nativePath}: it is larger than an Int can express, so its size cannot be stated.');
			__sendErrorResponse(500, "Internal Server Error");
			return;
		}

		var lastModifiedTime:Float = file.modificationDate.getTime();
		var lastModHeader:URLRequestHeader = new URLRequestHeader("Last-Modified", __toHttpDate(lastModifiedTime));
		var mimeType:String = __getMimeType(file.nativePath);

		var ims:String = __headers.exists("if-modified-since") ? __headers.get("if-modified-since") : null;
		if (ims != null) {
			try {
				var since:Null<Float> = __parseHttpDate(ims);
				// Math.ffloor, not Math.floor: floor returns an Int, and seconds
				// since 1970 leave an Int in January 2038. On hxcpp the cast
				// wrapped, so a validator dated after that compared as long ago
				// and every such revalidation was answered with the whole file.
				if (since != null && Math.ffloor(lastModifiedTime / 1000) <= Math.ffloor(since / 1000)) {
					var h:Array<URLRequestHeader> = [new URLRequestHeader("Accept-Ranges", "bytes"), lastModHeader];
					__dispatchResponse(304, "Not Modified", h, "text/plain", "", true);
					return;
				}
			} catch (_:Dynamic) {}
		}

		var baseHeaders:Array<URLRequestHeader> = [new URLRequestHeader("Accept-Ranges", "bytes"), lastModHeader];
		var rangeHdr:String = __headers.exists("range") ? __headers.get("range") : null;

		if (rangeHdr != null) {
			var r:Dynamic = __parseRange(rangeHdr, total);
			if (r == null) {
				var h:Array<URLRequestHeader> = baseHeaders.concat([new URLRequestHeader("Content-Range", 'bytes */${total}')]);
				__dispatchResponse(416, "Range Not Satisfiable", h, "text/plain", "Requested Range Not Satisfiable", headOnly);
			} else {
				var start:Int = r.start;
				var end:Int = r.end;
				var len:Int = end - start + 1;

				var h = baseHeaders.concat([new URLRequestHeader("Content-Range", 'bytes ${start}-${end}/${total}')]);
				if (headOnly) {
					// A ranged HEAD answers with the range's length and no
					// body, so loading the file to cut a slice that is then
					// discarded is pure cost, the same reason the 200 path
					// has always short-circuited HEAD.
					__dispatchResponseBytes(206, "Partial Content", h, mimeType, null, true, len);
				} else if (__canStreamFile(206, h, total)) {
					// The stream owns the close; falling through to the
					// shared tail below would sever the transfer before its
					// first slice reached the peer.
					__streamFileResponse(206, "Partial Content", h, mimeType, file, start, len);
					return;
				} else {
					file.load();
					var slice = new ByteArray();
					slice.writeBytes(file.data, start, len);
					__dispatchResponseBytes(206, "Partial Content", h, mimeType, slice, false);
				}
			}
		} else {
			// Encoded ahead of time where that is possible: a precompressed
			// sibling, or a body kept from an earlier request.
			if (__serveEncodedFile(file, mimeType, baseHeaders, total, lastModifiedTime, headOnly)) {
				return;
			}

			// A file that streams goes out as it is on disk, and a HEAD for
			// it says so rather than naming a coding the GET would not use.
			var streams:Bool = __canStreamFile(200, baseHeaders, total);
			if (headOnly) {
				__dispatchResponseBytes(200, "OK", baseHeaders, mimeType, null, true, total, false, !streams);
			} else {
				if (streams) {
					// The stream owns the close (see the range path above).
					__streamFileResponse(200, "OK", baseHeaders, mimeType, file, 0, total);
					return;
				}

				file.load();
				__dispatchResponseBytes(200, "OK", baseHeaders, mimeType, file.data, false);
			}
		}
	}

	/**
		Answers a whole-file request with a body encoded before the request
		came, and says whether it did: the file's precompressed sibling, or a
		body `HTTPServerConfig.compression` kept from an earlier request,
		encoding and keeping one now if the file is small enough to hold.

		A static file was compressed again on every request, on the runtime's
		thread: a 150 KB script served 863 requests a second as it was and 64
		as Brotli, natively.
	**/
	@:noCompletion private function __serveEncodedFile(file:File, mimeType:String, baseHeaders:Array<URLRequestHeader>, total:Int, modified:Float,
			headOnly:Bool):Bool {
		var policy:Null<HTTPCompression> = __config.compression;
		if (policy == null || !__mayCompress(200, baseHeaders, mimeType, total, false)) {
			return false;
		}

		// A refusal of every coding is the ordinary path's to answer, 406.
		// Kept once encoded, so Brotli first.
		var decision:ResponseEncodingDecision = __resolveResponseEncoding(200, baseHeaders, false, true);
		if (decision.encoding == null) {
			return false;
		}
		var coding:Null<String> = __encodingToHeaderValue(decision.encoding);
		if (coding == null) {
			return false;
		}
		var headers:Array<URLRequestHeader> = baseHeaders.concat([
			new URLRequestHeader("Content-Encoding", coding),
			new URLRequestHeader("Vary", "Accept-Encoding")
		]);

		if (policy.precompressed) {
			var sibling:Null<File> = __precompressedSibling(file, decision.encoding, modified);
			if (sibling != null) {
				var size:Int = -1;
				try {
					size = sibling.size;
				} catch (_:Dynamic) {}
				if (size >= 0) {
					if (headOnly) {
						__dispatchResponseBytes(200, "OK", headers, mimeType, null, true, size, false, false);
					} else if (size > STREAM_THRESHOLD) {
						__streamFileResponse(200, "OK", headers, mimeType, sibling, 0, size);
					} else {
						sibling.load();
						__dispatchResponseBytes(200, "OK", headers, mimeType, sibling.data, false, null, false, false);
					}
					return true;
				}
			}
		}

		// A file past the streaming threshold is sent as it is on disk.
		if (total > STREAM_THRESHOLD) {
			return false;
		}

		var kept:Null<haxe.io.Bytes> = policy.cached(file.nativePath, decision.encoding, total, modified);
		if (kept == null) {
			if (headOnly) {
				// Nothing is encoded for a HEAD; the ordinary path answers it
				// with the coding named and the length left out.
				return false;
			}
			file.load();
			var encoded:Null<ByteArray> = __encodeBody(file.data, decision.encoding);
			if (encoded == null) {
				return false;
			}
			var bytes:haxe.io.Bytes = haxe.io.Bytes.alloc(encoded.length);
			bytes.blit(0, encoded, 0, encoded.length);
			policy.keep(file.nativePath, decision.encoding, total, modified, bytes);
			kept = bytes;
		}

		if (headOnly) {
			__dispatchResponseBytes(200, "OK", headers, mimeType, null, true, kept.length, false, false);
		} else {
			__dispatchResponseBytes(200, "OK", headers, mimeType, ByteArray.fromBytes(kept), false, null, false, false);
		}
		return true;
	}

	/**
		The `.br` or `.gz` beside `file` for `algorithm`, when there is one the
		server may send and it is not older than the file; null otherwise. The
		blacklist and whitelist hold for it as for any file.
	**/
	@:noCompletion private function __precompressedSibling(file:File, algorithm:CompressionAlgorithm, modified:Float):Null<File> {
		var suffix:Null<String> = switch (algorithm) {
			case CompressionAlgorithm.BROTLI: ".br";
			case CompressionAlgorithm.GZIP: ".gz";
			default: null;
		}
		if (suffix == null) {
			return null;
		}

		var path:String = file.nativePath + suffix;
		if (__config.blacklist.indexOf(path) != -1 || (__config.whitelist.length > 0 && __config.whitelist.indexOf(path) == -1)) {
			return null;
		}

		try {
			var sibling:File = new File(path);
			if (!sibling.exists || sibling.isDirectory || sibling.modificationDate.getTime() < modified) {
				return null;
			}
			return sibling;
		} catch (_:Dynamic) {
			return null;
		}
	}

	/**
	 * Whether a file response can bypass whole-file buffering.
	 *
	 * Size decides first, and it decides against compression: a body big
	 * enough to stream is exactly one whose whole-buffer `compress()` would
	 * cost the memory this path exists to bound, so a large file is served
	 * identity even to a client that offered gzip. Trading a compressed
	 * body for a bounded one is the deliberate choice, the alternative is
	 * that any gzip-capable client, which is every browser, defeats
	 * streaming entirely. Only an outright refusal of identity keeps the
	 * buffered path, because that path owns the 406.
	 *
	 * The gate is the file's size, not the response's: a small range of a
	 * large file still streams, since the buffered alternative loads the
	 * whole file just to cut the slice.
	 */
	@:noCompletion private function __canStreamFile(statusCode:Int, headers:Array<URLRequestHeader>, fileSize:Int):Bool {
		if (fileSize <= STREAM_THRESHOLD) {
			return false;
		}

		return !__resolveResponseEncoding(statusCode, headers).reject;
	}

	/**
	 * Sends a file response without holding the whole body in memory.
	 *
	 * The buffered path loads the file and then copies it again into the
	 * socket's output buffer, so a download costs twice its size in
	 * resident memory for as long as the peer takes to drain it, and a
	 * configured `maxOutputBufferSize` kills such a transfer for exceeding
	 * a limit the server itself filled in one call. Here only the head is
	 * written up front; the body follows in bounded bursts driven by the
	 * socket's own drain, so peak memory per transfer is the watermark, not
	 * the file.
	 *
	 * The head goes through `__dispatchResponseBytes` with a null body and
	 * an explicit `contentLength` rather than through an extracted
	 * header-assembly helper: the header set stays identical to the
	 * buffered path's by construction, at a fraction of the diff.
	 *
	 * Known limitation: a client that half-closes its write side after
	 * sending the request, legal, and what some download tools do, is
	 * indistinguishable from one that hung up, because the socket read loop
	 * reports EOF as a close either way. Such a transfer is abandoned
	 * partway. Fixing it needs a half-close signal on `Socket`, not a
	 * change here.
	 */
	@:noCompletion private function __streamFileResponse(statusCode:Int, statusMessage:String, headers:Array<URLRequestHeader>, contentType:String, file:File,
			fileOffset:Int, length:Int):Void {
		var stream:FileStream = new FileStream();
		try {
			// Synchronous open: openAsync preloads the entire file, which is
			// the exact cost this path exists to avoid.
			stream.open(file, FileMode.READ);
			// Seek once, here. Reads advance the position themselves, so a
			// seek per slice would only re-derive what the stream already
			// knows.
			stream.position = fileOffset;
		} catch (error:Dynamic) {
			Logger.error('Failed to open ${file.nativePath} for streaming: ' + error);
			try {
				stream.close();
			} catch (_:Dynamic) {}
			// Nothing is on the wire yet, so a clean 500 is still possible.
			__sendErrorResponse(500, "Internal Server Error");
			return;
		}

		// Held across the head dispatch so both __decideKeepAlive and
		// __finishResponse can see that a body is still to come. Cleared on
		// every path out, so a failed head cannot poison a later decision.
		__streamPending = true;

		try {
			__dispatchResponseBytes(statusCode, statusMessage, headers, contentType, null, true, length);
		} catch (error:Dynamic) {
			__streamPending = false;
			// The head write failed before the pump took ownership; release
			// the file handle before the error takes its usual route, or it
			// leaks until the collector notices.
			try {
				stream.close();
			} catch (_:Dynamic) {}
			throw error;
		}

		__streamPending = false;

		if (!__origin.connected) {
			try {
				stream.close();
			} catch (_:Dynamic) {}
			return;
		}

		__streamSource = stream;
		__streamSlice = new ByteArray();
		__beginStreamedBody(length);
	}

	/** Whether a response body is being fed out by the pump. */
	@:noCompletion private var __streaming(get, never):Bool;

	@:noCompletion private inline function get___streaming():Bool {
		return __streamSource != null || __streamBytes != null;
	}

	/**
	 * Starts the pump on a body the head has promised `length` bytes of, from
	 * whichever source was set: a file, or bytes already in memory.
	 */
	@:noCompletion private function __beginStreamedBody(length:Int):Void {
		__streamRemaining = length;
		__streamPeakBuffered = 0;
		__streamLastBuffered = 0;
		__streamStallDeadline = haxe.Timer.stamp() + STREAM_STALL_SECONDS;

		// The peer can vanish mid-transfer; without these the pump would
		// keep reading a file for a connection that no longer exists.
		__origin.addEventListener(Event.CLOSE, __onStreamSocketGone);
		__origin.addEventListener(IOErrorEvent.IO_ERROR, __onStreamSocketGone);

		// Resume on the socket's own drain rather than on a tick of our
		// own. Every write queues the socket on the registry's writable
		// queue, which the runtime drains each pass, so this fires whether
		// the flush completed or blocked, the cadence follows the peer
		// instead of the clock, and costs nothing on connections that are
		// not mid-transfer.
		__writer.onDrain = __pumpStream;

		// First burst goes out now rather than a drain later.
		__pumpStream();
	}

	@:noCompletion private function __onStreamSocketGone(_:Event):Void {
		// Peer closed or errored mid-transfer: stop reading, release the
		// file, and never write again, the response is unfinishable.
		__stopStream();
		if (__origin.connected) {
			__origin.close();
		}
	}

	/**
	 * Feeds the streamed body one bounded burst at a time.
	 *
	 * Feeding pauses at the watermark so a slow peer bounds this
	 * connection's memory instead of growing it, and the burst budget
	 * bounds how long one invocation can hold the runtime when the peer is
	 * fast enough to swallow everything offered. The connection closes only
	 * when every slice is written and the socket buffer is empty: closing
	 * with bytes still queued silently discards them, which is the
	 * truncation hazard the buffered path's write-all-then-close lives with
	 * and this path exists not to repeat.
	 */
	@:noCompletion private function __pumpStream():Void {
		if (!__streaming) {
			return;
		}

		var watermark:Int = STREAM_WATERMARK;
		var limit:Int = __writer.maxBufferedBytes;
		if (limit > 0 && limit < watermark) {
			// The overflow policy exists for writers that outrun the peer
			// without bound; this pump is the bounded case, so it must stay
			// under the socket's own limit or the policy would kill a
			// healthy transfer mid-body.
			watermark = limit;
		}

		var entryBuffered:Int = __writer.bufferedBytes;
		if (entryBuffered < __streamLastBuffered) {
			// The peer consumed something since the last visit: real
			// progress, even if this burst turns out to write nothing.
			__streamStallDeadline = haxe.Timer.stamp() + STREAM_STALL_SECONDS;
		}

		var budget:Int = STREAM_BURST;
		var wrote:Bool = false;

		try {
			while (__streamRemaining > 0 && budget > 0) {
				var buffered:Int = __writer.bufferedBytes;
				if (buffered >= watermark) {
					break;
				}

				var take:Int = STREAM_SLICE;
				if (take > __streamRemaining) {
					take = __streamRemaining;
				}
				if (take > budget) {
					take = budget;
				}
				if (limit > 0 && take > limit - buffered) {
					// Cap the slice to the remaining headroom so not even
					// the final write can overshoot the enforced limit;
					// buffered < watermark <= limit here, so at least one
					// byte always fits and the pump cannot stall.
					take = limit - buffered;
				}

				if (__streamBytes != null) {
					// Straight from the body's own bytes: no slice, no copy.
					__writer.writeBody(__streamBytes, __streamOffset, take);
					__streamOffset += take;
				} else {
					var before:Int = __streamSource.position;
					__streamSource.readBytes(__streamSlice, 0, take);
					var read:Int = __streamSource.position - before;
					if (read < take) {
						// The file shrank under a Content-Length already sent.
						// FileStream discards short-read counts and leaves the
						// destination's tail as it found it, so continuing here
						// would put fabricated bytes on the wire as though they
						// were file content. A truncated body the client can
						// detect against the promised length beats a complete
						// one that is quietly wrong.
						Logger.error('Streamed file ${__requestPath} ended early; closing rather than sending fabricated bytes.');
						__stopStream();
						if (__origin.connected) {
							__origin.close();
						}
						return;
					}

					__writer.writeBody(__streamSlice, 0, take);
				}
				__streamRemaining -= take;
				budget -= take;
				wrote = true;

				var pending:Int = __writer.bufferedBytes;
				if (pending > __streamPeakBuffered) {
					__streamPeakBuffered = pending;
				}
			}

			if (wrote) {
				// One flush per burst. Every writeBytes has already queued
				// the socket, so flushing per slice would only repeat the
				// same syscall against the same buffer.
				__origin.flush();
				__streamStallDeadline = haxe.Timer.stamp() + STREAM_STALL_SECONDS;
			}
		} catch (error:Dynamic) {
			// Mid-body there is no in-band way to signal failure: the status
			// and Content-Length are already on the wire, so the best
			// available outcome is a short body the client can detect
			// against the length it was promised.
			Logger.error("Streamed file response failed mid-body: " + error);
			__stopStream();
			if (__origin.connected) {
				__origin.close();
			}
			return;
		}

		__streamLastBuffered = __writer.bufferedBytes;

		if (__streamRemaining == 0 && __streamLastBuffered == 0) {
			// Every byte has left this process, so the response the head
			// promised is complete and the connection can be settled on the
			// decision that head recorded, kept for the next request, or
			// closed. Deferring to here is the whole reason a streamed
			// response can be kept alive at all: the body is well framed by
			// the Content-Length that went out with the head, so the only
			// thing that ever made it unsafe was settling too early.
			__stopStream();

			// The body is complete, so the response is too. HTTP/1.1 framed it
			// with the Content-Length that went out in the head and has
			// nothing left to say; HTTP/2 has to close the stream, or the
			// client sits waiting on a request it believes is still running.
			__writer.endResponse();

			__settleConnection();
		}
	}

	/**
	 * Closes a transfer that has stopped making progress.
	 *
	 * A peer that stops reading without closing would otherwise hold the
	 * file handle, the connection and its buffered bytes indefinitely: the
	 * pump is drain-driven, and a peer that never drains produces no
	 * drains. Closing is the whole response, no status can be sent,
	 * because the status line left with the head.
	 */
	@:noCompletion private function __checkStreamStall(now:Float):Void {
		if (__streamStallDeadline <= 0 || now < __streamStallDeadline) {
			return;
		}

		Logger.error('Streamed response to ${__requestPath} stalled; closing.');
		__stopStream();
		if (__origin.connected) {
			__origin.close();
		}
	}

	/**
	 * Releases everything a streamed response holds. Idempotent because one
	 * transfer can reach it twice, from the pump that finishes or aborts
	 * it, and again through the socket's CLOSE dispatch, and the second
	 * pass must not touch a stream that is already gone.
	 */
	@:noCompletion private function __stopStream():Void {
		if (!__streaming) {
			return;
		}

		var stream:Null<FileStream> = __streamSource;
		__streamSource = null;
		__streamBytes = null;
		__streamOffset = 0;
		__streamSlice = null;
		__streamRemaining = 0;
		__streamStallDeadline = 0;

		// Cleared before the socket is touched: a drain dispatched during
		// teardown would otherwise re-enter the pump with a half-released
		// transfer.
		__writer.onDrain = null;
		__origin.removeEventListener(Event.CLOSE, __onStreamSocketGone);
		__origin.removeEventListener(IOErrorEvent.IO_ERROR, __onStreamSocketGone);

		if (stream != null) {
			try {
				stream.close();
			} catch (_:Dynamic) {}
		}
	}

	/**
	 * @param open The head of a response whose body follows through `write`
	 *        with no length yet known: see `beginResponse`.
	 */
	@:noCompletion private function __dispatchResponseBytes(statusCode:Int, statusMessage:String, headers:Array<URLRequestHeader>, contentType:String,
			data:ByteArray, headOnly:Bool = false, ?contentLength:Int, open:Bool = false, mayEncode:Bool = true):Void {
		// A response for this request slot has already been written (a
		// middleware that called respond() and then next() anyway); a
		// second one would corrupt the stream. Suppressed before the log
		// and the status event so it neither logs, counts, nor touches
		// the socket.
		if (__responded) {
			return;
		}

		if (!__writer.connected) {
			return;
		}

		// Assembled as fields rather than concatenated into a status line and
		// header block. Everything above this point decides a response; how it
		// reaches the wire belongs to the writer, and that split is what lets
		// the same response go out as HTTP/1.1 or as HTTP/2.
		var fields:Array<URLRequestHeader> = [];
		fields.push(new URLRequestHeader("Date", __formatHttpDate()));
		fields.push(new URLRequestHeader("Content-Type", contentType));
		fields.push(new URLRequestHeader("X-Content-Type-Options", "nosniff"));
		fields.push(new URLRequestHeader("Server", "CrossByte"));

		__responseKeepAlive = __decideKeepAlive(statusCode);

		if (headers != null) {
			for (h in headers) {
				fields.push(h);
			}
		}

		var responseData:ByteArray = data;
		// What a GET would send, which a HEAD is answered as: its body is not
		// here, but its length is, and the two must be negotiated alike, a
		// HEAD used to report the identity length while the GET beside it
		// went out as br. Not a head whose body the pump streams after it,
		// which goes as it is on disk.
		var plainLength:Int = contentLength != null ? contentLength : (responseData != null ? responseData.length : 0);
		var lengthUnknown:Bool = false;
		if (mayEncode && !__streamPending && __mayCompress(statusCode, headers, contentType, plainLength, open)) {
			// Whichever coding this client gets, the answer depends on what it
			// asked for, and a cache keyed on the URL alone replayed a br body
			// to clients that had not asked for one.
			fields.push(new URLRequestHeader("Vary", "Accept-Encoding"));

			var responseEncoding = __resolveResponseEncoding(statusCode, headers);
			if (responseEncoding.reject) {
				__sendErrorResponse(406, "Not Acceptable");
				return;
			}
			if (responseEncoding.encoding != null) {
				if (headOnly) {
					// The encoded length is known only by encoding, which a HEAD
					// does not; RFC 9110 9.3.2 lets it leave out a field only
					// generating the content would settle.
					lengthUnknown = true;
				} else {
					var encoded:Null<ByteArray> = __encodeBody(data, responseEncoding.encoding);
					if (encoded == null) {
						__sendErrorResponse(500, "Internal Server Error");
						return;
					}
					responseData = encoded;
				}

				var headerValue = __encodingToHeaderValue(responseEncoding.encoding);
				if (headerValue != null) {
					fields.push(new URLRequestHeader("Content-Encoding", headerValue));
				}
				__weakenETags(fields);
			}
		}

		if (__config.corsEnabled) {
			var allowOrigin = __computeAllowOrigin();
			if (allowOrigin != null) {
				fields.push(new URLRequestHeader("Access-Control-Allow-Origin", allowOrigin));
			}
			// Only beside an origin that was named. It went out to origins that
			// were refused as well, which granted nothing but said otherwise.
			if (__config.corsAllowCredentials && allowOrigin != null && allowOrigin != "*") {
				fields.push(new URLRequestHeader("Access-Control-Allow-Credentials", "true"));
			}
			fields.push(new URLRequestHeader("Vary", "Origin"));
			fields.push(new URLRequestHeader("Access-Control-Expose-Headers", "Content-Length, Content-Range, Accept-Ranges, Last-Modified"));
		}

		for (header in __config.customHeaders) {
			fields.push(header);
		}

		var length:Null<Int> = null;
		if (!__statusOmitsBody(statusCode) && !open && !lengthUnknown) {
			// The encoded body's own length when there is one: a length given
			// for the plain body would promise bytes the coding took away.
			length = (contentLength != null && responseData == data) ? contentLength : (responseData != null ? responseData.length : 0);
		}

		// An open body is framed as it goes: chunked under HTTP/1.1, a stream
		// held open under HTTP/2. An HTTP/1.0 client knows neither, so its
		// body ends when the connection does.
		var openBody:Bool = open && !headOnly;
		var chunked:Bool = openBody && (__writer.ownsConnection || __httpVersion == "HTTP/1.1");
		if (openBody && !chunked) {
			__responseKeepAlive = false;
		}

		// Logged and dispatched only once the response is certain to reach
		// the wire: a nested rebuild (a 406 negotiation failure, a
		// compression failure) replaces this response entirely, and an
		// event fired earlier would count and time a response that was
		// never sent, under per-response metrics, twice for one request.
		// Guarded rather than handed straight to Logger.info, because the
		// argument is built before the call regardless of whether the level
		// admits it, five concatenations per request, on a server whose
		// operator has every reason to run above INFO.
		if (ACCESS_LOG.isEnabled(LogLevel.INFO)) {
			ACCESS_LOG.info('Client ' + __origin.remoteAddress + ' ' + __method + ' ' + __requestPath + ' - Status: ' + statusCode);
		}
		var statusEvent:HTTPStatusEvent = new HTTPStatusEvent(HTTPStatusEvent.HTTP_RESPONSE_STATUS, statusCode, false);
		statusEvent.responseURL = __origin.remoteAddress;
		statusEvent.responseHeaders = headers;
		dispatchEvent(statusEvent);

		// A body the output buffer cannot hold goes out as a file does, in
		// bounded bursts on the socket's drain. Written whole, whatever the
		// peer had not taken by the first flush stayed buffered, past the cap
		// the socket closed, and a 12 MB response went out as a 200 with its
		// full Content-Length, then 65,346 bytes, logged and counted as a
		// success.
		var bodyLength:Int = (!headOnly && responseData != null) ? responseData.length : 0;
		var cap:Int = __writer.maxBufferedBytes;
		var fromMemory:Bool = bodyLength > 0 && cap > 0 && __writer.bufferedBytes + bodyLength > cap;
		if (fromMemory || openBody) {
			__streamPending = true;
		}

		__writer.writeHead({
			statusCode: statusCode,
			statusMessage: statusMessage,
			headers: fields,
			contentLength: length,
			keepAlive: __responseKeepAlive,
			chunked: chunked
		});

		if (openBody) {
			// The body is the caller's to write, and endResponse settles the
			// connection once it is done.
			__writer.flush();
			__finishResponse();
			__streamPending = false;
			return;
		}

		if (fromMemory) {
			__writer.flush();
			__finishResponse();
			__streamPending = false;
			if (!__origin.connected) {
				return;
			}
			__streamBytes = responseData;
			__streamOffset = 0;
			__beginStreamedBody(bodyLength);
			return;
		}

		if (bodyLength > 0) {
			__writer.writeBody(responseData, 0, bodyLength);
		}

		__writer.flush();

		// Only when the body is complete. A streaming response has just had
		// its head written and ends when the pump drains.
		if (!__streamPending) {
			__writer.endResponse();
		}

		__finishResponse();
	}


	@:noCompletion private function __findIndexFile(directory:File):Null<String> {
		for (index in __config.directoryIndex) {
			// Same rule as RewriteEngine.dirIndex, and it has to be the same
			// rule: two selectors that disagree resolve one directory two
			// ways depending on which one reached it first.
			if (__php == null && __isPhp(index)) {
				continue;
			}

			var indexPath:File = directory.resolvePath(index);
			if (indexPath.exists) {
				return indexPath.nativePath;
			}
		}
		return null;
	}

	/**
	 * Sends a response and ends the request.
	 *
	 * Intended for middleware that answers a request itself, a health
	 * check, a metrics endpoint, an authentication failure, a small API
	 * route, rather than letting it fall through to static-file routing.
	 *
	 * A middleware that calls this must **not** also call `next()`: the
	 * request is already complete, and continuing the chain would attempt
	 * a second response on the same connection.
	 *
	 * @param statusCode HTTP status to send.
	 * @param contentType Value for the `Content-Type` header.
	 * @param body Response body, sent as UTF-8. Suppressed for `HEAD`.
	 * @param headers Optional additional response headers.
	 * @param statusMessage Reason phrase; defaults to the standard text
	 *        for `statusCode`.
	 */
	public function respond(statusCode:Int, contentType:String, body:String, ?headers:Array<URLRequestHeader>, ?statusMessage:String):Void {
		var reason:String = (statusMessage == null) ? __statusMessage(statusCode) : statusMessage;
		__dispatchResponse(statusCode, reason, headers, contentType, body, __method == "HEAD");
	}

	/**
	 * `respond`, with a body of bytes: an image, an archive, anything that
	 * is not text. Sent as given; `respond` could only send a String, as
	 * UTF-8.
	 */
	public function respondBytes(statusCode:Int, contentType:String, body:ByteArray, ?headers:Array<URLRequestHeader>, ?statusMessage:String):Void {
		var reason:String = (statusMessage == null) ? __statusMessage(statusCode) : statusMessage;
		__dispatchResponseBytes(statusCode, reason, headers, contentType, body != null ? body : new ByteArray(), __method == "HEAD");
	}

	/**
	 * Whether the client can still be written to: false once it has gone,
	 * or, over HTTP/2, has reset this request's stream. A route holding a
	 * request open, a long poll, can read it, or listen for
	 * `Event.CLOSE` instead.
	 */
	public var connected(get, never):Bool;

	@:noCompletion private function get_connected():Bool {
		return !__clientLeft && __writer.connected;
	}

	/**
	 * Starts a response whose body is written as it is produced, server-
	 * sent events, a download generated on the fly, rather than handed over
	 * whole. The status and headers go out now, and the returned stream
	 * carries the body: `write` it, then `end` it. Until then nothing else
	 * can answer the request.
	 *
	 * No `Content-Length` is sent. Under HTTP/1.1 the body is chunked,
	 * ended by closing the connection for an HTTP/1.0 client, and under
	 * HTTP/2 it is DATA on a stream held open. It is compressed as it goes
	 * where the compression policy covers its type and the client takes gzip
	 * or deflate, each write flushed so the client can inflate it at once;
	 * br and lz4 cannot be streamed here, and are not used. For a
	 * `HEAD`, or a status that carries no body, the head is the response and
	 * the stream drops what it is given.
	 *
	 * Listen here for `Event.CLOSE` to hear that the client went away, the
	 * connection closed, or under HTTP/2 the stream was reset, and stop
	 * producing; the stream refuses writes from then on. A request already
	 * answered gets a stream that refuses them from the start.
	 */
	public function beginResponse(statusCode:Int, contentType:String, ?headers:Array<URLRequestHeader>, ?statusMessage:String):HTTPResponseStream {
		if (__responded || __openStream != null) {
			// One response to a request, as respond() allows.
			return @:privateAccess new HTTPResponseStream(null, false);
		}

		var reason:String = (statusMessage == null) ? __statusMessage(statusCode) : statusMessage;
		// Framing is the server's: a caller's length would contradict the
		// chunks, and its Transfer-Encoding would repeat them.
		var fields:Array<URLRequestHeader> = [];
		if (headers != null) {
			for (header in headers) {
				var name:String = header.name == null ? "" : header.name.toLowerCase();
				if (name != "content-length" && name != "transfer-encoding") {
					fields.push(header);
				}
			}
		}

		var bodiless:Bool = __method == "HEAD" || __statusOmitsBody(statusCode);

		// Compressed as it goes, for a client that takes gzip or deflate: the
		// codings that can be flushed a chunk at a time here. br and lz4 are
		// not, so a client asking only for those gets the body as it is.
		var encoder:Null<crossbyte._internal.deflatex.StreamEncoder> = null;
		if (__mayStreamCompress(statusCode, fields, contentType)) {
			fields.push(new URLRequestHeader("Vary", "Accept-Encoding"));
			var decision = __resolveResponseEncoding(statusCode, fields, true);
			if (decision.encoding != null) {
				fields.push(new URLRequestHeader("Content-Encoding", __encodingToHeaderValue(decision.encoding)));
				__weakenETags(fields);
				if (!bodiless) {
					encoder = new crossbyte._internal.deflatex.StreamEncoder(decision.encoding == CompressionAlgorithm.GZIP);
				}
			}
		}

		__dispatchResponseBytes(statusCode, reason, fields, contentType, null, bodiless, null, true);
		if (!__responded) {
			// Never went out: the client had already gone.
			return @:privateAccess new HTTPResponseStream(null, false);
		}
		if (bodiless) {
			// Complete already, and the connection settled with it; the
			// stream only has to swallow what the producer sends.
			return @:privateAccess new HTTPResponseStream(null, true);
		}

		var stream:HTTPResponseStream = @:privateAccess new HTTPResponseStream(this, false);
		__openStream = stream;
		__openEncoder = encoder;
		__watchClient();
		__writer.onDrain = __onOpenStreamDrain;
		return stream;
	}

	/** `HTTPResponseStream.write`, for the stream this handler has open. */
	@:noCompletion private function __writeOpenStream(stream:HTTPResponseStream, data:ByteArray, offset:Int, length:Int):Bool {
		if (stream != __openStream) {
			return false;
		}
		if (!__writer.connected) {
			__clientGone();
			return false;
		}

		var encoder:Null<crossbyte._internal.deflatex.StreamEncoder> = __openEncoder;
		if (encoder != null) {
			// Compressed and flushed, so the client can inflate it now.
			data = ByteArray.fromBytes(encoder.write(data, offset, length));
			offset = 0;
			length = data.length;
		}

		var cap:Int = __writer.maxBufferedBytes;
		if (cap > 0 && __writer.bufferedBytes + length > cap) {
			Logger.error('A streamed response to ${__requestPath} outran its client: ' + (__writer.bufferedBytes + length)
				+ ' bytes would be waiting, past maxOutputBufferSize ($cap). Ending it.');
			__detachOpenStream();
			__writer.abort();
			return false;
		}

		__writer.writeBody(data, offset, length);
		__writer.flush();

		if (__writer.bufferedBytes >= __openStreamWatermark()) {
			@:privateAccess stream.__blocked = true;
			return false;
		}
		return true;
	}

	/** `HTTPResponseStream.end`, for the stream this handler has open. */
	@:noCompletion private function __endOpenStream(stream:HTTPResponseStream):Void {
		if (stream != __openStream) {
			return;
		}
		var encoder:Null<crossbyte._internal.deflatex.StreamEncoder> = __openEncoder;
		__detachOpenStream();

		if (encoder != null && __writer.connected) {
			// The last block and the trailer.
			var tail:ByteArray = ByteArray.fromBytes(encoder.finish());
			__writer.writeBody(tail, 0, tail.length);
		}

		if (__writer.connected) {
			__writer.endResponse();
			__writer.flush();
		}
		__settleConnection();
	}

	@:noCompletion private function __detachOpenStream():Void {
		var stream:Null<HTTPResponseStream> = __openStream;
		__openStream = null;
		__openEncoder = null;
		__writer.onDrain = null;
		if (stream != null) {
			@:privateAccess stream.__handler = null;
		}
	}

	/**
	 * What an open stream may have queued before `write` asks its producer to
	 * wait: the file pump's watermark, kept under the output cap.
	 */
	@:noCompletion private function __openStreamWatermark():Int {
		var cap:Int = __writer.maxBufferedBytes;
		return (cap > 0 && cap < STREAM_WATERMARK) ? cap : STREAM_WATERMARK;
	}

	@:noCompletion private function __onOpenStreamDrain():Void {
		var stream:Null<HTTPResponseStream> = __openStream;
		if (stream == null || !@:privateAccess stream.__blocked || __writer.bufferedBytes >= __openStreamWatermark()) {
			return;
		}
		@:privateAccess stream.__blocked = false;
		var callback:Null<Void->Void> = stream.onDrain;
		if (callback != null) {
			callback();
		}
	}

	/**
	 * Watches the connection for Event.CLOSE only once something listens for
	 * it here, so a handler nobody asks costs no listener on its socket.
	 */
	override public function addEventListener<T>(type:crossbyte.events.EventType<T>, listener:T->Void, priority:Int = 0):Void {
		super.addEventListener(type, listener, priority);
		if ((type : String) == Event.CLOSE) {
			__watchClient();
		}
	}

	@:noCompletion private function __watchClient():Void {
		if (__watchingClient) {
			return;
		}
		__watchingClient = true;
		__origin.addEventListener(Event.CLOSE, __onClientClosed);
		__writer.onAbandoned = __clientGone;
	}

	@:noCompletion private function __unwatchClient():Void {
		if (!__watchingClient) {
			return;
		}
		__watchingClient = false;
		__origin.removeEventListener(Event.CLOSE, __onClientClosed);
		__writer.onAbandoned = null;
	}

	@:noCompletion private function __onClientClosed(_:Event):Void {
		__clientGone();
	}

	/**
	 * The client went away before its response was done: an open stream is
	 * cut loose, and whoever listens hears `Event.CLOSE`.
	 */
	@:noCompletion private function __clientGone():Void {
		__clientLeft = true;
		__unwatchClient();
		__detachOpenStream();
		dispatchEvent(new Event(Event.CLOSE));
	}

	@:noCompletion private function __dispatchResponse(statusCode:Int, statusMessage:String, headers:Array<URLRequestHeader>, contentType:String,
			content:String, headOnly:Bool = false):Void {
		// Was a near-verbatim second copy of __dispatchResponseBytes, differing
		// only in taking a String. Two copies of the header-assembly rules is
		// one too many to keep in step, and the duplicate would have needed the
		// same rewrite to reach a writer.
		// The encoded text is the body, rather than copied into one: written
		// into a new ByteArray it was allocated and copied twice more, 64 KB
		// at a time for a page.
		var hasText:Bool = content != null && content.length > 0;
		var bodyBytes:ByteArray = (!headOnly && hasText) ? ByteArray.fromBytes(crossbyte._internal.Utf8.bytesOf(content)) : new ByteArray();

		// A HEAD says what the GET would: its length, not the empty body it
		// sends, which went out as "Content-Length: 0" beside a GET of 20 KB.
		var headLength:Null<Int> = (headOnly && hasText) ? crossbyte._internal.Utf8.bytesOf(content).length : null;
		__dispatchResponseBytes(statusCode, statusMessage, headers, contentType, bodyBytes, headOnly, headLength);
	}


	/**
	 * Whether the request's `Connection` header carries the given token.
	 *
	 * Token equality after splitting, never substring search: `close`
	 * must not match a value of `not-close`, while `keep-alive, Upgrade`
	 * must still match `keep-alive`. Duplicate Connection headers arrive
	 * comma-folded by the header parser, so one split sees them all.
	 */
	@:noCompletion private function __hasConnectionToken(token:String):Bool {
		var header:String = __headers.exists("connection") ? __headers.get("connection") : null;
		if (header == null) {
			return false;
		}

		for (raw in header.split(",")) {
			if (StringTools.trim(raw).toLowerCase() == token) {
				return true;
			}
		}

		return false;
	}

	/**
	 * Whether the response about to be written may leave the connection
	 * open. Decided once, at header-write time, and stored in
	 * `__responseKeepAlive` for `__finishResponse` to act on, so the
	 * Connection header and the socket action can never disagree.
	 */
	@:noCompletion private function __decideKeepAlive(statusCode:Int):Bool {
		if (__writer.ownsConnection) {
			// Not this response's decision. Under HTTP/2 the connection
			// carries other streams and is ended by the frame layer, and the
			// checks below all reason from an HTTP/1.x version token this
			// request does not have, so they would answer "close" for every
			// HTTP/2 response and take the connection down after each one.
			return true;
		}

		if (!__config.keepAlive) {
			return false;
		}

		if (__closeAfterResponse) {
			return false;
		}

		// Nothing sent before the request was fully consumed may keep the
		// connection: unread request bytes are still in the buffer and
		// would be parsed as the next request. This one bit subsumes every
		// early-error close, 400s, 505, the containment 403, 415, 417,
		// 501, 408, the pre-request-line 429, without listing them.
		if (!__requestConsumed) {
			return false;
		}

		// __requestsServed counts previous responses at decision time (the
		// increment lands in __finishResponse), so a limit of N sends
		// exactly N responses, the Nth carrying the close.
		if (__config.keepAliveMaxRequests > 0 && (__requestsServed + 1) >= __config.keepAliveMaxRequests) {
			return false;
		}

		var clientAllows:Bool = (__httpVersion == "HTTP/1.1" && !__hasConnectionToken(Connection.CLOSE))
			|| (__httpVersion == "HTTP/1.0" && __hasConnectionToken(Connection.KEEP_ALIVE));
		if (!clientAllows) {
			return false;
		}

		// Statuses after which handler or connection state is suspect.
		// 404/405/304/406/415/417/429 are deliberately absent: reached
		// after consumption they are well-framed, routine answers, the
		// browser fetching a missing favicon must not pay a handshake for
		// it, and reached before consumption, the bit above closes.
		// The streaming follow-up must add "response length known" here.
		if (statusCode == 400 || statusCode == 408 || statusCode == 413 || statusCode >= 500) {
			return false;
		}

		return true;
	}

	/**
	 * The single tail every buffered response runs through after its
	 * flush: act on the keep/close decision, preserve pipelined surplus,
	 * and arm the deadline for whichever phase comes next.
	 *
	 * Funneling every builder through here is also what fixes the
	 * middleware that calls respond() without next(): the old builders
	 * zeroed the deadline and left the socket open with nothing armed to
	 * ever reclaim it, because only the routing paths carried a close.
	 */
	@:noCompletion private function __finishResponse():Void {
		__requestsServed++;
		__responded = true;

		if (__streamPending) {
			// The head is on the wire but the body has not been pumped yet.
			// The transfer owns the connection from here and settles it when
			// the last byte leaves: settling now would either cut the body
			// before its first byte or, on a kept-alive connection, invite
			// the next request's response into the middle of it. The keep or
			// close decision has already been made and written into the
			// header above; the pump acts on it through __settleConnection.
			return;
		}

		__settleConnection();
	}

	/**
	 * Ends the connection, or readies it for the request after this one.
	 *
	 * Split out of `__finishResponse` because a streamed response reaches
	 * this point long after its head was written, the head decides, the
	 * pump settles, while every buffered response reaches it immediately.
	 */
	@:noCompletion private function __settleConnection():Void {
		// The response is done, so a close from here on, this one's own,
		// or a later request's, is not this response's client going away.
		__unwatchClient();

		if (!__responseKeepAlive && !__writer.ownsConnection) {
			// Surplus pipelined bytes are discarded with the close,
			// identical to the old clear-and-close, whose clients re-send
			// on a fresh connection. close() dispatches Event.CLOSE even
			// when locally initiated, so the server's cleanupSocket
			// accounting fires exactly as it always has.
			if (__origin.connected) {
				__origin.close();
			}
			return;
		}

		// The header loop and the body readers leave position exactly one
		// byte past the request's framing, so everything beyond it is the
		// next pipelined request and must survive the reset, clearing
		// it here is the hang the proposal exists to avoid.
		var surplus:Int = __incomingBuffer.length - __incomingBuffer.position;
		if (surplus > 0) {
			// Allocate-and-swap rather than compacting in place: a
			// ByteArray blit from a buffer into itself has no defined
			// overlap semantics across targets.
			var carried:ByteArray = new ByteArray();
			carried.writeBytes(__incomingBuffer, __incomingBuffer.position, surplus);
			carried.position = 0;
			__incomingBuffer = carried;
		} else {
			__incomingBuffer.clear();
		}

		__resetForNextRequest(surplus > 0);

		if (surplus > 0) {
			// Pipelined surplus never passes through __onData, so the
			// request stamp and the re-parse both happen here. Under an
			// active driver loop this schedules one more iteration after
			// the current dispatch stack unwinds.
			__requestStartedAt = haxe.Timer.stamp();
			__processBuffer();
		}
	}

	/**
	 * Clears every field that describes one request so the next request
	 * on the same connection starts from nothing. The enumeration is the
	 * point: any request-scoped field missing here leaks request N's
	 * state into request N+1, which is exactly the class of bug
	 * keep-alive introduces.
	 *
	 * Deliberately untouched: `__responded` (its clear point is the
	 * driver loop's iteration boundary; clearing it here would unguard
	 * the synchronous respond-then-next() window), `__requestsServed` and
	 * `__closeAfterResponse` (connection-scoped), `__incomingBuffer` (the
	 * funnel already preserved or cleared it), `__requestStartedAt`
	 * (stamped where each request actually starts).
	 */
	@:noCompletion private function __resetForNextRequest(nextRequestPending:Bool):Void {
		__requestGeneration++;
		__headers.clear();
		__method = null;
		__filePath = null;
		__httpVersion = null;
		__queryString = "";
		__requestPath = "/";
		__requestContentEncodings = null;
		__awaitingBody = false;
		__expectBody = 0;
		__bodyBuf = null;
		__bodyComplete = null;
		__bodyIsChunked = false;
		__chunkBytesRemaining = -1;
		// A fresh ByteArray rather than clear(): the old body must become
		// collectable now, not stay referenced through a five-second idle
		// window per megabyte a client happened to POST.
		__requestBody = new ByteArray();
		__requestConsumed = false;
		// Unconditionally, same invariant as everywhere else: scan
		// offsets die with the buffer they pointed into.
		__resetHeaderScan();

		if (nextRequestPending) {
			// A pipelined request already sits in the buffer: straight
			// back to receiving, request clock armed immediately.
			__idle = false;
			__receiveDeadline = __config.requestTimeout > 0 ? haxe.Timer.stamp() + __config.requestTimeout : 0;
		} else {
			// Between requests. The same deadline field now bounds idle
			// time; zero when idle reaping is disabled.
			__idle = true;
			__receiveDeadline = (__config.keepAlive && __config.keepAliveTimeout > 0) ? haxe.Timer.stamp() + __config.keepAliveTimeout : 0;
		}
	}

	@:noCompletion private inline function __isIdle():Bool {
		return __idle;
	}

	@:noCompletion private function __sendErrorResponse(statusCode:Int, message:String):Void {
		__dispatchResponse(statusCode, message, null, "text/plain", message);
	}

	/**
	 * Asks the rate limiter about this request, and answers `429` when it
	 * says no, with a `Retry-After` giving the seconds until the key could
	 * try again. The 429 used to say nothing about when, so a client could
	 * only guess, and a polite one had nothing to be polite with.
	 */
	@:noCompletion private function __refusedByLimiter():Bool {
		var limiter:RateLimiter = __config.rateLimiter;
		if (limiter == null) {
			return false;
		}

		var key:Null<String> = __config.rateLimitKey != null ? __config.rateLimitKey(this) : RateLimiter.addressKey(remoteAddress);
		if (key == null || !limiter.isRateLimited(key)) {
			return false;
		}

		// Whole seconds, rounded up, and at least one: a client told 0 comes
		// straight back. A day at most, which also covers a cost the bucket
		// could never hold.
		var wait:Float = limiter.secondsUntil(key);
		var seconds:Int = wait < 86400 ? Math.ceil(wait) : 86400;
		if (seconds < 1) {
			seconds = 1;
		}

		__dispatchResponse(429, "Too Many Requests", [new URLRequestHeader("Retry-After", Std.string(seconds))], "text/plain", "Too Many Requests");
		return true;
	}

	@:noCompletion private function __parseContentEncodingHeader():Array<CompressionAlgorithm> {
		var header:String = __headers.exists("content-encoding") ? __headers.get("content-encoding") : null;
		if (header == null) {
			return [];
		}

		var encodings:Array<CompressionAlgorithm> = [];
		for (raw in header.split(",")) {
			var token:String = StringTools.trim(raw);
			if (token == "") {
				continue;
			}

			var qIndex:Int = token.indexOf(";");
			if (qIndex >= 0) {
				token = StringTools.trim(token.substr(0, qIndex));
			}

			var coding = HTTPContentCoding.fromString(token);
			switch (coding) {
				case HTTPContentCoding.IDENTITY:
					continue;
				case null:
					__sendErrorResponse(415, "Unsupported Content-Encoding: " + token.toLowerCase());
					return null;
				default:
					var algorithm = coding.toCompressionAlgorithm();
					if (algorithm == null) {
						__sendErrorResponse(415, "Unsupported Content-Encoding: " + token.toLowerCase());
						return null;
					}
					encodings.push(algorithm);
			}
		}

		// They multiply, each pass expanding what the last produced, and no
		// client stacks more than a proxy might add to one. The URLLoader
		// client allows the same two on a response.
		if (encodings.length > MAX_REQUEST_CODINGS) {
			__sendErrorResponse(415, "Too many content codings");
			return null;
		}

		return encodings;
	}

	/**
		Whether a response is one `HTTPServerConfig.compression` compresses
		for a client that asks: compression on, a status that is not an error
		and has a body to speak of, a body of at least `minimumSize`, `length`,
		what a GET would send, and a `contentType` the policy lists. Not a
		range, nor a body encoded already, nor one written as it goes.

		Every non-empty body used to be compressed, a `429` and a `404`
		included, so each refusal of a flood cost the setup of a Brotli encoder
		when the client listed `br`, which every browser does: 18.8 ms a
		refusal on Node rather than 0.57.
	**/
	/**
		Whether a streamed body may be compressed: as `__mayCompress` judges a
		whole one, less the size, which a stream does not know.
	**/
	@:noCompletion private function __mayStreamCompress(statusCode:Int, headers:Array<URLRequestHeader>, contentType:Null<String>):Bool {
		var policy:Null<HTTPCompression> = __config.compression;
		if (policy == null || !policy.enabled) {
			return false;
		}
		if (statusCode < 200 || statusCode >= 400 || statusCode == 204 || statusCode == 206 || statusCode == 304) {
			return false;
		}
		if (__hasResponseHeader(headers, "Content-Range") || __hasResponseHeader(headers, "Content-Encoding")) {
			return false;
		}
		return policy.compresses(contentType);
	}

	@:noCompletion private function __mayCompress(statusCode:Int, headers:Array<URLRequestHeader>, contentType:Null<String>, length:Int, open:Bool):Bool {
		var policy:Null<HTTPCompression> = __config.compression;
		if (policy == null || !policy.enabled || open) {
			return false;
		}
		if (statusCode < 200 || statusCode >= 400 || statusCode == 204 || statusCode == 206 || statusCode == 304) {
			return false;
		}
		if (length <= 0 || length < policy.minimumSize) {
			return false;
		}
		if (__hasResponseHeader(headers, "Content-Range") || __hasResponseHeader(headers, "Content-Encoding")) {
			return false;
		}
		return policy.compresses(contentType);
	}

	/**
		`data` in `algorithm`, or null when the encoder failed. Brotli at the
		policy's `level`; the other codings have one setting here.
	**/
	@:noCompletion private function __encodeBody(data:ByteArray, algorithm:CompressionAlgorithm):Null<ByteArray> {
		try {
			if (algorithm == CompressionAlgorithm.BROTLI) {
				var level:Int = __config.compression != null ? __config.compression.level : 4;
				var plain:haxe.io.Bytes = haxe.io.Bytes.alloc(data.length);
				plain.blit(0, data, 0, data.length);
				return ByteArray.fromBytes(crossbyte._internal.brotli.Brotli.compress(plain, level < 0 ? 0 : (level > 11 ? 11 : level)));
			}
			var encoded:ByteArray = new ByteArray();
			encoded.writeBytes(data, 0, data.length);
			encoded.compress(algorithm);
			return encoded;
		} catch (_:Dynamic) {
			return null;
		}
	}

	/**
		The `ETag` fields in `fields` made weak, for an encoded variant.

		A strong validator names one exact sequence of bytes, and the same tag
		went out on the identity, gzip, br and deflate bodies of one route: a
		cache or a range request could take one variant's bytes for another's.
		Weak, as nginx sends it, a revalidation still matches by RFC 9110's
		weak comparison, which `If-None-Match` uses, where a suffixed tag
		would not.
	**/
	@:noCompletion private static function __weakenETags(fields:Array<URLRequestHeader>):Void {
		for (i in 0...fields.length) {
			var field:URLRequestHeader = fields[i];
			if (field == null || field.name == null || field.name.toLowerCase() != "etag" || field.value == null) {
				continue;
			}
			var value:String = StringTools.trim(field.value);
			if (!StringTools.startsWith(value, "W/")) {
				// Replaced rather than changed: the field may be the caller's.
				fields[i] = new URLRequestHeader(field.name, "W/" + value);
			}
		}
	}

	/**
		@param kept Whether the encoded body is kept and served again, as a
		       static file's is. A body encoded for one response is put to
		       gzip before Brotli when the client takes both equally, every
		       browser lists them so, unless Brotli is native: Brotli in
		       Haxe took 1.3 ms for 64 KB of JSON where gzip from native zlib
		       takes 0.2, and a server answering browsers was held to about
		       800 compressed responses a second. A kept body is encoded once,
		       so it goes as Brotli, the smallest.
	**/
	@:noCompletion private function __resolveResponseEncoding(statusCode:Int, headers:Array<URLRequestHeader>, streamable:Bool = false, kept:Bool = false):ResponseEncodingDecision {
		// A body that is already encoded, a PHP script's under
		// zlib.output_compression, a route's own gzip, is not encoded again.
		if (statusCode == 206 || __hasResponseHeader(headers, "Content-Range") || __hasResponseHeader(headers, "Content-Encoding")) {
			return {encoding: null, reject: false};
		}

		// A 406 is itself the negotiation failure and always ships
		// identity. Negotiating its body against the same Accept-Encoding
		// that just failed would reject again and recurse
		// builder -> 406 -> builder without bound: one request header
		// ("Accept-Encoding: identity;q=0") was a stack overflow.
		if (statusCode == 406) {
			return {encoding: null, reject: false};
		}

		var acceptEncoding:String = getHeader("accept-encoding");
		if (acceptEncoding == null || StringTools.trim(acceptEncoding) == "") {
			return {encoding: null, reject: false};
		}

		var explicitQ:Map<String, Float> = new Map();
		var bestEncoding:Null<CompressionAlgorithm> = null;
		var identityAllowed:Bool = true;
		var hasIdentityToken:Bool = false;

		for (raw in acceptEncoding.split(",")) {
			var token:String = StringTools.trim(raw);
			if (token == "") {
				continue;
			}

			var q:Float = 1.0;
			var parts = token.split(";");
			token = StringTools.trim(parts[0]);
			if (parts.length > 1) {
				for (i in 1...parts.length) {
					var param = StringTools.trim(parts[i]).toLowerCase();
					if (StringTools.startsWith(param, "q=")) {
						var qValue = StringTools.trim(param.substring(2));
						var parsed = Std.parseFloat(qValue);
						q = (parsed != parsed || parsed < 0 || parsed > 1) ? 0 : parsed;
						break;
					}
				}
			}

			token = token.toLowerCase();
			explicitQ.set(token, q);
			switch (token) {
				case HTTPContentCoding.GZIP:
				case HTTPContentCoding.BR:
				case HTTPContentCoding.DEFLATE:
				case HTTPContentCoding.LZ4:
				case HTTPContentCoding.IDENTITY:
					hasIdentityToken = true;
					if (q <= 0) {
						identityAllowed = false;
					}
				default:
			}
		}

		var wildcardQ:Float = explicitQ.exists(AcceptEncoding.DEFAULT) ? explicitQ.get(AcceptEncoding.DEFAULT) : -1;
		var bestQ:Float = -1;
		// For a streamed body, only the codings that can be flushed a chunk at
		// a time.
		var supported = streamable ? [
			{name: HTTPContentCoding.GZIP, algorithm: CompressionAlgorithm.GZIP},
			{name: HTTPContentCoding.DEFLATE, algorithm: CompressionAlgorithm.ZLIB}
		] : (kept || crossbyte._internal.brotli.Brotli.isNativeAvailable()) ? [
			{name: HTTPContentCoding.BR, algorithm: CompressionAlgorithm.BROTLI},
			{name: HTTPContentCoding.GZIP, algorithm: CompressionAlgorithm.GZIP},
			{name: HTTPContentCoding.DEFLATE, algorithm: CompressionAlgorithm.ZLIB},
			{name: HTTPContentCoding.LZ4, algorithm: CompressionAlgorithm.LZ4}
		] : [
			// First among equals wins: see `kept`.
			{name: HTTPContentCoding.GZIP, algorithm: CompressionAlgorithm.GZIP},
			{name: HTTPContentCoding.DEFLATE, algorithm: CompressionAlgorithm.ZLIB},
			{name: HTTPContentCoding.BR, algorithm: CompressionAlgorithm.BROTLI},
			{name: HTTPContentCoding.LZ4, algorithm: CompressionAlgorithm.LZ4}
		];

		for (option in supported) {
			if (option.name == HTTPContentCoding.BR && !explicitQ.exists(option.name)) {
				continue;
			}

			var q = explicitQ.exists(option.name) ? explicitQ.get(option.name) : wildcardQ;
			if (q > 0 && q > bestQ) {
				bestQ = q;
				bestEncoding = option.algorithm;
			}
		}

		if (bestEncoding != null) {
			return {encoding: bestEncoding, reject: false};
		}

		if (hasIdentityToken && !identityAllowed) {
			return {encoding: null, reject: true};
		}

		return {encoding: null, reject: false};
	}

	@:noCompletion private function __encodingToHeaderValue(algorithm:CompressionAlgorithm):Null<String> {
		return switch (algorithm) {
			case CompressionAlgorithm.BROTLI: HTTPContentCoding.BR;
			// zlib is what `deflate` names; raw DEFLATE has no HTTP name, so a
			// body in it is never labelled as one.
			case CompressionAlgorithm.ZLIB: HTTPContentCoding.DEFLATE;
			case CompressionAlgorithm.GZIP: HTTPContentCoding.GZIP;
			case CompressionAlgorithm.LZ4: HTTPContentCoding.LZ4;
			default: null;
		}
	}

	@:noCompletion private function __hasResponseHeader(headers:Array<URLRequestHeader>, name:String):Bool {
		if (headers == null) {
			return false;
		}

		var needle = name.toLowerCase();
		for (header in headers) {
			if (header != null && header.name != null && header.name.toLowerCase() == needle) {
				return true;
			}
		}

		return false;
	}

	@:noCompletion private function __readLine(buffer:ByteArray):Null<String> {
		var startPos:UInt = buffer.position;
		// A StringBuf rather than string concatenation: += allocated a new
		// string per byte, which priced a header block at the square of its
		// length. addChar keeps the original byte-for-byte semantics, each
		// byte becomes one code point, no UTF-8 decoding, so header values
		// carrying bytes above 0x7F read back exactly as they arrived.
		var line:StringBuf = new StringBuf();
		while (buffer.position < buffer.length) {
			// Unsigned, which is the whole claim above. `readByte` carries
			// Flash's sign extension, so 0xE9 arrives as -23 and `addChar`
			// gets a negative code point: harmless on a target whose String is
			// bytes, and a `RangeError: Invalid code point -23` thrown out of
			// request parsing on Node. Any byte above 0x7F anywhere in a
			// request line or header did it, a UTF-8 filename in a
			// Content-Disposition, an accented Referer, a non-ASCII
			// User-Agent.
			var b:Int = buffer.readUnsignedByte();
			line.addChar(b);
			if (b == 10) {
				return line.toString();
			}
		}
		buffer.position = startPos;
		return null;
	}

	/**
	 * Whether the buffer now holds a complete header block.
	 *
	 * The scan resumes where the previous call stopped, carrying its last
	 * three bytes across data events. It used to restart from byte zero
	 * every time more data arrived, which made header receipt quadratic in
	 * the number of arrivals, the shape a slow client produces, whether an
	 * honest one on a bad link or a deliberate one feeding a byte at a
	 * time. Measured at 7.6x on a 2 KB block arriving in 64-byte chunks.
	 */
	@:noCompletion private function __hasCompleteHeaderBlock(buffer:ByteArray):Bool {
		var startPos:UInt = buffer.position;
		var a:Int = __scanA;
		var b:Int = __scanB;
		var c:Int = __scanC;

		buffer.position = __scanned;

		while (buffer.position < buffer.length) {
			var d:Int = buffer.readByte();

			if ((a == 13 && b == 10 && c == 13 && d == 10) || (c == 10 && d == 10)) {
				buffer.position = startPos;
				__resetHeaderScan();
				return true;
			}

			a = b;
			b = c;
			c = d;
		}

		__scanA = a;
		__scanB = b;
		__scanC = c;
		__scanned = buffer.length;
		buffer.position = startPos;
		return false;
	}

	/**
	 * Forgets scan progress. Belongs wherever `__incomingBuffer` restarts
	 * from empty: offsets held across data events point into bytes that no
	 * longer exist once the buffer is cleared.
	 */
	@:noCompletion private inline function __resetHeaderScan():Void {
		__scanA = -1;
		__scanB = -1;
		__scanC = -1;
		__scanned = 0;
	}

	@:noCompletion private function __getMimeType(filePath:String):String {
		final ext = filePath.split('.').pop().toLowerCase();
		var mimeType:String = switch (ext) {
			case "html", "htm": "text/html; charset=utf-8";
			case "css": "text/css; charset=utf-8";
			case "js", "mjs": "application/javascript; charset=utf-8";
			case "txt": "text/plain; charset=utf-8";
			case "json", "map": "application/json; charset=utf-8";
			case "csv": "text/csv; charset=utf-8";
			case "xml": "application/xml; charset=utf-8";
			case "webmanifest", "manifest": "application/manifest+json";
			case "svg": "image/svg+xml";

			case "png": "image/png";
			case "jpg", "jpeg": "image/jpeg";
			case "gif": "image/gif";
			case "webp": "image/webp";
			case "ico": "image/x-icon";

			case "woff2": "font/woff2";
			case "woff": "font/woff";
			case "ttf": "font/ttf";
			case "otf": "font/otf";

			case "wasm": "application/wasm";
			case "mp3": "audio/mpeg";
			case "wav": "audio/wav";
			case "mp4": "video/mp4";
			case "pdf": "application/pdf";

			default: "application/octet-stream";
		}
		return mimeType;
	}

	/**
	 * Decodes `%XX` escapes in a request path, and nothing else.
	 *
	 * `StringTools.urlDecode` is form decoding: it also reads `+` as a
	 * space, a rule RFC 3986 confines to query strings. In a path `+` is an
	 * ordinary literal, so `GET /a+b.html` must look up `a+b.html`. Escapes
	 * are decoded as bytes and each maximal run is read back as UTF-8, so
	 * `%C3%A9` arrives as one character, not two. A truncated or non-hex
	 * escape throws; the caller answers it with `400 Bad Request`.
	 *
	 * A decoded NUL throws as well, and that one is load-bearing rather
	 * than tidy. Every filesystem call underneath `File` reaches a C API
	 * through the string's `char*`, which ends at the first NUL, while the
	 * blacklist and whitelist compare whole Haxe strings that do not. So
	 * `/secret.txt%00.html` would be checked as one name and opened as
	 * another, a blacklist matching `secret.txt` finds no match, then
	 * `exists()` and `load()` truncate and serve it. No legitimate path
	 * carries a NUL, so it is refused here rather than defended against
	 * at every use.
	 */
	@:noCompletion private static function __percentDecodePath(path:String):String {
		if (path.indexOf("%") < 0) {
			return path;
		}

		var out:StringBuf = new StringBuf();
		var i:Int = 0;
		var n:Int = path.length;
		while (i < n) {
			var c:Int = StringTools.fastCodeAt(path, i);
			if (c != "%".code) {
				out.addChar(c);
				i++;
				continue;
			}

			var bytes:BytesBuffer = new BytesBuffer();
			while (i < n && StringTools.fastCodeAt(path, i) == "%".code) {
				if (i + 2 >= n) {
					throw "truncated percent escape";
				}
				var hi:Int = __hexDigit(StringTools.fastCodeAt(path, i + 1));
				var lo:Int = __hexDigit(StringTools.fastCodeAt(path, i + 2));
				if (hi < 0 || lo < 0) {
					throw "invalid percent escape";
				}
				var b:Int = (hi << 4) | lo;
				if (b == 0) {
					throw "NUL byte in path";
				}
				bytes.addByte(b);
				i += 3;
			}
			out.add(bytes.getBytes().toString());
		}

		return out.toString();
	}

	@:noCompletion private static function __hexDigit(c:Int):Int {
		if (c >= "0".code && c <= "9".code) {
			return c - "0".code;
		}
		if (c >= "a".code && c <= "f".code) {
			return c - "a".code + 10;
		}
		if (c >= "A".code && c <= "F".code) {
			return c - "A".code + 10;
		}
		return -1;
	}

	/**
	 * The filesystem path of a settled web path under the document root, or
	 * null when it would not be inside it.
	 *
	 * String work only. Resolving through `File` stats what it names on
	 * construction, and every lookup after this repeats that anyway.
	 * `HttpSyntax.normalizePath` already keeps a settled path inside the
	 * root; the containment check is a second lock on the same door.
	 */
	@:noCompletion private function __nativePathFor(webPath:String):Null<String> {
		var root:String = __config.rootDirectory.nativePath;
		var separator:String = __pathSeparator();
		var relative:String = webPath.length > 1 ? webPath.substr(1) : "";
		if (separator != "/" && relative.indexOf("/") >= 0) {
			relative = relative.split("/").join(separator);
		}

		var full:String = (StringTools.endsWith(root, "/") || StringTools.endsWith(root, "\\")) ? root + relative : root + separator + relative;
		return __isWithinRoot(root, full) ? full : null;
	}

	@:noCompletion private static function __isWithinRoot(rootPath:String, fullPath:String):Bool {
		var rootNorm:String = __normalizeContainmentPath(rootPath);
		var fullNorm:String = __normalizeContainmentPath(fullPath);
		if (fullNorm == rootNorm) {
			return true;
		}

		var rootWithBoundary:String = rootNorm;
		if (!StringTools.endsWith(rootWithBoundary, __pathSeparator())) {
			rootWithBoundary += __pathSeparator();
		}
		return StringTools.startsWith(fullNorm, rootWithBoundary);
	}

	@:noCompletion private static function __normalizeContainmentPath(path:String):String {
		var normalized:String = Path.normalize(path);

		// Runtime, because this decides whether a request escapes the document
		// root and `#if windows` says which target the compiler was aimed at
		// rather than which machine is serving. eval, Node and the JVM all run
		// on Windows without it, and all three skipped the case fold, so
		// `C:\WWW\index.html` was judged not to be inside `C:\www`. That
		// direction is fail-closed, a legitimate request refused rather than a
		// forbidden one allowed, which is why nothing caught it.
		if (crossbyte.sys.System.isWindows) {
			normalized = normalized.split("/").join("\\").toLowerCase();
		} else {
			normalized = normalized.split("\\").join("/");
		}

		return __trimTrailingSeparators(normalized);
	}

	@:noCompletion private static function __trimTrailingSeparators(path:String):String {
		while (path.length > 1 && __isTrailingSeparatorSafeToTrim(path)) {
			path = path.substr(0, path.length - 1);
		}
		return path;
	}

	@:noCompletion private static inline function __isTrailingSeparatorSafeToTrim(path:String):Bool {
		var last:String = path.charAt(path.length - 1);
		if (last != "/" && last != "\\") {
			return false;
		}
		// "C:\" is a root, not a path with a trailing separator to trim.
		if (crossbyte.sys.System.isWindows && path.length == 3 && path.charAt(1) == ":") {
			return false;
		}
		return true;
	}

	@:noCompletion private static inline function __pathSeparator():String {
		return crossbyte.sys.System.isWindows ? "\\" : "/";
	}

	@:noCompletion private static final HTTP_DATE_DAYS:Array<String> = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
	@:noCompletion private static final HTTP_DATE_MONTHS:Array<String> = [
		"Jan", "Feb", "Mar", "Apr", "May", "Jun",
		"Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
	];

	/**
	 * The `Date` header only carries whole seconds, so within one second
	 * every response is asking for the same string. The tables live in
	 * statics because this used to be `inline`, which re-created both
	 * array literals at every call site, on every response.
	 *
	 * Two runtime threads may race this cache. The string is written
	 * before the stamp, so a reader that sees the new stamp finds the
	 * matching string in place; the worst a race costs is one redundant
	 * format, never a wrong date.
	 */
	@:noCompletion private static var __httpDateCached:String = null;
	@:noCompletion private static var __httpDateSecond:Float = -1;

	@:noCompletion private static function __formatHttpDate():String {
		var second:Float = Math.ffloor(Sys.time()); // time of day: the header states it

		if (second == __httpDateSecond) {
			return __httpDateCached;
		}

		var formatted:String = __toHttpDate(second * 1000);
		__httpDateCached = formatted;
		__httpDateSecond = second;

		return formatted;
	}

	/**
	 * Reads a single `bytes=first-last` range against a file of `total`
	 * bytes, or answers null when it cannot be satisfied.
	 *
	 * By hand rather than through a regular expression, which was compiled
	 * on every ranged request, and through `IntParse` rather than
	 * `Std.parseInt`, which on Linux native read `bytes=4294967296-` as a
	 * range starting at 0. A number past an `Int` is still a number here:
	 * as a start it lies beyond any file this serves, as an end or a suffix
	 * it covers the whole file, which is what RFC 9110 14.1.2 makes of it.
	 */
	@:noCompletion private static function __parseRange(h:String, total:Int):{start:Int, end:Int} {
		if (h == null || total <= 0) {
			// A range of an empty representation is never satisfiable.
			return null;
		}

		var spec:String = StringTools.trim(h);
		if (spec.length < 7 || spec.substr(0, 6).toLowerCase() != "bytes=") {
			return null;
		}

		var dash:Int = spec.indexOf("-", 6);
		if (dash < 0) {
			return null;
		}

		var first:Int = __rangeNumber(spec.substring(6, dash));
		var last:Int = __rangeNumber(spec.substr(dash + 1));
		if (first == RANGE_INVALID || last == RANGE_INVALID || (first == RANGE_ABSENT && last == RANGE_ABSENT)) {
			return null;
		}

		if (first == RANGE_ABSENT) {
			// A suffix: the last `last` bytes.
			if (last <= 0) {
				return null;
			}
			return {start: total > last ? total - last : 0, end: total - 1};
		}

		if (first >= total) {
			return null;
		}

		var end:Int = (last == RANGE_ABSENT || last >= total) ? total - 1 : last;
		if (end < first) {
			return null;
		}
		return {start: first, end: end};
	}

	@:noCompletion private static inline var RANGE_ABSENT:Int = -1;
	@:noCompletion private static inline var RANGE_INVALID:Int = -2;

	/**
	 * One side of a byte range: `RANGE_ABSENT` when empty, `RANGE_INVALID`
	 * when not all digits, and the largest `Int` for digits past it.
	 */
	@:noCompletion private static function __rangeNumber(text:String):Int {
		if (text.length == 0) {
			return RANGE_ABSENT;
		}

		var value:Int = IntParse.decimal(text);
		if (value >= 0) {
			return value;
		}

		for (i in 0...text.length) {
			var code:Int = StringTools.fastCodeAt(text, i);
			if (code < "0".code || code > "9".code) {
				return RANGE_INVALID;
			}
		}
		return 0x7FFFFFFF;
	}

	/**
	 * `t`, milliseconds since 1970, as an IMF-fixdate in UTC.
	 *
	 * Worked out by arithmetic, as `__parseHttpDate` reads one back. Through
	 * `Date` it took the local offset at one instant and applied it at
	 * another, so it was an hour out around a daylight-saving change, and a
	 * `Date` on neko keeps its time in 32 bits.
	 */
	@:noCompletion private static function __toHttpDate(t:Float):String {
		var days:Float = Math.ffloor(t / 86400000);
		var secondOfDay:Int = Std.int(Math.ffloor((t - days * 86400000) / 1000));
		var z:Int = Std.int(days);
		// 1 January 1970 was a Thursday, and HTTP_DATE_DAYS starts on Sunday.
		var weekday:Int = ((z % 7) + 11) % 7;

		// Howard Hinnant's civil_from_days: the proleptic Gregorian date of
		// day `z`, in eras of 400 years that each repeat exactly.
		z += 719468;
		var era:Int = Std.int((z >= 0 ? z : z - 146096) / 146097);
		var dayOfEra:Int = z - era * 146097;
		var yearOfEra:Int = Std.int((dayOfEra - Std.int(dayOfEra / 1460) + Std.int(dayOfEra / 36524) - Std.int(dayOfEra / 146096)) / 365);
		var dayOfYear:Int = dayOfEra - (365 * yearOfEra + Std.int(yearOfEra / 4) - Std.int(yearOfEra / 100));
		var shiftedMonth:Int = Std.int((5 * dayOfYear + 2) / 153);
		var day:Int = dayOfYear - Std.int((153 * shiftedMonth + 2) / 5) + 1;
		var month:Int = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9;
		var year:Int = yearOfEra + era * 400 + (month <= 2 ? 1 : 0);

		return HTTP_DATE_DAYS[weekday] + ", " + StringTools.lpad(Std.string(day), "0", 2) + " " + HTTP_DATE_MONTHS[month - 1] + " "
			+ StringTools.lpad(Std.string(year), "0", 4) + " " + StringTools.lpad(Std.string(Std.int(secondOfDay / 3600)), "0", 2) + ":"
			+ StringTools.lpad(Std.string(Std.int(secondOfDay / 60) % 60), "0", 2) + ":" + StringTools.lpad(Std.string(secondOfDay % 60), "0", 2) + " GMT";
	}
	/**
	 * Whether a static file may be served under the settled web path `path`:
	 * there is a document root to serve it from, the path names nothing the
	 * configuration keeps back (see `HTTPServerConfig.serveDotFiles`), and,
	 * for a path the resolver `found`, it is spelled the way the
	 * filesystem spells it.
	 */
	@:noCompletion private function __servesStaticPath(path:String, found:Bool):Bool {
		if (__config.rootDirectory == null) {
			return false;
		}

		if (!__config.serveDotFiles && __hasHiddenSegment(path)) {
			return false;
		}

		return !found || !__caselessFilesystem() || __isSpelledAsOnDisk(path);
	}

	/**
	 * Whether each segment of `webPath` is spelled exactly as the directory
	 * holding it lists it.
	 *
	 * Windows and macOS answer to many spellings of one name: any letter
	 * case, and on Windows a trailing dot or space, an 8.3 short name, or
	 * `name::$DATA`. A middleware guard compares the path as a string, so a
	 * guard on `/private/` let `/PRIVATE/report.txt` through and the file
	 * under `private/` was served. Serving a file only under its own spelling
	 * makes those systems answer as Linux does, and a guard's comparison mean
	 * what it says, for dotfiles too, which Windows also names by a short
	 * name that has no dot.
	 *
	 * One directory listing per segment, paid only for a path the resolver
	 * found, only on those two systems, and held for a second by
	 * `DirectoryListings` so a busy directory is not listed per request.
	 */
	@:noCompletion private function __isSpelledAsOnDisk(webPath:String):Bool {
		var listings:DirectoryListings = DirectoryListings.current();
		var directory:String = __config.rootDirectory.nativePath;
		var length:Int = webPath.length;
		var start:Int = 1;

		while (start < length) {
			var end:Int = webPath.indexOf("/", start);
			if (end < 0) {
				end = length;
			}

			if (end > start) {
				var name:String = webPath.substring(start, end);
				if (!listings.lists(directory, name)) {
					return false;
				}
				directory = Path.join([directory, name]);
			}

			start = end + 1;
		}

		return true;
	}

	@:noCompletion private static var __caseless:Int = -1;

	/** Whether this machine's filesystems answer to more than one spelling of a name: Windows and macOS. */
	@:noCompletion private static function __caselessFilesystem():Bool {
		if (__caseless < 0) {
			// Asked at runtime, for the reason __normalizeContainmentPath gives.
			__caseless = (crossbyte.sys.System.isWindows || Sys.systemName() == "Mac") ? 1 : 0;
		}

		return __caseless == 1;
	}

	/**
	 * Whether any segment of `path` starts with a dot, other than a leading
	 * `/.well-known`, which RFC 8615 reserves for files meant to be public.
	 *
	 * `.` and `..` are not names but steps, and are not counted. Backslash
	 * separates segments too, because it does on the filesystem the file
	 * would be read from on Windows: `/a\.env` names `a/.env` there.
	 */
	@:noCompletion private static function __hasHiddenSegment(path:String):Bool {
		if (path == null) {
			return false;
		}

		var length:Int = path.length;
		var start:Int = 0;
		var first:Bool = true;

		while (start < length) {
			var code:Int = StringTools.fastCodeAt(path, start);
			if (code == "/".code || code == "\\".code) {
				start++;
				continue;
			}

			var end:Int = start + 1;
			while (end < length) {
				var next:Int = StringTools.fastCodeAt(path, end);
				if (next == "/".code || next == "\\".code) {
					break;
				}
				end++;
			}

			if (code == ".".code) {
				var size:Int = end - start;
				var step:Bool = size == 1 || (size == 2 && StringTools.fastCodeAt(path, start + 1) == ".".code);
				if (!step) {
					if (!(first && size == WELL_KNOWN.length && path.substr(start, size) == WELL_KNOWN)) {
						return true;
					}
				}
			}

			first = false;
			start = end;
		}

		return false;
	}

	@:noCompletion private static inline var WELL_KNOWN:String = ".well-known";

	@:noCompletion private inline function __isPhp(path:String):Bool {
		var dot:Int = path.lastIndexOf(".");
		return (dot >= 0) && (path.substr(dot + 1).toLowerCase() == "php");
	}

	@:noCompletion private function __servePhp(absPhpPath:String, headOnly:Bool, ?body:ByteArray, ?overrideScriptName:String):Void {
		if (__php == null) {
			// A rewrite routed here with the PHP flag on a server that has no
			// PHP bridge, which the shipped defaults do to every /api path
			// while phpEnabled defaults to false. Reaching the bridge anyway
			// dereferenced null and took the process down, a segfault on a
			// default configuration, from a request path a great many services
			// use. A 500 says the server is misconfigured; a crash says
			// nothing and loses every other connection with it.
			Logger.error("Request rewritten to PHP but no PHP bridge is configured; set phpEnabled or remove the PHP rewrite.");
			__sendErrorResponse(500, "Internal Server Error");
			return;
		}

		// final reqUri:String = (__queryString != "" ? (__extractPathOnly() + "?" + __queryString) : __extractPathOnly());

		var hostHeader:String = __headers.exists("host") ? __headers.get("host") : null;
		var sName:String = hostHeader;
		var sPort:String = null;
		if (hostHeader != null) {
			// The port follows the last colon, and for an IPv6 literal only a
			// colon after the closing bracket: "[::1]:8080" split at its first
			// colon named the server "[".
			var close:Int = StringTools.startsWith(hostHeader, "[") ? hostHeader.indexOf("]") : -1;
			var i:Int = hostHeader.indexOf(":", close < 0 ? 0 : close);
			if (i > 0) {
				sName = hostHeader.substr(0, i);
				// Through IntParse: Std.parseInt took trailing junk, and a
				// number past an Int differently on every target.
				var p:Int = IntParse.decimal(hostHeader.substr(i + 1), 65535);
				if (p >= 0) {
					sPort = Std.string(p);
				}
			}
		}

		final phpReq:PHPRequest = {
			scriptFilename: absPhpPath,
			requestMethod: __method,
			requestUri: (__queryString != "" ? (__extractPathOnly() + "?" + __queryString) : __extractPathOnly()),
			scriptName: overrideScriptName != null ? overrideScriptName : __extractPathOnly(),
			queryString: __queryString,
			contentType: __headers.exists("content-type") ? __headers.get("content-type") : null,
			remoteAddr: __origin.remoteAddress,
			serverName: sName,
			serverPort: sPort,
			extraHeaders: __forwardedToPhp(__headers),
			body: body
		};

		// The tail of this method is now the callback, which is the whole of
		// the handler-side change. execute() used to block here, inside a
		// tick, so for the duration of a PHP script nothing else on this
		// runtime ran: no other request read, no response written, no timer
		// advanced, so one slow page stalled every other client on the runtime,
		// none of which had anything to do with it.
		var exchange = __php.execute(phpReq);

		exchange.then(function(phpRes:PHPResponse):Void {
			// The connection may have gone while PHP was thinking, a client
			// that gave up, or a drain() closing us down. __dispatchResponse
			// guards against a second response on one request, but writing
			// into a socket that has moved on to the next one would not be a
			// second response, it would be a stray one.
			if (__origin == null || !__origin.connected || __responded) {
				return;
			}

			var ctype:String = phpRes.headers.exists("content-type") ? phpRes.headers.get("content-type") : "text/html; charset=utf-8";

			// Everything the script said but the status and what the server
			// writes itself. Only Cache-Control, Location and Set-Cookie came
			// through, so ETag, Content-Disposition, WWW-Authenticate, Vary,
			// CORS and a script's own fields never reached the client.
			var out:Array<URLRequestHeader> = [];
			for (name => value in phpRes.headers) {
				if (PHP_UNRETURNED.indexOf(name) >= 0 || (__config.corsEnabled && StringTools.startsWith(name, "access-control-"))) {
					continue;
				}
				if (name == "set-cookie") {
					// An escape, not a line break between the quotes. A literal
					// one takes the file's line ending, so a CRLF checkout split
					// on "\r\n", never separated the cookies PHPExchange joins
					// with "\n", and sent them glued into one header.
					for (cookie in value.split("\n")) {
						var c:String = StringTools.trim(cookie);
						if (c != "") {
							out.push(new URLRequestHeader("Set-Cookie", c));
						}
					}
					continue;
				}
				out.push(new URLRequestHeader(__fieldCase(name), value));
			}

			var bodyBytes:ByteArray = phpRes.body;
			__dispatchResponseBytes(phpRes.status, __statusMessage(phpRes.status), out, ctype, bodyBytes, (__method == "HEAD" || headOnly));
		}, function(message:String):Void {
			if (__origin == null || !__origin.connected || __responded) {
				return;
			}

			// 504 against 502. A backend that answered badly and one that did
			// not answer are different faults with different fixes, and only
			// one of them still has something wedged on the other side. The
			// operator gets the detail; a client cannot be told which upstream
			// is stuck.
			//
			// Decided from the failure itself, not from its wording. This read
			// `message.indexOf("did not respond within") >= 0`, so rewording
			// PHPTimeout would have turned every gateway timeout into a bad
			// gateway with nothing to say it had.
			if (Std.isOfType(exchange.cause, PHPTimeout)) {
				Logger.error("PHP backend timed out: " + message, ["path" => __requestPath]);
				__dispatchResponse(504, "Gateway Timeout", null, "text/plain", "Gateway Timeout", true);
				return;
			}

			Logger.error("PHP backend failed: " + message, ["path" => __requestPath]);
			__dispatchResponse(502, "Bad Gateway", null, "text/plain", "Bad Gateway", true);
		});
	}

	@:noCompletion private inline function __extractPathOnly():String {
		return __requestPath;
	}

	/**
	 * Request fields a script is not given as `HTTP_*`: those about this
	 * connection rather than the request, the two CGI gives variables of their
	 * own, and `Proxy`, which a script would read as `HTTP_PROXY`, where
	 * HTTP client libraries look for a proxy to send everything through
	 * (httpoxy).
	 */
	@:noCompletion private static final PHP_UNFORWARDED:Array<String> = [
		"connection", "keep-alive", "proxy-connection", "te", "trailer", "transfer-encoding", "upgrade", "http2-settings", "content-type",
		"content-length", "proxy"
	];

	/**
	 * Response fields a script's are not passed back for: the CGI status, the
	 * framing, and what the server writes on every response itself.
	 * `access-control-*` joins them when the server's own CORS is on.
	 */
	@:noCompletion private static final PHP_UNRETURNED:Array<String> = [
		"status", "content-type", "content-length", "transfer-encoding", "connection", "keep-alive", "proxy-connection", "te", "trailer",
		"upgrade", "date", "server", "x-content-type-options"
	];

	/**
	 * The request's fields for the bridge, which gives a script each as
	 * `HTTP_<NAME>`. It was eight of them, host, user-agent, accept,
	 * accept-language, accept-encoding, referer, cookie and authorization,
	 * so a script never saw Origin, X-Requested-With, a CSRF token, a
	 * conditional request, Range or what a proxy forwarded.
	 *
	 * All of them now, but those in `PHP_UNFORWARDED`, those `Connection`
	 * names as its own, and any whose name is not letters, digits and hyphens:
	 * `X_Forwarded_For` would reach a script as `HTTP_X_FORWARDED_FOR`, the
	 * variable a proxy's `X-Forwarded-For` becomes.
	 */
	@:noCompletion private static function __forwardedToPhp(fields:Map<String, String>):Map<String, String> {
		var hop:Array<String> = [];
		var connection:Null<String> = fields.get("connection");
		if (connection != null) {
			for (token in connection.split(",")) {
				hop.push(StringTools.trim(token).toLowerCase());
			}
		}

		var forwarded:Map<String, String> = new Map();
		for (name => value in fields) {
			if (value == null || !__isPlainFieldName(name) || PHP_UNFORWARDED.indexOf(name) >= 0 || hop.indexOf(name) >= 0) {
				continue;
			}
			forwarded.set(name, value);
		}
		return forwarded;
	}

	@:noCompletion private static function __isPlainFieldName(name:String):Bool {
		if (name.length == 0) {
			return false;
		}
		for (i in 0...name.length) {
			var c:Int = StringTools.fastCodeAt(name, i);
			if (!((c >= "a".code && c <= "z".code) || (c >= "A".code && c <= "Z".code) || (c >= "0".code && c <= "9".code) || c == "-".code)) {
				return false;
			}
		}
		return true;
	}

	/** `content-disposition` as `Content-Disposition`. */
	@:noCompletion private static function __fieldCase(name:String):String {
		var parts:Array<String> = name.split("-");
		for (i in 0...parts.length) {
			var part:String = parts[i];
			if (part.length > 0) {
				parts[i] = part.charAt(0).toUpperCase() + part.substr(1);
			}
		}
		return parts.join("-");
	}

	@:noCompletion private inline function __statusMessage(code:Int):String {
		return switch (code) {
			case 200: "OK";
			case 201: "Created";
			case 204: "No Content";
			case 301: "Moved Permanently";
			case 302: "Found";
			case 304: "Not Modified";
			case 400: "Bad Request";
			case 401: "Unauthorized";
			case 403: "Forbidden";
			case 404: "Not Found";
			case 405: "Method Not Allowed";
			case 406: "Not Acceptable";
			case 415: "Unsupported Media Type";
			case 413: "Payload Too Large";
			case 416: "Range Not Satisfiable";
			case 417: "Expectation Failed";
			case 422: "Unprocessable Content";
			case 428: "Precondition Required";
			case 429: "Too Many Requests";
			case 431: "Request Header Fields Too Large";
			case 500: "Internal Server Error";
			case 501: "Not Implemented";
			case 502: "Bad Gateway";
			case 503: "Service Unavailable";
			case 504: "Gateway Timeout";
			case 505: "HTTP Version Not Supported";
			// A status with no phrase of its own gets one for its class rather
			// than "OK", which is what this used to answer for everything it
			// did not know. A middleware raising 503 through next(503) put
			// "HTTP/1.1 503 OK" on the wire, a status line that contradicts
			// itself, and reads as success to anything matching on the phrase
			// rather than the code. HTTP/1.1 allows the phrase to be anything,
			// including empty; it does not allow it to be a lie.
			default: __statusClass(code);
		}
	}

	@:noCompletion private inline function __statusClass(code:Int):String {
		return if (code >= 100 && code < 200) {
			"Informational";
		} else if (code < 300) {
			"Success";
		} else if (code < 400) {
			"Redirection";
		} else if (code < 500) {
			"Client Error";
		} else if (code < 600) {
			"Server Error";
		} else {
			"Unknown Status";
		}
	}

	@:noCompletion private function __beginRequestBodyRead(onComplete:Void->Void):Bool {
		__requestBody = new ByteArray();
		__requestBody.endian = __incomingBuffer.endian;

		var transferEncoding:String = __headers.exists("transfer-encoding") ? __headers.get("transfer-encoding") : null;

		// RFC 7230 3.3.3: a message with both Transfer-Encoding and Content-Length is
		// ambiguous and a vector for request smuggling. Reject it outright.
		if (HttpSyntax.hasConflictingFraming(transferEncoding != null, __headers.exists("content-length"))) {
			__sendErrorResponse(400, "Bad Request");
			return true;
		}

		var chunked:Bool = false;
		if (transferEncoding != null) {
			var encodings = transferEncoding.toLowerCase().split(",");
			if (encodings.length == 0 || StringTools.trim(encodings[encodings.length - 1]) != "chunked") {
				__dispatchResponse(501, "Not Implemented", null, "text/plain", "Transfer-Encoding not supported");
				return true;
			}
			chunked = true;
		}

		var contentLength:Int = 0;
		if (!chunked) {
			var contentLengthHeader:String = __headers.exists("content-length") ? __headers.get("content-length") : null;
			if (contentLengthHeader != null) {
				contentLength = __parseContentLength(contentLengthHeader);
				if (contentLength < 0) {
					__sendErrorResponse(400, "Bad Request");
					return true;
				}
				// Too big is not malformed: 413, and before a byte of the body
				// is read. This was a 400.
				if (contentLength > __config.maxRequestBodySize) {
					__sendErrorResponse(413, "Payload Too Large");
					return true;
				}
			}
		}

		var expect:String = __headers.exists("expect") ? __headers.get("expect") : null;
		if (expect != null) {
			var expectValue:String = StringTools.trim(expect.toLowerCase());
			if (expectValue != "100-continue") {
				__sendErrorResponse(417, "Expectation Failed");
				return true;
			}

			// Asked before the client is told to send: the point of the
			// expectation is that a request refused on its headers, no
			// credentials, say, never has its body sent at all. The server
			// used to say go ahead before any middleware had seen the request.
			if (__config.onExpectContinue != null) {
				var proceed:Bool = false;
				try {
					proceed = __config.onExpectContinue(this);
				} catch (error:Dynamic) {
					Logger.error("HTTPServerConfig.onExpectContinue threw: " + Std.string(error), ["method" => __method, "path" => __requestPath]);
				}

				if (!proceed) {
					if (!__responded) {
						__sendErrorResponse(417, "Expectation Failed");
					}
					return true;
				}
			}

			if (__responded || !__origin.connected) {
				return true;
			}
			__origin.writeUTFBytes("HTTP/1.1 100 Continue\r\n\r\n");
			__origin.flush();
		}

		if (!chunked && contentLength == 0) {
			return false;
		}

		__bodyBuf = __requestBody;
		__bodyComplete = onComplete;
		__bodyIsChunked = chunked;
		__chunkBytesRemaining = -1;
		__expectBody = chunked ? 0 : contentLength;
		__awaitingBody = true;

		if (__readRequestBodyFromBuffer()) {
			__finishRequestBody();
		}

		return true;
	}

	@:noCompletion private function __readBodyFromBuffer():Void {
		if (__bodyBuf == null || __expectBody <= 0) {
			__awaitingBody = false;
			return;
		}
		var avail:UInt = __incomingBuffer.length - __incomingBuffer.position;
		var need:UInt = __expectBody - __bodyBuf.length;
		var take:UInt = (avail < need) ? avail : need;
		if (take > 0) {
			__bodyBuf.writeBytes(__incomingBuffer, __incomingBuffer.position, take);
			__incomingBuffer.position += take;
		}
		__awaitingBody = (__bodyBuf.length < __expectBody);
	}

	@:noCompletion private function __readRequestBodyFromBuffer():Bool {
		if (__bodyIsChunked) {
			return __readChunkedBodyFromBuffer();
		}

		__readBodyFromBuffer();
		return !__awaitingBody;
	}

	@:noCompletion private function __readChunkedBodyFromBuffer():Bool {
		while (true) {
			if (__chunkBytesRemaining < 0) {
				var sizeLine:String = __readLine(__incomingBuffer);
				if (sizeLine == null) {
					return false;
				}

				var semi:Int = sizeLine.indexOf(";");
				if (semi >= 0) {
					sizeLine = sizeLine.substr(0, semi);
				}

				// Hex digits only, leading zeros allowed, and nothing past the
				// bound, answered the same on every target. Std.parseInt had four
				// answers past seven digits, -1 on eval and cpp, a throw on the
				// jvm, and on Node a number too large for an Int, which was
				// accepted, so 0xFFFFFFFF went on to expect a four gigabyte
				// chunk, and this counted digits and ran a regular expression
				// per chunk to stay clear of them. The bound is the one that
				// guard enforced, far above any body this server holds.
				var parsed:Int = IntParse.hex(StringTools.trim(sizeLine), MAX_CHUNK_SIZE);
				if (parsed < 0) {
					__sendErrorResponse(400, "Bad Request");
					return false;
				}
				__chunkBytesRemaining = parsed;

				// A chunk that would take the body past its limit is refused on
				// its size line, rather than once it has been buffered whole.
				if (__bodyBuf.length + parsed > __config.maxRequestBodySize) {
					__sendErrorResponse(413, "Payload Too Large");
					return false;
				}

				if (__chunkBytesRemaining == 0) {
					while (true) {
						var trailer:String = __readLine(__incomingBuffer);
						if (trailer == null) {
							return false;
						}
						if (StringTools.trim(trailer).length == 0) {
							return true;
						}
					}
				}
			}

			var available:UInt = __incomingBuffer.length - __incomingBuffer.position;
			if (available < __chunkBytesRemaining + 2) {
				return false;
			}

			__bodyBuf.writeBytes(__incomingBuffer, __incomingBuffer.position, __chunkBytesRemaining);
			__incomingBuffer.position += __chunkBytesRemaining;

			var cr:Int = __incomingBuffer.readByte();
			var lf:Int = __incomingBuffer.readByte();
			if (cr != 13 || lf != 10) {
				__sendErrorResponse(400, "Bad Request");
				return false;
			}

			if (__bodyBuf.length > __config.maxRequestBodySize) {
				__sendErrorResponse(413, "Payload Too Large");
				return false;
			}

			__chunkBytesRemaining = -1;
		}
	}

	/**
	 * Undoes the request's content codings, never past the ceiling the body
	 * is held to on the wire. Answers the request and returns false when that
	 * cannot be done.
	 *
	 * The ceiling is the point. The wire limit counts compressed bytes and
	 * compression ratios have none, so a 32 KB gzip body became 32 MB at the
	 * route; a decoder given a ceiling stops at it and never takes the rest.
	 *
	 * Refused with 413 when the body grows past the ceiling, and with 400
	 * when it is not what its coding says: every codec throws a RangeError
	 * for the one and an IOError for the other. A `deflate` body is read as
	 * zlib, or as raw DEFLATE when it has no zlib header.
	 */
	@:noCompletion private function __decodeRequestBody():Bool {
		if (__requestBody == null || __requestBody.length == 0 || __requestContentEncodings == null || __requestContentEncodings.length == 0) {
			return true;
		}

		try {
			for (i in 0...__requestContentEncodings.length) {
				var algorithm = __requestContentEncodings[__requestContentEncodings.length - 1 - i];
				__requestBody.uncompress(HTTPContentCoding.codecFor(algorithm, __requestBody), __config.maxRequestBodySize);
			}
		} catch (_:crossbyte.errors.RangeError) {
			// Grew past the ceiling: every codec says so with a RangeError.
			__sendErrorResponse(413, "Payload Too Large");
			return false;
		} catch (_:Dynamic) {
			// Not what its coding says it is.
			__sendErrorResponse(400, "Malformed request body");
			return false;
		}

		return true;
	}

	@:noCompletion private function __finishRequestBody():Void {
		if (!__decodeRequestBody()) {
			return;
		}

		var onComplete = __bodyComplete;
		__bodyBuf = null;
		__expectBody = 0;
		__awaitingBody = false;
		__bodyComplete = null;
		__bodyIsChunked = false;
		__chunkBytesRemaining = -1;

		if (onComplete != null) {
			onComplete();
		}
	}

	/**
	 * `^https?://` case-insensitively, without building an EReg.
	 *
	 * A regex literal written inside a function is constructed every time
	 * that function runs, and on cpp constructing one compiles the pattern:
	 * about 126us a call, measured, against a request this server otherwise
	 * answers in roughly 265us. This one ran on every request, so half the
	 * time spent answering was spent rebuilding a seven character pattern.
	 *
	 * Hand-written rather than hoisted to a static, because an EReg carries
	 * the results of its last match and two runtimes share no more than
	 * they must.
	 */
	@:noCompletion private static function __hasAbsoluteScheme(target:String):Bool {
		var length:Int = target.length;

		// "http://" is the shortest this can be, which also makes the four
		// reads below safe without checking each one.
		if (length < 7) {
			return false;
		}

		if (__lowerCode(target.charCodeAt(0)) != "h".code
			|| __lowerCode(target.charCodeAt(1)) != "t".code
			|| __lowerCode(target.charCodeAt(2)) != "t".code
			|| __lowerCode(target.charCodeAt(3)) != "p".code) {
			return false;
		}

		var at:Int = __lowerCode(target.charCodeAt(4)) == "s".code ? 5 : 4;
		if (at + 3 > length) {
			return false;
		}

		return target.charCodeAt(at) == ":".code
			&& target.charCodeAt(at + 1) == "/".code
			&& target.charCodeAt(at + 2) == "/".code;
	}

	@:noCompletion private static inline function __lowerCode(code:Null<Int>):Int {
		var c:Int = code == null ? -1 : code;
		return (c >= "A".code && c <= "Z".code) ? c + 32 : c;
	}

	/**
	 * Reads a `Content-Length` field, or answers `-1` when it is not one.
	 *
	 * Repeated values, folded into a list by the header parser, must agree;
	 * RFC 9112 6.3 lets a recipient accept `5, 5` and requires it to refuse
	 * `5, 6`.
	 *
	 * Through `IntParse` rather than `Std.parseInt`, which is what made this a
	 * smuggling vector. The field was checked to be all digits and then handed
	 * to `Std.parseInt`, which on Linux and macOS native is `strtol` cast to an
	 * `int`: 4294967296 read as 0 and 4294967396 as 100. At 0 the server read
	 * no body and parsed the body as the next request, so a request carried
	 * inside another reached the application unseen by whatever inspected the
	 * outer one, the reason a request with both framings is already refused.
	 * On the jvm the same field threw, and every such request was a 500 and an
	 * ERROR line. A value too large for an `Int` is now simply not a length.
	 */
	@:noCompletion private static function __parseContentLength(header:String):Int {
		if (header == null) {
			return -1;
		}

		var parsed:Int = -1;
		for (raw in header.split(",")) {
			var value:Int = IntParse.decimal(StringTools.trim(raw));
			if (value < 0 || (parsed >= 0 && parsed != value)) {
				return -1;
			}
			parsed = value;
		}

		return parsed;
	}

	@:noCompletion private function __handlePost(filePath:String):Void {
		var file:File = new File(filePath);
		if (!file.exists) {
			__dispatchResponse(404, "Not Found", null, "text/plain", "404 Not Found");
			return;
		}

		if (file.isDirectory) {
			var indexFile:String = __findIndexFile(file);
			if (indexFile != null) {
				__handlePost(indexFile);
			} else {
				__dispatchResponse(404, "Not Found", null, "text/plain", "404 Not Found");
			}
			return;
		}

		if (__php == null || !__isPhp(file.nativePath)) {
			__sendMethodNotAllowed();
			return;
		}

		__servePhp(file.nativePath, false, __requestBody);
	}

	/**
	 * The `Access-Control-Allow-Origin` to answer with, or null for none.
	 *
	 * `*` is answered as `*` and never by echoing the request's `Origin`.
	 * With credentials allowed the echo was a grant to every site of what a
	 * signed-in user can read, the auditor read `/me` from
	 * `https://evil.example`. `validate` refuses that pairing; answering `*`
	 * here keeps it harmless for a configuration changed after the server
	 * started, since a browser will not pair `*` with credentials.
	 */
	@:noCompletion private inline function __computeAllowOrigin():Null<String> {
		if (__config.corsAllowedOrigins.indexOf("*") != -1) {
			return "*";
		}

		var origin:String = __headers.exists("origin") ? __headers.get("origin") : null;
		if (origin != null && __config.corsAllowedOrigins.indexOf(origin) != -1) {
			return origin;
		}
		return null;
	}

	/**
	 * Reads an IMF-fixdate, `Sun, 06 Nov 1994 08:49:37 GMT`, as milliseconds
	 * since 1970, or answers null.
	 *
	 * The format is fixed width, so it is read by position. A regular
	 * expression did this, and a literal one is compiled each time the
	 * function runs, on every conditional request, which is what a browser
	 * revalidating its cache sends for every asset.
	 *
	 * The time is worked out by arithmetic, in UTC as the date is written,
	 * not through a local `Date`: neko keeps a `Date`'s time in 32 bits, so a
	 * validator past January 2038 came back as a date long gone there, and
	 * the revalidation it asked for was answered with the whole file.
	 */
	@:noCompletion private static function __parseHttpDate(s:String):Null<Float> {
		var t:String = StringTools.trim(s);
		if (t.length != 29 || t.charCodeAt(3) != ",".code || t.charCodeAt(4) != " ".code || t.charCodeAt(7) != " ".code || t.charCodeAt(11) != " ".code
			|| t.charCodeAt(16) != " ".code || t.charCodeAt(19) != ":".code || t.charCodeAt(22) != ":".code || t.substr(25) != " GMT") {
			return null;
		}

		var day:Int = IntParse.decimal(t.substr(5, 2));
		var mon = switch (t.substr(8, 3)) {
			case "Jan": 0;
			case "Feb": 1;
			case "Mar": 2;
			case "Apr": 3;
			case "May": 4;
			case "Jun": 5;
			case "Jul": 6;
			case "Aug": 7;
			case "Sep": 8;
			case "Oct": 9;
			case "Nov": 10;
			case "Dec": 11;
			default: -1;
		}

		if (mon < 0) {
			return null;
		}

		var year:Int = IntParse.decimal(t.substr(12, 4));
		var hh:Int = IntParse.decimal(t.substr(17, 2));
		var mm:Int = IntParse.decimal(t.substr(20, 2));
		var ss:Int = IntParse.decimal(t.substr(23, 2));
		// Second 60 is a leap second, which the format allows.
		if (year < 0 || day < 1 || day > 31 || hh < 0 || hh > 23 || mm < 0 || mm > 59 || ss < 0 || ss > 60) {
			return null;
		}

		// Howard Hinnant's days_from_civil, the inverse of the one in
		// __toHttpDate. Floats past the day count: seconds since 1970 leave
		// neko's 31-bit Int in 2004 and everyone's in 2038.
		var month:Int = mon + 1;
		var y:Int = month <= 2 ? year - 1 : year;
		var era:Int = Std.int((y >= 0 ? y : y - 399) / 400);
		var yearOfEra:Int = y - era * 400;
		var dayOfYear:Int = Std.int((153 * (month > 2 ? month - 3 : month + 9) + 2) / 5) + day - 1;
		var dayOfEra:Int = yearOfEra * 365 + Std.int(yearOfEra / 4) - Std.int(yearOfEra / 100) + dayOfYear;
		var days:Float = era * 146097.0 + dayOfEra - 719468;
		return ((days * 24 + hh) * 60 + mm) * 60000.0 + ss * 1000.0;
	}

	@:noCompletion private inline function __sanitizeHeaderValue(v:String):String {
		return HttpSyntax.sanitizeHeaderValue(v);
	}

	@:noCompletion private inline function __sanitizeHeaderName(n:String):String {
		return HttpSyntax.sanitizeHeaderName(n);
	}

	/**
	 * Whether this status forbids a `Content-Length`.
	 *
	 * RFC 7230 3.3.2: a server must not send one on a 1xx or a 204. Such a
	 * response carries no body by definition, and 3.3.3 has the client end it
	 * at the blank line after the headers whatever the headers say, so
	 * omitting it is not merely allowed under keep-alive, it matches the
	 * framing rule the client already applies. 304 is here on the same
	 * reasoning: `Content-Length: 0` there asserts a zero-length
	 * representation rather than describing the one the client already holds.
	 */
	@:noCompletion private inline function __statusOmitsBody(statusCode:Int):Bool {
		return statusCode == 204 || statusCode == 304 || (statusCode >= 100 && statusCode < 200);
	}


	@:noCompletion private inline function __appendHeader(buf:String, name:String, value:String):String {
		var safeName:String = __sanitizeHeaderName(name);
		if (safeName.length == 0) {
			return buf;
		}
		return buf + safeName + ": " + __sanitizeHeaderValue(value) + "\r\n";
	}
}

typedef ResponseEncodingDecision = {
	var encoding:Null<CompressionAlgorithm>;
	var reject:Bool;
}
#end
