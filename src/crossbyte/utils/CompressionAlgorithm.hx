package crossbyte.utils;

/**
 * ...
 * @author Christopher Speciale
 */
@:enum abstract CompressionAlgorithm(Null<Int>) {
	/**
		Defines the string to use for the deflate compression algorithm.
	**/
	public var DEFLATE = 0;

	// GZIP;
	// public var LZMA = 1;

	/**
		Defines the string to use for the zlib compression algorithm.
	**/
	// public var ZLIB = 2;
	public var LZ4 = 3;

	@:from private static function fromString(value:String):CompressionAlgorithm {
		return switch (value) {
			case "deflate": DEFLATE;
			// case "lzma": LZMA;
			// case "zlib": ZLIB;
			case "lz4": LZ4;
			default: null;
		}
	}

	@:to private function toString():String {
		return switch (cast this : CompressionAlgorithm) {
			case CompressionAlgorithm.DEFLATE: "deflate";
			// case CompressionAlgorithm.LZMA: "lzma";
			///case CompressionAlgorithm.ZLIB: "zlib";
			case CompressionAlgorithm.LZ4: "lz4";
			default: null;
		}
	}
}
