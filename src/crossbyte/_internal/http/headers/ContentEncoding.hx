package crossbyte._internal.http.headers;

/**
 * ...
 * @author Christopher Speciale
 */
abstract ContentEncoding(String) from String to String {
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
}
