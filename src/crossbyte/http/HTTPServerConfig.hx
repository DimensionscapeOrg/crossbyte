package crossbyte.http;

import crossbyte.io.File;
import crossbyte.url.URLRequestHeader;

/**
 * ...
 * @author Christopher Speciale
 */
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

	public function new(address:String = "0.0.0.0", port:UInt = 30000, rootDirectory:File = null, errorDocument:File = null,
			directoryIndex:Array<String> = null, whitelist:Array<String> = null, blacklist:Array<String> = null, customHeaders:Array<URLRequestHeader> = null,
			middleware:Array<Middleware> = null, rateLimiter:RateLimiter = null, corsEnabled:Bool = false, corsAllowedOrigins:Array<String> = null,
			corsAllowedMethods:Array<String> = null, corsAllowedHeaders:Array<String> = null, corsMaxAge:Int = 600, maxConnections:Int = 256, backlog:Int = 0) {
		this.address = address;
		this.port = port;
		this.rootDirectory = rootDirectory == null ? File.applicationStorageDirectory : rootDirectory;
		this.directoryIndex = directoryIndex == null ? ["index.html"] : directoryIndex;
		this.errorDocument = errorDocument;
		this.whitelist = whitelist == null ? [] : whitelist;
		this.blacklist = blacklist == null ? [] : blacklist;
		this.customHeaders = customHeaders == null ? [] : customHeaders;
		this.rateLimiter = rateLimiter == null ? new RateLimiter() : rateLimiter;
		this.corsEnabled = corsEnabled;
		this.corsAllowedOrigins = corsAllowedOrigins == null ? ["*"] : corsAllowedOrigins;
		this.corsAllowedMethods = corsAllowedMethods == null ? ["GET", "POST", "OPTIONS"] : corsAllowedMethods;
		this.corsAllowedHeaders = corsAllowedHeaders == null ? ["Content-Type"] : corsAllowedHeaders;
		this.corsMaxAge = corsMaxAge;
		this.maxConnections = maxConnections;
		this.backlog = backlog;
	}
}

typedef Middleware = (HTTPRequestHandler, Dynamic->Void) -> Void;
