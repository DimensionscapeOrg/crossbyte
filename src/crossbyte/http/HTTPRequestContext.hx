package crossbyte.http;

import haxe.io.Bytes;

/**
 * Immutable request data and callbacks passed to an HTTPBackend.
 */
typedef HTTPRequestContext = {
	var url:String;
	var method:String;
	var headers:Array<String>;
	var requestData:Dynamic;
	var contentType:Null<String>;
	var data:Dynamic;
	var version:HTTPVersion;
	var timeout:Int;
	var userAgent:String;
	var followRedirects:Bool;
	var onProgress:(bytesLoaded:Int, bytesTotal:Int) -> Void;
	var onError:(message:String, ?data:Bytes) -> Void;
	var onComplete:(data:Bytes) -> Void;
	var onStatus:(status:Int) -> Void;
}
