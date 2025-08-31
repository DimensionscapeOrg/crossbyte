package crossbyte._internal.http.headers;

/**
 * @author Christopher Speciale
 */
enum abstract TransferEncoding(String) from String to String {
	public var CHUNKED:String = "chunked";
	public var GZIP:String = "gzip";
	public var X_GZIP:String = "x-gzip";
	public var DEFLATE:String = "deflate";
	public var COMPRESSED:String = "compressed";
}
