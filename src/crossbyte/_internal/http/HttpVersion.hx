package crossbyte._internal.http;

/**
 * ...
 * @author Christopher Speciale
 */
enum abstract HttpVersion(String) from String to String {
	public var HTTP_1:String = "HTTP/1.0";
	public var HTTP_1_1:String = "HTTP/1.1";
	public var HTTP_2:String = "HTTP/2";
	public var HTTP_3:String = "HTTP/3";
}
