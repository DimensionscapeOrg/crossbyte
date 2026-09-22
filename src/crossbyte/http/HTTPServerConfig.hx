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

	public var address:String;
	public var port:UInt;
	public var rootDirectory:File;
	public var directoryIndex:Array<String>;
	public var errorDocument:File;
	public var whitelist:Array<String>;
	public var blacklist:Array<String>;
	public var customHeaders:Array<URLRequestHeader>;
	public var middleware:Array<Middleware>;
	/**
		Refuses a request with `429` once its client has spent its budget.

		Keyed on the remote address and consulted for **every** request, not
		every connection. Leaving it out of the constructor does not leave the
		server unlimited: one is fitted, with `RateLimiter`'s own defaults of ten
		requests a minute per client.

		The fitted budget is `DEFAULT_REQUESTS_PER_MINUTE`, which is a visitor's
		page load with room to spare rather than `RateLimiter`'s own default of
		ten -- ten is smaller than one page, and a document with eleven assets
		used to come back as ten served and two refused.

		Pass a limiter of your own to say something different. A server behind a
		proxy wants one sized to the proxy rather than to a visitor, since every
		request then arrives from one address.
	**/
	public var rateLimiter:RateLimiter;
	public var corsEnabled:Bool;
	public var corsAllowedOrigins:Array<String>;
	public var corsAllowedMethods:Array<String>;
	public var corsAllowedHeaders:Array<String>;
	public var corsMaxAge:Int;
	public var maxConnections:Int;
	public var backlog:Int;
	public var phpEnabled:Bool;
	public var phpAddress:String;
	public var phpPort:Int;
	public var phpCGIPath:String;
	public var phpINIPath:String;
	public var phpMode:Int;

	/**
		Seconds a single PHP request may take before the server gives up on it
		and answers `504 Gateway Timeout`. `0` disables the deadline.

		Defaults to 30. There was no deadline at all before, and no socket
		timeout either, so a php-fpm that accepted a connection and then said
		nothing held the runtime for as long as it liked. That is not one slow
		request: a CrossByte runtime serves all of its connections from one
		tick, and `maxConnections` defaults to 256, so an unresponsive backend
		stopped the server for every client at once and stayed stopped.

		Note that `requestTimeout` does not cover this window -- it stops the
		moment a request has been read, on the principle that the time a
		response takes is the server's own. This is that principle's other
		half: the server's own time still has a limit.
	**/
	public var phpTimeout:Float;
	public var corsAllowCredentials:Bool;
	/**
		Paths tried, in order, when resolving a request.

		The order the server actually follows is fixed at the front and only
		free at the back, so the list is required to be spelled the way it
		runs — see `validate`, which rejects anything else rather than
		silently reordering it:

		1. `$uri` — the request path as a file
		2. `$uri/` — the request path as a directory, resolved through
		   `directoryIndex`
		3. every rule in `rewrites`, in order
		4. the remaining entries here, in order

		The consequence worth knowing is that **an existing file wins over a
		rewrite**, whatever the rules say. This is Apache's `RewriteCond !-f`
		idiom applied for you rather than written out; to invert it for a
		given rule, give that rule a `FileExists` condition with `negate` set
		and it will run before the file is looked for. It is not nginx's
		model, where `try_files` runs after the rewrite phase in the order
		written.

		Defaults to `["$uri", "$uri/"]`: the request path as a file, then as a
		directory to be resolved to its index. A path matching neither answers
		404.

		It used to end with `"/index.html"` as well — a single-page application
		fallback, on for every server whether or not it served an application.
		The two failure modes are not comparable. An SPA that wanted the
		fallback and does not have it breaks on the first refresh of a deep
		link, which is loud, immediate, and one entry from fixed. A static site
		that did not want it and had it answers **200 with the root index for
		every path that does not exist**: a broken link looks alive to a
		crawler, a monitor sees a healthy page, and a cache stores the wrong
		body under the missing URL. Silent, and indistinguishable from working.

		Add `"/index.html"` back as a final entry for an SPA:

		```haxe
		config.tryFiles = ["$uri", "$uri/", "/index.html"];
		```
	**/
	public var tryFiles:Array<String>;

	/**
		Rewrite rules, applied in order after `tryFiles` has failed to resolve
		the request against an existing file or directory index.

		Empty by default. A rule carrying the `PHP` flag needs `phpEnabled`,
		and the two shipped out of step until 1.0.0-rc.2: the defaults rewrote
		every `/api` path to `/index.php` while PHP defaulted to off, so a
		stock server took a null bridge and segfaulted on a request path a
		great many services use. Nothing here is enabled unless it is asked
		for now, and a `PHP` rewrite without a bridge answers 500 rather than
		reaching one.
	**/
	public var rewrites:Array<RewriteRule>;

	/**
		Seconds a request has to arrive in full — request line, headers and
		body together. `0` disables the deadline. Defaults to 60.

		The rate limiter cannot cover this window: it runs once a complete
		header block exists, so a client trickling one byte at a time was
		never rate limited and held a connection slot for as long as it
		cared to. With `maxConnections` at its default of 256, tying up
		every slot this way cost an attacker almost nothing. A connection
		that misses the deadline is answered with `408 Request Timeout`
		and closed.

		Enforced by the owning server's sweep, which runs a few times a
		second, so the deadline is precise to roughly a quarter second.
	**/
	public var requestTimeout:Float;

	/**
		Whether one connection may carry more than one request.

		Off, every response ends its connection, so every request pays TCP
		setup — and a full TLS handshake when `tlsEnabled` is set — to be
		answered: a page, its stylesheet and its favicon are three
		handshakes. On, a response whose framing allows it leaves the
		connection open for the next request, which is what HTTP/1.1
		specifies and what every client already expects. Defaults to
		`true`; `false` restores the one-shot close-per-request behavior
		exactly.
	**/
	/**
		Offer HTTP/2 on this listener, alongside HTTP/1.1.

		Opt-in but not exclusive: each connection is served as whichever
		version it turns out to be speaking. Over TLS that is settled by ALPN,
		which the listener advertises as `h2` and `http/1.1`. Over cleartext
		there is nothing to negotiate -- RFC 9113 3.1 retired the
		`Upgrade: h2c` handshake, leaving prior knowledge -- so the first bytes
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
		frees its slot immediately -- so a peer opening and instantly resetting
		streams never approaches that limit while still making the server route
		and dispatch every one of them.

		The default is generous enough that ordinary cancellation never reaches
		it; lower it only if you are being abused, and raise it only if a
		legitimate client genuinely cancels in bursts.
	**/
	public var http2MaxResetStreams:Int;

	/** Seconds the `http2MaxResetStreams` budget is measured over. **/
	public var http2ResetWindowSeconds:Float;

	public var keepAlive:Bool;

	/**
		Seconds a kept-alive connection may sit idle between requests
		before the server closes it. Defaults to 5; `0` and below disables
		idle reaping.

		Without a bound, every client that wanders off mid-session holds a
		connection slot until its own end gives up, and `maxConnections`
		fills with peers doing nothing. An idle connection reaching this
		deadline is the normal end of its life, not a client fault, so it
		is closed without a `408`. Enforced by the same sweep as
		`requestTimeout`, so precision is roughly a quarter second.
	**/
	public var keepAliveTimeout:Float;

	/**
		Responses one connection may carry before the server closes it.
		Defaults to 100; `0` and below means unlimited.

		Bounds how long any single connection's accumulated state — peer
		buffers, handler bookkeeping — can live, and gives a server behind
		a load balancer a periodic chance to rebalance. A limit of 100
		yields exactly 100 responses, the 100th carrying
		`Connection: close`.
	**/
	public var keepAliveMaxRequests:Int;

	/**
		Bytes of undrained response data allowed to accumulate per accepted
		connection before `outputOverflowPolicy` applies, or `0` for no
		limit.

		A client that stops reading mid-response — a dropped mobile
		connection, a stalled proxy — leaves its response buffered in
		memory with nothing to reclaim it. Setting a limit bounds that per
		connection, which matters most on a server holding many at once.

		Applied to every socket this server accepts, since an application
		cannot reach those sockets before they are used.

		`DEFAULT_MAX_OUTPUT_BUFFER` by default, which no ordinary response comes
		near. A file over 256 KB streams, and streaming peaks at the watermark
		plus one slice -- 320 KB -- while a file under that is buffered whole and
		so is smaller again. What is left above the default is a peer that
		stopped reading, and a response an application built in one call that is
		larger than any file this server would have buffered.

		`0` restores the old behaviour of no limit at all, which bounds nothing:
		a client that stops reading mid-response then holds its whole response in
		memory for as long as it likes, and many of them hold many.
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
		with `tlsKeyPath` to serve HTTPS.
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

	public function new(address:String = "0.0.0.0", port:UInt = 30000, rootDirectory:File = null, errorDocument:File = null,
			directoryIndex:Array<String> = null, whitelist:Array<String> = null, blacklist:Array<String> = null, customHeaders:Array<URLRequestHeader> = null,
			middleware:Array<Middleware> = null, rateLimiter:RateLimiter = null, corsEnabled:Bool = false, corsAllowedOrigins:Array<String> = null,
			corsAllowedMethods:Array<String> = null, corsAllowedHeaders:Array<String> = null, corsMaxAge:Int = 600, corsAllowCredentials:Bool = false,
			maxConnections:Int = 256, backlog:Int = 0, phpEnabled:Bool = false, phpAddress:String = "127.0.0.1", phpPort:Int = 8080,
			phpCGIPath:String = "php-cgi", phpINIPath:String = "php.ini", phpMode:Int = 1, phpTimeout:Float = 30, tryFiles:Array<String> = null, rewrites:Array<RewriteRule> = null, requestTimeout:Float = 60,
			keepAlive:Bool = true, keepAliveTimeout:Float = 5, keepAliveMaxRequests:Int = 100, http2Enabled:Bool = false) {
		this.address = address;
		this.port = port;
		this.rootDirectory = rootDirectory == null ? File.applicationStorageDirectory : rootDirectory;
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
		Throws if this configuration describes a resolution order the server
		will not follow. Called by `HTTPServer` on construction.

		Only `tryFiles` is checked, and only its shape. `$uri` and `$uri/` are
		tested by the resolver before it reads this list at all — before the
		rewrite rules, and whether or not the list mentions them — so any
		spelling other than those two first describes something that does not
		happen. Listing a literal ahead of them does not give it priority;
		leaving them out does not switch direct file serving off, which is the
		reading most likely to be mistaken for a restriction.

		Refusing at construction rather than warning is deliberate. The list
		decides which bytes a request is answered with, a config that quietly
		means something other than it says is how the `/api` default came to
		crash a stock server, and the correction is to write the two entries
		out.
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
	}
}

typedef Middleware = (HTTPRequestHandler, ?Dynamic->Void) -> Void;
#end
