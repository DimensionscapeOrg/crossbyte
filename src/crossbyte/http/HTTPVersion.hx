package crossbyte.http;

/**
 * HTTP protocol versions recognized by CrossByte's HTTP client surface.
 *
 * HTTP/1.0 and HTTP/1.1 are implemented by the core library. HTTP/2 and
 * HTTP/3 require a registered HTTPBackend.
 */
enum abstract HTTPVersion(String) from String to String {
	public var HTTP_1:String = "HTTP/1.0";
	public var HTTP_1_1:String = "HTTP/1.1";
	public var HTTP_2:String = "HTTP/2";
	public var HTTP_3:String = "HTTP/3";
}
