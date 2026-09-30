package crossbyte.utils;

/** Enumerates the generic compression codecs supported by CrossByte core. */
enum abstract CompressionAlgorithm(Null<Int>) {
	/**
		Defines the string to use for the deflate compression algorithm: a raw
		deflate stream (RFC 1951), with no header and no checksum.
	**/
	public var DEFLATE = 0;

	/**
		Defines the string to use for the gzip compression algorithm.
	**/
	public var GZIP = 1;

	/**
		Defines the string to use for the Brotli compression algorithm.
	**/
	public var BROTLI = 2;

	/**
		Defines the string to use for the LZ4 compression algorithm.
	**/
	public var LZ4 = 3;

	/**
		The zlib format (RFC 1950): a deflate stream behind a two-byte header,
		followed by an Adler-32 of the data.

		This is what HTTP's `deflate` content coding is (RFC 9110 8.4.1.2), and
		what most other "deflate" APIs read and write, zlib itself, Node's
		`zlib.deflateSync`, Java's `Deflater`. `DEFLATE` is the bare stream
		inside it.
	**/
	public var ZLIB = 4;

	/**
		Converts a lowercase codec token into a supported generic compression
		algorithm.
	**/
	public static function fromString(value:String):CompressionAlgorithm {
		if (value == null) {
			return null;
		}

		return switch (value) {
			case "deflate": DEFLATE;
			case "gzip": GZIP;
			case "br", "brotli": BROTLI;
			case "lz4": LZ4;
			case "zlib": ZLIB;
			default: null;
		}
	}

	@:from private static function fromStringInternal(value:String):CompressionAlgorithm {
		return fromString(value);
	}

	@:to private function toString():String {
		return switch (cast this : CompressionAlgorithm) {
			case CompressionAlgorithm.DEFLATE: "deflate";
			case CompressionAlgorithm.GZIP: "gzip";
			case CompressionAlgorithm.BROTLI: "br";
			case CompressionAlgorithm.LZ4: "lz4";
			case CompressionAlgorithm.ZLIB: "zlib";
			default: null;
		}
	}
}
