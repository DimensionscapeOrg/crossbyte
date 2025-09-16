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
	public var phpEnabled:Bool;
	public var phpAddress:String;
	public var phpPort:Int;
	public var phpCGIPath:String;
	public var phpINIPath:String;
	public var phpMode:Int;
	public var corsAllowCredentials:Bool;

	public function new(address:String = "0.0.0.0", port:UInt = 30000, rootDirectory:File = null, errorDocument:File = null,
			directoryIndex:Array<String> = null, whitelist:Array<String> = null, blacklist:Array<String> = null, customHeaders:Array<URLRequestHeader> = null,
			middleware:Array<Middleware> = null, rateLimiter:RateLimiter = null, corsEnabled:Bool = false, corsAllowedOrigins:Array<String> = null,
			corsAllowedMethods:Array<String> = null, corsAllowedHeaders:Array<String> = null, corsMaxAge:Int = 600, corsAllowCredentials:Bool = false, maxConnections:Int = 256, backlog:Int = 0, 
			phpEnabled:Bool = false, phpAddress:String = "127.0.0.1", phpPort:Int = 8080, phpCGIPath:String = "php-cgi", phpINIPath:String = "php.ini", phpMode:Int = 1) {
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
		
	}
}

typedef Middleware = (HTTPRequestHandler, Dynamic->Void) -> Void;
