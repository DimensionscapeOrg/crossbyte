package crossbyte.utils;

/**
	Enumerates the generic compression codecs supported by CrossByte core.

	An `Int` underneath, so a value is never boxed. Code that keeps "no
	algorithm" in a variable types it `Null<CompressionAlgorithm>`.
**/
enum abstract CompressionAlgorithm(Int) {
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
		what most other "deflate" APIs read and write: zlib itself, Node's
		`zlib.deflateSync`, Java's `Deflater`. `DEFLATE` is the bare stream
		inside it.
	**/
	public var ZLIB = 4;

	/**
		The LZ4 frame format: what the `lz4` tool writes and `.lz4` files hold.
		`LZ4` blocks with their sizes, an end mark and checksums, so a frame
		that is cut short or damaged is always caught, where a bare `LZ4` block
		has no length to check against.
	**/
	public var LZ4_FRAME = 5;

	/**
		Converts a lowercase codec token into a supported generic compression
		algorithm, or null for a token it does not know.
	**/
	public static function fromString(value:String):Null<CompressionAlgorithm> {
		if (value == null) {
			return null;
		}

		return switch (value) {
			case "deflate": DEFLATE;
			case "gzip": GZIP;
			case "br", "brotli": BROTLI;
			case "lz4": LZ4;
			case "zlib": ZLIB;
			case "lz4-frame": LZ4_FRAME;
			default: null;
		}
	}

	/**
		A token as the algorithm it names, where a `CompressionAlgorithm` is
		asked for. One it does not know is refused, since null, which an
		`Int` cannot hold, would read as `DEFLATE`.
		@throws crossbyte.errors.ArgumentError For a token `fromString` does
				not know.
	**/
	@:from private static function fromStringInternal(value:String):CompressionAlgorithm {
		var algorithm:Null<CompressionAlgorithm> = fromString(value);
		if (algorithm == null) {
			throw new crossbyte.errors.ArgumentError('Unknown compression algorithm: "$value".');
		}
		return algorithm;
	}

	@:to private function toString():String {
		return switch (cast this : CompressionAlgorithm) {
			case CompressionAlgorithm.DEFLATE: "deflate";
			case CompressionAlgorithm.GZIP: "gzip";
			case CompressionAlgorithm.BROTLI: "br";
			case CompressionAlgorithm.LZ4: "lz4";
			case CompressionAlgorithm.ZLIB: "zlib";
			case CompressionAlgorithm.LZ4_FRAME: "lz4-frame";
			default: null;
		}
	}
}
