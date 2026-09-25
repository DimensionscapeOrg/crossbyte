package crossbyte.http;

// Not built for JavaScript. This drives HTTP/2 framing over a raw socket, and
// neither a browser nor Node exposes one through `FlexSocket`; a page reaches
// HTTP/2 through fetch, which negotiates it below the API surface.
#if !js
import crossbyte._internal.http.h2.H2ClientSession;
import crossbyte._internal.http.h2.H2Connection;
import crossbyte._internal.http.h2.H2ConnectionPool;
import crossbyte._internal.http.h2.H2ConnectionError;
import crossbyte._internal.http.h2.H2ErrorCode;
import crossbyte._internal.http.h2.H2Settings;
import crossbyte._internal.http.h2.H2Stream;
import crossbyte._internal.http.h2.hpack.HpackHeader;
import crossbyte._internal.socket.FlexSocket;
import crossbyte.url.URL;
import haxe.io.Bytes;

/**
 * An HTTP/2 backend for `HTTPBackendRegistry`.
 *
 * Not registered by default. HTTP/2 is opt-in so that a program which never
 * asks for it does not link the framing layer, and so that registering a
 * different implementation stays possible:
 *
 * ```haxe
 * HTTPBackendRegistry.register(new HTTP2Backend());
 * ```
 *
 * `http://` uses prior-knowledge h2c: the client opens with the connection
 * preface and assumes the server speaks HTTP/2. That is the only cleartext
 * mode left -- RFC 9113 §3.1 retired the `Upgrade: h2c` handshake -- and it
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
 * Still missing: cancellation. `HTTPBackend.load()` returns `Void`, so an
 * abandoned request has no handle through which to reset its stream, and the
 * slot stays held until the response arrives or the timeout fires.
 */
class HTTP2Backend implements HTTPBackend {
	/**
	 * Whether this target can carry an HTTP/2 request at all.
	 *
	 * False on eval, and not for want of an implementation: that target raises
	 * socket errors as native exceptions no Haxe `catch` can see, so a peer
	 * reset kills the reader thread a pooled connection parks on -- or, on a
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

		var url:URL = new URL(context.url);
		var secure:Bool = url.scheme == "https";
		var port:Int = url.port != null ? url.port : (secure ? 443 : 80);
		var scheme:String = secure ? "https" : "http";
		var origin:String = '$scheme://${url.host}:$port';

		if (secure && !FlexSocket.alpnSupported) {
			context.onError("HTTP/2 over TLS needs ALPN, which this target does not support");
			return;
		}

		var session:H2ClientSession = null;

		try {
			var authority:String = (port == (secure ? 443 : 80)) ? url.host : '${url.host}:$port';
			var body:Null<Bytes> = __body(context);
			var timeout:Float = context.timeout > 0 ? context.timeout / 1000 : 30;

			// Sent once more, on whatever session the pool hands over next,
			// when the first refuses the stream before anything goes out: it
			// was retired as idle a moment after being handed over, or its
			// peer has said GOAWAY. REFUSED_STREAM promises the request was
			// not processed (RFC 9113, 8.7), so sending it again is safe.
			var stream:H2Stream = null;
			var refused:Int = 0;
			while (stream == null) {
				session = H2ConnectionPool.acquire(origin, () -> __open(origin, url.host, port, secure, context));
				try {
					stream = session.execute(context.method, scheme, authority, __target(url), __headers(context, body), body, timeout,
						context.cancelToken);
				} catch (e:H2ConnectionError) {
					if (e.code != H2ErrorCode.REFUSED_STREAM || refused > 0) {
						throw e;
					}
					refused++;
					H2ConnectionPool.discard(session);
					session = null;
				}
			}
			__report(context, stream, session.connection);

			// A session that died mid-request must not be handed to the next
			// caller; one that merely finished a stream stays pooled, which is
			// the whole point.
			if (session.dead) {
				H2ConnectionPool.discard(session);
			}
		} catch (e:H2ConnectionError) {
			if (session != null) {
				H2ConnectionPool.discard(session);
			}
			context.onError("HTTP/2 connection error: " + e.message);
		} catch (e:Dynamic) {
			if (session != null) {
				H2ConnectionPool.discard(session);
			}
			context.onError("HTTP/2 request failed: " + Std.string(e));
		}
	}

	/**
	 * Opens a connection for the pool.
	 *
	 * The socket deliberately has no read timeout. A pooled connection is idle
	 * between requests by design, and a deadline on the reader would tear down
	 * a perfectly good connection for the crime of waiting; per-request
	 * deadlines live on the stream instead.
	 */
	private function __open(origin:String, host:String, port:Int, secure:Bool, context:HTTPRequestContext):H2ClientSession {
		var socket:FlexSocket = new FlexSocket(secure);

		if (secure) {
			// Only h2 is offered. Accepting http/1.1 here would hand back a
			// connection this backend cannot speak.
			socket.setALPN(["h2"]);
		}

		socket.connect(host, port);

		if (secure && socket.getALPN() != "h2") {
			try {
				socket.close();
			} catch (_:Dynamic) {}
			throw new H2ConnectionError(H2ErrorCode.PROTOCOL_ERROR, "Server did not negotiate h2 over ALPN");
		}

		return new H2ClientSession(origin, socket, new H2Connection(socket.input, socket.output, settings));
	}

	private function __report(context:HTTPRequestContext, stream:H2Stream, connection:H2Connection):Void {
		if (context.cancelToken != null && context.cancelToken.cancelled && stream.status < 0) {
			// Reported as cancellation rather than as the reset it produced:
			// the caller asked for this, and "stream reset" would read as the
			// peer having done something.
			context.onError("Request cancelled");
			return;
		}

		if (stream.resetCode != null && stream.status < 0) {
			var code:H2ErrorCode = stream.resetCode;
			context.onError('Stream reset by peer: ${code.toString()}');
			return;
		}

		if (stream.status < 0 && !stream.endOfStream) {
			// The peer hung up before the response headers arrived. Distinct
			// from a malformed message, and the distinction is what tells a
			// caller whether retrying is worth anything.
			context.onError("Connection closed before the response headers arrived");
			return;
		}

		if (stream.status < 0) {
			// §8.3 requires exactly one :status on a response, so its absence
			// is a malformed message rather than a missing default.
			context.onError("Response had no :status pseudo-header");
			return;
		}

		context.onStatus(stream.status);

		var headers:Map<String, String> = new Map();
		for (header in stream.headers) {
			if (headers.exists(header.name)) {
				// The same joining rule the HTTP/1 client uses, so a caller
				// sees one shape regardless of which version served it.
				var joiner:String = header.name == "set-cookie" ? "\n" : ", ";
				headers.set(header.name, headers.get(header.name) + joiner + header.value);
			} else {
				headers.set(header.name, header.value);
			}
		}
		context.onHeaders(headers);

		var body:Bytes = stream.takeBody();
		context.onProgress(body.length, body.length);
		context.onComplete(body);
	}

	/** `:path` is the path and query together, and is never empty (§8.3.1). */
	private function __target(url:URL):String {
		var path:String = (url.path != null && url.path.length > 0) ? url.path : "/";
		var query:String = url.query;
		return (query != null && query.length > 0) ? '$path?$query' : path;
	}

	private function __body(context:HTTPRequestContext):Null<Bytes> {
		if (context.method == "HEAD" || context.method == "GET") {
			return null;
		}
		if (context.data == null) {
			return null;
		}
		if (Std.isOfType(context.data, String)) {
			return Bytes.ofString((context.data : String));
		}
		if (Std.isOfType(context.data, Bytes)) {
			return (context.data : Bytes);
		}
		return null;
	}

	/**
	 * Turns the caller's `"Name: value"` list into HPACK fields.
	 *
	 * Field names are lowercased because §8.2.1 requires it -- an uppercase
	 * name is malformed, not merely unusual. Connection-specific fields are
	 * dropped for the same reason: HTTP/2 has its own framing and §8.2.2 makes
	 * `Connection`, `Keep-Alive`, `Transfer-Encoding`, `Upgrade` and
	 * `Proxy-Connection` malformed. `Host` is dropped because `:authority`
	 * already carries it.
	 */
	private function __headers(context:HTTPRequestContext, body:Null<Bytes>):Array<HpackHeader> {
		var out:Array<HpackHeader> = [];
		var seenContentType:Bool = false;
		var seenUserAgent:Bool = false;

		if (context.headers != null) {
			for (raw in context.headers) {
				var split:Int = raw.indexOf(":");
				if (split <= 0) {
					continue;
				}

				var name:String = StringTools.trim(raw.substr(0, split)).toLowerCase();
				var value:String = StringTools.trim(raw.substr(split + 1));

				switch (name) {
					case "connection" | "keep-alive" | "transfer-encoding" | "upgrade" | "proxy-connection" | "host":
						continue;
					case "content-type":
						seenContentType = true;
					case "user-agent":
						seenUserAgent = true;
					case _:
				}

				// A credential must not be entered into the dynamic table,
				// where its presence is inferable from later compressed sizes.
				var sensitive:Bool = name == "authorization" || name == "proxy-authorization" || name == "cookie";
				out.push(new HpackHeader(name, value, sensitive));
			}
		}

		if (!seenUserAgent && context.userAgent != null) {
			out.push(new HpackHeader("user-agent", context.userAgent));
		}
		if (!seenContentType && context.contentType != null && body != null) {
			out.push(new HpackHeader("content-type", context.contentType));
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
		return settings;
	}
}
#end
