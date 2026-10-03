package crossbyte._internal.php;

import haxe.ds.StringMap;
import haxe.io.Bytes;

/** What a request is handed to PHP as: built from an object literal; the optional parts default to null. */
@:structInit
final class PHPRequest {
	public var scriptFilename:String;
	public var requestMethod:String;
	public var requestUri:String;
	public var scriptName:Null<String> = null;
	public var queryString:Null<String> = null;
	public var contentType:Null<String> = null;
	public var remoteAddr:Null<String> = null;
	public var serverName:Null<String> = null;
	public var serverPort:Null<String> = null;
	public var extraHeaders:Null<StringMap<String>> = null;
	public var body:Null<Bytes> = null;
}
