package crossbyte.utils;

/**
 * ...
 * @author Christopher Speciale
 */
enum abstract CompressionAlgorithm(Null<Int>) {
	/**
		Defines the string to use for the deflate compression algorithm.
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
			default: null;
		}
	}
}
