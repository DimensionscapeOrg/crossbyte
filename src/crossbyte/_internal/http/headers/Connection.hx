package crossbyte._internal.http.headers;

/**
 * ...
 * @author Christopher Speciale
 */
enum abstract Connection(String) from String to String {
	public var CLOSE:String = "close";
	public var KEEP_ALIVE:String = "keep-alive";
}
