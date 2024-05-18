package crossbyte.http;
import crossbyte.io.File;

/**
 * ...
 * @author Christopher Speciale
 */
class HTTPServerConfig 
{
	public var address:String;
	public var port:UInt;
	public var rootDirectory:File;
	public var directoryIndex:Array<String>;
	public var errorDocument:File;
	public var whitelist:Array<String>;
	public var blacklist:Array<String>;
	
	public function new(address:String = "0.0.0.0", port:UInt = 30000, rootDirectory:File = null, errorDocument:File = null, directoryIndex:Array<String> = null, whitelist:Array<String> = null, blacklist:Array<String> = null) 
	{
		this.address = address;
		this.port = port;
		this.rootDirectory = rootDirectory == null ? File.applicationStorageDirectory : rootDirectory;
		this.directoryIndex = directoryIndex == null ? ["index.html"] : directoryIndex;
		this.errorDocument = errorDocument;
		this.whitelist = whitelist == null ? [] : whitelist;
		this.blacklist = blacklist == null ? [] : blacklist;
		
	}
	
}