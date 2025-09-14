package crossbyte._internal.http.headers;

/**
 * ...
 * @author Christopher Speciale
 */
enum abstract AcceptEncoding(String) from String to String {
	/*
		A compression format that uses the Brotli algorithm.
	 */
	public var BR:String = "br";

	/*
		A format using the Lempel-Ziv-Welch (LZW) algorithm. The value name was taken from the
		UNIX compress program, which implemented this algorithm. Like the compress program, which
		has disappeared from most UNIX distributions, this content-encoding is not used by many
		browsers today, partly because of a patent issue (it expired in 2003).
	 */
	public var COMPRESS:String = "compress";

	/*
		Using the zlib structure (defined in RFC 1950) with the deflate compression algorithm
		(defined in RFC 1951).
	 */
	public var DEFLATE:String = "deflate";

	/**
		A format using the Lempel-Ziv coding (LZ77), with a 32-bit CRC. This is the original 
		format of the UNIX gzip program. The HTTP/1.1 standard also recommends that the servers
		supporting this content-encoding should recognize x-gzip as an alias, for compatibility
		purposes.
	 */
	public var GZIP:String = "gzip";

	/*
		Indicates the identity function (that is, without modification or compression). This value 
		is always considered as acceptable, even if omitted.
	 */
	public var IDENTITY:String = "identity";

	/*
		Matches any content encoding not already listed in the header. This is the default value if 
		the header is not present. This directive does not suggest that any algorithm is supported
		but indicates that no preference is expressed.
	 */
	public var DEFAULT:String = "*";

	/*
		Any value is placed in an order of preference expressed using a relative quality value called weight.
	 */
	public var Q_VALUE:String = ";q=";
}
