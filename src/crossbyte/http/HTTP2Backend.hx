package crossbyte.http;

// Not built for JavaScript. This drives HTTP/2 framing over a raw socket, and
// neither a browser nor Node exposes one through `FlexSocket`; a page reaches
// HTTP/2 through fetch, which negotiates it below the API surface.
#if !js
import crossbyte._internal.http.CookieJar;
import crossbyte._internal.http.Http;
import crossbyte._internal.http.HttpSyntax;
import crossbyte._internal.http.h2.H2ClientSession;
import crossbyte._internal.http.h2.H2Connection;
import crossbyte._internal.http.h2.H2ConnectionPool;
import crossbyte._internal.http.h2.H2ConnectionError;
import crossbyte._internal.http.h2.H2ErrorCode;
import crossbyte._internal.http.h2.H2Settings;
import crossbyte._internal.http.h2.H2Stream;
import crossbyte._internal.http.h2.H2StreamError;
import crossbyte._internal.http.h2.hpack.HpackHeader;
import crossbyte._internal.socket.FlexSocket;
import crossbyte.url.URL;
import haxe.io.Bytes;

/**
 * An HTTP/2 backend for `HTTPBackendRegistry`.
 *
 * Registered on first use: the registry resolves HTTP/2 to this backend the
 * first time a request asks for it, unless
 * `HTTPBackendRegistry.autoRegisterBundled` was turned off before then.
 * Register one yourself only in that case, or to give it settings of its
 * own; a backend registered later takes precedence over the bundled one:
 *
 * ```haxe
 * HTTPBackendRegistry.register(new HTTP2Backend());
 * ```
 *
 * A build that never asks for HTTP/2 and should not link the framing layer
 * is compiled with `-D crossbyte_no_http2`; see `autoRegisterBundled`.
 *
 * `http://` uses prior-knowledge h2c: the client opens with the connection
 * preface and assumes the server speaks HTTP/2. That is the only cleartext
 * mode left, RFC 9113 §3.1 retired the `Upgrade: h2c` handshake, and it
 * means a server that does *not* speak HTTP/2 fails rather than negotiating
 * down, which is why the version has to be asked for explicitly.
 *
 * `https://` negotiates `h2` through ALPN and fails if the server declines,
 * for the same reason. ALPN needs native TLS support, so this path works
 * wherever `FlexSocket.alpnSupported` is true and errors where it is not,
 * rather than silently sending HTTP/2 framing into an HTTP/1.1 server.
 *
 * Connections are pooled by origin and shared, so concurrent requests to the
 * same host travel as concurrent streams over one connection rather than
 * opening one each. That is the point of HTTP/2, and it also means the second
 * request to a host skips the handshakes and starts with a warm HPACK table.
 *
 * Cancelling through the request's `cancelToken` resets its stream and
 * leaves the connection to the other requests on it. A request cancelled
 * before the end of its response reports `"Request cancelled"` and never
 * completes, however much of the response then arrives; one whose response
 * had already ended when the cancel came completes as usual.
 *
 * Redirects are followed as the HTTP/1.1 client follows them, through the
 * same code: `Http.MAX_REDIRECTS` at most, a relative `Location` resolved
 * against the request's URL, a 301, 302 or 303 turned into a bodiless GET,
 * `https` to `http` only with `followInsecureRedirects`, and the caller's
 * `Authorization`, `Proxy-Authorization` and `Cookie` dropped once a hop
 * leaves the origin the request started at. A hop to an origin already
 * connected to rides that connection.
 *
 * The request's `timeout` is an idle limit on its stream, as it is on the
 * HTTP/1.1 client's socket: the longest the response may go with nothing
 * arriving for it. `0` or less is none, as it is there.
 */
class HTTP2Backend implements HTTPBackend {
	/**
	 * Whether this target can carry an HTTP/2 request at all.
	 *
	 * False on eval, and not for want of an implementation: that target raises
	 * socket errors as native exceptions no Haxe `catch` can see, so a peer
	 * reset kills the reader thread a pooled connection parks on, or, on a
	 * send, the process. Everything would appear to work until the first
	 * reset, which is the worst way for it not to work.
	 *
	 * The framing and HPACK layers are unaffected and run everywhere,
	 * including the browser. This is about driving a socket with them.
	 */
	public static var isSupported(default, null):Bool = #if eval false #else true #end;

	/** Our SETTINGS, sent at the head of every connection. */
	public var settings:H2Settings;

	public function new(?settings:H2Settings) {
		this.settings = settings != null ? settings : __defaultSettings();
	}

	public function supports(version:HTTPVersion):Bool {
		return version == HTTPVersion.HTTP_2;
	}

	public function load(context:HTTPRequestContext):Void {
		if (!isSupported) {
			// Refused at the door rather than part way through a request that
			// would have looked fine until something reset it.
			context.onError("HTTP/2 is not supported on this target: socket errors cannot be caught here, "
				+ "so a connection reset would take down the reader thread or the process. Use HTTP/1.1.");
			return;
		}

		// What a redirect may change about the request, hop to hop.
		var url:URL = new URL(context.url);
		var method:String = context.method;
		var headers:Array<String> = context.headers;
		var data:Dynamic = context.data;
		var contentType:Null<String> = context.contentType;
		var cookies:Null<CookieJar> = context.manageCookies == true ? new CookieJar() : null;

		// `requestData`, encoded as the HTTP/1.1 client encodes it, a
		// URLVariables, or an object's fields, and ignored beside a body of
		// the caller's own: a GET's or HEAD's query, any other method's form.
		// Nothing here read it, so a form went out as an empty POST with no
		// Content-Type, and a GET without its query.
		var query:Null<String> = null;
		if (data == null && context.requestData != null && Reflect.isObject(context.requestData)) {
			var form:String = Http.__buildQuery(context.requestData);
			if (method == "GET" || method == "HEAD") {
				query = form;
			} else {
				data = form;
				if (contentType == null) {
					contentType = "application/x-www-form-urlencoded; charset=utf-8";
				}
			}
		}

		// The HTTP/1.1 client's redirect policy, through the same functions:
		// a 3xx completed here with its Location unfollowed, where the
		// HTTP/1.1 client, Node and the browser all followed it.
		var visited:Array<String> = [url];
		var origin:String = Http.__originOf(url);
		var credentialsDropped:Bool = false;

		while (true) {
			var exchange:Null<H2Exchange> = __exchange(context, url, method, headers, query, data, contentType, cookies, credentialsDropped);
			if (exchange == null) {
				// Reported already.
				return;
			}
			// The first hop's only, as over HTTP/1.1: a redirect's Location is
			// the whole of the next hop's target.
			query = null;

			var stream:H2Stream = exchange.stream;
			if (!context.followRedirects || !Http.__isRedirect(stream.status) || !stream.endOfStream || __cancelled(context)) {
				__report(context, stream, exchange.connection);
				return;
			}

			// Each hop is reported as it goes, as the HTTP/1.1 client reports
			// them: a caller watching onStatus sees the chain, and only the
			// final response reaches onComplete.
			var fields:Map<String, String> = __fields(stream);
			context.onStatus(stream.status);
			context.onHeaders(fields);
			if (cookies != null) {
				// While `url` is still the host that set them.
				cookies.store(fields.get("set-cookie"), url.host);
			}

			var location:Null<String> = fields.get("location");
			if (location == null || location.length == 0) {
				context.onError("Could not complete redirect");
				return;
			}
			if (visited.length - 1 >= Http.MAX_REDIRECTS) {
				context.onError("Exceeded the number of allowed redirects");
				return;
			}

			var next:URL;
			try {
				next = new URL(Http.__resolveLocation(url, location));
			} catch (_:Dynamic) {
				context.onError("Could not complete redirect: malformed Location " + location);
				return;
			}
			if (visited.indexOf(next) > -1) {
				context.onError("Redirect loop detected");
				return;
			}
			var refusal:Null<String> = Http.__redirectRefusal(url, next, context.followInsecureRedirects == true);
			if (refusal != null) {
				context.onError(refusal);
				return;
			}

			// Written for the origin the caller asked, and not handed to
			// another because a response names it, for the rest of the
			// exchange, even should a later hop come back.
			if (!credentialsDropped && Http.__originOf(next) != origin) {
				credentialsDropped = true;
				headers = Http.__withoutCredentials(headers);
			}

			var nextMethod:String = Http.__methodAfterRedirect(stream.status, method);
			if (nextMethod != method) {
				method = nextMethod;
				data = null;
				contentType = null;
			}

			if (context.onRedirect != null) {
				context.onRedirect(next);
			}
			visited.push(next);
			url = next;
		}
	}

	/**
	 * Sends one request and waits for its response, or reports why it could
	 * not and answers null.
	 */
	private function __exchange(context:HTTPRequestContext, url:URL, method:String, headers:Array<String>, query:Null<String>, data:Dynamic,
			contentType:Null<String>, cookies:Null<CookieJar>, leftOrigin:Bool):Null<H2Exchange> {
		if (__cancelled(context)) {
			// Between two hops, or before the first. Nothing is opened for it,
			// and nothing already open is disturbed.
			context.onError("Request cancelled");
			return null;
		}

		var secure:Bool = url.scheme == "https";
		var port:Int = url.port != null ? url.port : (secure ? 443 : 80);
		var scheme:String = secure ? "https" : "http";
		var origin:String = scheme + "://" + HttpSyntax.authority(url.host.toLowerCase(), port, -1);

		if (secure && !FlexSocket.alpnSupported) {
			context.onError("HTTP/2 over TLS needs ALPN, which this target does not support");
			return null;
		}

		var session:H2ClientSession = null;
		// The request's TLS, as the HTTP/1.1 client applies it: less its client
		// certificate once a redirect has left the origin it was made to.
		var tls:Null<HTTPTLSOptions> = null;
		if (secure && context.tls != null && !context.tls.isDefault()) {
			tls = leftOrigin ? context.tls.withoutClientCertificate() : context.tls;
		}

		try {
			// Bracketed for an IPv6 host: 2001:db8::1:8080 cannot be split.
			var authority:String = HttpSyntax.authority(url.host, port, secure ? 443 : 80);
			var body:Null<Bytes> = __body(method, data);
			// 0, for 0 or less, is none: see Http.__idleSeconds.
			var timeout:Float = Http.__idleSeconds(context.timeout);
			var cookie:Null<String> = cookies != null ? cookies.headerFor(url.host, secure) : null;
			var fields:Array<HpackHeader> = __headers(headers, context.userAgent, contentType, body, cookie);

			// Sent once more, on whatever session the pool hands over next,
			// when the first refuses the stream before anything goes out: it
			// was retired as idle a moment after being handed over, or its
			// peer has said GOAWAY. REFUSED_STREAM promises the request was
			// not processed (RFC 9113, 8.7), so sending it again is safe.
			var stream:H2Stream = null;
			var refused:Int = 0;
			while (stream == null) {
				session = H2ConnectionPool.acquire(origin, () -> __open(origin, url.host, port, secure, context, tls), timeout, context.cancelToken, tls);
				try {
					// The HTTP/1.1 client's limit on a body, read per request
					// as that client reads it.
					stream = session.execute(method, scheme, authority, __target(url, query), fields, body, timeout, context.cancelToken,
						Http.MAX_BODY_SIZE);
				} catch (e:H2ConnectionError) {
					if (e.code == H2ErrorCode.CANCEL && __cancelled(context)) {
						// Cancelled as it was about to start: refused before
						// the session was touched, which stays for the rest.
						context.onError("Request cancelled");
						return null;
					}
					if (e.code != H2ErrorCode.REFUSED_STREAM || refused > 0) {
						throw e;
					}
					refused++;
					H2ConnectionPool.discard(session);
					session = null;
				}
			}

			// A session that died mid-request must not be handed to the next
			// caller; one that merely finished a stream stays pooled, which is
			// the whole point.
			if (session.dead) {
				H2ConnectionPool.discard(session);
			}
			return {stream: stream, connection: session.connection};
		} catch (e:H2StreamError) {
			// One stream failed, a timeout, and has been reset. The
			// connection is left pooled for the requests still on it and the
			// next: discarding it here failed all of them along with this one.
			if (session != null && session.dead) {
				H2ConnectionPool.discard(session);
			}
			context.onError(e.message);
		} catch (e:H2ConnectionError) {
			if (session != null) {
				H2ConnectionPool.discard(session);
			}
			// A cancel that ended the connect, or the wait on another
			// request's, is reported as the cancel it was.
			context.onError(__cancelled(context) ? "Request cancelled" : "HTTP/2 connection error: " + e.message);
		} catch (e:Dynamic) {
			if (session != null) {
				H2ConnectionPool.discard(session);
			}
			context.onError(__cancelled(context) ? "Request cancelled" : "HTTP/2 request failed: " + Std.string(e));
		}
		return null;
	}

	private static inline function __cancelled(context:HTTPRequestContext):Bool {
		return context.cancelToken != null && context.cancelToken.cancelled;
	}

	/**
	 * A response's header fields by name, repeats joined as the HTTP/1 client
	 * joins them, so a caller sees one shape whichever version served it.
	 *
	 * Collected, then joined once per name: each repeat was appended to the
	 * whole value so far, which is quadratic in the repeats, and the server
	 * chooses how many there are.
	 */
	private static function __fields(stream:H2Stream):Map<String, String> {
		var fields:Map<String, String> = new Map();
		var repeats:Null<Map<String, Array<String>>> = null;
		for (header in stream.headers) {
			var first:Null<String> = fields.get(header.name);
			if (first == null) {
				fields.set(header.name, header.value);
				continue;
			}
			if (repeats == null) {
				repeats = new Map();
			}
			var values:Null<Array<String>> = repeats.get(header.name);
			if (values == null) {
				values = [first];
				repeats.set(header.name, values);
			}
			values.push(header.value);
		}
		if (repeats != null) {
			for (name => values in repeats) {
				fields.set(name, values.join(name == "set-cookie" ? "\n" : ", "));
			}
		}
		return fields;
	}

	/**
	 * Opens a connection for the pool.
	 *
	 * The connect and the TLS handshake are held to the request's timeout,
	 * and its cancel token reaches the socket while they run. They had
	 * neither: a server that accepted TCP and then said nothing held this
	 * request, and every other request to its origin waiting on this connect,
	 * for good, and a cancel did nothing.
	 *
	 * Once open, the socket has no read timeout. A pooled connection is idle
	 * between requests by design, and a deadline on the reader would tear down
	 * a perfectly good connection for the crime of waiting; per-request
	 * deadlines live on the stream instead.
	 */
	private function __open(origin:String, host:String, port:Int, secure:Bool, context:HTTPRequestContext, ?tls:HTTPTLSOptions):H2ClientSession {
		var socket:FlexSocket = new FlexSocket(secure);

		if (secure) {
			// Only h2 is offered. Accepting http/1.1 here would hand back a
			// connection this backend cannot speak.
			socket.setALPN(["h2"]);
			if (tls != null) {
				tls.configure(socket);
			}
		}

		// An idle limit, as the HTTP/1.1 client sets on its socket: the
		// handshake's reads give up after it, however many there are.
		var timeout:Float = Http.__idleSeconds(context.timeout);
		socket.setTimeout(timeout);

		// Published to the token for as long as the connect runs, which is
		// how a cancel from another thread reaches a blocking call: by ending
		// it under the thread, as the HTTP/1.1 client does.
		var token:Null<HTTPCancelToken> = context.cancelToken;
		var interrupt:Void->Void = () -> Http.__interrupt(socket);
		if (token != null) {
			token.onCancel(interrupt);
		}

		try {
			// The name is looked up here, on the calling thread. That is the
			// load's own thread, URLLoader runs every load on one of its pool
			// threads, never on a runtime's, so a slow resolver holds up this
			// request and no one else's sockets or timers. Resolver, which
			// hands its answer back to a runtime's thread, is for code on one.
			socket.connect(host, port);
		} catch (e:Dynamic) {
			if (token != null) {
				token.removeHandler(interrupt);
			}
			__closeQuietly(socket);
			if (token != null && token.cancelled) {
				throw new H2ConnectionError(H2ErrorCode.CANCEL, "Request was cancelled while connecting to " + origin);
			}
			// Said as the timeout it was, the same way on every target.
			if (Http.__isTimeout(e)) {
				throw new H2ConnectionError(H2ErrorCode.CANCEL, 'Connecting to $origin timed out after ${timeout}s');
			}
			throw e;
		}

		if (token != null) {
			token.removeHandler(interrupt);
			if (token.cancelled) {
				// Cancelled as the connect finished: the socket may have been
				// shut down under it, so it is no connection to keep.
				__closeQuietly(socket);
				throw new H2ConnectionError(H2ErrorCode.CANCEL, "Request was cancelled while connecting to " + origin);
			}
		}

		if (secure && socket.getALPN() != "h2") {
			__closeQuietly(socket);
			throw new H2ConnectionError(H2ErrorCode.PROTOCOL_ERROR, "Server did not negotiate h2 over ALPN");
		}

		// Once the handshake is done and before the preface: a server whose
		// key is not pinned is sent nothing.
		if (tls != null) {
			var refusal:Null<String> = tls.checkPins(socket);
			if (refusal != null) {
				__closeQuietly(socket);
				throw new H2ConnectionError(H2ErrorCode.CONNECT_ERROR, refusal);
			}
		}

		socket.setTimeout(0);
		return new H2ClientSession(origin, socket, new H2Connection(socket.input, socket.output, settings), tls);
	}

	private static function __closeQuietly(socket:FlexSocket):Void {
		try {
			socket.close();
		} catch (_:Dynamic) {}
	}

	private function __report(context:HTTPRequestContext, stream:H2Stream, connection:H2Connection):Void {
		if (context.cancelToken != null && context.cancelToken.cancelled && !stream.endOfStream) {
			// Reported as cancellation rather than as the reset it produced:
			// the caller asked for this, and "stream reset" would read as the
			// peer having done something.
			//
			// Keyed on the end of the stream, not on its status. A cancel that
			// lands after the response headers but before the last of the body
			// still abandons the request, and testing the status reported it
			// complete with whatever part of the body had arrived.
			context.onError("Request cancelled");
			return;
		}

		// Everything below this block is a stream that reached its end. One
		// that did not is an error however much of it arrived: these branches
		// tested for a missing status, so a reset or a hang-up after the
		// headers reported the response complete with a truncated body.
		if (!stream.endOfStream) {
			if (stream.failure != null) {
				// Given up on here, for a reason of this side's own: a header
				// section past the limit.
				context.onError(stream.failure);
				return;
			}

			if (stream.resetCode != null) {
				var code:H2ErrorCode = stream.resetCode;
				context.onError('Stream reset by peer: ${code.toString()}');
				return;
			}

			if (stream.status < 0) {
				// The peer hung up before the response headers arrived.
				// Distinct from a malformed message, and the distinction is
				// what tells a caller whether retrying is worth anything.
				context.onError("Connection closed before the response headers arrived");
				return;
			}

			context.onError("Connection closed before the response body completed");
			return;
		}

		if (stream.status < 0) {
			// §8.3 requires exactly one :status on a response, so its absence
			// is a malformed message rather than a missing default.
			context.onError("Response had no :status pseudo-header");
			return;
		}

		context.onStatus(stream.status);

		var headers:Map<String, String> = __fields(stream);
		context.onHeaders(headers);

		var body:Bytes = stream.takeBody();

		// Decoded as the HTTP/1.1 client decodes, within the same limits. A
		// request sent with no Accept-Encoding accepts any coding (RFC 9110
		// 12.5.3), and a gzip body reached the caller still compressed.
		try {
			body = Http.decodeResponseBody(body, headers.get("content-encoding"), context.maxDecompressedSize);
		} catch (error:Dynamic) {
			if (Std.isOfType(error, String)) {
				context.onError('Unsupported content encoding: ${error}', body);
			} else {
				context.onError('Failed to decode response body: ' + Std.string(error), body);
			}
			return;
		}

		context.onProgress(body.length, body.length);

		// The HTTP/1.1 client's contract: a 4xx or 5xx is an error carrying
		// its body. This completed, so a 404 was IO_ERROR over HTTP/1.1 and
		// COMPLETE over HTTP/2.
		if (stream.status >= 400) {
			context.onError('HTTP error ' + stream.status, body);
			return;
		}

		context.onComplete(body);
	}

	/**
	 * `:path` is the path and query together, and is never empty (§8.3.1).
	 * Encoded as the HTTP/1.1 client encodes its request target: a space or a
	 * byte past ASCII left raw is a malformed `:path` to a strict server.
	 * `extra` is a form's fields, after any query the URL has already.
	 */
	private function __target(url:URL, ?extra:String):String {
		var path:String = (url.path != null && url.path.length > 0) ? url.path : "/";
		var query:String = url.query;
		if (extra != null && extra.length > 0) {
			query = (query != null && query.length > 0) ? query + "&" + extra : extra;
		}
		return HttpSyntax.encodeRequestTarget((query != null && query.length > 0) ? '$path?$query' : path);
	}

	private function __body(method:String, data:Dynamic):Null<Bytes> {
		if (method == "HEAD" || method == "GET") {
			return null;
		}
		if (data == null) {
			return null;
		}
		if (Std.isOfType(data, String)) {
			return Bytes.ofString((data : String));
		}
		if (Std.isOfType(data, Bytes)) {
			return (data : Bytes);
		}
		return null;
	}

	/**
	 * Turns the caller's `"Name: value"` list into HPACK fields.
	 *
	 * Field names are lowercased because §8.2.1 requires it, an uppercase
	 * name is malformed, not merely unusual. Connection-specific fields are
	 * dropped for the same reason: HTTP/2 has its own framing and §8.2.2 makes
	 * `Connection`, `Keep-Alive`, `Transfer-Encoding`, `Upgrade` and
	 * `Proxy-Connection` malformed. `Host` is dropped because `:authority`
	 * already carries it.
	 */
	private function __headers(lines:Array<String>, userAgent:Null<String>, contentType:Null<String>, body:Null<Bytes>,
			jarCookie:Null<String>):Array<HpackHeader> {
		var out:Array<HpackHeader> = [];
		var seenContentType:Bool = false;
		var seenUserAgent:Bool = false;
		var seenCookie:Bool = false;
		var seenAcceptEncoding:Bool = false;

		if (lines != null) {
			for (raw in lines) {
				var split:Int = raw.indexOf(":");
				if (split <= 0) {
					continue;
				}

				var name:String = HttpSyntax.sanitizeHeaderName(raw.substr(0, split)).toLowerCase();
				// RFC 9113 8.2.1 makes a CR, LF or NUL in a value a malformed
				// request, which a strict server answers by resetting the stream;
				// stripped here as the HTTP/1.1 client strips them.
				var value:String = StringTools.trim(HttpSyntax.sanitizeHeaderValue(raw.substr(split + 1)));
				if (name.length == 0) {
					continue;
				}

				switch (name) {
					case "connection" | "keep-alive" | "transfer-encoding" | "upgrade" | "proxy-connection" | "host":
						continue;
					case "content-type":
						seenContentType = true;
					case "user-agent":
						seenUserAgent = true;
					case "cookie":
						seenCookie = true;
					case "accept-encoding":
						seenAcceptEncoding = true;
					case _:
				}

				// A credential must not be entered into the dynamic table,
				// where its presence is inferable from later compressed sizes.
				var sensitive:Bool = name == "authorization" || name == "proxy-authorization" || name == "cookie";
				out.push(new HpackHeader(name, value, sensitive));
			}
		}

		// What an earlier hop of this request was handed, unless the caller
		// wrote a Cookie of its own: the HTTP/1.1 client's rule.
		if (jarCookie != null && !seenCookie) {
			out.push(new HpackHeader("cookie", jarCookie, true));
		}
		if (!seenUserAgent && userAgent != null) {
			out.push(new HpackHeader("user-agent", HttpSyntax.sanitizeHeaderValue(userAgent)));
		}
		// What the HTTP/1.1 client and Node ask for unless told otherwise, as
		// URLRequest.requestHeaders says the client does. With none, RFC 9110
		// 12.5.3 lets a server pick any coding, one this client cannot decode
		// among them. Indexed after the first request, so it costs a byte.
		if (!seenAcceptEncoding) {
			out.push(new HpackHeader("accept-encoding", crossbyte._internal.http.headers.AcceptEncoding.IDENTITY));
		}
		if (!seenContentType && contentType != null && body != null) {
			out.push(new HpackHeader("content-type", HttpSyntax.sanitizeHeaderValue(contentType)));
		}
		if (body != null) {
			out.push(new HpackHeader("content-length", Std.string(body.length)));
		}

		return out;
	}

	private static function __defaultSettings():H2Settings {
		var settings = new H2Settings();
		// Nothing here can consume a promised stream, and §8.4 lets us make
		// one a connection error by saying so up front.
		settings.enablePush = false;
		// Said as well as enforced, so a server knows to keep under it rather
		// than have its response refused.
		settings.maxHeaderListSize = H2Connection.DEFAULT_MAX_HEADER_LIST_SIZE;
		return settings;
	}
}

/** One request's stream, answered, and the connection it came on. */
private typedef H2Exchange = {
	var stream:H2Stream;
	var connection:H2Connection;
}
#end
