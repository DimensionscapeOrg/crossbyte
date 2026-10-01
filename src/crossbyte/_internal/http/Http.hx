package crossbyte._internal.http;

// Not built for the browser. This drives HTTP over a raw socket with its own TLS; a page issues requests through fetch or XMLHttpRequest, which is a different shape and a separate piece of work.
#if !js

import haxe.exceptions.NotImplementedException;
import crossbyte._internal.http.HttpSyntax;
import crossbyte._internal.http.headers.Connection;
import crossbyte._internal.socket.FlexSocket;
import crossbyte.http.HTTPBackend;
import crossbyte.http.HTTPBackendRegistry;
import crossbyte.http.HTTPCancelToken;
import crossbyte.http.HTTPContentCoding;
import crossbyte.http.HTTPRequestContext;
import crossbyte.http.HTTPVersion;
import crossbyte.io.ByteArray;
import crossbyte.utils.CompressionAlgorithm;
import crossbyte.utils.IntParse;
import crossbyte.url.URL;
import haxe.ds.StringMap;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
#if target.threaded
import sys.thread.Mutex;
#end

/**
 * ...
 * @author Christopher Speciale
 */
class Http {
	public static var MAX_REDIRECTS:Int = 10;

	/**
	 * Maximum number of bytes the chunked response decoder will accumulate before
	 * aborting. Guards against an unbounded `Transfer-Encoding: chunked` response
	 * exhausting memory. Defaults to 64 MB; set to `<= 0` to disable the cap.
	 */
	public static var MAX_CHUNKED_BODY_SIZE:Int = 64 * 1024 * 1024;

	/**
	 * Maximum number of bytes a response body framed by `Content-Length`, or by
	 * the connection closing, may declare or deliver. Defaults to 64 MB; set to
	 * `<= 0` to disable. `MAX_CHUNKED_BODY_SIZE` is the same bound for a
	 * chunked body.
	 *
	 * A declared length is checked before anything is allocated for it. The
	 * body used to be allocated whole from the header, so one response saying
	 * `Content-Length: 2000000000` cost two gigabytes before a byte arrived.
	 */
	public static var MAX_BODY_SIZE:Int = 64 * 1024 * 1024;

	/**
	 * Maximum number of bytes a decoded response body may reach before the
	 * download is abandoned. Defaults to 64 MB; set to `<= 0` to disable.
	 *
	 * MAX_CHUNKED_BODY_SIZE bounds what arrives on the wire, which is not the
	 * same number: compression ratios have no ceiling, and a megabyte of
	 * zeros returns as roughly a gigabyte. A server choosing what to send is
	 * choosing how much memory this client spends, unless something says
	 * otherwise.
	 */
	public static var MAX_DECOMPRESSED_BODY_SIZE:Int = 64 * 1024 * 1024;

	/**
	 * Bytes a response's header section may take -- its status line, its
	 * header lines, and any informational (1xx) responses ahead of it -- and,
	 * separately, the trailers after a chunked body. Defaults to 64 KB, the
	 * limit the server holds a request's header block to; `<= 0` disables it.
	 *
	 * Nothing bounded it. The client read header lines for as long as a
	 * server sent them, a single line for as long as it went without ending,
	 * and 1xx responses for as long as they kept coming, so the server chose
	 * how much memory and time the client spent before a byte of the body.
	 */
	public static var MAX_RESPONSE_HEADER_BYTES:Int = 64 * 1024;

	/**
	 * Bytes one chunk-size line may take, extensions included. A size is
	 * seven hex digits at most here, and no extension anyone sends is long;
	 * one that never ended was read for as long as the server kept it going.
	 */
	private static inline var MAX_CHUNK_LINE:Int = 4096;

	/**
	 * Content codings one response may stack. Defaults to 2.
	 *
	 * They multiply: each pass expands what the one before it produced, so
	 * `gzip, gzip, gzip` is three ratios on top of each other. Real responses
	 * carry one, and two leaves room for a proxy that added its own over what
	 * the origin sent.
	 */
	public static var MAX_CONTENT_CODINGS:Int = 2;

	/**
	 * Returns `true` when adding `incoming` bytes to an already-accumulated
	 * `accumulated` total would exceed `limit`. A `limit <= 0` disables the cap.
	 */
	public static function exceedsChunkedBodyLimit(accumulated:Int, incoming:Int, limit:Int):Bool {
		return HttpSyntax.exceedsChunkedBodyLimit(accumulated, incoming, limit);
	}
	private static inline final CRLF:String = "\r\n";
	private static inline final CRLFCRLF:String = "\r\n\r\n";
	private static inline final HEADER_LOCATION = "location";
	private static inline final HEADER_CONTENT_LENGTH = "content-length";
	private static inline final HEADER_CONTENT_ENCODING = "content-encoding";
	private static inline final HEADER_TRANSFER_ENCODING = "transfer-encoding";
	private static inline final CANCELLED:String = "Request cancelled";

	public var onProgress:(bytesLoaded:Int, bytesTotal:Int) -> Void = (bytesLoaded:Int, bytesTotal:Int) -> {};
	public var onError:(message:String, ?data:Bytes) -> Void = (message:String, ?data:Bytes) -> {};
	public var onComplete:(data:Bytes) -> Void = (data:Bytes) -> {};
	public var onStatus:(status:Int) -> Void = (status:Int) -> {};
	public var onHeaders:(headers:Map<String, String>) -> Void = (headers:Map<String, String>) -> {};

	/**
	 * Abandons this request from another thread.
	 *
	 * `load()` blocks, so cancellation cannot come from the thread running
	 * it. Handing the token out before the request starts is what makes it
	 * reachable at all.
	 */
	public var cancelToken:HTTPCancelToken = new HTTPCancelToken();

	/**
		The most bytes this response may decode to; `<= 0` removes the limit.
		`MAX_DECOMPRESSED_BODY_SIZE` unless the request says otherwise:
		`URLRequest.maxDecompressedSize` sets it, per load.
	**/
	public var maxDecompressedSize:Int = MAX_DECOMPRESSED_BODY_SIZE;

	/**
		The TLS an `https` request asks for, or null for the defaults:
		`URLRequest.verifyCert`, `certAuthority`, `clientCertificate`,
		`clientKey` and `pinnedPublicKeys`, which `URLLoader` gathers here.
	**/
	public var tls:Null<crossbyte.http.HTTPTLSOptions> = null;

	// Set once a redirect has left the origin the request was made to.
	private var __leftOrigin:Bool = false;

	private var __socket:FlexSocket;
	private var __url:URL;
	private var __headers:Array<String>;
	private var __status:Int = 0;
	private var __data:Dynamic;
	private var __requestData:Dynamic;
	private var __timeout:Int;
	private var __connected:Bool = false;
	private var __version:String;
	private var __method:String;
	private var __contentType:String;
	private var __userAgent:String;
	private var __responseHeaders:StringMap<String>;
	private var __followRedirects:Bool;
	private var __cookies:Null<CookieJar>;
	private var __redirect:Bool = false;
	private var __followInsecureRedirects:Bool;

	// Whether this request went out on a kept connection, whether that one
	// turned out to be closed, and whether the response was HTTP/1.1.
	private var __reusedSocket:Bool = false;
	private var __staleRetry:Bool = false;
	private var __responseHttp11:Bool = false;

	// A cancel arrives on another thread, and the only way it reaches a
	// blocking call is through the socket under it. This lock is how the two
	// threads agree on which socket that is: `__adopt` publishes one only if
	// the request is still wanted, and `__abortSocket` marks the request and
	// takes whatever is published, both under it -- so one always sees the
	// other. `__socket` is written only by the loading thread, and only
	// under the lock; that thread reads it freely.
	#if target.threaded
	private final __socketLock:Mutex = new Mutex();
	#end
	private var __aborted:Bool = false;
	// Counts calls to load(), so a cancel handler knows which it was for.
	private var __loads:Int = 0;

	// Whether onComplete or onError has been called: a request has exactly
	// one outcome, however many of its steps fail on the way out.
	private var __settled:Bool = false;

	/**
	 * Whether HTTP/1.1 connections are kept and reused between requests to one
	 * origin. On by default; see HttpConnectionPool.
	 */
	@:noCompletion public static var poolConnections:Bool = true;

	public function new(url:String, method:String = "GET", headers:Array<String> = null, requestData:Dynamic = null, contentType:Null<String> = null,
			data:Dynamic = null, version:HttpVersion = HttpVersion.HTTP_1_1, timeout:Int = 10000, userAgent:String = "CrossByte", followRedirects:Bool = true,
			manageCookies:Bool = true, followInsecureRedirects:Bool = false) {
		__followInsecureRedirects = followInsecureRedirects;
		__url = new URL(url);
		__headers = headers;
		__requestData = requestData;
		__timeout = timeout;
		__method = method;
		__contentType = contentType;
		__data = data;
		__userAgent = userAgent;
		__followRedirects = followRedirects;
		// Null rather than an empty jar when the caller said no, so the send
		// and store sites below read as "if we are keeping cookies".
		__cookies = manageCookies ? new CookieJar() : null;

		if (validateHttpVersion(version) || HTTPBackendRegistry.isRegistered(version)) {
			__version = version;
		} else {
			throw new NotImplementedException(__unsupportedVersionMessage(version));
		}
	}

	/** The URL the response came from: the request's, or the last redirect's. */
	public var url(get, never):String;

	private function get_url():String {
		return Std.string(__url);
	}

	/** Whether a redirect was followed to reach the response. */
	public var redirected(get, never):Bool;

	private inline function get_redirected():Bool {
		return __redirect;
	}

	public function advance():Void {}

	public function loadAsync():Void {
		if (!__usesBuiltInBackend()) {
			__loadWithBackend();
		}
	}

	public function load():Void {
		__redirect = false;

		// A method is a token or it is not one, whichever version carries it.
		// URLRequest.method takes any string, and HTTP/1.1 wrote it first on
		// the request line as given: a "method" holding a line break and a
		// request of its own put that request on the connection.
		if (!HttpSyntax.isToken(__method)) {
			__settled = false;
			__fail("Refused the request: its method is not an HTTP token");
			return;
		}

		if (!__usesBuiltInBackend()) {
			__loadWithBackend();
			return;
		}

		__lockSocket();
		__aborted = false;
		var generation:Int = ++__loads;
		__unlockSocket();
		__settled = false;

		// The only way to interrupt a blocking read is through the socket
		// underneath it. Crude next to an HTTP/2 stream reset, but HTTP/1.1
		// has no in-band way to abandon a response: the connection is the
		// unit, so the connection is what goes. Held in a local so the same
		// closure is removed as was added -- on eval and the jvm each read of
		// a method is a new one -- and tied to this load, so a cancel of an
		// earlier one running late cannot reach it.
		var abort:Void->Void = () -> __abortSocket(generation);
		cancelToken.onCancel(abort);
		try {
			__load();
		} catch (e:Dynamic) {
			cancelToken.removeHandler(abort);
			__close();
			throw e;
		}
		// Over, one way or the other: a cancel from now on has nothing left to
		// stop, and the token must not keep this request reachable.
		cancelToken.removeHandler(abort);
	}

	private function __load():Void {
		__leftOrigin = false;
		if (__isAborted()) {
			// Cancelled before it started: the handler ran as it was added.
			__fail(CANCELLED);
			return;
		}

		var redirects:Array<String> = [__url];
		var origin:String = __originOf(__url);
		var credentialsDropped:Bool = false;

		__tryRequest();

		if (__followRedirects) {
			while (__connected && __isRedirect(__status) && (redirects.length - 1) < MAX_REDIRECTS) {
				if (__responseHeaders.exists(HEADER_LOCATION)) {
					var location:String = __responseHeaders.get(HEADER_LOCATION);

					if (location.length > 0) {
						__redirect = true;

						var url:URL;
						try {
							url = new URL(__resolveLocation(__url, location));
						} catch (_:Dynamic) {
							__close();
							__fail("Could not complete redirect: malformed Location " + location);
							return;
						}

						if (redirects.indexOf(url) > -1) {
							__close();
							__fail("Redirect loop detected");
							return;
						}

						var refusal:Null<String> = __redirectRefusal(__url, url, __followInsecureRedirects);
						if (refusal != null) {
							__close();
							__fail(refusal);
							return;
						}

						// The caller's credentials were written for the origin it
						// asked, and the response naming another is not the caller
						// agreeing to hand them over: a 302 to another host
						// delivered Authorization: Bearer ... to it. Dropped for
						// the rest of the exchange, as browsers, curl and Go drop
						// them, even should a later hop come back. Cookies the jar
						// holds go only to the host that set them already.
						if (!credentialsDropped && __originOf(url) != origin) {
							credentialsDropped = true;
							__headers = __withoutCredentials(__headers);
							// The client certificate too, which was meant for the
							// server the caller named.
							__leftOrigin = true;
						}

						var method:String = __methodAfterRedirect(__status, __method);
						if (method != __method) {
							__method = method;
							__data = null;
							__contentType = null;
							__requestData = null;
						}

						__url = url;
					} else {
						__close();
						__fail("Could not complete redirect");
						return;
					}
				} else {
					__close();
					__fail("Could not complete redirect");
					return;
				}

				redirects.push(__url);
				__close();
				__tryRequest();
			}

			// Only when the budget ran out on a redirect. This tested the count
			// alone, so ten redirects ending in a 200 -- a full budget, spent
			// and done with -- were reported as too many.
			if (__connected && __isRedirect(__status) && (redirects.length - 1) >= MAX_REDIRECTS) {
				__close();
				__fail("Exceeded the number of allowed redirects");
				return;
			}
		}

		__parseResponse();
	}

	// The redirect policy, shared with the HTTP/2 backend so the two versions
	// follow the same redirects the same way.

	@:allow(crossbyte.http.HTTP2Backend)
	private static inline function __isRedirect(status:Int):Bool {
		return status == 301 || status == 302 || status == 303 || status == 307 || status == 308;
	}

	/**
	 * The method a redirect's next hop is made with. A 301, 302 or 303 turns
	 * the request into a GET, without its body, as browsers do -- except a
	 * HEAD, which asked for no body and gets none: it was turned into a GET,
	 * which downloaded the body it had asked not to. A 307 or 308 keeps the
	 * request as it was.
	 */
	@:allow(crossbyte.http.HTTP2Backend)
	private static function __methodAfterRedirect(status:Int, method:String):String {
		return (status == 301 || status == 302 || status == 303) && method != "HEAD" ? "GET" : method;
	}

	/**
	 * `scheme://host:port`, which is what two URLs share when they share an
	 * origin. An IPv6 host is bracketed, as it is written in a URL, so the
	 * port cannot be read as part of it.
	 */
	@:allow(crossbyte.http.HTTP2Backend)
	private static function __originOf(url:URL):String {
		return url.scheme + "://" + HttpSyntax.authority(url.host.toLowerCase(), url.port, -1);
	}

	/**
	 * Why a redirect from `from` to `to` may not be followed, or null when it
	 * may: only to `http` or `https`, and from `https` to `http` only when
	 * the caller said so.
	 */
	@:allow(crossbyte.http.HTTP2Backend)
	private static function __redirectRefusal(from:URL, to:URL, followInsecure:Bool):Null<String> {
		if (to.scheme != "http" && to.scheme != "https") {
			return "Refused a redirect to " + to.scheme + ": only http and https are followed";
		}

		if (from.ssl && !to.ssl && !followInsecure) {
			return "Refused a redirect from https to http; set URLRequest.followInsecureRedirects to allow it";
		}

		return null;
	}

	/** The caller's header lines, less those that carry credentials. */
	@:allow(crossbyte.http.HTTP2Backend)
	private static function __withoutCredentials(headers:Array<String>):Array<String> {
		if (headers == null) {
			return null;
		}

		var kept:Array<String> = [];
		for (header in headers) {
			var colon:Int = header.indexOf(":");
			var name:String = StringTools.trim(colon < 0 ? header : header.substr(0, colon)).toLowerCase();
			if (name != "authorization" && name != "proxy-authorization" && name != "cookie") {
				kept.push(header);
			}
		}
		return kept;
	}

	/**
	 * Marks the request cancelled and ends whatever blocking call its socket
	 * has the loading thread in.
	 *
	 * Called from whichever thread cancelled, which is not the thread inside
	 * `load()`. That call then fails and unwinds through the ordinary error
	 * path, which is the point: there is nothing else to poll. A socket not
	 * yet published is left to `__adopt`, which finds the mark and closes it.
	 */
	private function __abortSocket(generation:Int):Void {
		__lockSocket();
		if (generation != __loads) {
			// For a load that has finished; this one is not being cancelled.
			__unlockSocket();
			return;
		}
		__aborted = true;
		var socket:Null<FlexSocket> = __socket;
		if (socket != null) {
			// Under the lock, so the loading thread cannot close the socket
			// between this taking it and interrupting it.
			__interrupt(socket);
		}
		__unlockSocket();
	}

	/**
	 * Ends a blocking read or write on `socket` from another thread, without
	 * releasing anything that thread is using.
	 *
	 * Shut down, not closed. Closing from here was the old way, and it went
	 * wrong in three ways. On Linux, native or eval, a close does not wake a
	 * `recv` already waiting on the socket, and the peer is not told until that
	 * read gives up: a cancelled load held its thread and its server for the
	 * whole idle timeout. On eval the close failed the waiting read with a
	 * native error no Haxe catch sees, which killed the thread -- and the
	 * reset it caused killed the reader on the peer's side too. And a TLS
	 * socket's close frees its mbedTLS context while the loading thread may be
	 * inside a read on it. A shutdown wakes the read everywhere with the end of
	 * the stream, and tells the peer at once, and the loading thread closes
	 * the socket itself on its way out.
	 *
	 * Windows differs twice. A shutdown there does not wake a `recv` already
	 * waiting on the same socket -- only the peer answering the shutdown's
	 * FIN does -- where a close does; so natively a plain socket is closed as
	 * well, and a TLS one, for the reason above, is left to the peer. And a
	 * `recv` begun after the reading side is shut down fails there with
	 * WSAESHUTDOWN, which eval raises as a native error no catch sees, just
	 * as it did the close; so on eval under Windows only the writing side is
	 * shut down, and the read ends when the peer closes in answer.
	 */
	@:allow(crossbyte.http.HTTP2Backend)
	@:allow(crossbyte._internal.http.h2.H2ClientSession)
	private static function __interrupt(socket:FlexSocket):Void {
		try {
			socket.shutdown(__shutDownReads, true);
		} catch (_:Dynamic) {
			// Not connected yet, or already closed: the connect or the next
			// read then fails on its own, and the mark is checked after it.
		}
		#if cpp
		if (__onWindows && !socket.isSecure) {
			try {
				socket.close();
			} catch (_:Dynamic) {}
		}
		#end
	}

	#if (cpp || eval)
	private static final __onWindows:Bool = Sys.systemName() == "Windows";
	#end
	private static final __shutDownReads:Bool = #if eval !__onWindows #else true #end;

	/**
	 * Makes `socket` the request's, where a cancel can reach it -- unless the
	 * request has been cancelled already, in which case `socket` is closed
	 * and this answers false.
	 */
	private function __adopt(socket:FlexSocket):Bool {
		__lockSocket();
		var aborted:Bool = __aborted;
		if (!aborted) {
			__socket = socket;
		}
		__unlockSocket();

		if (aborted) {
			__closeQuietly(socket);
		}
		return !aborted;
	}

	/** Takes the request's socket back out of a cancel's reach; null when it has none. */
	private function __detach():Null<FlexSocket> {
		__lockSocket();
		var socket:Null<FlexSocket> = __socket;
		__socket = null;
		__unlockSocket();
		return socket;
	}

	/** Whether the request has been cancelled. */
	private function __isAborted():Bool {
		__lockSocket();
		var aborted:Bool = __aborted;
		__unlockSocket();
		return aborted;
	}

	private inline function __lockSocket():Void {
		#if target.threaded
		__socketLock.acquire();
		#end
	}

	private inline function __unlockSocket():Void {
		#if target.threaded
		__socketLock.release();
		#end
	}

	/**
	 * Ends the request with `message`, unless it has already ended. A request
	 * that was cancelled says so, whatever step then failed under it: the
	 * read the cancel ended reports the end of the stream, and it is the
	 * cancel, not the server, that ended it.
	 */
	private function __fail(message:String, ?data:Bytes):Void {
		if (__settled) {
			return;
		}
		__settled = true;
		onError(__isAborted() ? CANCELLED : message, data);
	}

	private function __complete(data:Bytes):Void {
		if (__settled) {
			return;
		}
		__settled = true;
		onComplete(data);
	}

	private static function __closeQuietly(socket:FlexSocket):Void {
		try {
			socket.close();
		} catch (_:Dynamic) {}
	}

	public static inline function validateHttpVersion(version:HttpVersion):Bool {
		return HttpSyntax.validateHttpVersion(version);
	}

	/**
	 * Strips CR, LF and control characters from a header value so it cannot be
	 * used to inject additional headers or split the response (CRLF injection).
	 */
	public static inline function sanitizeHeaderValue(v:String):String {
		return HttpSyntax.sanitizeHeaderValue(v);
	}

	/**
	 * Sanitizes a header field name: strips CR/LF/control characters, whitespace
	 * and any embedded colon so a value cannot smuggle a new header name. Returns
	 * an empty string when nothing valid remains (caller should then skip it).
	 */
	public static inline function sanitizeHeaderName(n:String):String {
		return HttpSyntax.sanitizeHeaderName(n);
	}

	/**
	 * Detects request smuggling vectors that must be rejected with `400` per
	 * RFC 7230 §3.3.3: a request that carries both `Transfer-Encoding` and
	 * `Content-Length` is ambiguous and must not be processed.
	 */
	public static inline function hasConflictingFraming(hasTransferEncoding:Bool, hasContentLength:Bool):Bool {
		return HttpSyntax.hasConflictingFraming(hasTransferEncoding, hasContentLength);
	}

	private static function __unsupportedVersionMessage(version:HTTPVersion):String {
		// Names the call rather than the concept. The previous wording said an
		// HTTPBackend was needed without saying that one ships in this
		// library, which read as "unsupported" when it meant "one line away".
		return version
			+ " has no registered HTTPBackend. HTTP/2 ships with CrossByte and registers itself on demand; "
			+ "if that was disabled, call HTTPBackendRegistry.register(new HTTP2Backend()).";
	}

	private function __usesBuiltInBackend():Bool {
		return validateHttpVersion(cast __version);
	}

	private function __loadWithBackend():Void {
		var version:HTTPVersion = cast __version;
		var backend:HTTPBackend = HTTPBackendRegistry.resolve(version);
		if (backend == null) {
			onError(__unsupportedVersionMessage(version));
			return;
		}

		try {
			backend.load(__createRequestContext(version));
		} catch (e:Dynamic) {
			onError("HTTP backend failed: " + Std.string(e));
		}
	}

	private function __createRequestContext(version:HTTPVersion):HTTPRequestContext {
		return {
			url: Std.string(__url),
			method: __method,
			headers: __headers != null ? __headers.copy() : [],
			requestData: __requestData,
			contentType: __contentType,
			data: __data,
			version: version,
			timeout: __timeout,
			userAgent: __userAgent,
			followRedirects: __followRedirects,
			followInsecureRedirects: __followInsecureRedirects,
			manageCookies: __cookies != null,
			// So `url` and `redirected` say where the response came from, as
			// they do for a response this client fetched itself.
			onRedirect: location -> {
				__url = new URL(location);
				__redirect = true;
			},
			maxDecompressedSize: maxDecompressedSize,
			tls: tls,
			onProgress: onProgress,
			onError: onError,
			onComplete: onComplete,
			onStatus: onStatus,
			onHeaders: onHeaders,
			cancelToken: cancelToken
		};
	}

	private function __parseResponse():Void {
		if (!__connected) {
			__close();
			// Whatever lost the connection has said so already; this is only
			// here so that nothing can end without an outcome.
			__fail("Connection lost");
			return;
		}

		var transferEncodingHeader:String = __responseHeaders.get(HEADER_TRANSFER_ENCODING);
		var isChunked:Bool = false;
		if (transferEncodingHeader != null) {
			var encodings:Array<String> = transferEncodingHeader.toLowerCase().split(",");
			// Only when chunked is the *final* coding, which is the test the
			// server half already makes. RFC 9112 6.1: anything applied after
			// it means the body is not framed by chunks, so reading it as
			// though it were takes the next coding's bytes for chunk headers.
			// A body that is not chunk-framed falls through to reading until
			// the connection closes, which is what 6.1 prescribes.
			isChunked = encodings.length > 0 && StringTools.trim(encodings[encodings.length - 1]) == "chunked";
		}

		var contentLengthHeader:String = __responseHeaders.get(HEADER_CONTENT_LENGTH);
		var contentLength:Null<Int> = isChunked ? null : __parseContentLength(contentLengthHeader);
		if (!isChunked && contentLengthHeader != null && contentLength == null) {
			__close();
			__fail("Download failed: invalid Content-Length");
			return;
		}

		var bytesTotalForProgress:Int = (!isChunked && contentLength != null) ? contentLength : -1;

		var isNoContentStatus:Bool = (__status == 204 || __status == 304);

		var isHttpError:Bool = (__status >= 400);
		var isHead:Bool = (__method == "HEAD");
		var mode:String = "undefined";

		if (isHead) {
			mode = "nocontent";
		} else if (isNoContentStatus) {
			mode = "nocontent";
		} else if (isChunked) {
			mode = "chunked";
		} else if (contentLength != null && contentLength >= 0) {
			mode = "fixed";
		} else {
			mode = "unknown";
		}

		var bytesLoaded:UInt = 0;
		var data:Bytes = null;

		onProgress(bytesLoaded, bytesTotalForProgress);

		try {
			switch (mode) {
				case "nocontent":
					data = Bytes.alloc(0);

				case "fixed":
					var total:Int = contentLength;
					if (MAX_BODY_SIZE > 0 && total > MAX_BODY_SIZE) {
						throw "Response declared " + total + " bytes, more than the " + MAX_BODY_SIZE + " allowed";
					}
					data = Bytes.alloc(total);
					var offset:Int = 0;

					while (offset < total) {
						var n:Int = __socket.input.readBytes(data, offset, total - offset);
						if (n <= 0) {
							break;
						}

						offset += n;
						bytesLoaded = offset;
						onProgress(bytesLoaded, bytesTotalForProgress);
					}

					if (offset != total) {
						__close();
						__fail("Download failed: expected " + total + " bytes, got " + offset);
						return;
					}

				case "chunked":
					var buffer:BytesBuffer = new BytesBuffer();
					while (true) {
						var sizeLine:String = __readLine(MAX_CHUNK_LINE);
						if (sizeLine == null) {
							throw "Unexpected EOF while reading chunk size";
						}

						var semi:Int = sizeLine.indexOf(";");
						if (semi >= 0) {
							sizeLine = sizeLine.substr(0, semi);
						}

						var hexStr:String = StringTools.trim(sizeLine);

						// Hex digits only, and no more than seven significant
						// ones, the same on every target. Std.parseInt stopped at
						// the first character it could not use, so "10junk" read
						// as 16, and past seven digits it answered differently on
						// each target -- on Node with a number too large for an
						// Int, which walked past every check. 0xFFFFFFF is already
						// far beyond MAX_CHUNKED_BODY_SIZE.
						var chunkSize:Int = IntParse.hex(hexStr, 0xFFFFFFF);
						if (chunkSize < 0) {
							throw "Invalid chunk size: " + hexStr;
						}

						if (chunkSize == 0) {
							// Trailers are a header section of their own, held to
							// the same limit; they were read for as long as the
							// server sent them.
							var budget:Int = MAX_RESPONSE_HEADER_BYTES > 0 ? MAX_RESPONSE_HEADER_BYTES : 0x7FFFFFFF;
							var trailer:String = "";
							do {
								trailer = __readLine(budget);
								if (trailer == null) {
									throw "Unexpected EOF while reading trailers";
								}
								budget -= __lineBytes + 1;
								if (budget < 0) {
									throw new LineTooLong(MAX_RESPONSE_HEADER_BYTES);
								}

								trailer = StringTools.trim(trailer);
							} while (trailer.length > 0);
							break;
						}

						if (exceedsChunkedBodyLimit(buffer.length, chunkSize, MAX_CHUNKED_BODY_SIZE)) {
							throw "Chunked response exceeded maximum size of " + MAX_CHUNKED_BODY_SIZE + " bytes";
						}

						var chunk:Bytes = __socket.input.read(chunkSize);
						if (chunk == null || chunk.length != chunkSize)
							throw "Truncated chunk";
						buffer.add(chunk);

						bytesLoaded += chunkSize;
						onProgress(bytesLoaded, bytesTotalForProgress);

						var lineEnd:Bytes = __socket.input.read(2);
						if (lineEnd == null || lineEnd.length != 2 || lineEnd.get(0) != 13 || lineEnd.get(1) != 10) {
							throw "Invalid chunk terminator";
						}
					}
					data = buffer.getBytes();

				case "unknown":
					var buffer:BytesBuffer = new BytesBuffer();
					var b:Bytes = Bytes.alloc(64 * 1024);
					while (true) {
						var n:Int;
						try {
							n = __socket.input.readBytes(b, 0, b.length);
						} catch (_:haxe.io.Eof) {
							// The connection closing is how this body ends.
							n = 0;
						} catch (e:Dynamic) {
							// Anything else is the body being cut off: a reset, a
							// timeout. Every error was read as the end and the
							// response reported complete with part of its body.
							throw "Connection lost before the body ended: " + Std.string(e);
						}
						if (n <= 0)
							break;
						if (MAX_BODY_SIZE > 0 && buffer.length + n > MAX_BODY_SIZE) {
							throw "Response body exceeded " + MAX_BODY_SIZE + " bytes";
						}
						buffer.addBytes(b, 0, n);
						bytesLoaded += n;
						onProgress(bytesLoaded, bytesTotalForProgress);
					}
					// A cancel ends the stream the same way the server closing
					// does, which here is how the body ends: without this, a
					// body cut short by a cancel was delivered as complete.
					if (__isAborted()) {
						throw CANCELLED;
					}
					data = buffer.getBytes();

				default:
					__close();
					__fail("Download failed: unsupported response mode");
					return;
			}
		} catch (e:Dynamic) {
			__close();
			// `e` was bound and then dropped, so every way a body can fail --
			// a chunk size that is not one, a truncated chunk, a missing
			// terminator, an early EOF -- reached the caller as the same four
			// words. The three messages above this one all name the thing that
			// went wrong.
			__fail("Download failed: " + Std.string(e));
			return;
		}

		if (data != null) {
			try {
				data = __decodeResponseBody(data);
			} catch (error:Dynamic) {
				__close();
				// Two different things reach here. A coding this build cannot
				// decode is thrown as the token itself, a String; a body that
				// decoded past its ceiling, or stacked more codings than are
				// allowed, arrives as an exception. Reporting the second as an
				// unsupported coding sent the caller looking in the wrong place.
				if (Std.isOfType(error, String)) {
					__fail('Unsupported content encoding: ${error}', data);
				} else {
					__fail('Failed to decode response body: ' + Std.string(error), data);
				}
				return;
			}
		}

		// Read to its framed end, so the connection can serve another request;
		// a body that ended with the connection has none left to give.
		var framed:Bool = mode != "unknown";

		if (isHttpError) {
			var status:Int = __status;
			__release(framed);
			__fail('HTTP error ' + status, data);
			return;
		}

		// Released before the callback: what it does next -- another request
		// to the same origin, say -- can then have the connection.
		__release(framed);

		if (data != null) {
			__complete(data);
		}
	}

	@:noCompletion private function __decodeResponseBody(data:Bytes):Bytes {
		return decodeResponseBody(data, __responseHeaders.exists(HEADER_CONTENT_ENCODING) ? __responseHeaders.get(HEADER_CONTENT_ENCODING) : null,
			maxDecompressedSize);
	}

	/**
	 * Undoes a response's content codings, within `MAX_CONTENT_CODINGS` and
	 * `limit` -- `MAX_DECOMPRESSED_BODY_SIZE` unless given. Throws the
	 * coding's name, a `String`, for one this build cannot decode, and an
	 * exception for a body past the limits. Shared with the HTTP/2 backend,
	 * which did not decode at all.
	 */
	@:noCompletion public static function decodeResponseBody(data:Bytes, header:Null<String>, ?limit:Int):Bytes {
		if (limit == null) {
			limit = MAX_DECOMPRESSED_BODY_SIZE;
		}
		if (data == null || data.length == 0) {
			return data;
		}

		if (header == null || StringTools.trim(header) == "") {
			return data;
		}

		var encodings:Array<CompressionAlgorithm> = [];
		for (raw in header.split(",")) {
			var token = StringTools.trim(raw);
			if (token == "") {
				continue;
			}

			var semi:Int = token.indexOf(";");
			if (semi >= 0) {
				token = StringTools.trim(token.substr(0, semi));
			}

			var coding = HTTPContentCoding.fromString(token);
			switch (coding) {
			case HTTPContentCoding.IDENTITY:
				continue;
			case null:
				throw token.toLowerCase();
				default:
					var algorithm = coding.toCompressionAlgorithm();
					if (algorithm == null) {
						throw token.toLowerCase();
					}
					encodings.push(algorithm);
			}
		}

		if (encodings.length == 0) {
			return data;
		}

		if (MAX_CONTENT_CODINGS > 0 && encodings.length > MAX_CONTENT_CODINGS) {
			throw new haxe.Exception("Response stacked " + encodings.length + " content codings, more than the " + MAX_CONTENT_CODINGS + " allowed");
		}

		var payload:ByteArray = data;
		for (i in 0...encodings.length) {
			payload.uncompress(crossbyte.http.HTTPContentCoding.codecFor(encodings[encodings.length - 1 - i], payload), limit > 0 ? limit : 0);
		}

		return payload;
	}

	private function __tryRequest():Void {
		__status = 0;
		__responseHeaders = new StringMap();
		__responseHttp11 = false;
		__staleRetry = false;
		__reusedSocket = false;

		// A kept connection, for a request that may be sent twice: one the
		// server closed while it sat idle is only found out by using it, and
		// then the request goes again on a new connection. A POST is never
		// sent on one, since whether the server acted on it cannot be known.
		var kept:Null<FlexSocket> = null;
		#if (sys && !eval)
		if (__pooling() && __repeatable()) {
			// Only a connection opened under the same TLS: one that did not
			// check its server must not carry a request that does.
			kept = HttpConnectionPool.take(__originOf(__url), __poolTls());
		}
		#end

		if (kept != null) {
			// Every socket this request uses is published through __adopt, so
			// a cancel landing anywhere before it -- here, between redirect
			// hops, while the pool is searched -- is found rather than lost.
			// It used to be lost: the cancel found no socket to close, the
			// request went out regardless, and its thread waited out the
			// whole idle timeout for an answer nobody wanted.
			if (!__adopt(kept)) {
				__fail(CANCELLED);
				return;
			}
			__connected = true;
			__reusedSocket = true;
			try {
				kept.setTimeout(__idleSeconds(__timeout));
			} catch (_:Dynamic) {
				// Closed under this thread, which only a cancel does.
				__close();
				__fail("Connection lost");
				return;
			}
			__handleRequest();
			if (!__staleRetry) {
				__handleResponse();
			}
			if (!__staleRetry) {
				return;
			}
			__staleRetry = false;
			__reusedSocket = false;
			__status = 0;
			__responseHeaders = new StringMap();
		}

		var hopTls:Null<crossbyte.http.HTTPTLSOptions> = __poolTls();
		try {
			var socket:FlexSocket = new FlexSocket(__url.ssl);
			if (!__adopt(socket)) {
				__fail(CANCELLED);
				return;
			}
			// Seconds, where `timeout` is milliseconds: it was passed as it came,
			// so a 30 second idle timeout waited 30,000 seconds. The same
			// conversion as the HTTP/2 backend's; see __idleSeconds.
			socket.setTimeout(__idleSeconds(__timeout));
			if (hopTls != null) {
				hopTls.configure(socket);
			}
			socket.connect(__url.host, __url.port);
			__connected = true;
		} catch (e:Dynamic) {
			__close();
			// With the reason. Every failure read "Connection Failed" alone --
			// an untrusted, expired or misnamed certificate, a refused port --
			// where the WebSocket client beside this one said which. A timeout
			// is said as one: natively it would read "Blocked".
			__fail("Connection Failed: "
				+ (__isTimeout(e) ? '${__url.host}:${__url.port} did not answer' + (__timeout > 0 ? ' within ${__idleSeconds(__timeout)} s' : '') : __describe(e)));
			return;
		}

		// A cancel while the connection was being made found nothing it could
		// shut down -- a socket not yet connected has no stream to end -- so
		// it is looked for again now there is one. From here on, a cancel
		// reaches the socket itself.
		if (__isAborted()) {
			__close();
			__fail(CANCELLED);
			return;
		}

		// After the handshake and before a byte of the request.
		if (hopTls != null) {
			var refusal:Null<String> = hopTls.checkPins(__socket);
			if (refusal != null) {
				__close();
				__fail(refusal);
				return;
			}
		}

		__handleRequest();
		__handleResponse();
	}

	/**
		The socket timeout, in seconds, for an idle timeout of `milliseconds`:
		`0`, which a socket takes as none, for `0` or less. It was 30 seconds
		here and none on JavaScript, so one setting meant two things; it is
		none everywhere now, as `0` is on every socket and WebSocket.
	**/
	@:allow(crossbyte.http.HTTP2Backend)
	private static inline function __idleSeconds(milliseconds:Int):Float {
		return milliseconds > 0 ? milliseconds / 1000 : 0;
	}

	/**
		The TLS this hop is made under, for an `https` URL, or null for a
		plain one or the defaults: the request's, less its client certificate
		once a redirect has left the origin it was made to.
	**/
	private function __poolTls():Null<crossbyte.http.HTTPTLSOptions> {
		if (tls == null || !__url.ssl || tls.isDefault()) {
			return null;
		}
		return __leftOrigin ? tls.withoutClientCertificate() : tls;
	}

	/**
		Whether `error`, out of a connect, is the socket's timeout running
		out: `Blocked` natively, the read the TLS handshake was waiting on
		having timed out, and on the jvm a `Custom` naming the timeout, its
		handshake holding to the deadline and saying so. Neither says what
		happened to a caller as it stands.
	**/
	@:allow(crossbyte.http.HTTP2Backend)
	private static function __isTimeout(error:Dynamic):Bool {
		if (!Std.isOfType(error, haxe.io.Error)) {
			return false;
		}
		return switch ((error : haxe.io.Error)) {
			case Blocked: true;
			case Custom(detail): StringTools.startsWith(Std.string(detail), "Timeout");
			default: false;
		}
	}

	/**
		What an error says, for a message: a haxe.Exception's text, what a
		`haxe.io.Error.Custom` carries rather than the wrapper around it, or
		the value.
	**/
	private static function __describe(error:Dynamic):String {
		if (Std.isOfType(error, haxe.Exception)) {
			return (error : haxe.Exception).message;
		}
		if (Std.isOfType(error, haxe.io.Error)) {
			switch ((error : haxe.io.Error)) {
				case Custom(detail):
					return Std.string(detail);
				default:
			}
		}
		return Std.string(error);
	}

	/** Whether connections are kept for reuse: everywhere with threads but eval. */
	private static inline function __pooling():Bool {
		#if (sys && !eval)
		return poolConnections;
		#else
		return false;
		#end
	}

	/** A request that may be sent again if a kept connection fails under it. */
	private inline function __repeatable():Bool {
		return __method == "GET" || __method == "HEAD" || __method == "OPTIONS" || __method == "PUT" || __method == "DELETE";
	}

	/**
	 * Ends this request's use of its connection: back to the pool when the
	 * response was read to its framed end and neither side asked to close,
	 * closed otherwise.
	 */
	private function __release(framed:Bool):Void {
		#if (sys && !eval)
		var connection:Null<String> = __responseHeaders.get("connection");
		var closing:Bool = connection != null && connection.toLowerCase().indexOf("close") >= 0;
		if (framed && __pooling() && __responseHttp11 && !closing && __socket != null && __version == HttpVersion.HTTP_1_1) {
			// Out of a cancel's reach first: a cancel shutting down a
			// connection already back in the pool would hand the next request
			// to this origin a dead one.
			var socket:Null<FlexSocket> = __detach();
			__connected = false;
			if (socket != null) {
				if (__isAborted()) {
					// Cancelled before it was taken back, so it may have been
					// shut down under the response: not one to keep.
					__closeQuietly(socket);
				} else {
					HttpConnectionPool.put(__originOf(__url), socket, __poolTls());
				}
			}
			return;
		}
		#end
		__close();
	}

	private function __handleResponse():Void {
		if (!__connected) {
			return;
		}

		var line:String = '';
		var first:Bool = true;
		// What the section may still take. Interim responses count against it
		// too: a server sending 1xx after 1xx held the client in this loop for
		// as long as it liked, and the socket's idle timeout never fired,
		// since the bytes kept coming.
		var budget:Int = MAX_RESPONSE_HEADER_BYTES > 0 ? MAX_RESPONSE_HEADER_BYTES : 0x7FFFFFFF;
		// Repeats of one field, joined once the block ends. Appending each to
		// the whole value so far was quadratic in the repeats, and the server
		// chooses how many there are.
		var repeats:Null<StringMap<Array<String>>> = null;
		while (true) {
			try {
				line = __readLine(budget);
				budget -= __lineBytes + 1;
				if (budget < 0) {
					throw new LineTooLong(MAX_RESPONSE_HEADER_BYTES);
				}
			} catch (e:Dynamic) {
				if (Std.isOfType(e, LineTooLong)) {
					__close();
					__fail("Response header section exceeded " + MAX_RESPONSE_HEADER_BYTES + " bytes");
					return;
				}
				if (first && __reusedSocket) {
					// A kept connection the server had already closed. Nothing
					// of a response arrived, so the request goes again on a new
					// one; see __tryRequest.
					__close();
					__staleRetry = true;
					return;
				}
				__close();
				if (Std.isOfType(e, haxe.io.Eof)) {
					__fail(__status == 0 ? "Connection closed without a response" : "Connection closed while reading headers");
				} else {
					__fail("Failed to read response");
				}
				return;
			}
			first = false;

			if (line == null) {
				__close();
				__fail("Connection closed while reading headers");
				return;
			}

			line = StringTools.trim(line);
			#if http_debug
			// Still behind the compile flag, so it costs nothing by default,
			// but routed through Logger so that when it is enabled the
			// output honours the configured level and sink rather than
			// going straight to stdout.
			crossbyte.utils.Logger.trace(line);
			#end

			if (line == '') {
				if (__status >= 100 && __status < 200) {
					__status = 0;
					__responseHeaders = new StringMap();
					repeats = null;
					continue;
				}
				break;
			}

			if (__status == 0) {
				var code:Int = __parseStatusLine(line);
				if (code < 0) {
					__close();
					__fail('Malformed status line: ' + line);
					return;
				}
				__status = code;
				// Only an HTTP/1.1 response keeps its connection by default.
				__responseHttp11 = StringTools.startsWith(line, "HTTP/1.1");
				onStatus(__status);
			} else {
				var i:Int = line.indexOf(":");
				if (i <= 0) {
					continue;
				}

				var key:String = line.substr(0, i).toLowerCase();
				var value:String = StringTools.trim(line.substr(i + 1));

				var earlier:Null<String> = __responseHeaders.get(key);
				if (earlier == null) {
					__responseHeaders.set(key, value);
					continue;
				}
				if (repeats == null) {
					repeats = new StringMap();
				}
				var values:Null<Array<String>> = repeats.get(key);
				if (values == null) {
					values = [earlier];
					repeats.set(key, values);
				}
				values.push(value);
			}
		}

		if (repeats != null) {
			// Set-Cookie with a newline, since a cookie's own Expires holds a
			// comma; every other repeat with a comma, which RFC 9110 5.3 makes
			// equivalent.
			for (key => values in repeats) {
				__responseHeaders.set(key, values.join(key == "set-cookie" ? "\n" : ", "));
			}
		}

		// Taken here, while `__url` is still the host that served the response.
		// A redirect reassigns it a few lines later, and these headers are
		// thrown away with it.
		if (__cookies != null) {
			__cookies.store(__responseHeaders.get("set-cookie"), __url.host);
		}

		// Only reached once the blank line closed a final (non-1xx) block;
		// every failure above returns instead, and an informational block is
		// discarded and re-read before control gets here.
		onHeaders(__responseHeaders);
	}

	/** Bytes the last `__readLine` took, its line ending's LF aside. */
	private var __lineBytes:Int = 0;

	/**
	 * One line of the response without its line ending, or `Eof` when the
	 * stream ends before any of it. Throws `LineTooLong` once more than
	 * `limit` bytes have arrived without the line ending: this was
	 * `Input.readLine`, which read a line for as long as the server kept it
	 * going, into memory, with no bound at all.
	 *
	 * A byte at a time, as `readLine` read, so nothing past the line is taken
	 * from the body. On eval through `readBytes`: a socket's `readByte` there
	 * answers 0 at the end of the stream rather than throwing, so a server
	 * closing without an answer read as endless NUL bytes, the line never
	 * ended, and `load()` never returned.
	 */
	private function __readLine(limit:Int):String {
		var input:haxe.io.Input = __socket.input;
		var line:BytesBuffer = new BytesBuffer();
		var count:Int = 0;
		var read:Bool = false;
		#if eval
		var one:Bytes = Bytes.alloc(1);
		#end
		while (true) {
			var byte:Int;
			try {
				#if eval
				input.readBytes(one, 0, 1);
				byte = one.get(0);
				#else
				byte = input.readByte();
				#end
			} catch (e:haxe.io.Eof) {
				if (!read) {
					throw e;
				}
				break;
			}
			read = true;
			if (byte == "\n".code) {
				break;
			}
			if (++count > limit) {
				throw new LineTooLong(limit);
			}
			line.addByte(byte);
		}
		__lineBytes = count;
		var text:String = line.getBytes().toString();
		if (text.length > 0 && StringTools.fastCodeAt(text, text.length - 1) == "\r".code) {
			text = text.substr(0, text.length - 1);
		}
		return text;
	}

	/**
	 * The status code of an HTTP/1.x status line, or -1 when it is not one.
	 *
	 * `HTTP/` DIGITs `.` DIGITs, whitespace, then exactly three digits, as RFC
	 * 9112 4 has it. This was `(\d+)` through Std.parseInt, compiled per
	 * response, and a status of any length was read however the target read
	 * it: "HTTP/1.1 4294967496 OK" was 200 on Linux native.
	 */
	private static function __parseStatusLine(line:String):Int {
		if (!StringTools.startsWith(line, "HTTP/")) {
			return -1;
		}

		var length:Int = line.length;
		var i:Int = __skipDigits(line, 5);
		if (i == 5 || i >= length || StringTools.fastCodeAt(line, i) != ".".code) {
			return -1;
		}

		var minor:Int = i + 1;
		i = __skipDigits(line, minor);
		if (i == minor) {
			return -1;
		}

		var gap:Int = i;
		while (i < length && (StringTools.fastCodeAt(line, i) == " ".code || StringTools.fastCodeAt(line, i) == "\t".code)) {
			i++;
		}
		if (i == gap || i + 3 > length) {
			return -1;
		}
		if (i + 3 < length && StringTools.fastCodeAt(line, i + 3) != " ".code && StringTools.fastCodeAt(line, i + 3) != "\t".code) {
			return -1;
		}

		var code:Int = IntParse.decimal(line.substr(i, 3));
		return code < 100 ? -1 : code;
	}

	private static function __skipDigits(text:String, from:Int):Int {
		var i:Int = from;
		while (i < text.length) {
			var code:Int = StringTools.fastCodeAt(text, i);
			if (code < "0".code || code > "9".code) {
				break;
			}
			i++;
		}
		return i;
	}

	/** Whether the caller supplied a header starting with `prefix` (lowercase, with its colon). **/
	private function __hasHeader(prefix:String):Bool {
		if (__headers == null) {
			return false;
		}

		for (header in __headers) {
			if (StringTools.startsWith(header.toLowerCase(), prefix)) {
				return true;
			}
		}

		return false;
	}

	private function __handleRequest():Void {
		try {
			var isGetLike:Bool = (__method == "GET" || __method == "HEAD");

			var baseQuery:String = __url.query;
			var extraQuery:String = "";
			if (!__redirect && isGetLike && __requestData != null && Reflect.isObject(__requestData)) {
				extraQuery = __buildQuery(__requestData);
			}
			var combined:String = (baseQuery.length > 0 && extraQuery.length > 0) ? (baseQuery + "&" + extraQuery) : (baseQuery + extraQuery);
			var queryString:String = (combined.length > 0) ? ("?" + combined) : "";

			var path:String = (__url.path != null && __url.path.length > 0) ? __url.path : "/";
			// Encoded, and the header values below sanitised, for the reason
			// the caller's own header lines are: each was written as given, so
			// a space ended the target early, and a CR or LF in any of them --
			// the URL's path, the user agent, the content type -- ended its
			// line and began one of the value's choosing.
			var target:String = HttpSyntax.encodeRequestTarget(path + queryString);
			__socket.output.writeString('${__method} ${target} $__version${CRLF}');
			__socket.output.writeString('User-Agent: ${HttpSyntax.sanitizeHeaderValue(__userAgent)}${CRLF}');
			var hostHeader:String = HttpSyntax.authority(__url.host, __url.port, __url.ssl ? 443 : 80);
			__socket.output.writeString('Host: ${HttpSyntax.sanitizeHeaderValue(hostHeader)}${CRLF}');
			if (__version == HttpVersion.HTTP_1_1 && __pooling()) {
				// Kept for the next request to this origin if the response
				// allows it: see HttpConnectionPool.
				__socket.output.writeString('Connection: ${Connection.KEEP_ALIVE}${CRLF}');
			} else if (__version == HttpVersion.HTTP_1_1 || __version == HttpVersion.HTTP_1) {
				__socket.output.writeString('Connection: ${Connection.CLOSE}${CRLF}');
			}

			// Whatever an earlier hop in this same request was handed. Skipped
			// when the caller writes its own Cookie header, on the same rule as
			// Content-Type and Accept-Encoding below: what the caller said wins.
			if (__cookies != null && !__hasHeader("cookie:")) {
				var jar:Null<String> = __cookies.headerFor(__url.host, __url.ssl == true);
				if (jar != null) {
					__socket.output.writeString('Cookie: ${jar}${CRLF}');
				}
			}

			var sentAcceptEncoding:Bool = __hasHeader("accept-encoding:");
			if (!sentAcceptEncoding) {
				__socket.output.writeString('Accept-Encoding: ' + crossbyte._internal.http.headers.AcceptEncoding.IDENTITY + CRLF);
			}

			__writeHeaders();

			var hasContentType:Bool = false;
			var hasContentLength:Bool = false;
			if (__headers != null) {
				for (header in __headers) {
					var hl:String = header.toLowerCase();
					if (StringTools.startsWith(hl, "content-type:"))
						hasContentType = true;
					if (StringTools.startsWith(hl, "content-length:"))
						hasContentLength = true;
				}
			}

			var body:Bytes = null;
			var isHead:Bool = (__method == "HEAD");

			if (!isHead) {
				if (__data != null) {
					if (Std.isOfType(__data, String)) {
						if (__contentType == null) {
							__contentType = "text/plain; charset=utf-8";
						}

						body = haxe.io.Bytes.ofString((__data : String));
					} else if (Std.isOfType(__data, haxe.io.Bytes)) {
						body = (__data : haxe.io.Bytes);
					} else {
						throw "Data Type not recognized";
					}
				} else if (!isGetLike && __requestData != null && Reflect.isObject(__requestData)) {
					var form:String = __buildQuery(__requestData);
					body = haxe.io.Bytes.ofString(form);
					if (__contentType == null) {
						__contentType = "application/x-www-form-urlencoded; charset=utf-8";
					}
				}
			}

			if (body != null) {
				// Bytes handed over with no type went out as "Content-Type:
				// null"; a body with no Content-Type at all is the honest form.
				if (!hasContentType && __contentType != null) {
					__socket.output.writeString('Content-Type: ${HttpSyntax.sanitizeHeaderValue(__contentType)}${CRLF}');
				}
				if (!hasContentLength) {
					__socket.output.writeString('$HEADER_CONTENT_LENGTH: ${body.length}${CRLF}');
				}
			}

			__socket.output.writeString(CRLF);

			if (body != null) {
				// Full, not writeBytes: that writes what it can and says how
				// much, and over TLS it can never take more than one record,
				// 16 KB. The rest of a larger body was dropped, and the server
				// waited for bytes that were never coming.
				__socket.output.writeFullBytes(body, 0, body.length);
			}

			__socket.output.flush();
		} catch (e:Dynamic) {
			__close();
			// A kept connection the server had closed refuses the write; the
			// one String thrown above is the caller's data, not the socket.
			if (__reusedSocket && !Std.isOfType(e, String)) {
				__staleRetry = true;
				return;
			}
			__fail("URL Request failed");
		}
	}

	private function __close():Void {
		// Taken out of a cancel's reach before it is closed, so the two
		// threads never close it at once.
		var socket:Null<FlexSocket> = __detach();
		__connected = false;
		if (socket != null) {
			__closeQuietly(socket);
		}

		// should we reset the status?
		//__status = 0;
	}

	private function __writeHeaders():Void {
		if (__headers == null) {
			return;
		}

		for (header in __headers) {
			// Through the sanitisers the server's response writer uses. These
			// lines were written as given, so a CR or LF in a value -- one
			// forwarded from someone else, say -- ended the header and began
			// another, or a second request, on every hop of the exchange.
			var colon:Int = header.indexOf(":");
			if (colon <= 0) {
				continue;
			}

			var name:String = HttpSyntax.sanitizeHeaderName(header.substr(0, colon));
			if (name.length == 0) {
				continue;
			}

			__socket.output.writeString(name + ": " + StringTools.trim(HttpSyntax.sanitizeHeaderValue(header.substr(colon + 1))) + CRLF);
		}
	}

	private static inline function __encodeKV(k:String, v:String):String {
		return StringTools.urlEncode(k) + "=" + StringTools.urlEncode(v);
	}

	/**
	 * Reads a `Content-Length` field, or answers null when it is not one.
	 *
	 * Through `IntParse`, as the server reads the same field. `Std.parseInt`
	 * is `strtol` cast to an `int` on Linux and macOS native, so a response
	 * declaring 4294967296 bytes read as 0 there -- an empty body, reported as
	 * a complete download -- and on the jvm the same header threw.
	 */
	private function __parseContentLength(header:String):Null<Int> {
		if (header == null) {
			return null;
		}

		var parsed:Int = -1;
		for (raw in header.split(",")) {
			var value:Int = IntParse.decimal(StringTools.trim(raw));
			if (value < 0 || (parsed >= 0 && parsed != value)) {
				return null;
			}
			parsed = value;
		}

		return parsed;
	}

	/**
		`requestData` encoded as a form: a GET's or HEAD's query, any other
		method's body. Shared with the HTTP/2 backend, which never read
		`requestData` and sent a form as nothing at all.
	**/
	@:allow(crossbyte.http.HTTP2Backend)
	private static function __buildQuery(obj:Dynamic):String {
		// A URLVariables is a StringMap at run time, and its fields are the
		// map's, not the caller's: a POST of one went out with an empty body.
		var form:Null<String> = crossbyte.url.URLVariables.encodeData(obj);
		if (form != null) {
			return form;
		}

		var parts:Array<String> = [];

		var fields = Reflect.fields(obj);
		for (f in fields) {
			buildQueryAdd(parts, f, Reflect.field(obj, f));
		}

		return parts.join("&");
	}

	private static function buildQueryAdd(parts:Array<String>, k:String, v:Dynamic):Void {
		if (v == null) {
			return;
		}

		switch (Type.typeof(v)) {
			case TBool:
				parts.push(__encodeKV(k, (v : Bool) ? "true" : "false"));
			case TInt, TFloat:
				parts.push(__encodeKV(k, Std.string(v)));
			case TClass(String):
				parts.push(__encodeKV(k, (v : String)));
			case TClass(Array):
				var arr = (v : Array<Dynamic>);
				for (i in 0...arr.length) {
					buildQueryAdd(parts, k + "[]", arr[i]);
				}

			case TObject:
				var fields = Reflect.fields(v);
				for (f in fields) {
					buildQueryAdd(parts, k + "[" + f + "]", Reflect.field(v, f));
				}

			default:
				parts.push(__encodeKV(k, Std.string(v)));
		}
	}

	@:allow(crossbyte.http.HTTP2Backend)
	@:noCompletion private static function __resolveLocation(base:URL, loc:String):String {
		var locRegex:EReg = ~/^[a-zA-Z][a-zA-Z0-9+\-.]*:\/\//;
		if (locRegex.match(loc)) {
			return loc;
		}

		var scheme:String = base.scheme;
		// Bracketed for an IPv6 host, and the port kept unless it is the
		// scheme's own: the host went in bare, so a relative redirect from
		// [::1]:8080 named http://::1:8080/, which is not a URL, and one from
		// http://host:443/ lost its port.
		var authority:String = HttpSyntax.authority(base.host, base.port, base.ssl ? 443 : 80);

		if (StringTools.startsWith(loc, "//")) {
			return scheme + ":" + loc;
		}

		var basePath:String = (base.path != null && base.path.length > 0) ? base.path : "/";
		if (StringTools.startsWith(loc, "?")) {
			return scheme + "://" + authority + __normalizeReferencePath(basePath + loc);
		}

		if (StringTools.startsWith(loc, "#")) {
			var baseQuery:String = (base.query != null && base.query.length > 0) ? ("?" + base.query) : "";
			return scheme + "://" + authority + __normalizeReferencePath(basePath + baseQuery + loc);
		}

		if (loc.charAt(0) == "/") {
			return scheme + "://" + authority + __normalizeReferencePath(loc);
		}

		var slash:Int = basePath.lastIndexOf("/");
		var dir:String = (slash >= 0) ? basePath.substr(0, slash + 1) : "/";
		var joined:String = dir + loc;

		return scheme + "://" + authority + __normalizeReferencePath(joined);
	}

	private static function __normalizeReferencePath(pathWithQuery:String):String {
		var pathEnd:Int = pathWithQuery.length;
		var queryIndex:Int = pathWithQuery.indexOf("?");
		var fragmentIndex:Int = pathWithQuery.indexOf("#");
		if (queryIndex >= 0 && (fragmentIndex < 0 || queryIndex < fragmentIndex)) {
			pathEnd = queryIndex;
		} else if (fragmentIndex >= 0) {
			pathEnd = fragmentIndex;
		}

		var suffix:String = pathWithQuery.substr(pathEnd);
		var path:String = pathWithQuery.substr(0, pathEnd);
		var absolute:Bool = StringTools.startsWith(path, "/");
		var trailingSlash:Bool = StringTools.endsWith(path, "/");
		var output:Array<String> = [];

		for (segment in path.split("/")) {
			if (segment == "" || segment == ".") {
				continue;
			}
			if (segment == "..") {
				if (output.length > 0) {
					output.pop();
				}
			} else {
				output.push(segment);
			}
		}

		var normalized:String = (absolute ? "/" : "") + output.join("/");
		if (normalized == "") {
			normalized = absolute ? "/" : "";
		} else if (trailingSlash && !StringTools.endsWith(normalized, "/")) {
			normalized += "/";
		}

		return normalized + suffix;
	}
}

/** A line, or a section of lines, of a response ran past its limit. */
private class LineTooLong extends haxe.Exception {
	public function new(limit:Int) {
		super("A line of the response ran past its " + limit + " byte limit");
	}
}
#end
