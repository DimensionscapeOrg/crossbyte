package crossbyte.http;

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
import crossbyte.net.Socket;
import crossbyte.http.HTTPContentCoding;
import crossbyte.url.URL;
import crossbyte.url.URLRequestHeader;
import crossbyte.utils.CompressionAlgorithm;
import crossbyte.utils.Logger;
import crossbyte._internal.http.headers.AcceptEncoding;
import crossbyte._internal.http.headers.Connection;
import crossbyte._internal.php.PHPBridge;
import crossbyte._internal.php.PHPRequest;
import crossbyte._internal.php.PHPResponse;
import crossbyte._internal.http.Http;
import crossbyte._internal.http.RewriteEngine;

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
	@:noCompletion private static inline var MAX_BUFFER_SIZE:Int = 1024 * 1024; // 1 MB
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
	// True once the current request's framing -- headers AND body -- has
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
	// a stale next() from an already-answered request — even one that
	// fires asynchronously, ticks after its slot was reset — cannot
	// route its dispatch into a later request's state.
	@:noCompletion private var __requestGeneration:Int = 0;
	// When the current request's first byte arrived; the duration metric
	// measures from here, never from connection accept, so request N is
	// not billed for the idle time since request N-1.
	@:noCompletion private var __requestStartedAt:Float;
	// Pushed in by the server's drain(): the in-flight response goes out
	// with Connection: close so shutdown does not sever it mid-work.
	@:noCompletion private var __closeAfterResponse:Bool = false;
	@:noCompletion private var __streamSource:FileStream;
	@:noCompletion private var __streamRemaining:Int = 0;
	@:noCompletion private var __streamSlice:ByteArray;
	@:noCompletion private var __streamLastBuffered:Int = 0;
	@:noCompletion private var __streamStallDeadline:Float = 0;
	@:noCompletion private var __streamPending:Bool = false;

	/**
	 * Largest socket output-buffer size observed while pumping a streamed
	 * response; zero when nothing streamed. Exists for tests: the
	 * bounded-memory guarantee — peak buffering near the watermark no
	 * matter the file size — is otherwise unobservable from outside, and a
	 * regression back to whole-file buffering would pass every
	 * byte-equality assertion while defeating the point.
	 */
	@:noCompletion private var __streamPeakBuffered(default, null):Int = 0;
	/** Uppercased request method, for example `GET` or `POST`. */
	public var method(get, null):String;
	/** Normalized request path without the query string. */
	public var requestPath(get, null):String;
	/** Raw query string without the leading `?`. */
	public var queryString(get, null):String;
	/** Fully buffered request body after supported content decoding. */
	public var requestBody(get, null):ByteArray;
	/** Convenience UTF-8 string view of `requestBody`. */
	public var requestText(get, null):String;

	/**
	 * Creates a request handler for one accepted client socket.
	 *
	 * @param socket Connected client socket supplying request bytes.
	 * @param config Server configuration used for routing and response behavior.
	 * @param php Optional PHP bridge used when routing requests into PHP handlers.
	 */
	public function new(socket:Socket, config:HTTPServerConfig, ?php:PHPBridge) {
		super();
		__origin = socket;
		__config = config;
		__incomingBuffer = new ByteArray();
		__headers = new Map<String, String>();
		__requestBody = new ByteArray();
		__setup();
		__php = php;
		__requestStartedAt = Sys.time();
		__receiveDeadline = config.requestTimeout > 0 ? Sys.time() + config.requestTimeout : 0;
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
		try {
			__origin.readBytes(__incomingBuffer, __incomingBuffer.length);

			// A response body is streaming out. Bytes arriving now are the
			// next request on a kept-alive connection, and they are kept
			// rather than parsed: answering one now would interleave a second
			// response into the body going out. They are picked up when the
			// transfer finishes and the connection settles, through the same
			// surplus path a pipelined request takes after a buffered
			// response.
			if (__streamSource != null) {
				if (__incomingBuffer.length > MAX_BUFFER_SIZE) {
					// No status can be sent to explain this: the status line
					// left with the head and the body is mid-flight. Dropping
					// the connection is the only honest end.
					Logger.error("Request buffer exceeded " + MAX_BUFFER_SIZE + " bytes while a response was streaming; closing.");
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
				__requestStartedAt = Sys.time();
				__receiveDeadline = __config.requestTimeout > 0 ? Sys.time() + __config.requestTimeout : 0;
				// This edge is a request-slot boundary just like a driver
				// iteration, and must clear the previous slot's flag
				// itself: a flood tripping the size check below never
				// reaches __processBuffer, and a still-set __responded
				// would swallow the 413 -- leaving the connection wedged
				// with an over-limit buffer nothing will ever reclaim.
				__responded = false;
			}

			if (__incomingBuffer.length > MAX_BUFFER_SIZE) {
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
	@:noCompletion private function __processBuffer():Void {
		if (__processing) {
			__reprocess = true;
			return;
		}

		__processing = true;
		do {
			__reprocess = false;
			if (__requestConsumed && !__responded) {
				// A fully consumed request is mid-dispatch — an
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
		// status line for this one left with the head — a second one would
		// land inside the body as though it were file content. The stall
		// check closes instead, which is the only signal left.
		//
		// The sweep is the one periodic visit both cases already share, so
		// they ride it together rather than arming a second timer. When
		// keep-alive lands and responses end at a single __finishResponse
		// funnel (keep-alive integration), this dispatch belongs there.
		if (__streamSource != null) {
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

	@:noCompletion private function __parseRequest():Void {
		if (!__hasCompleteHeaderBlock(__incomingBuffer)) {
			return;
		}

		if (__config.rateLimiter != null && __config.rateLimiter.isRateLimited(__origin.remoteAddress)) {
			__sendErrorResponse(429, "Too Many Requests");
			return;
		}

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

		if (!Http.validateHttpVersion(__httpVersion)) {
			__sendErrorResponse(505, "HTTP Version Not Supported");
			return;
		}

		var absoluteTarget:EReg = ~/^https?:\/\//i;
		if (absoluteTarget.match(rawTarget)) {
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

		try {
			pathOnly = __percentDecodePath(pathOnly);
			__requestPath = pathOnly;
		} catch (_:Dynamic) {
			__sendErrorResponse(400, "Bad Request");
			return;
		}

		var resolvedFile:File = __resolveSafePath(__config.rootDirectory, pathOnly);
		if (resolvedFile == null) {
			__sendErrorResponse(403, "Forbidden");
			return;
		}
		__filePath = resolvedFile.nativePath;
		while (true) {
			var headerLine:Null<String> = __readLine(__incomingBuffer);
			if (headerLine == null) {
				return;
			}

			headerLine = StringTools.trim(headerLine);
			if (headerLine.length == 0) {
				break;
			}

			var sep:Int = headerLine.indexOf(":");
			if (sep <= 0) {
				continue;
			}

			var key:String = StringTools.trim(headerLine.substr(0, sep)).toLowerCase();
			var value:String = StringTools.trim(headerLine.substr(sep + 1));

			if (__headers.exists(key)) {
				if (key == "cookie") {
					__headers.set(key, __headers.get(key) + "; " + value);
				} else {
					__headers.set(key, __headers.get(key) + ", " + value);
				}
			} else {
				__headers.set(key, value);
			}
		}

		if (__httpVersion == "HTTP/1.1" && !__headers.exists("host")) {
			__sendErrorResponse(400, "Bad Request");
			return;
		}

		__requestContentEncodings = __parseContentEncodingHeader();
		if (__requestContentEncodings == null) {
			return;
		}

		var continueDispatch = function():Void {
			// The request is fully here; whatever time the response takes
			// is the server's own and must not be billed to the client.
			__receiveDeadline = 0;
			// The one place consumption is recorded, because reaching here
			// is the one guarantee the request's framing -- headers and
			// body both -- has been read out of the buffer. Every response
			// sent earlier (parse errors, the pre-request-line 429, a body
			// cut short) must close, or the leftover bytes would be parsed
			// as the next request -- for the 429, the same request forever.
			__requestConsumed = true;
			var decision:Decision = RewriteEngine.decide(__config, __requestPath, __queryString, __method, __headers);
			if (__config.middleware != null && __config.middleware.length > 0) {
				__runMiddleware(0, function() {
					__continueRequestDispatch(decision);
				});
				return;
			}

			__continueRequestDispatch(decision);
		}

		if (__beginRequestBodyRead(continueDispatch)) {
			return;
		}

		continueDispatch();
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
		// ignored — including the asynchronous case, where the __responded
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
			__dispatchMiddlewareError(error);
		}
	}

	@:noCompletion private function __dispatchMiddlewareError(error:Dynamic):Void {
		var status:Int = 500;
		if (Std.isOfType(error, Int)) {
			status = cast error;
		}
		var statusText:String = __statusMessage(status);
		__sendErrorResponse(status, statusText);
	}

	@:noCompletion private function __continueRequestDispatch(decision:Decision):Void {
		if (decision != null) {
			var targetAbs:File = __config.rootDirectory.resolvePath("." + decision.finalPath);

			switch (__method) {
				case "GET" | "HEAD":
					if (decision.toPHP) {
						__queryString = decision.query;
						__servePhp(targetAbs.nativePath, (__method == "HEAD"), null, decision.finalPath);
					} else if (decision.isStatic) {
						__serveFile(targetAbs.nativePath, (__method == "HEAD"));
					} else {
						__sendMethodNotAllowed();
					}
					return;

				case "POST":
					if (decision.toPHP) {
						__queryString = decision.query;
						__servePhp(targetAbs.nativePath, false, __requestBody, decision.finalPath);
						return;
					} else {
						__handlePost(__filePath);
						return;
					}

			default:
		}
	}

		switch (__method) {
			case "GET":
				__serveFile(__filePath);
			case "HEAD":
				__serveFile(__filePath, true);
			case "OPTIONS":
				if (__config.corsEnabled) {
					__handleOptionsRequest();
				} else {
					__sendMethodNotAllowed();
				}
			case "POST":
				__handlePost(__filePath);

			default:
				__sendMethodNotAllowed();
		}
	}

	// Deliberately still close-per-request: this path writes its response
	// by hand, bypassing both builders, and routing it through one would
	// change its wire output in the same commit that changes connection
	// lifecycle. Keeping preflights alive is a follow-up.
	@:noCompletion private function __handleOptionsRequest():Void {
		var response:String = "HTTP/1.1 204 No Content\r\n";

		response += "Date: " + __formatHttpDate() + "\r\n";
		response += "Server: CrossByte\r\n";
		response += "X-Content-Type-Options: nosniff\r\n";
		response += "Connection: close\r\n";

		var allowOrigin = __computeAllowOrigin();
		if (allowOrigin != null) {
			response += "Access-Control-Allow-Origin: " + allowOrigin + "\r\n";
		}
		if (__config.corsAllowCredentials && allowOrigin != "*") {
			response += "Access-Control-Allow-Credentials: true\r\n";
		}
		response += "Vary: Origin, Access-Control-Request-Method, Access-Control-Request-Headers\r\n";

		var reqMethod:String = __headers.exists("access-control-request-method") ? __headers.get("access-control-request-method") : null;
		response += "Access-Control-Allow-Methods: " + (reqMethod != null ? reqMethod : __config.corsAllowedMethods.join(", ")) + "\r\n";

		var reqHdrs:String = __headers.exists("access-control-request-headers") ? __headers.get("access-control-request-headers") : null;
		response += "Access-Control-Allow-Headers: " + (reqHdrs != null ? reqHdrs : __config.corsAllowedHeaders.join(", ")) + "\r\n";

		if (__config.corsMaxAge > 0) {
			response += "Access-Control-Max-Age: " + __config.corsMaxAge + "\r\n";
		}
		response += "Allow: " + ALLOWED_METHODS.join(", ") + "\r\n";
		response += "Content-Length: 0\r\n\r\n";

		__origin.writeUTFBytes(response);
		__origin.flush();
		__origin.close();
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
			// Keeps the connection: a routine 404 -- a page fetching a
			// missing favicon -- must not cost the client a new handshake.
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
			if (__php != null && __isPhp(file.nativePath)) {
				__servePhp(file.nativePath, headOnly);
				return;
			}
		}

		// file.load();
		var total:Int = file.size; // file.data.length;

		// `File.size` is an Int, so a file past 2 GB has already overflowed
		// by the time it is read here. Refusing the negative case keeps a
		// nonsensical Content-Length off the wire — but it is only half a
		// guard: a size that wraps to a positive value is indistinguishable
		// from a genuine one, and such a file will be served truncated to
		// whatever the wrapped number says. A 64-bit size on `File` is what
		// actually fixes that; this only refuses the detectable half.
		if (total < 0) {
			Logger.error('Refusing to serve ${file.nativePath}: size does not fit in an Int.');
			__sendErrorResponse(500, "Internal Server Error");
			return;
		}

		var lastModifiedTime:Float = file.modificationDate.getTime();
		var lastModHeader:URLRequestHeader = new URLRequestHeader("Last-Modified", __toHttpDate(lastModifiedTime));
		var mimeType:String = __getMimeType(file.nativePath);

		var ims:String = __headers.exists("if-modified-since") ? __headers.get("if-modified-since") : null;
		if (ims != null) {
			try {
				var since:Date = __parseHttpDate(ims);
				if (since != null && Math.floor(lastModifiedTime / 1000) <= Math.floor(since.getTime() / 1000)) {
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
					// discarded is pure cost — the same reason the 200 path
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
			if (headOnly) {
				__dispatchResponseBytes(200, "OK", baseHeaders, mimeType, null, true, total);
			} else {
				if (__canStreamFile(200, baseHeaders, total)) {
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
	 * Whether a file response can bypass whole-file buffering.
	 *
	 * Size decides first, and it decides against compression: a body big
	 * enough to stream is exactly one whose whole-buffer `compress()` would
	 * cost the memory this path exists to bound, so a large file is served
	 * identity even to a client that offered gzip. Trading a compressed
	 * body for a bounded one is the deliberate choice — the alternative is
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
	 * resident memory for as long as the peer takes to drain it — and a
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
	 * sending the request — legal, and what some download tools do — is
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
		__streamRemaining = length;
		__streamSlice = new ByteArray();
		__streamPeakBuffered = 0;
		__streamLastBuffered = 0;
		__streamStallDeadline = Sys.time() + STREAM_STALL_SECONDS;

		// The peer can vanish mid-transfer; without these the pump would
		// keep reading a file for a connection that no longer exists.
		__origin.addEventListener(Event.CLOSE, __onStreamSocketGone);
		__origin.addEventListener(IOErrorEvent.IO_ERROR, __onStreamSocketGone);

		// Resume on the socket's own drain rather than on a tick of our
		// own. Every write queues the socket on the registry's writable
		// queue, which the runtime drains each pass, so this fires whether
		// the flush completed or blocked — the cadence follows the peer
		// instead of the clock, and costs nothing on connections that are
		// not mid-transfer.
		__origin.__onWritableDrain = __pumpStream;

		// First burst goes out now rather than a drain later.
		__pumpStream();
	}

	@:noCompletion private function __onStreamSocketGone(_:Event):Void {
		// Peer closed or errored mid-transfer: stop reading, release the
		// file, and never write again — the response is unfinishable.
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
		if (__streamSource == null) {
			return;
		}

		var watermark:Int = STREAM_WATERMARK;
		var limit:Int = __origin.maxOutputBufferSize;
		if (limit > 0 && limit < watermark) {
			// The overflow policy exists for writers that outrun the peer
			// without bound; this pump is the bounded case, so it must stay
			// under the socket's own limit or the policy would kill a
			// healthy transfer mid-body.
			watermark = limit;
		}

		var entryBuffered:Int = __origin.outputBufferLength;
		if (entryBuffered < __streamLastBuffered) {
			// The peer consumed something since the last visit: real
			// progress, even if this burst turns out to write nothing.
			__streamStallDeadline = Sys.time() + STREAM_STALL_SECONDS;
		}

		var budget:Int = STREAM_BURST;
		var wrote:Bool = false;

		try {
			while (__streamRemaining > 0 && budget > 0) {
				var buffered:Int = __origin.outputBufferLength;
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

				__origin.writeBytes(__streamSlice, 0, take);
				__streamRemaining -= take;
				budget -= take;
				wrote = true;

				var pending:Int = __origin.outputBufferLength;
				if (pending > __streamPeakBuffered) {
					__streamPeakBuffered = pending;
				}
			}

			if (wrote) {
				// One flush per burst. Every writeBytes has already queued
				// the socket, so flushing per slice would only repeat the
				// same syscall against the same buffer.
				__origin.flush();
				__streamStallDeadline = Sys.time() + STREAM_STALL_SECONDS;
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

		__streamLastBuffered = __origin.outputBufferLength;

		if (__streamRemaining == 0 && __streamLastBuffered == 0) {
			// Every byte has left this process, so the response the head
			// promised is complete and the connection can be settled on the
			// decision that head recorded — kept for the next request, or
			// closed. Deferring to here is the whole reason a streamed
			// response can be kept alive at all: the body is well framed by
			// the Content-Length that went out with the head, so the only
			// thing that ever made it unsafe was settling too early.
			__stopStream();
			__settleConnection();
		}
	}

	/**
	 * Closes a transfer that has stopped making progress.
	 *
	 * A peer that stops reading without closing would otherwise hold the
	 * file handle, the connection and its buffered bytes indefinitely: the
	 * pump is drain-driven, and a peer that never drains produces no
	 * drains. Closing is the whole response — no status can be sent,
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
	 * transfer can reach it twice — from the pump that finishes or aborts
	 * it, and again through the socket's CLOSE dispatch — and the second
	 * pass must not touch a stream that is already gone.
	 */
	@:noCompletion private function __stopStream():Void {
		if (__streamSource == null) {
			return;
		}

		var stream:FileStream = __streamSource;
		__streamSource = null;
		__streamSlice = null;
		__streamRemaining = 0;
		__streamStallDeadline = 0;

		// Cleared before the socket is touched: a drain dispatched during
		// teardown would otherwise re-enter the pump with a half-released
		// transfer.
		__origin.__onWritableDrain = null;
		__origin.removeEventListener(Event.CLOSE, __onStreamSocketGone);
		__origin.removeEventListener(IOErrorEvent.IO_ERROR, __onStreamSocketGone);

		try {
			stream.close();
		} catch (_:Dynamic) {}
	}

	@:noCompletion private function __dispatchResponseBytes(statusCode:Int, statusMessage:String, headers:Array<URLRequestHeader>, contentType:String,
			data:ByteArray, headOnly:Bool = false, ?contentLength:Int):Void {
		// A response for this request slot has already been written (a
		// middleware that called respond() and then next() anyway); a
		// second one would corrupt the stream. Suppressed before the log
		// and the status event so it neither logs, counts, nor touches
		// the socket.
		if (__responded) {
			return;
		}

		if (!__origin.connected) {
			return;
		}

		var response:String = "HTTP/1.1 " + statusCode + " " + statusMessage + "\r\n";
		response += "Date: " + __formatHttpDate() + "\r\n";
		__responseKeepAlive = __decideKeepAlive(statusCode);
		response += "Connection: " + (__responseKeepAlive ? Connection.KEEP_ALIVE : Connection.CLOSE) + "\r\n";
		response += "Content-Type: " + contentType + "\r\n";
		response += "X-Content-Type-Options: nosniff\r\n";
		response += "Server: CrossByte\r\n";

		if (headers != null) {
			for (h in headers) {
				response = __appendHeader(response, h.name, h.value);
			}
		}

		var responseData = data;
		if (!headOnly && responseData != null && responseData.length > 0) {
			var responseEncoding = __resolveResponseEncoding(statusCode, headers);
			if (responseEncoding.reject) {
				__sendErrorResponse(406, "Not Acceptable");
				return;
			}
			if (responseEncoding.encoding != null) {
				responseData = new ByteArray();
				responseData.writeBytes(data, 0, data.length);
				try {
					responseData.compress(responseEncoding.encoding);
				} catch (_:Dynamic) {
					__sendErrorResponse(500, "Internal Server Error");
					return;
				}
			}

			if (responseEncoding.encoding != null) {
				var headerValue = __encodingToHeaderValue(responseEncoding.encoding);
				if (headerValue != null) {
					response += "Content-Encoding: " + headerValue + "\r\n";
				}
			}
		}

		if (__config.corsEnabled) {
			var allowOrigin = __computeAllowOrigin();
			if (allowOrigin != null) {
				response += "Access-Control-Allow-Origin: " + allowOrigin + "\r\n";
			}
			if (__config.corsAllowCredentials && allowOrigin != "*") {
				response += "Access-Control-Allow-Credentials: true\r\n";
			}
			response += "Vary: Origin\r\n";
			response += "Access-Control-Expose-Headers: Content-Length, Content-Range, Accept-Ranges, Last-Modified\r\n";
		}

		for (header in __config.customHeaders) {
			response = __appendHeader(response, header.name, header.value);
		}
		var headerLen:Int = (contentLength != null) ? contentLength : (responseData != null ? responseData.length : 0);
		response += "Content-Length: " + headerLen + "\r\n";
		response += "\r\n";

		// Logged and dispatched only once the response is certain to reach
		// the wire: a nested rebuild (a 406 negotiation failure, a
		// compression failure) replaces this response entirely, and an
		// event fired earlier would count and time a response that was
		// never sent — under per-response metrics, twice for one request.
		Logger.info('Client ' + __origin.remoteAddress + ' ' + __method + ' ' + __requestPath + ' - Status: ' + statusCode);
		var statusEvent:HTTPStatusEvent = new HTTPStatusEvent(HTTPStatusEvent.HTTP_RESPONSE_STATUS, statusCode, false);
		statusEvent.responseURL = __origin.remoteAddress;
		statusEvent.responseHeaders = headers;
		dispatchEvent(statusEvent);

		__origin.writeUTFBytes(response);

		if (!headOnly && responseData != null && responseData.length > 0) {
			__origin.writeBytes(responseData, 0, responseData.length);
		}

		__origin.flush();
		__finishResponse();
	}

	@:noCompletion private function __findIndexFile(directory:File):Null<String> {
		for (index in __config.directoryIndex) {
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
	 * Intended for middleware that answers a request itself — a health
	 * check, a metrics endpoint, an authentication failure, a small API
	 * route — rather than letting it fall through to static-file routing.
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

	@:noCompletion private function __dispatchResponse(statusCode:Int, statusMessage:String, headers:Array<URLRequestHeader>, contentType:String,
			content:String, headOnly:Bool = false):Void {
		// Same guard as __dispatchResponseBytes: one response per request
		// slot, suppressed before it can log, count, or touch the socket.
		if (__responded) {
			return;
		}

		if (!__origin.connected) {
			return;
		}

		var bodyBytes:ByteArray = new ByteArray();
		if (!headOnly && content != null && content.length > 0) {
			bodyBytes.writeUTFBytes(content);
		}

		var response:String = "HTTP/1.1 " + statusCode + " " + statusMessage + "\r\n";
		response += "Date: " + __formatHttpDate() + "\r\n";
		__responseKeepAlive = __decideKeepAlive(statusCode);
		response += "Connection: " + (__responseKeepAlive ? Connection.KEEP_ALIVE : Connection.CLOSE) + "\r\n";
		response += "Content-Type: " + contentType + "\r\n";
		response += "X-Content-Type-Options: nosniff\r\n";
		response += "Server: CrossByte\r\n";

		if (headers != null) {
			for (h in headers) {
				response = __appendHeader(response, h.name, h.value);
			}
		}

		var responseData = bodyBytes;
		if (!headOnly && responseData != null && responseData.length > 0) {
			var responseEncoding = __resolveResponseEncoding(statusCode, headers);
			if (responseEncoding.reject) {
				__sendErrorResponse(406, "Not Acceptable");
				return;
			}
			if (responseEncoding.encoding != null) {
				responseData = new ByteArray();
				responseData.writeBytes(bodyBytes, 0, bodyBytes.length);
				try {
					responseData.compress(responseEncoding.encoding);
				} catch (_:Dynamic) {
					__sendErrorResponse(500, "Internal Server Error");
					return;
				}
			}
			if (responseEncoding.encoding != null) {
				var headerValue = __encodingToHeaderValue(responseEncoding.encoding);
				if (headerValue != null) {
					response += "Content-Encoding: " + headerValue + "\r\n";
				}
			}
		}

		if (__config.corsEnabled) {
			var allowOrigin = __computeAllowOrigin();
			if (allowOrigin != null) {
				response += "Access-Control-Allow-Origin: " + allowOrigin + "\r\n";
			}
			if (__config.corsAllowCredentials && allowOrigin != "*") {
				response += "Access-Control-Allow-Credentials: true\r\n";
			}
			response += "Vary: Origin\r\n";
			response += "Access-Control-Expose-Headers: Content-Length, Content-Range, Accept-Ranges, Last-Modified\r\n";
		}

		for (header in __config.customHeaders) {
			response = __appendHeader(response, header.name, header.value);
		}

		response += "Content-Length: " + (responseData != null ? responseData.length : 0) + "\r\n";
		response += "\r\n";

		// Same placement rationale as __dispatchResponseBytes: log and
		// count only what actually reaches the wire.
		Logger.info('Client ' + __origin.remoteAddress + ' ' + __method + ' ' + __requestPath + ' - Status: ' + statusCode);
		var statusEvent:HTTPStatusEvent = new HTTPStatusEvent(HTTPStatusEvent.HTTP_RESPONSE_STATUS, statusCode, false);
		statusEvent.responseURL = __origin.remoteAddress;
		statusEvent.responseHeaders = headers;
		dispatchEvent(statusEvent);

		__origin.writeUTFBytes(response);

		if (!headOnly && responseData != null && responseData.length > 0) {
			__origin.writeBytes(responseData, 0, responseData.length);
		}

		__origin.flush();
		__finishResponse();
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
		if (!__config.keepAlive) {
			return false;
		}

		if (__closeAfterResponse) {
			return false;
		}

		// Nothing sent before the request was fully consumed may keep the
		// connection: unread request bytes are still in the buffer and
		// would be parsed as the next request. This one bit subsumes every
		// early-error close -- 400s, 505, the containment 403, 415, 417,
		// 501, 408, the pre-request-line 429 -- without listing them.
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
		// after consumption they are well-framed, routine answers -- the
		// browser fetching a missing favicon must not pay a handshake for
		// it -- and reached before consumption, the bit above closes.
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
	 * this point long after its head was written — the head decides, the
	 * pump settles — while every buffered response reaches it immediately.
	 */
	@:noCompletion private function __settleConnection():Void {
		if (!__responseKeepAlive) {
			// Surplus pipelined bytes are discarded with the close --
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
		// next pipelined request and must survive the reset -- clearing
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
			__requestStartedAt = Sys.time();
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
			__receiveDeadline = __config.requestTimeout > 0 ? Sys.time() + __config.requestTimeout : 0;
		} else {
			// Between requests. The same deadline field now bounds idle
			// time; zero when idle reaping is disabled.
			__idle = true;
			__receiveDeadline = (__config.keepAlive && __config.keepAliveTimeout > 0) ? Sys.time() + __config.keepAliveTimeout : 0;
		}
	}

	@:noCompletion private inline function __isIdle():Bool {
		return __idle;
	}

	@:noCompletion private function __sendErrorResponse(statusCode:Int, message:String):Void {
		__dispatchResponse(statusCode, message, null, "text/plain", message);
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

		return encodings;
	}

	@:noCompletion private function __resolveResponseEncoding(statusCode:Int, headers:Array<URLRequestHeader>):ResponseEncodingDecision {
		if (statusCode == 206 || __hasResponseHeader(headers, "Content-Range")) {
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
		var supported = [
			{name: HTTPContentCoding.BR, algorithm: CompressionAlgorithm.BROTLI},
			{name: HTTPContentCoding.GZIP, algorithm: CompressionAlgorithm.GZIP},
			{name: HTTPContentCoding.DEFLATE, algorithm: CompressionAlgorithm.DEFLATE},
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
			case CompressionAlgorithm.DEFLATE: HTTPContentCoding.DEFLATE;
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
		// length. addChar keeps the original byte-for-byte semantics — each
		// byte becomes one code point, no UTF-8 decoding — so header values
		// carrying bytes above 0x7F read back exactly as they arrived.
		var line:StringBuf = new StringBuf();
		while (buffer.position < buffer.length) {
			var b:Int = buffer.readByte();
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
	 * the number of arrivals — the shape a slow client produces, whether an
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
	 * another — a blacklist matching `secret.txt` finds no match, then
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

	@:noCompletion private function __resolveSafePath(root:File, targetPath:String):File {
		if (targetPath == null || targetPath == "") {
			targetPath = "/";
		}

		if (targetPath.charAt(0) != "/") {
			targetPath = "/" + targetPath;
		}

		var resolved:File = root.resolvePath("." + targetPath);

		if (!__isWithinRoot(root.nativePath, resolved.nativePath)) {
			return null;
		}
		return resolved;
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
		#if windows
		normalized = normalized.split("/").join("\\").toLowerCase();
		#else
		normalized = normalized.split("\\").join("/");
		#end
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
		#if windows
		if (path.length == 3 && path.charAt(1) == ":") {
			return false;
		}
		#end
		return true;
	}

	@:noCompletion private static inline function __pathSeparator():String {
		#if windows
		return "\\";
		#else
		return "/";
		#end
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
		var second:Float = Math.ffloor(Sys.time());

		if (second == __httpDateSecond) {
			return __httpDateCached;
		}

		var formatted:String = __toHttpDate(second * 1000);
		__httpDateCached = formatted;
		__httpDateSecond = second;

		return formatted;
	}

	@:noCompletion private function __parseRange(h:String, total:UInt):{start:UInt, end:UInt} {
		if (h == null) {
			return null;
		}

		var m:EReg = ~/^bytes=(\d*)-(\d*)$/;
		if (!m.match(StringTools.trim(h))) {
			return null;
		}

		var sStr:String = m.matched(1), eStr = m.matched(2);
		var start:UInt;
		var end:UInt;

		if (sStr == "" && eStr == "") {
			return null;
		}

		if (sStr == "") {
			var n:Null<Int> = Std.parseInt(eStr);
			if (n == null || n <= 0) {
				return null;
			}

			start = (total > n) ? (total - n) : 0;
			end = total - 1;
		} else {
			start = Std.parseInt(sStr);
			end = (eStr == "") ? (total - 1) : Std.parseInt(eStr);
			if (start >= total) {
				return null;
			}

			if (end >= total) {
				end = total - 1;
			}

			if (end < start) {
				return null;
			}
		}
		return {start: start, end: end};
	}

	@:noCompletion private static inline function __toHttpDate(t:Float):String {
		var d:Date = Date.fromTime(t);
		var utc:Float = d.getTime() + d.getTimezoneOffset() * 60000;
		d = Date.fromTime(utc);
		return HTTP_DATE_DAYS[d.getDay()] + ", " + StringTools.lpad(Std.string(d.getDate()), "0", 2) + " " + HTTP_DATE_MONTHS[d.getMonth()] + " "
			+ d.getFullYear() + " " + StringTools.lpad(Std.string(d.getHours()), "0", 2) + ":" + StringTools.lpad(Std.string(d.getMinutes()), "0", 2)
			+ ":" + StringTools.lpad(Std.string(d.getSeconds()), "0", 2) + " GMT";
	}
	@:noCompletion private inline function __isPhp(path:String):Bool {
		var dot:Int = path.lastIndexOf(".");
		return (dot >= 0) && (path.substr(dot + 1).toLowerCase() == "php");
	}

	@:noCompletion private function __servePhp(absPhpPath:String, headOnly:Bool, ?body:ByteArray, ?overrideScriptName:String):Void {
		// final reqUri:String = (__queryString != "" ? (__extractPathOnly() + "?" + __queryString) : __extractPathOnly());

		var hostHeader:String = __headers.exists("host") ? __headers.get("host") : null;
		var sName:String = hostHeader;
		var sPort:String = null;
		if (hostHeader != null) {
			var i:Int = hostHeader.indexOf(":");
			if (i > 0) {
				sName = hostHeader.substr(0, i);
				var p:Null<Int> = Std.parseInt(hostHeader.substr(i + 1));
				if (p != null) {
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
			extraHeaders: __forwardSubset(__headers),
			body: body
		};

		var phpRes:PHPResponse;
		try {
			phpRes = __php.execute(phpReq);
		} catch (e:Dynamic) {
			__dispatchResponse(502, "Bad Gateway", null, "text/plain", "Bad Gateway", true);
			return;
		}

		var ctype:String = phpRes.headers.exists("content-type") ? phpRes.headers.get("content-type") : "text/html; charset=utf-8";

		var out:Array<URLRequestHeader> = [];
		if (phpRes.headers.exists("cache-control")) {
			out.push(new URLRequestHeader("Cache-Control", phpRes.headers.get("cache-control")));
		}
		if (phpRes.headers.exists("location")) {
			out.push(new URLRequestHeader("Location", phpRes.headers.get("location")));
		}
		if (phpRes.headers.exists("set-cookie")) {
			for (cookie in phpRes.headers.get("set-cookie").split("\n")) {
				var c:String = StringTools.trim(cookie);
				if (c != "") {
					out.push(new URLRequestHeader("Set-Cookie", c));
				}
			}
		}

		var bodyBytes:ByteArray = phpRes.body;
		__dispatchResponseBytes(phpRes.status, __statusMessage(phpRes.status), out, ctype, bodyBytes, (__method == "HEAD" || headOnly));
	}

	@:noCompletion private inline function __extractPathOnly():String {
		return __requestPath;
	}

	@:noCompletion private function __forwardSubset(h:Map<String, String>):Map<String, String> {
		var m:Map<String, String> = new Map();
		inline function put(k:String) {
			if (h.exists(k)) {
				final v = h.get(k);
				if (v != null)
					m.set(k, v);
			}
		}
		put("host");
		put("user-agent");
		put("accept");
		put("accept-language");
		put("accept-encoding");
		put("referer");
		put("cookie");
		put("authorization");
		return m;
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
			// "HTTP/1.1 503 OK" on the wire — a status line that contradicts
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
		if (Http.hasConflictingFraming(transferEncoding != null, __headers.exists("content-length"))) {
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

		var contentLength:Null<Int> = null;
		if (!chunked) {
			var contentLengthHeader:String = __headers.exists("content-length") ? __headers.get("content-length") : null;
			contentLength = __parseContentLength(contentLengthHeader);
			if (contentLengthHeader != null && contentLength == null) {
				__sendErrorResponse(400, "Bad Request");
				return true;
			}
		}

		var expect:String = __headers.exists("expect") ? __headers.get("expect") : null;
		if (expect != null) {
			var expectValue:String = StringTools.trim(expect.toLowerCase());
			if (expectValue == "100-continue") {
				__origin.writeUTFBytes("HTTP/1.1 100 Continue\r\n\r\n");
				__origin.flush();
			} else {
				__sendErrorResponse(417, "Expectation Failed");
				return true;
			}
		}

		if (!chunked && (contentLength == null || contentLength == 0)) {
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

				var hex:String = StringTools.trim(sizeLine);
				if (hex.length == 0 || !~/^[0-9a-fA-F]+$/.match(hex)) {
					__sendErrorResponse(400, "Bad Request");
					return false;
				}

				var parsed:Null<Int> = Std.parseInt("0x" + hex);
				if (parsed == null || parsed < 0) {
					__sendErrorResponse(400, "Bad Request");
					return false;
				}
				__chunkBytesRemaining = parsed;

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

			if (__bodyBuf.length > MAX_BUFFER_SIZE) {
				__sendErrorResponse(413, "Payload Too Large");
				return false;
			}

			__chunkBytesRemaining = -1;
		}
	}

	@:noCompletion private function __finishRequestBody():Void {
		if (__requestBody != null && __requestBody.length > 0 && __requestContentEncodings != null && __requestContentEncodings.length > 0) {
			try {
				for (i in 0...__requestContentEncodings.length) {
					var algorithm = __requestContentEncodings[__requestContentEncodings.length - 1 - i];
					__requestBody.uncompress(algorithm);
				}
			} catch (e:Dynamic) {
				__sendErrorResponse(415, "Unsupported Content-Encoding");
				return;
			}
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

	@:noCompletion private function __parseContentLength(header:String):Null<Int> {
		if (header == null) {
			return null;
		}

		var values = header.split(",");
		var parsed:Null<Int> = null;
		for (raw in values) {
			var value = StringTools.trim(raw);
			if (value.length == 0 || !~/^[0-9]+$/.match(value)) {
				return null;
			}

			var n:Null<Int> = Std.parseInt(value);
			if (n == null || n < 0 || n > MAX_BUFFER_SIZE) {
				return null;
			}
			if (parsed != null && parsed != n) {
				return null;
			}
			parsed = n;
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

	@:noCompletion private inline function __computeAllowOrigin():Null<String> {
		var origin:String = __headers.exists("origin") ? __headers.get("origin") : null;
		if (__config.corsAllowedOrigins.indexOf("*") != -1) {
			if (__config.corsAllowCredentials && origin != null) {
				return origin;
			}
			return "*";
		}
		if (origin != null && __config.corsAllowedOrigins.indexOf(origin) != -1) {
			return origin;
		}
		return null;
	}

	@:noCompletion private static function __parseHttpDate(s:String):Date {
		var r = ~/^\w{3}, (\d{2}) (\w{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$/;

		if (!r.match(StringTools.trim(s))) {
			return null;
		}

		var day:Null<Int> = Std.parseInt(r.matched(1));
		var mon = switch (r.matched(2)) {
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

		var year:Null<Int> = Std.parseInt(r.matched(3));
		var hh:Null<Int> = Std.parseInt(r.matched(4));
		var mm:Null<Int> = Std.parseInt(r.matched(5));
		var ss:Null<Int> = Std.parseInt(r.matched(6));
		if (year == null || day == null || hh == null || mm == null || ss == null) {
			return null;
		}

		var localDate:Date = new Date(year, mon, day, hh, mm, ss);
		return Date.fromTime(localDate.getTime() - localDate.getTimezoneOffset() * 60000);
	}

	@:noCompletion private inline function __sanitizeHeaderValue(v:String):String {
		return Http.sanitizeHeaderValue(v);
	}

	@:noCompletion private inline function __sanitizeHeaderName(n:String):String {
		return Http.sanitizeHeaderName(n);
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



