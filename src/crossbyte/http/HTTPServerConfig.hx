package crossbyte.http;

import crossbyte.net.RateLimiter;
// Not built for the browser: it configures the HTTP server, which cannot run in a page.
#if !(js && !nodejs)

import crossbyte.io.File;
import crossbyte.url.URLRequestHeader;
import crossbyte.http.config.RewriteRule;
import crossbyte.errors.ArgumentError;

/** Configuration object for `HTTPServer` routing, limits, headers, and PHP integration. */
class HTTPServerConfig {
	/**
		Requests a minute a single client may make before being refused.

		Roomy on purpose: this is per remote address and counted per request,
		so one visitor opening one page spends a dozen of it at once.
	**/
	public static inline var DEFAULT_REQUESTS_PER_MINUTE:Int = 240;

	/**
		Bytes a single connection may have waiting to go out before it is cut.

		Eight megabytes: far above what serving a file costs, since anything
		over 256 KB streams in bounded bursts, and far below what a few stalled
		peers cost a process that never reclaims any of it.
	**/
	public static inline var DEFAULT_MAX_OUTPUT_BUFFER:Int = 8 * 1024 * 1024;

	/** The request body a server accepts by default: one megabyte. **/
	public static inline var DEFAULT_MAX_REQUEST_BODY:Int = 1024 * 1024;

	/** What one HTTP/2 connection holds of request bodies by default: four megabytes. **/
	public static inline var DEFAULT_HTTP2_REQUEST_BODY_BUFFER:Int = 4 * 1024 * 1024;

	/**
		Bytes a request body may reach, on the wire and once decoded, over
		HTTP/1.1 and HTTP/2 alike. A larger one is answered `413 Payload Too
		Large` as soon as a `Content-Length` says so, before any of the body
		is read, on either protocol. Defaults to `DEFAULT_MAX_REQUEST_BODY`.

		The limit counts the body alone; the header block has its own. Raise
		it for uploads; the whole body is held in memory before middleware
		runs.
		An HTTP/1.1 connection reads one request at a time, so it holds one
		such body; an HTTP/2 connection carries many at once, and
		`http2MaxRequestBodyBuffer` is what all of them may hold together.
	**/
	public var maxRequestBodySize:Int = DEFAULT_MAX_REQUEST_BODY;

	/**
		Bytes of request body one HTTP/2 connection holds at once, across
		every stream whose body is still arriving, or `0` and below for no
		limit. Defaults to `DEFAULT_HTTP2_REQUEST_BODY_BUFFER`, and is never
		less than `maxRequestBodySize`: one body of the largest size the
		server takes always fits.

		HTTP/1.1 reads one request at a time, so a connection holds one body.
		HTTP/2 carries up to 128 requests at once, and with each body allowed
		to grow to `maxRequestBodySize`, a client uploading slowly on every
		stream would make the server hold 128 of them (128 MB at the
		defaults, from one connection, and with `requestTimeout` at `0` for
		as long as it liked), and a client ignoring its flow-control windows
		could send whatever it pleased.

		Held to it with HTTP/2's own flow control. The server opens its
		windows only as far as this has room, so a client that keeps to them
		never sends more, and one that does not is refused with
		`FLOW_CONTROL_ERROR`. The room goes to the oldest stream first. Every
		stream may send its first window unasked, so that window is made
		small enough for all 128 streams' to fit with one whole body besides:
		the largest of 64, 32 or 16 KB that does (16 KB at the defaults, and
		64 KB, the protocol's own, from about 9 MB up with the default
		`maxRequestBodySize`). Past it, a stream's window is opened as its
		HEADERS arrive, from what is left once those first windows and every
		older stream's remaining body (its `Content-Length`, or else
		`maxRequestBodySize`) are set aside, up to a megabyte at a time.
		Uploads that fit together go together; ones
		that do not go a few at a time, the rest waiting for window, and
		none is turned away for it. What a client sees:

		- a body larger than the first window waits a round trip for the
		  rest of its window, and then one round trip per megabyte;
		- a stream waits for window while the bodies ahead of it arrive, its
		  `requestTimeout` still counted from its HEADERS. One left waiting
		  with no body arriving and none finished on its connection for 30
		  seconds is reset with `REFUSED_STREAM`, which tells the client the
		  request was not processed and may be sent again;
		- the header sections of requests whose bodies are still to come are
		  held to a quarter of this (a megabyte at the default, by HPACK's
		  count of them), since flow control cannot hold a HEADERS back and
		  HPACK makes a large one cheap to send. A stream whose section would
		  go past it is reset with `REFUSED_STREAM` the same way;
		- nothing is answered `413` for it: that is `maxRequestBodySize`'s.

		A body counts from its first byte until it has all arrived and is
		handed to the application, or is refused. What the application then
		holds while it answers is its own, as for an HTTP/1.1 request.
	**/
	public var http2MaxRequestBodyBuffer:Int = DEFAULT_HTTP2_REQUEST_BODY_BUFFER;

	/**
		What this server compresses, and how hard: text of a kilobyte or more,
		for a client that asks, in a response that is not an error. See
		`HTTPCompression`; set `compression.enabled = false` to send everything
		as it is.
	**/
	public var compression:HTTPCompression = new HTTPCompression();

	/**
		Bytes of small static files kept in memory, so a file read once is
		served from memory while its size and modification time stay as they
		were (they are read on every request, which is how a change is seen).
		Defaults to 16 MB; `0` keeps nothing. Files over 256 KB, which are
		streamed from disk, are not kept, and neither is a file modified in the
		last two seconds: a modification time is often whole seconds, so a
		file written twice within one, at the same size, would otherwise be
		served as it first was.
	**/
	public var fileCacheSize(default, set):Int = 16 * 1024 * 1024;

	// The kept files: shared by the servers this configuration starts, which
	// may run on several runtimes' threads, and locked per call.
	@:noCompletion private final __keptFiles:crossbyte._internal.http.KeptBodies = new crossbyte._internal.http.KeptBodies(16 * 1024 * 1024);

	@:noCompletion private function set_fileCacheSize(value:Int):Int {
		__keptFiles.budget = value;
		return fileCacheSize = value;
	}

	/**
		Asked, with the request's method, path and headers, whether a request
		carrying `Expect: 100-continue` may send its body. Return `true` to let
		it; to refuse, answer with `handler.respond()` (a `401`, say) and
		return `false`. A `false` with no answer is answered `417`.

		This is the moment authentication belongs in for such a request: an
		unauthenticated upload is refused before it is sent. Left `null`, a
		request within `maxRequestBodySize` is told to go ahead.

		Over HTTP/2 too, when the request's headers arrive: a refusal answers
		its stream and resets it, which asks the client not to send the body,
		and going ahead sends an interim `100`.
	**/
	public var onExpectContinue:(handler:HTTPRequestHandler) -> Bool = null;

	/**
		The address to listen on. Defaults to `127.0.0.1`, which only this
		machine can reach.

		Set it to `0.0.0.0` (or one interface's address) to serve other
		machines, which a deployed server, and any server in a container,
		needs. The default is the safer of the two mistakes: a server that
		should be public and is not fails its first request from outside,
		loudly, and is one line from fixed, while a development server or an
		admin endpoint that should be private and is not keeps working and
		shows nothing wrong.
	**/
	public var address:String;
	public var port:UInt;

	/**
		The directory static files are served from, or `null` to serve none.

		`null` is the default. A request that no middleware answers is then
		`404 Not Found` without the filesystem being consulted, which is what
		a server that only has routes wants.

		Nothing is served by default, so a server with only routes does not
		answer other paths from an account's home or storage directory
		(`GET /.ssh/id_rsa`, or the files `Store` keeps). Name the directory
		to serve:

		```haxe
		config.rootDirectory = new File("/srv/www");
		```

		PHP, `rewrites`, and `tryFiles` entries past the first two all resolve
		files under this directory, so `validate` refuses them without one.
	**/
	public var rootDirectory:File;

	/**
		Whether a static file whose path has a segment starting with `.` may be
		served. Defaults to `false`.

		Dotfiles are where secrets live: `.env`, `.git/`, `.htpasswd`,
		`.ssh/`. A document root that is a checkout, or that a deploy copied a
		whole project into, holds them without anyone having decided to publish
		them. With this off, a request naming one is answered `404`, the same as
		a file that is not there, so the answer does not confirm it exists.

		`/.well-known/` is served either way. RFC 8615 reserves it for exactly
		the files a site is meant to publish (an ACME challenge, a
		`security.txt`), and refusing it would break certificate renewal.

		This decides static files only. Middleware and routes see every path.
	**/
	public var serveDotFiles:Bool = false;

	public var directoryIndex:Array<String>;

	/**
		A page sent as the body of every error this server answers by itself,
		in place of the line of plain text each carries, with the status it
		would have had: a file that is not there (`404`), one kept back
		(`403`), a method the files are not served to (`405`), a request
		refused, limited or late, and a server error. `null`, the default,
		keeps the text. An answer middleware or a route gives with `respond()`
		is its own, and is never replaced.

		Its `Content-Type` is the one its extension names, as for any file
		served. It is read when first needed and kept, so a change to it is
		seen after a restart, and `validate` refuses one that is not there.
	**/
	public var errorDocument:File;

	// The error document's bytes, read once: see errorDocument.
	@:noCompletion private var __errorPage:Null<ErrorPage> = null;

	/**
		When not empty, the only files under `rootDirectory` this server serves
		or runs: a request that ends at any other is answered `403 Forbidden`.
		Empty by default, which keeps nothing back.

		Held as `blacklist` is, to the file a request resolves to, whatever
		the method and however it got there. A precompressed `.br` or `.gz`
		sibling is sent in a file's place only if it is listed too.
	**/
	public var whitelist:Array<String>;

	/**
		Files under `rootDirectory` this server never serves or runs: a request
		that ends at one is answered `403 Forbidden`. Empty by default.

		Each entry is a file's `File.nativePath`, compared whole, so build it
		from the root: `config.rootDirectory.resolvePath("admin.php").nativePath`.
		It is checked against the file a request resolves to (the one it
		names, a directory's index, or a rewrite's target) for every method,
		so a blacklisted script is refused to a `POST`, and to a rewrite with
		the `PHP` flag, as it is to a `GET`.

		This decides what the filesystem answers with. Middleware and routes
		run first and see every path.
	**/
	public var blacklist:Array<String>;
	public var customHeaders:Array<URLRequestHeader>;
	public var middleware:Array<Middleware>;

	/**
		Called when a middleware or route throws, or passes an error to
		`next()`, with the request and what was thrown or passed.

		The hook may answer the request itself (a JSON error body, say)
		with `handler.respond()`, and must do so before it returns. If it does
		not, the server answers `500`, or the status an `Int` error names; the
		client is told the status and never the error's text. A response
		whose head has already gone out, cut short by a write that threw, is
		answered by neither: no status can follow a head, so the response is
		given up (the connection closed under HTTP/1.1, the stream reset
		under HTTP/2), which the client can tell from the length it was
		promised.

		What the server's own handling throws before any middleware runs (the
		rate limiter's key, say), or on a server with no middleware, is
		answered `500` without the hook, over either protocol.

		Whatever it does, an error that is not an `Int` is first logged at
		ERROR with the method, the path and, where the target keeps one, the
		stack.
	**/
	public var onError:(handler:HTTPRequestHandler, error:Dynamic) -> Void = null;
	/**
		Refuses a request with `429` once its client has spent its budget,
		saying in `Retry-After` how many seconds until it may try again.

		Keyed by `rateLimitKey` (the client's address unless that says
		otherwise), and consulted for **every** request, not every connection.
		Leaving it out of the constructor does not leave the server unlimited:
		one is fitted, allowing `DEFAULT_REQUESTS_PER_MINUTE`, which is a
		visitor's page load with room to spare rather than `RateLimiter`'s own
		default of ten, which is smaller than one page.

		Pass a limiter of your own to say something different.

		A server spread over `runtimes` asks it from each runtime's thread,
		and a `RateLimiter` is not safe to call from two at once, so the
		server puts a lock in front of it as it starts: from then on this is
		a limiter that passes each call to the one you gave, one at a time,
		keeping one budget per client across every runtime. Call it through
		this property from code of your own on other threads, not through the
		limiter you passed.
	**/
	public var rateLimiter:RateLimiter;

	/**
		The key `rateLimiter` counts a request under, or null to leave the
		request unlimited. Asked once the request's headers are read, so it can
		look at them as well as at `handler.remoteAddress`.

		Unset, a request is keyed by `RateLimiter.addressKey(remoteAddress)`: an
		IPv4 address as it is and an IPv6 one by its /64, which is what one
		subscriber is given, so a client stepping through its own /64 does
		not get a fresh budget for every request.

		Behind a proxy every request arrives from the proxy's address, so key on
		the address it forwards, but only when the request did come through
		it, since anyone can send the header:

		```haxe
		config.rateLimitKey = handler -> {
			var forwarded = handler.remoteAddress == "10.0.0.2" ? handler.getHeader("x-real-ip") : null;
			RateLimiter.addressKey(forwarded != null ? forwarded : handler.remoteAddress);
		};
		```

		A login route limiting attempts per account rather than per client can
		use the same limiter, or one of its own, from middleware.
	**/
	public var rateLimitKey:(handler:HTTPRequestHandler) -> Null<String> = null;
	public var corsEnabled:Bool;

	/**
		Origins a cross-origin page may read responses from, such as
		`https://app.example.com`, or `["*"]` (the default) for any.

		`"*"` is answered as `*`, never by echoing the request's `Origin`, and
		cannot be combined with `corsAllowCredentials`: `validate` refuses the
		pair, since it would let every site read what a signed-in user can.
	**/
	public var corsAllowedOrigins:Array<String>;

	/**
		Methods a preflight approves. The answer is this list whatever the
		preflight asked for; a browser then refuses a method not on it.
	**/
	public var corsAllowedMethods:Array<String>;

	/**
		Request headers a preflight approves, such as `Authorization`. The
		answer is this list whatever the preflight asked for.
	**/
	public var corsAllowedHeaders:Array<String>;
	public var corsMaxAge:Int;

	/**
		Connections the server holds at once. Past it, a new connection is
		closed as it is accepted, and logged. Defaults to 10,000.

		A held connection costs a few kilobytes (under 2 KB for a bare one,
		around 6 KB as a WebSocket, measured on native), so the default is
		tens of megabytes at most, while a few dozen browser users at six
		connections each come nowhere near it.
	**/
	public var maxConnections:Int;
	public var backlog:Int;

	/**
		The runtimes the server's connections are served on, so that it
		uses more than one core; `null`, the default, serves them all on the
		runtime that makes the server. See `ServerSocket.runtimes`, which this
		sets as the server starts: the listener stays on its runtime, and
		each connection it accepts is handed to one of these, where all of it
		(its TLS handshake, its requests, HTTP/1.1 or HTTP/2, its timeouts)
		is served for its whole life. Make them with
		`CrossByte.make(POLL)`, or set `runtimeCount` instead.

		Every runtime then runs the code this configuration names, at once:
		`middleware`, routes, `onError`, `onExpectContinue` and `rateLimitKey`
		are called on whichever runtime holds the request, so what they share
		between requests (a cache, a session table, a connection pool)
		must be thread-safe, or kept per runtime (`CrossByte.current()` says
		which). A `Router` is read-only once its routes are added, and is
		safe to share once they are. What the server itself shares is made
		safe: `maxConnections` counts every runtime's connections together,
		`rateLimiter` keeps one budget per client across them (see there),
		the metrics registry and `compression`'s cache take locks of their
		own, and with PHP each runtime has a bridge of its own to the same
		backend.

		`HTTPServer.drain()`, `close()` and `stopAccepting()` cover every
		runtime's connections. On Node, whose runtimes share one thread, a
		server with runtimes is refused.
	**/
	public var runtimes:Array<crossbyte.core.CrossByte> = null;

	/**
		How many runtimes the server makes to serve its connections on, as
		`runtimes` does with given ones: `ServerSocket.runtimeCount`. `0`, the
		default, makes none; `runtimes`, when set, wins. Made as the server
		starts, POLL loops each, and exited once `HTTPServer.drain()` has
		finished.
	**/
	public var runtimeCount:Int = 0;

	/**
		Whether each runtime listens for itself, the kernel sharing
		connections out, rather than the server's runtime handing them on:
		`ServerSocket.reusePort`, Linux only, refused elsewhere. Needs
		`runtimes` or `runtimeCount`.
	**/
	public var reusePort:Bool = false;
	public var phpEnabled:Bool;
	public var phpAddress:String;
	public var phpPort:Int;
	public var phpCGIPath:String;
	public var phpINIPath:String;
	public var phpMode:Int;

	/**
		Seconds a single PHP request may take before the server gives up on it
		and answers `504 Gateway Timeout`. `0` disables the deadline.

		Defaults to 30. Without a deadline, a php-fpm that accepted a
		connection and then said nothing would hold the runtime for as long
		as it liked, and since a CrossByte runtime serves all of its
		connections from one tick, an unresponsive backend would stop the
		server for every client at once.

		Note that `requestTimeout` does not cover this window: it stops the
		moment a request has been read, on the principle that the time a
		response takes is the server's own. This is that principle's other
		half: the server's own time still has a limit.
	**/
	public var phpTimeout:Float;

	/**
		The most bytes a PHP script's response may take (its CGI header
		block and its body together, as the script writes them) before the
		server gives up on it and answers `502 Bad Gateway`. Defaults to
		8 MiB; `0` or less removes the limit. Raise it for a script that
		serves larger files, or serve those files as static ones.

		Without it, a script, or a backend that is not running PHP at all,
		would choose how much of the server's memory each request takes: a
		response is held whole before it is answered, twice over for a
		moment as the body is taken from it.

		The header block has limits of its own whatever this says: 64 KiB
		and 100 lines, past which the response fails the same way.
	**/
	public var phpMaxResponseSize:Int = 8 * 1024 * 1024;

	/**
		How many requests a runtime has with its PHP backend at once, at
		most, each holding a connection to it. Defaults to 64; `0` or less
		removes the limit.

		More wait their turn, in the order they came, each still under
		`phpTimeout` (`504 Gateway Timeout` if it passes while waiting), and
		past 1,024 waiting a request is refused at once: the PHP bridge
		fails it as busy. Without the limit every request for a script would
		open its own connection to the backend however many were already
		waiting on it, and the `php-cgi -b` that `phpMode` 1 launches answers
		one at a time.
	**/
	public var phpMaxExchanges:Int = 64;
	public var corsAllowCredentials:Bool;
	/**
		Paths tried, in order, when resolving a request.

		The order the server actually follows is fixed at the front and only
		free at the back, so the list is required to be spelled the way it
		runs: see `validate`, which rejects anything else rather than
		silently reordering it:

		1. `$uri`: the request path as a file
		2. `$uri/`: the request path as a directory, resolved through
		   `directoryIndex`
		3. every rule in `rewrites`, in order
		4. the remaining entries here, in order

		The consequence worth knowing is that **an existing file wins over a
		rewrite** unless the rule asks about files. For a request that names
		a file or a directory with an index, every rule without a
		`FileExists` or `DirExists` condition is passed over and the file is
		served: Apache's `RewriteCond !-f` idiom applied for you rather than
		written out. A rule with one of those conditions asks for itself and
		is tried in its place even then, so to have a rule win over a file
		that exists, give it a `FileExists` condition without `negate`: it
		then applies to exactly the requests that name an existing file.
		It is not nginx's model, where `try_files` runs after the rewrite
		phase in the order written.

		Defaults to `["$uri", "$uri/"]`: the request path as a file, then as a
		directory to be resolved to its index. A path matching neither answers
		404.

		It does not end with `"/index.html"`, a single-page application
		fallback, by default. The two failure modes are not comparable. An
		SPA that wants the fallback and does not have it breaks on the first
		refresh of a deep link, which is loud, immediate, and one entry from
		fixed. A static site that does not want it and has it answers **200
		with the root index for every path that does not exist**: a broken
		link looks alive to a crawler, a monitor sees a healthy page, and a
		cache stores the wrong body under the missing URL. Silent, and
		indistinguishable from working.

		Add `"/index.html"` back as a final entry for an SPA:

		```haxe
		config.tryFiles = ["$uri", "$uri/", "/index.html"];
		```

		In an entry after the first two, `$uri` is the request path, so
		`"$uri.html"` serves `/about` from `about.html`, the way clean URLs
		are served.
	**/
	public var tryFiles:Array<String>;

	/**
		Rewrite rules, applied in order to a request that names no existing
		file or directory index. One that does is tried only against the rules
		that ask about files (a `FileExists` or `DirExists` condition), and
		served its file when none of them applies; see `tryFiles`.

		Empty by default. A rule carrying the `PHP` flag needs `phpEnabled`,
		and a `PHP` rewrite without a bridge answers 500 rather than reaching
		one.
	**/
	public var rewrites:Array<RewriteRule>;

	/**
		Seconds a request has to arrive in full (request line, headers and
		body together). `0` disables the deadline. Defaults to 60.

		The rate limiter cannot cover this window: it runs once a complete
		header block exists, so without the deadline a client trickling one
		byte at a time would never be rate limited and would hold a
		connection slot for as long as it cared to, and tying up every one of
		`maxConnections` slots this way would cost an attacker almost
		nothing. A connection that misses the deadline is answered with
		`408 Request Timeout` and closed.

		Over HTTP/2 each request has its own deadline, counted from its
		HEADERS, and nothing sent after them moves it: a request whose body
		has not all arrived by then is answered `408` on its stream, which is
		then reset, and the connection carries its other requests on. A header
		block still unfinished then closes the connection, since nothing else
		on it can be read until the block ends.

		Enforced by the owning server's sweep, which runs a few times a
		second, so the deadline is precise to roughly a quarter second.

		Neither this at `0` nor `keepAliveTimeout` at `0` lifts the deadline
		a response keeps of its own while it goes out: one whose client takes
		none of it for 30 seconds is given up (a file the server sends in
		bursts, a body written whole and waiting on an HTTP/2 stream's window,
		or bytes in a socket its client stopped reading), the connection
		closed under HTTP/1.1, and under HTTP/2 the stream reset, or the
		connection closed when its own window is what holds them.
	**/
	public var requestTimeout:Float;

	/**
		Offer HTTP/2 on this listener, alongside HTTP/1.1.

		Opt-in but not exclusive: each connection is served as whichever
		version it turns out to be speaking. Over TLS that is settled by ALPN,
		which the listener advertises as `h2` and `http/1.1`. Over cleartext
		there is nothing to negotiate (RFC 9113 3.1 retired the
		`Upgrade: h2c` handshake, leaving prior knowledge), so the first bytes
		decide: an HTTP/2 client opens with a connection preface no HTTP/1.1
		client would send.

		Leaving it off keeps the listener HTTP/1.1 only, and costs nothing.
	**/
	public var http2Enabled:Bool;

	/**
		Streams a peer may abandon before their response, within
		`http2ResetWindowSeconds`, before the connection is closed. Negative
		disables the check.

		This is the Rapid Reset defence (CVE-2023-44487). The concurrency limit
		does not provide one, because a reset stream is a closed stream and
		frees its slot immediately, so a peer opening and instantly resetting
		streams never approaches that limit while still making the server route
		and dispatch every one of them.

		The default is generous enough that ordinary cancellation never reaches
		it; lower it only if you are being abused, and raise it only if a
		legitimate client genuinely cancels in bursts.
	**/
	public var http2MaxResetStreams:Int;

	/**
		Seconds the `http2MaxResetStreams` budget is measured over. Defaults
		to 30.

		The same window measures a second budget: the PING and SETTINGS frames
		a peer may make the server answer, a hundred in a window, past which
		the connection is closed with `ENHANCE_YOUR_CALM` (the ping and
		settings floods, CVE-2019-9512 and CVE-2019-9515). Each obliges a
		reply, and none opens a stream, so no other limit sees them.

		`0` or below makes every window end as it starts, so nothing
		accumulates and both defences are off. To turn off the reset check
		alone, make `http2MaxResetStreams` negative instead.
	**/
	public var http2ResetWindowSeconds:Float;

	/**
		Whether one connection may carry more than one request.

		Off, every response ends its connection, so every request pays TCP
		setup (and a full TLS handshake when `tlsEnabled` is set) to be
		answered: a page, its stylesheet and its favicon are three
		handshakes. On, a response whose framing allows it leaves the
		connection open for the next request, which is what HTTP/1.1
		specifies and what every client already expects. Defaults to
		`true`; `false` closes each connection after its one response.

		Off, an HTTP/2 connection ends at its first stream, as
		`keepAliveMaxRequests` describes with a limit of one: streams the
		client sent with it are answered too, one opened after it has said it
		read the GOAWAY is refused with `REFUSED_STREAM` (safe to send again
		elsewhere), and the connection closes once they have been answered.
	**/
	public var keepAlive:Bool;

	/**
		Seconds a kept-alive connection may sit idle between requests
		before the server closes it. Defaults to 5; `0` and below disables
		idle reaping, and only that: a response being sent keeps a deadline
		of its own (see `requestTimeout`).

		Without a bound, every client that wanders off mid-session holds a
		connection slot until its own end gives up, and `maxConnections`
		fills with peers doing nothing. An idle connection reaching this
		deadline is the normal end of its life, not a client fault, so it
		is closed without a `408`. Enforced by the same sweep as
		`requestTimeout`, so precision is roughly a quarter second.

		A connection is idle from when its last response has gone to the
		client, not from when it was written, so a response larger than the
		system takes at once, to a client slower to read it than this, is not
		cut off as though the connection sat idle. One with
		`Connection: close`, and one `HTTPServer.drain` closes, likewise close
		once what they sent has gone.

		An HTTP/2 connection is idle while it has no stream open, counted
		from when its last one ended. Its PINGs, SETTINGS and WINDOW_UPDATEs
		ask nothing of the server and do not count, so a client sending only
		PINGs cannot hold a connection open.
	**/
	public var keepAliveTimeout:Float;

	/**
		Responses one connection may carry before the server closes it.
		Defaults to 1,000, as nginx's does; `0` and below means unlimited.

		Bounds how long any single connection's accumulated state (peer
		buffers, handler bookkeeping) can live, and gives a server behind
		a load balancer a periodic chance to rebalance. A limit of 1,000
		yields exactly 1,000 responses, the 1,000th carrying
		`Connection: close`.

		Over HTTP/2, the streams one connection asks for. As the last of them
		opens a GOAWAY goes out, naming no stream, and a PING after it. The
		streams the client had already sent by then are taken and answered
		as well, so a busy connection carries a few past the limit; once the
		client has answered the PING, a final GOAWAY names the last stream
		taken, one opened after that is refused with `REFUSED_STREAM`, and
		the connection closes once the streams it took have been answered.
		A client that never answers the PING has the final GOAWAY two seconds
		on. So the streams a busy client has in flight are answered, rather
		than refused as a GOAWAY naming the last stream at once would refuse
		them.

		Each close costs the client a new connection, and over HTTPS a new
		handshake: at 100, a native HTTPS server with 64 clients spends two
		thirds of its time on those handshakes, 18,900 requests a second
		where 1,000 serves 55,800.
	**/
	public var keepAliveMaxRequests:Int;

	/**
		Bytes of undrained response data allowed to accumulate per accepted
		connection before `outputOverflowPolicy` applies, or `0` for no
		limit.

		A client that stops reading mid-response (a dropped mobile
		connection, a stalled proxy) leaves its response buffered in
		memory with nothing to reclaim it. Setting a limit bounds that per
		connection, which matters most on a server holding many at once.

		Applied to every socket this server accepts, since an application
		cannot reach those sockets before they are used.

		`DEFAULT_MAX_OUTPUT_BUFFER` by default, which no ordinary response comes
		near. A file over 256 KB streams, and streaming peaks at the watermark
		plus one slice (320 KB), while a file under that is buffered whole and
		so is smaller again. What is left above the default is a peer that
		stopped reading, and a response an application built in one call that is
		larger than any file this server would have buffered.

		`0` means no limit at all, which bounds nothing:
		a client that stops reading mid-response then holds its whole response in
		memory for as long as it likes, and many of them hold many.

		Over HTTP/2 the limit is the connection's, across its streams: what
		flow control holds back on each stream counts with what the socket
		holds. While a connection holds this much, the requests it sends next
		wait to be handed to the application (as an HTTP/1.1 connection's
		next request waits behind the response going out) and go on, in the
		order they came, as its client takes what is held. They wait rather
		than being refused: `REFUSED_STREAM` would turn a slow reader's page
		into errors and retries. A client that opens 128 streams and no
		window holds this much, not 128 times it. An answer an application
		gives later, to a request it was
		handed before the connection filled, is held as well; what bounds that
		is the stall deadline (see `requestTimeout`).
	**/
	public var maxOutputBufferSize:Int = DEFAULT_MAX_OUTPUT_BUFFER;

	/**
		What to do when an accepted connection exceeds
		`maxOutputBufferSize`. Defaults to closing it, which is what a
		server wants for a client that has stopped reading.
	**/
	public var outputOverflowPolicy:crossbyte.net.OutputOverflowPolicy = CLOSE;

	/**
		Registry this server records request metrics into.

		When set, the server publishes request counts by status class,
		request duration, and a live connection gauge. Leave `null` to
		record nothing.

		This does not by itself expose an endpoint; add
		`MetricsEndpoint.middleware(...)` to `middleware` to serve them.
	**/
	public var metrics:crossbyte.metrics.Metrics;

	/**
		Prefix for metric names published by this server, so several servers
		in one process can be told apart. Defaults to `http`, yielding
		`http_requests_total` and similar.
	**/
	public var metricsPrefix:String = "http";

	/**
		Path to the PEM certificate chain this server presents. Set together
		with `tlsKeyPath` to serve HTTPS; `validate` refuses one without the
		other.
	**/
	public var tlsCertificatePath:String;

	/**
		Path to the PEM private key matching `tlsCertificatePath`.
	**/
	public var tlsKeyPath:String;

	/**
		Whether this configuration describes an HTTPS server, i.e. both a
		certificate and a key path are set.
	**/
	public var tlsEnabled(get, never):Bool;

	@:noCompletion private function get_tlsEnabled():Bool {
		return tlsCertificatePath != null && tlsCertificatePath != "" && tlsKeyPath != null && tlsKeyPath != "";
	}

	public function new(address:String = "127.0.0.1", port:UInt = 30000, rootDirectory:File = null, errorDocument:File = null,
			directoryIndex:Array<String> = null, whitelist:Array<String> = null, blacklist:Array<String> = null, customHeaders:Array<URLRequestHeader> = null,
			middleware:Array<Middleware> = null, rateLimiter:RateLimiter = null, corsEnabled:Bool = false, corsAllowedOrigins:Array<String> = null,
			corsAllowedMethods:Array<String> = null, corsAllowedHeaders:Array<String> = null, corsMaxAge:Int = 600, corsAllowCredentials:Bool = false,
			maxConnections:Int = 10000, backlog:Int = 0, phpEnabled:Bool = false, phpAddress:String = "127.0.0.1", phpPort:Int = 8080,
			phpCGIPath:String = "php-cgi", phpINIPath:String = "php.ini", phpMode:Int = 1, phpTimeout:Float = 30, tryFiles:Array<String> = null, rewrites:Array<RewriteRule> = null, requestTimeout:Float = 60,
			keepAlive:Bool = true, keepAliveTimeout:Float = 5, keepAliveMaxRequests:Int = 1000, http2Enabled:Bool = false) {
		this.address = address;
		this.port = port;
		// Null means no static files at all. See `rootDirectory`.
		this.rootDirectory = rootDirectory;
		this.directoryIndex = directoryIndex == null ? ["index.php", "index.html"] : directoryIndex;
		this.errorDocument = errorDocument;
		this.whitelist = whitelist == null ? [] : whitelist;
		this.blacklist = blacklist == null ? [] : blacklist;
		this.customHeaders = customHeaders == null ? [] : customHeaders;
		this.middleware = middleware == null ? [] : middleware;
		// 240 a minute rather than RateLimiter's own ten. See `rateLimiter`.
		this.rateLimiter = rateLimiter == null ? new RateLimiter(DEFAULT_REQUESTS_PER_MINUTE, 60.0) : rateLimiter;
		this.corsEnabled = corsEnabled;
		this.corsAllowedOrigins = corsAllowedOrigins == null ? ["*"] : corsAllowedOrigins;
		this.corsAllowedMethods = corsAllowedMethods == null ? ["GET", "POST", "OPTIONS"] : corsAllowedMethods;
		this.corsAllowedHeaders = corsAllowedHeaders == null ? ["Content-Type"] : corsAllowedHeaders;
		this.corsAllowCredentials = corsAllowCredentials;
		this.corsMaxAge = corsMaxAge;
		this.maxConnections = maxConnections;
		this.backlog = backlog;
		this.phpEnabled = phpEnabled;
		this.phpAddress = phpAddress;
		this.phpPort = phpPort;
		this.phpCGIPath = phpCGIPath;
		this.phpINIPath = phpINIPath;
		this.phpMode = phpMode;
		this.phpTimeout = phpTimeout;
		this.tryFiles = (tryFiles == null) ? ["$uri", "$uri/"] : tryFiles;
		this.rewrites = (rewrites == null) ? [] : rewrites;
		this.requestTimeout = requestTimeout;
		this.keepAlive = keepAlive;
		this.http2Enabled = http2Enabled;
		this.http2MaxResetStreams = crossbyte._internal.http.h2.H2ServerConnection.DEFAULT_MAX_RESET_STREAMS;
		this.http2ResetWindowSeconds = crossbyte._internal.http.h2.H2ServerConnection.DEFAULT_RESET_WINDOW;
		this.keepAliveTimeout = keepAliveTimeout;
		this.keepAliveMaxRequests = keepAliveMaxRequests;
	}

	/**
		Throws an `ArgumentError` if this configuration says something the
		server would not do. Called by `HTTPServer` on construction.

		Checked:

		- the shape of `tryFiles`, below;
		- that nothing which resolves files under `rootDirectory` (PHP,
		  `rewrites`, `tryFiles` entries past the first two) is asked for
		  without one;
		- that `corsAllowCredentials` is not paired with an
		  `corsAllowedOrigins` of `"*"`;
		- that an `errorDocument` is a file that is there;
		- that `tlsCertificatePath` and `tlsKeyPath` are set together or not
		  at all.

		`$uri` and `$uri/` are
		tested by the resolver before it reads this list at all (before the
		rewrite rules look at the request, and whether or not the list
		mentions them), so any spelling other than those two first describes
		something that does not happen. Listing a literal ahead of them does not give it priority;
		leaving them out does not switch direct file serving off, which is the
		reading most likely to be mistaken for a restriction.

		Refusing at construction rather than warning is deliberate. The list
		decides which bytes a request is answered with, a config that quietly
		means something other than it says is worse than one refused, and the
		correction is to write the two entries out.
	**/
	public function validate():Void {
		if (tryFiles == null || tryFiles.length < 2 || tryFiles[0] != "$uri" || tryFiles[1] != "$uri/") {
			throw new ArgumentError("tryFiles must begin with \"$uri\" then \"$uri/\", got " + Std.string(tryFiles)
				+ ". Both are tested before every other entry and before the rewrite rules, whether or not this list names them, so any other order is not the order used.");
		}

		for (i in 2...tryFiles.length) {
			if (tryFiles[i] == "$uri" || tryFiles[i] == "$uri/") {
				throw new ArgumentError("tryFiles repeats \"" + tryFiles[i] + "\" at index " + i
					+ "; it is only ever tested first, so the later entry does nothing.");
			}
		}

		// Credentials are a grant of the signed-in user's data to the origins
		// named, and "*" names every site. The server honoured the pair by
		// echoing whatever Origin arrived, with Allow-Credentials: true, so any
		// page on the web could read a user's /me with their cookies.
		if (corsEnabled && corsAllowCredentials && corsAllowedOrigins != null && corsAllowedOrigins.indexOf("*") != -1) {
			throw new ArgumentError("corsAllowCredentials needs corsAllowedOrigins to name the origins it trusts, such as [\"https://app.example.com\"]; with \"*\" every site could read what a signed-in user can.");
		}

		// Each of these names files under the document root. Without one they
		// would do nothing at all, and a configuration that silently means
		// less than it says is refused here for the reason given above.
		if (rootDirectory == null) {
			if (phpEnabled) {
				throw new ArgumentError("phpEnabled needs a rootDirectory: PHP scripts are found under it. Set rootDirectory to the directory holding them.");
			}
			if (rewrites != null && rewrites.length > 0) {
				throw new ArgumentError("rewrites need a rootDirectory: every rule resolves to a file under it. Set rootDirectory, or remove the rules.");
			}
			if (tryFiles.length > 2) {
				throw new ArgumentError("tryFiles entries after \"$uri/\" need a rootDirectory: each names a file under it. Set rootDirectory, or remove them.");
			}
		}

		// Read only when the first error is answered, which is too late to
		// say it is missing.
		if (errorDocument != null && (!errorDocument.exists || errorDocument.isDirectory)) {
			throw new ArgumentError("errorDocument " + errorDocument.nativePath + " is not a file that is there.");
		}

		// One path without the other is not HTTPS, so tlsEnabled would be
		// false, and the server would listen in plaintext for a caller who
		// asked for HTTPS.
		var certificate:Bool = tlsCertificatePath != null && tlsCertificatePath != "";
		var key:Bool = tlsKeyPath != null && tlsKeyPath != "";
		if (certificate != key) {
			throw new ArgumentError(certificate
				? "tlsCertificatePath is set and tlsKeyPath is not: HTTPS needs both, and this server would have listened in plain HTTP. Set tlsKeyPath, or clear tlsCertificatePath for plain HTTP."
				: "tlsKeyPath is set and tlsCertificatePath is not: HTTPS needs both, and this server would have listened in plain HTTP. Set tlsCertificatePath, or clear tlsKeyPath for plain HTTP.");
		}
	}
}

/**
	A middleware: given the request and `next`, it answers the request, or
	calls `next()` to pass it on, or `next(error)` to fail it: an `Int` is
	the status to answer with, anything else answers `500` (see
	`HTTPServerConfig.onError`). The error is `Any`, as a thrown value is.
**/
typedef Middleware = (HTTPRequestHandler, ?Any->Void) -> Void;

/** `HTTPServerConfig.errorDocument` as read: `body` is null when it could not be. */
@:noCompletion
@:structInit
final class ErrorPage {
	public final document:File;
	public final body:Null<haxe.io.Bytes>;
	public final type:String;
}
#end
