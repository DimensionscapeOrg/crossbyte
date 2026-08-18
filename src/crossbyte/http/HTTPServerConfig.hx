package crossbyte.http;

import crossbyte.io.File;
import crossbyte.url.URLRequestHeader;
import crossbyte.http.config.RewriteRule;

/** Configuration object for `HTTPServer` routing, limits, headers, and PHP integration. */
class HTTPServerConfig {
	public var address:String;
	public var port:UInt;
	public var rootDirectory:File;
	public var directoryIndex:Array<String>;
	public var errorDocument:File;
	public var whitelist:Array<String>;
	public var blacklist:Array<String>;
	public var customHeaders:Array<URLRequestHeader>;
	public var middleware:Array<Middleware>;
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
	public var corsAllowCredentials:Bool;
	public var tryFiles:Array<String>;
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
		Bytes of undrained response data allowed to accumulate per accepted
		connection before `outputOverflowPolicy` applies, or `0` for no
		limit.

		A client that stops reading mid-response — a dropped mobile
		connection, a stalled proxy — leaves its response buffered in
		memory with nothing to reclaim it. Setting a limit bounds that per
		connection, which matters most on a server holding many at once.

		Applied to every socket this server accepts, since an application
		cannot reach those sockets before they are used. Defaults to `0`,
		preserving existing behavior; size it to the largest response the
		server legitimately sends, with headroom.
	**/
	public var maxOutputBufferSize:Int = 0;

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
		with `tlsKeyPath` to serve HTTPS. Not available on the jvm target.
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
			phpCGIPath:String = "php-cgi", phpINIPath:String = "php.ini", phpMode:Int = 1, tryFiles:Array<String> = null, rewrites:Array<RewriteRule> = null, requestTimeout:Float = 60) {
		this.address = address;
		this.port = port;
		this.rootDirectory = rootDirectory == null ? File.applicationStorageDirectory : rootDirectory;
		this.directoryIndex = directoryIndex == null ? ["index.php", "index.html"] : directoryIndex;
		this.errorDocument = errorDocument;
		this.whitelist = whitelist == null ? [] : whitelist;
		this.blacklist = blacklist == null ? [] : blacklist;
		this.customHeaders = customHeaders == null ? [] : customHeaders;
		this.middleware = middleware == null ? [] : middleware;
		this.rateLimiter = rateLimiter == null ? new RateLimiter() : rateLimiter;
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
		this.tryFiles = (tryFiles == null) ? ["$uri", "$uri/", "/index.html"] : tryFiles;
		this.rewrites = (rewrites == null) ? [
			{
				pattern: "^/api/.*$",
				target: "/index.php",
				flags: ["L", "QSA", "PHP"],
				conditions: []
			}
		] : rewrites;
		this.requestTimeout = requestTimeout;
	}
}

typedef Middleware = (HTTPRequestHandler, ?Dynamic->Void) -> Void;
