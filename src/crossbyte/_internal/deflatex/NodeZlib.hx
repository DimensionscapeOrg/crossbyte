package crossbyte._internal.deflatex;

#if nodejs
import haxe.io.Bytes;
import js.node.Buffer;

/**
	Node's own zlib, for the one-shot codings on Node, as `NativeZlib` is on
	native: gzip, zlib and raw DEFLATE at zlib's default level, and Brotli.

	The Haxe encoders took 888 microseconds for 64 KB of JSON as gzip, and
	2.5 milliseconds as Brotli at quality 4; Node's zlib takes about 170 for
	either, writing 6.0 KB of gzip where the Haxe one wrote 8.3, and Brotli
	the same size. Node ships zlib and Brotli, so this adds no dependency.

	The streaming encoder stays on the `Deflater`, as on native.
**/
@:noCompletion
class NodeZlib {
	/** zlib's own default, as `NativeZlib` uses. **/
	public static inline var LEVEL:Int = 6;

	/** A zlib stream (RFC 1950): what HTTP calls `deflate`. **/
	public static function zlib(input:Bytes):Bytes {
		return __bytes(ZlibModule.deflateSync(Buffer.hxFromBytes(input), {level: LEVEL}));
	}

	/** Raw DEFLATE (RFC 1951). **/
	public static function raw(input:Bytes):Bytes {
		return __bytes(ZlibModule.deflateRawSync(Buffer.hxFromBytes(input), {level: LEVEL}));
	}

	/**
		An unnamed gzip member (RFC 1952), with the header `GZCompressor` and
		`NativeZlib` write: no flags, modification time or system named. Node
		names its system there, which is all that differed.
	**/
	public static function gzip(input:Bytes):Bytes {
		var out:Bytes = __bytes(ZlibModule.gzipSync(Buffer.hxFromBytes(input), {level: LEVEL}));
		for (i in 3...10) {
			out.set(i, 0);
		}
		return out;
	}

	/**
		A Brotli stream at `quality`, 0 to 11, declaring the window the Haxe
		encoder does: the least that covers the input, where Node's would
		tell every decoder to keep 4 MB.
	**/
	public static function brotli(input:Bytes, quality:Int):Bytes {
		var constants:Dynamic = ZlibModule.constants;
		var params:haxe.DynamicAccess<Int> = {};
		params.set(Std.string(constants.BROTLI_PARAM_QUALITY), quality);
		params.set(Std.string(constants.BROTLI_PARAM_LGWIN), crossbyte._internal.brotli.codec.BrotliCodec.windowBitsFor(input.length));
		params.set(Std.string(constants.BROTLI_PARAM_SIZE_HINT), input.length);
		return __bytes(ZlibModule.brotliCompressSync(Buffer.hxFromBytes(input), {params: params}));
	}

	/**
		Copied out of the Buffer rather than wrapped. A small Buffer is a
		slice of Node's shared pool, and Bytes made over one carry the whole
		pool as their data.
	**/
	static function __bytes(buffer:Buffer):Bytes {
		var out:Bytes = Bytes.alloc(buffer.length);
		Buffer.hxFromBytes(out).set(buffer);
		return out;
	}
}

@:jsRequire("zlib")
private extern class ZlibModule {
	static var constants(default, never):Dynamic;
	static function deflateSync(input:Buffer, options:Dynamic):Buffer;
	static function deflateRawSync(input:Buffer, options:Dynamic):Buffer;
	static function gzipSync(input:Buffer, options:Dynamic):Buffer;
	static function brotliCompressSync(input:Buffer, options:Dynamic):Buffer;
}
#end
