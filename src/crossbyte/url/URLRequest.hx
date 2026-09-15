package crossbyte.url;

import crossbyte.http.HTTPVersion;

/** Mutable request descriptor consumed by `URLLoader` and related APIs. */
class URLRequest {
	public var contentType:String;

	/**
		**Note**: The value of `contentType` must correspond to
		the type of data in the `data` property. See the note in the
		description of the `contentType` property.
	**/
	public var data:Dynamic;

	/**
		Whether to follow HTTP redirects (`true`) or hand the 3xx response back
		as the result (`false`). The default comes from
		`URLRequestDefaults.followRedirects`, which is `true`.
	**/
	public var followRedirects:Bool;

	/**
		Specifies the HTTP protocol version requested by URLLoader.

		HTTP/1.1 is implemented by CrossByte core. HTTP/2 and HTTP/3 require
		an HTTPBackend registered with HTTPBackendRegistry.
	**/
	public var httpVersion:HTTPVersion;

	/**
		How long, in milliseconds, to wait for a response after the connection is
		established before abandoning the request.

		Taken from `URLRequestDefaults.idleTimeout` when that is greater than
		zero, and 30000 otherwise.
	**/
	public var idleTimeout:Int;

	/**
		Whether the HTTP stack should manage cookies for this request.

		**Nothing reads this yet.** The field is carried on the request and
		initialised from `URLRequestDefaults.manageCookies`, but no cookie jar
		is attached to a request and no `Set-Cookie` is remembered, whatever it
		is set to. Send and read cookies yourself through `requestHeaders` and
		the response headers.
	**/
	public var manageCookies:Bool;

	/**
		The HTTP method. Any of `URLRequestMethod` -- `GET`, `POST`, `PUT`,
		`DELETE`, `HEAD`, `OPTIONS` -- or any other token a server understands,
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

		`User-Agent`, `Host` and `Connection` are not checked that way. The
		client writes all three unconditionally, so a `User-Agent` added here
		goes out as a second header rather than replacing the first -- set the
		`userAgent` property instead.
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
		The `User-Agent` string to send.

		Initialised from `URLRequestDefaults.userAgent`, which is unset. While it
		is null the client sends `CrossByte`.
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
