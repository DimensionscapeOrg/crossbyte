package crossbyte.http;

import crossbyte.utils.CompressionAlgorithm;

/**
	HTTP content-coding tokens used in `Content-Encoding` and `Accept-Encoding`.
	This surface stays HTTP-specific because HTTP also needs concepts like
	`identity` and header aliases such as `x-gzip`.
**/
enum abstract HTTPContentCoding(String) from String to String {
	public var BR:String = "br";
	public var DEFLATE:String = "deflate";
	public var GZIP:String = "gzip";
	public var IDENTITY:String = "identity";
	public var LZ4:String = "lz4";

	public static function fromString(value:String):Null<HTTPContentCoding> {
		if (value == null) {
			return null;
		}

		return switch (StringTools.trim(value).toLowerCase()) {
			case "br": BR;
			case "deflate": DEFLATE;
			case "gzip", "x-gzip": GZIP;
			case "identity": IDENTITY;
			case "lz4": LZ4;
			default: null;
		}
	}

	public inline function toCompressionAlgorithm():Null<CompressionAlgorithm> {
		return switch (cast this : HTTPContentCoding) {
			case BR: CompressionAlgorithm.BROTLI;
			case DEFLATE: CompressionAlgorithm.DEFLATE;
			case GZIP: CompressionAlgorithm.GZIP;
			case LZ4: CompressionAlgorithm.LZ4;
			default: null;
		}
	}
}
