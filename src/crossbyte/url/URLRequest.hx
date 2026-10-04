package crossbyte.url;

import crossbyte.http.HTTPVersion;

/** Mutable request descriptor consumed by `URLLoader` and related APIs. */
class URLRequest {
	/**
		The `Content-Type` of the body `data` makes, or null, as it starts, for
		the client's choice. Name the type of what `data` holds: nothing checks
		that the two agree.

		Left null, natively a `String` or `haxe.io.Bytes` body goes as
		`application/octet-stream`, a number or `Bool` as
		`text/plain; charset=utf-8`, and a form as
		`application/x-www-form-urlencoded; charset=utf-8`. On Node and in a
		browser a form goes as `application/x-www-form-urlencoded` and any
		other body with no `Content-Type`, which RFC 9110 lets a server read as
		`application/octet-stream`: save that a browser labels a `String`
		`text/plain;charset=UTF-8` itself.
	**/
	public var contentType:String;

	/**
		What the request sends: a body, or a form's fields.

		- A `String` or `haxe.io.Bytes`, a `ByteArray` among them, sent as its
		  `length` bytes, is the body as it is, labelled with `contentType`.
		- A `URLVariables`, or any other object, is a form: its fields go as the
		  query of a GET or HEAD, and as an `application/x-www-form-urlencoded`
		  body otherwise, an array's items each as `name[]`, an object's
		  fields as `name[field]`.
		- A number or a `Bool` is sent as `Std.string` writes it.

		A redirect that turns the request into a GET, a 301, 302 or 303, for
		anything but a HEAD, leaves the body behind. In a browser a GET or
		HEAD carries no body at all: the browser drops it.
	**/
	public var data:Dynamic;

	/**
		Whether to follow HTTP redirects (`true`) or hand the 3xx response back
		as the result (`false`). The default comes from
		`URLRequestDefaults.followRedirects`, which is `true`.

		In a browser a request with this `false` is refused with an
		`IO_ERROR`, and nothing is sent: the browser follows every redirect
		itself and shows a page none of them, so the 3xx could not be handed
		back.
	**/
	public var followRedirects:Bool;

	/**
		Whether a redirect from `https` to plain `http` may be followed.
		Defaults to `false`, and such a redirect then fails the request.

		Following one sends the rest of the exchange, and whatever the
		response holds, in the clear, on the word of the server being left.
		Set this only for a server known to redirect that way.

		In a browser the browser makes the hop, one leaving an `https` page
		for `http` it blocks itself, and a page learns of it only once it has
		been made: the request then fails, with the response unread, but what
		the hop sent has gone in the clear.

		Separately, and always, `Authorization`, `Proxy-Authorization` and a
		`Cookie` set in `requestHeaders` are dropped once a redirect leaves the
		origin the request started at, as browsers, curl and Go drop them.
	**/
	public var followInsecureRedirects:Bool = false;

	/**
		The HTTP version to speak. `HTTP_1_1` unless set.

		HTTP/1.1 and HTTP/1.0 are CrossByte's own client. HTTP/2 is the
		bundled `HTTP2Backend`, registered on first use unless
		`HTTPBackendRegistry.autoRegisterBundled` is turned off, and it speaks
		HTTP/2 or fails rather than falling back to HTTP/1.1. HTTP/3 needs an
		`HTTPBackend` registered with `HTTPBackendRegistry`: none ships.

		On Node a request for anything but HTTP/1.1 is refused with an
		`IO_ERROR`, since Node's http client speaks no other. In a browser the
		browser negotiates the version itself, HTTP/2 or HTTP/3 over
		`https`, where the server offers it, and this is not consulted.
	**/
	public var httpVersion:HTTPVersion;

	/**
		How long, in milliseconds, the request may go with nothing arriving,
		waiting for the response, reading its body, and connecting too but on
		Node, where it starts once the connection is made, before it is
		abandoned with an `IO_ERROR`. Time without progress, not a deadline on
		the whole exchange: a large download that keeps moving is waited for.

		`0` or less is no limit, on every target: the load waits for as long
		as the server takes, until `close()` ends it. It was 30 seconds
		natively and no limit on JavaScript.

		Natively, on the jvm and the interpreter it also bounds the wait for
		a thread to run the load on, when `URLLoader.maxConcurrentLoads`
		loads are already running: a load that has not started by then fails
		with an `IO_ERROR` saying so. It waited for as long as the loads ahead
		of it took, which nothing bounded, a load whose server trickles its
		body holds its thread for as long as the body keeps coming.

		Bytes arriving reset it, so a server sending a byte at a time is
		waited for however long it takes; `headTimeout` and `totalTimeout`
		are what a trickle cannot reset.

		Taken from `URLRequestDefaults.idleTimeout` when that is greater than
		zero, and 30000 otherwise.
	**/
	public var idleTimeout:Int;

	/**
		How long, in milliseconds, the response's head, its status line and
		header fields, after any `1xx`, has to arrive once the request has
		been sent, before the load is abandoned with an `IO_ERROR`. A
		deadline, not an idle timeout: bytes trickling in do not move it, so
		a server sending its head a byte at a time is given up at it rather
		than waited on for as long as it keeps sending. Counted afresh for
		each redirect's request.

		Defaults to 300000, five minutes, as Node's own `fetch` waits for
		headers; `0` or less is no deadline. A long poll whose server holds
		its answer longer than this needs it raised, as it needs
		`idleTimeout` raised.

		Natively, on the jvm, the interpreter and Node, counted from when the
		request has gone, so an upload's time is not counted against it. In a
		browser, which tells a page when an upload ends only by a listener
		that makes a cross-origin request need a preflight, from when the
		request is handed to the browser.
	**/
	public var headTimeout:Int = 300000;

	/**
		How long, in milliseconds, the whole load may take, from `load()` to
		its `COMPLETE`, the wait for a thread, the name's lookup, connecting,
		every redirect, sending the request and reading all of the response,
		before it is abandoned with an `IO_ERROR`. The request is cancelled
		where it stands, as `close()` cancels it.

		Defaults to `0`, no deadline: a download that keeps moving is waited
		for however long it takes, which is right for a large file over a slow
		link. Set one for a server you do not trust: without it a response
		trickled a byte at a time, which resets `idleTimeout` with every byte,
		is waited for for as long as it lasts.

		Natively, on the jvm and the interpreter the loader's runtime ends the
		load, as it delivers the load's events; on Node and in a browser the
		platform's timers do.
	**/
	public var totalTimeout:Int = 0;

	/**
		The most bytes a response body may take as it arrives, before any
		content coding is undone, before the load is abandoned with an
		`IO_ERROR`. A `Content-Length` past it is refused before a byte of the
		body is read; a chunked body, or one ended by the connection closing,
		when it grows past it. Defaults to 64 MB; `0` or less removes the
		limit. `maxDecompressedSize` bounds what it then decodes to.

		It was `Http.MAX_BODY_SIZE` and `MAX_CHUNKED_BODY_SIZE`, process-wide
		statics of the native client that one caller changed for every
		request in the process, and Node had no limit at all.

		Natively, on the jvm, the interpreter and Node, and over HTTP/2. In a
		browser it is held to what the browser says it has received, which
		for a content-coded response may count the bytes once decoded.
	**/
	public var maxBodySize:Int = 64 * 1024 * 1024;

	/**
		How many redirects the load follows before it fails with an
		`IO_ERROR`, "Exceeded the number of allowed redirects". Defaults to
		10; `0` or less follows none, failing at the first, unlike
		`followRedirects = false`, which hands the redirect back as the
		response.

		It was `Http.MAX_REDIRECTS`, a process-wide static of the native
		client. In a browser the browser follows redirects itself, to its own
		limit, 20, by the Fetch standard, and this is not consulted.
	**/
	public var maxRedirects:Int = 10;

	/**
		The most bytes a response's header section may take, its status
		line and header fields, with any `1xx` responses ahead of it, and,
		apart from it, the trailers after a chunked body, before the load is
		abandoned with an `IO_ERROR`. Defaults to 65536, the 64 KB the server
		holds a request's header block to; `0` or less removes the limit.

		It was `Http.MAX_RESPONSE_HEADER_BYTES`, a process-wide static of the
		native client. Over HTTP/2 the section is counted as HPACK counts it,
		and is held to the 64 KB its connection tells the server it takes
		whatever this says, since the connection is shared. On Node it is
		Node's `maxHeaderSize` for the request, which was Node's default of
		16 KB; in a browser the browser keeps its own limit and this is not
		consulted.
	**/
	public var maxResponseHeaderSize:Int = 64 * 1024;

	/**
		Whether to carry cookies across this request's redirects.

		With `followRedirects` on, which it is by default, a sign-in that
		answers `302` with a session cookie was losing it: the cookie was read
		off the wire and dropped with the rest of the response headers when the
		next hop reset them. When this is `true` a `Set-Cookie` is kept and sent
		back on the following hops.

		For the length of one request and no longer. This is not a browser's
		cookie jar: a cookie goes back only to the host that set it, `Secure`
		cookies are withheld from a plaintext hop, and nothing survives the
		request finishing. There is no `Domain` attribute, no path matching and
		no persistence, if you need a session that outlives one call, hold the
		cookie yourself and set it through `requestHeaders`, which also takes
		precedence over this when you do. A host keeps 180 cookies at most, the
		oldest going first, as a browser's do, and one longer than 4,096
		characters is ignored.

		By these rules on every target but the browser. In a browser the
		browser's own jar is used instead, whatever this says, by the
		browser's rules: it keeps cookies between requests too, and a request
		to another origin carries none, since `XMLHttpRequest.withCredentials`
		is left off.

		The default comes from `URLRequestDefaults.manageCookies`.
	**/
	public var manageCookies:Bool;

	/**
		The most bytes a compressed response may decode to before the load is
		abandoned with an `IO_ERROR`. Defaults to 64 MB; `0` or less removes
		the limit.

		What a response sends and what it decodes to are different numbers:
		compression ratios have no ceiling, and a few hundred bytes of gzip or
		Brotli can name gigabytes. The limit used to be an internal setting of
		the native client only.

		In a browser the browser decodes a response before a page sees any of
		it, so the limit is held to the whole body once it has arrived: a load
		past it fails as it does elsewhere, but the browser has spent the
		memory by then. A response from another origin whose
		`Content-Encoding` the server does not expose to the page is not
		checked.
	**/
	public var maxDecompressedSize:Int = 64 * 1024 * 1024;

	/**
		The HTTP method. Any of `URLRequestMethod`, `GET`, `POST`, `PUT`,
		`DELETE`, `HEAD`, `OPTIONS`, or any other token a server understands,
		since this is a plain string and is not validated here.

		@default URLRequestMethod.GET
	**/
	public var method:String;

	/**
		HTTP request headers to append to the request, as `URLRequestHeader`
		objects carrying a name and a value.

		The client supplies `Content-Type`, `Content-Length` and
		`Accept-Encoding` only when you have not: name one here and yours is the
		one sent.

		`User-Agent`, `Host` and `Connection` are not checked that way over
		HTTP/1.1: the client writes all three unconditionally, so a
		`User-Agent` added here goes out as a second header rather than
		replacing the first, set the `userAgent` property instead. Over
		HTTP/2, and on Node, which send one, a `User-Agent` here is the one
		sent.

		In a browser the browser refuses the headers the Fetch standard keeps
		for itself, `Accept-Encoding`, `Content-Length`, `Cookie`, `Host` and
		`Connection` among them, and says so in the console.
	**/
	public var requestHeaders:Array<URLRequestHeader>;

	/**
		The URL to request.

		Encode any character that RFC 1738 calls unsafe, or that is reserved in
		this URL scheme and not being used for its reserved purpose: `"%25"` for
		`%` and `"%23"` for `#`, as in
		`"http://www.example.com/orderForm.cfm?item=%23B-3&discount=50%25"`.

		An IPv6 literal goes in brackets, as in
		`"http://[2001:db8:ccc3:ffff:0:444d:555e:666f]:8080/test"`.
	**/
	public var url:String;

	/**
		For `https`: whether the server's certificate is checked, that it
		chains to an authority this request trusts, and that it names the host.
		On by default.

		Turn it off only for a development server presenting a self-signed
		certificate, and prefer `certAuthority` even then: with it off the
		traffic is still encrypted, but anyone able to sit between the two ends
		can present a certificate of their own and read all of it. In a browser
		the browser decides, and this is not consulted; on neko, whose TLS
		checks the server whatever it is told, it cannot be turned off, and a
		request with it off is checked all the same.
	**/
	public var verifyCert:Bool = true;

	#if !(js && !nodejs)
	/**
		For `https`: the authority this request trusts, in place of the
		system's, a private CA's certificate, or a server's own self-signed
		one, to check a server the system does not know without turning
		`verifyCert` off. `null`, the default, trusts the system's store.

		It used to be reachable only as a process-wide static, through
		`@:privateAccess`, for every request at once.
	**/
	public var certAuthority:crossbyte.net.Certificate = null;

	/**
		For `https`: the certificate this request presents to a server that
		asks for one, mutual TLS, with `clientKey`. Presented only to the
		origin the request was made to: a redirect that leaves it leaves the
		certificate behind, as it leaves `Authorization`.
	**/
	public var clientCertificate:crossbyte.net.Certificate = null;

	/** The private key belonging to `clientCertificate`. **/
	public var clientKey:crossbyte.net.Key = null;
	#end

	/**
		For `https`: the public keys the server's certificate may carry, each
		the base64 SHA-256 of its SubjectPublicKeyInfo, RFC 7469's
		`pin-sha256`: with or without a `sha256/` in front. When set, a
		server whose key is not one of these fails the request, on every hop,
		after the handshake and before anything is sent. `null` or empty pins
		nothing.

		A pin names the key, so it survives a certificate renewed over the same
		key; list the next key too before rotating to it. `openssl x509 -pubkey
		-noout -in cert.pem | openssl pkey -pubin -outform der | openssl dgst
		-sha256 -binary | openssl base64` gives one. Natively, on the jvm and
		on Node; elsewhere a pinned request is refused rather than sent
		unchecked.
	**/
	public var pinnedPublicKeys:Array<String> = null;

	/**
		The `User-Agent` string to send.

		Initialised from `URLRequestDefaults.userAgent`, which is unset. While it
		is null the client sends `CrossByte`, on every target but the browser.

		In a browser the browser has the last word: unset, it sends its own,
		and one set here it sends or refuses as it sees fit, Firefox sends
		it, Chrome and Safari keep their own and say so in the console.
	**/
	public var userAgent:String;

	/**
		Creates a URLRequest object.

		@param url The URL to be requested. You can set the URL later by using
			   the `url` property.
	**/
	public function new(url:String = null) {
		if (url != null) {
			this.url = url;
		}

		contentType = null;
		followRedirects = URLRequestDefaults.followRedirects;

		if (URLRequestDefaults.idleTimeout > 0) {
			idleTimeout = URLRequestDefaults.idleTimeout;
		} else {
			idleTimeout = 30000;
		}

		manageCookies = URLRequestDefaults.manageCookies;
		method = URLRequestMethod.GET;
		requestHeaders = [];
		httpVersion = HTTPVersion.HTTP_1_1;
		userAgent = URLRequestDefaults.userAgent;
	}
}
