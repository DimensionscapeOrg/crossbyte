package crossbyte.http;

import crossbyte.io.ByteArray;
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

	/**
		The codec for this coding. `deflate` is zlib (RFC 9110 8.4.1.2), not
		raw DEFLATE: a client following the standard cannot read raw. See
		`codecFor` for reading one.
	**/
	public inline function toCompressionAlgorithm():Null<CompressionAlgorithm> {
		return switch (cast this : HTTPContentCoding) {
			case BR: CompressionAlgorithm.BROTLI;
			case DEFLATE: CompressionAlgorithm.ZLIB;
			case GZIP: CompressionAlgorithm.GZIP;
			case LZ4: CompressionAlgorithm.LZ4;
			default: null;
		}
	}

	/**
		The codec to read `body` with, where it arrived coded `algorithm`: as
		given, but for `deflate`, zlib when the body starts with a zlib header
		and raw DEFLATE when it does not: servers commonly send raw under the
		name, and every browser reads either.
	**/
	public static inline function codecFor(algorithm:CompressionAlgorithm, body:ByteArray):CompressionAlgorithm {
		return algorithm == CompressionAlgorithm.ZLIB && !(body.length >= 2
			&& crossbyte._internal.deflatex.ZlibCompressor.isHeader(body[0], body[1])) ? CompressionAlgorithm.DEFLATE : algorithm;
	}
}
