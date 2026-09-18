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
import crossbyte.url.URL;
import haxe.ds.StringMap;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;

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

	public function new(url:String, method:String = "GET", headers:Array<String> = null, requestData:Dynamic = null, contentType:Null<String> = null,
			data:Dynamic = null, version:HttpVersion = HttpVersion.HTTP_1_1, timeout:Int = 10000, userAgent:String = "CrossByte", followRedirects:Bool = true,
			manageCookies:Bool = true) {
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

	public function advance():Void {}

	public function loadAsync():Void {
		if (!__usesBuiltInBackend()) {
			__loadWithBackend();
		}
	}

	public function load():Void {
		__redirect = false;

		if (!__usesBuiltInBackend()) {
			__loadWithBackend();
			return;
		}

		// The only way to interrupt a blocking read is to close the socket
		// underneath it. Crude next to an HTTP/2 stream reset, but HTTP/1.1
		// has no in-band way to abandon a response: the connection is the
		// unit, so the connection is what goes.
		cancelToken.onCancel(__abortSocket);

		if (cancelToken.cancelled) {
			onError("Request cancelled");
			return;
		}

		var redirects:Array<String> = [__url];

		__tryRequest();

		if (__followRedirects) {
			while (__connected
				&& (__status == 301 || __status == 302 || __status == 303 || __status == 307 || __status == 308)
				&& (redirects.length - 1) < MAX_REDIRECTS) {
				if (__responseHeaders.exists(HEADER_LOCATION)) {
					var location:String = __responseHeaders.get(HEADER_LOCATION);

					if (location.length > 0) {
						__redirect = true;

						var url:URL = new URL(__resolveLocation(__url, location));

						if (redirects.indexOf(url) > -1) {
							__close();
							onError("Redirect loop detected");
							return;
						}

						if (__status == 301 || __status == 302 || __status == 303) {
							__method = "GET";
							__data = null;
							__contentType = null;
							__requestData = null;
						}

						__url = url;
					} else {
						__close();
						onError("Could not complete redirect");
						return;
					}
				} else {
					__close();
					onError("Could not complete redirect");
					return;
				}

				redirects.push(__url);
				__close();
				__tryRequest();
			}

			if ((redirects.length - 1) == MAX_REDIRECTS) {
				__close();
				onError("Exceeded the number of allowed redirects");
			}
		}

		__parseResponse();
	}

	/**
	 * Closes the socket out from under a blocking read.
	 *
	 * Called from whichever thread cancelled, which is not the thread inside
	 * `load()`. That read then fails and unwinds through the ordinary error
	 * path, which is the point: there is nothing else to poll.
	 */
	private function __abortSocket():Void {
		try {
			if (__socket != null) {
				__socket.close();
			}
		} catch (_:Dynamic) {}
		__connected = false;
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
			onError("Download failed: invalid Content-Length");
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
						onError("Download failed: expected " + total + " bytes, got " + offset);
						return;
					}

				case "chunked":
					var buffer:BytesBuffer = new BytesBuffer();
					while (true) {
						var sizeLine:String = __socket.input.readLine();
						if (sizeLine == null) {
							throw "Unexpected EOF while reading chunk size";
						}

						var semi:Int = sizeLine.indexOf(";");
						if (semi >= 0) {
							sizeLine = sizeLine.substr(0, semi);
						}

						var hexStr:String = StringTools.trim(sizeLine);

						// Checked as hex before it is parsed, the way the
						// Content-Length parser below checks its own field.
						// Std.parseInt stops at the first character it cannot use,
						// so "10junk" and "10 20" both came back as 16 -- a size
						// line this client read differently from whatever wrote it,
						// and nothing said so.
						if (hexStr.length == 0 || !~/^[0-9a-fA-F]+$/.match(hexStr)) {
							throw "Invalid chunk size: " + hexStr;
						}

						// Seven significant digits at most, leading zeros not
						// counted. Past that Std.parseInt answers differently on
						// every target: -1 on eval and cpp, a thrown
						// NumberFormatException on jvm, and on node a number too
						// large for Int, which is neither null nor negative and so
						// walked straight past the test below. 0xFFFFFFF is already
						// far beyond MAX_CHUNKED_BODY_SIZE.
						var firstSignificant:Int = 0;
						while (firstSignificant < hexStr.length - 1 && hexStr.charCodeAt(firstSignificant) == 48) {
							firstSignificant++;
						}
						if (hexStr.length - firstSignificant > 7) {
							throw "Invalid chunk size: " + hexStr;
						}

						var parsed:Null<Int> = Std.parseInt('0x' + hexStr);
						if (parsed == null || parsed < 0) {
							throw "Invalid chunk size: " + hexStr;
						}

						var chunkSize:Int = parsed;

						if (chunkSize == 0) {
							var trailer:String = "";
							do {
								trailer = __socket.input.readLine();
								if (trailer == null) {
									throw "Unexpected EOF while reading trailers";
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
						} catch (e:Dynamic) {
							n = 0;
						}
						if (n <= 0)
							break;
						buffer.addBytes(b, 0, n);
						bytesLoaded += n;
						onProgress(bytesLoaded, bytesTotalForProgress);
					}
					data = buffer.getBytes();

				default:
					__close();
					onError("Download failed: unsupported response mode");
					return;
			}
		} catch (e:Dynamic) {
			__close();
			// `e` was bound and then dropped, so every way a body can fail --
			// a chunk size that is not one, a truncated chunk, a missing
			// terminator, an early EOF -- reached the caller as the same four
			// words. The three messages above this one all name the thing that
			// went wrong.
			onError("Download failed: " + Std.string(e));
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
					onError('Unsupported content encoding: ${error}', data);
				} else {
					onError('Failed to decode response body: ' + Std.string(error), data);
				}
				return;
			}
		}

		if (isHttpError) {
			var status:Int = __status;
			__close();
			onError('HTTP error ' + status, data);
			return;
		}

		if (data != null) {
			onComplete(data);
		}

		__close();
	}

	@:noCompletion private function __decodeResponseBody(data:Bytes):Bytes {
		if (data == null || data.length == 0) {
			return data;
		}

		var header = __responseHeaders.exists(HEADER_CONTENT_ENCODING) ? __responseHeaders.get(HEADER_CONTENT_ENCODING) : null;
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
			payload.uncompress(encodings[encodings.length - 1 - i], MAX_DECOMPRESSED_BODY_SIZE);
		}

		return payload;
	}

	private function __tryRequest():Void {
		__status = 0;
		__responseHeaders = new StringMap();

		try {
			__socket = new FlexSocket(__url.ssl);
			__socket.setTimeout(__timeout);
			__socket.connect(__url.host, __url.port);
			__connected = true;
		} catch (e:Dynamic) {
			__close();
			onError("Connection Failed");
			return;
		}

		if (__connected) {
			__handleRequest();
		}

		__handleResponse();
	}

	private function __handleResponse():Void {
		if (!__connected) {
			return;
		}

		var line:String = '';
		while (true) {
			try {
				line = __socket.input.readLine();
			} catch (e:Dynamic) {
				__close();
				onError("Failed to read response");
				return;
			}

			if (line == null) {
				__close();
				onError("Connection closed while reading headers");
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
					continue;
				}
				break;
			}

			if (__status == 0) {
				var regex:EReg = ~/^HTTP\/\d+\.\d+\s+(\d+)/;
				if (!regex.match(line)) {
					__close();
					onError('Malformed status line: ' + line);
					return;
				}
				__status = Std.parseInt(regex.matched(1));
				onStatus(__status);
			} else {
				var i:Int = line.indexOf(":");
				if (i <= 0) {
					continue;
				}

				var key:String = line.substr(0, i).toLowerCase();
				var value:String = StringTools.trim(line.substr(i + 1));

				if (__responseHeaders.exists(key)) {
					if (key == "set-cookie") {
						var prev = __responseHeaders.get(key);
						__responseHeaders.set(key, prev + "\n" + value);
					} else {
						__responseHeaders.set(key, __responseHeaders.get(key) + ", " + value);
					}
				} else {
					__responseHeaders.set(key, value);
				}
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
			__socket.output.writeString('${__method} ${path}${queryString} $__version${CRLF}');
			__socket.output.writeString('User-Agent: ${__userAgent}${CRLF}');
			var hostHeader:String = (__url.port != 80 && __url.port != 443) ? '${__url.host}:${__url.port}' : __url.host;
			__socket.output.writeString('Host: ${hostHeader}${CRLF}');
			if (__version == HttpVersion.HTTP_1_1 || __version == HttpVersion.HTTP_1) {
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
				if (!hasContentType) {
					__socket.output.writeString('Content-Type: ${__contentType}${CRLF}');
				}
				if (!hasContentLength) {
					__socket.output.writeString('$HEADER_CONTENT_LENGTH: ${body.length}${CRLF}');
				}
			}

			__socket.output.writeString(CRLF);

			if (body != null) {
				__socket.output.writeBytes(body, 0, body.length);
			}

			__socket.output.flush();
		} catch (e:Dynamic) {
			__close();
			onError("URL Request failed");
		}
	}

	private function __close():Void {
		if (__socket != null) {
			__socket.close();
			__connected = false;
			__socket = null;
		}

		// should we reset the status?
		//__status = 0;
	}

	private function __writeHeaders():Void {
		if (__headers != null) {
			for (header in __headers) {
				__socket.output.writeString('${header}${CRLF}');
			}
		}
	}

	private inline function __encodeKV(k:String, v:String):String {
		return StringTools.urlEncode(k) + "=" + StringTools.urlEncode(v);
	}

	private function __parseContentLength(header:String):Null<Int> {
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
			if (n == null || n < 0) {
				return null;
			}
			if (parsed != null && parsed != n) {
				return null;
			}
			parsed = n;
		}

		return parsed;
	}

	private function __buildQuery(obj:Dynamic):String {
		var parts:Array<String> = [];

		var fields = Reflect.fields(obj);
		for (f in fields) {
			buildQueryAdd(parts, f, Reflect.field(obj, f));
		}

		return parts.join("&");
	}

	private inline function buildQueryAdd(parts:Array<String>, k:String, v:Dynamic):Void {
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

	@:noCompletion private function __resolveLocation(base:URL, loc:String):String {
		var locRegex:EReg = ~/^[a-zA-Z][a-zA-Z0-9+\-.]*:\/\//;
		if (locRegex.match(loc)) {
			return loc;
		}

		var scheme:String = base.scheme;
		var host:String = base.host;
		var port:Int = base.port;
		var portPart:String = (port != 80 && port != 443) ? (":" + port) : "";

		if (StringTools.startsWith(loc, "//")) {
			return scheme + ":" + loc;
		}

		var basePath:String = (base.path != null && base.path.length > 0) ? base.path : "/";
		if (StringTools.startsWith(loc, "?")) {
			return scheme + "://" + host + portPart + __normalizeReferencePath(basePath + loc);
		}

		if (StringTools.startsWith(loc, "#")) {
			var baseQuery:String = (base.query != null && base.query.length > 0) ? ("?" + base.query) : "";
			return scheme + "://" + host + portPart + __normalizeReferencePath(basePath + baseQuery + loc);
		}

		if (loc.charAt(0) == "/") {
			return scheme + "://" + host + portPart + __normalizeReferencePath(loc);
		}

		var slash:Int = basePath.lastIndexOf("/");
		var dir:String = (slash >= 0) ? basePath.substr(0, slash + 1) : "/";
		var joined:String = dir + loc;

		return scheme + "://" + host + portPart + __normalizeReferencePath(joined);
	}

	private function __normalizeReferencePath(pathWithQuery:String):String {
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
#end
