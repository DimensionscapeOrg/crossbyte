package crossbyte._internal.deflatex;

import haxe.io.Bytes;

/**
	hxcpp's own zlib, for the one-shot DEFLATE codings on native.

	The pure Haxe `Deflater` took 743 microseconds for 64 KB of JSON and wrote
	8.3 KB of it; zlib at its default level takes about 210 and writes 6.0 KB.
	An HTTP server compressing a page-sized body for every browser, which
	asks for it every time, was held to about 1,300 responses a second by
	that alone. hxcpp already links zlib for `haxe.zip`, so this adds no
	dependency.

	Each thread keeps one deflate stream and resets it for the next input,
	where a `haxe.zip.Compress` was made and closed for every one: zlib's
	`deflateInit` and `deflateEnd` were a third of what a 437-byte WebSocket
	message cost to compress (3.1-3.2 µs of 8.4-9.4, the audit's
	InflatePerf). The stream holds about 270 KB of zlib's state for the life
	of its thread. Its input is read to its length, so a `ByteArray`'s
	spare capacity is no longer copied off first.

	A body compressed as it streams goes through the same zlib, flushed after
	each piece; see `NativeDeflateStream`.
**/
#if cpp
@:noCompletion
@:buildXml('
<include name="${HXCPP}/src/hx/libs/zlib/Build.xml"/>
<files id="haxe">
	<compilerflag value="-I${ZLIB_DIR}"/>
</files>
')
@:cppFileCode('
#include <zlib.h>

// One deflate stream per thread, made on first use at the level asked for
// and reset between inputs; ended when the thread does.
struct crossbyte_deflater {
	z_stream *stream;
	int level;

	crossbyte_deflater() : stream(0), level(-1) {}

	~crossbyte_deflater() {
		if (stream) {
			deflateEnd(stream);
			delete stream;
		}
	}
};

static thread_local crossbyte_deflater crossbyte_thread_deflater;

// Deflates input[0, length) as one zlib stream (RFC 1950) into
// output[at, at + room), and answers the bytes written; throws when it does
// not fit or zlib fails.
static int crossbyte_zlib_deflate(Array<unsigned char> input, int length, Array<unsigned char> output, int at, int room, int level) {
	crossbyte_deflater &d = crossbyte_thread_deflater;
	int rc;

	if (d.stream && d.level != level) {
		deflateEnd(d.stream);
		delete d.stream;
		d.stream = 0;
	}

	if (!d.stream) {
		z_stream *stream = new z_stream();
		memset(stream, 0, sizeof(z_stream));
		rc = deflateInit(stream, level);

		if (rc != Z_OK) {
			delete stream;
			hx::Throw(HX_CSTRING("zlib could not start a deflate stream: ") + String(rc));
		}

		d.stream = stream;
		d.level = level;
	} else {
		deflateReset(d.stream);
	}

	// The arrays held from this frame while zlib reads and writes them
	// inside the collector-free zone, as hxcpp\'s own zip glue holds them.
	unsigned char * volatile pinInput = (unsigned char *)input->GetBase();
	unsigned char * volatile pinOutput = (unsigned char *)output->GetBase();
	z_stream *stream = d.stream;
	stream->next_in = (Bytef *)pinInput;
	stream->avail_in = (uInt)length;
	stream->next_out = (Bytef *)pinOutput + at;
	stream->avail_out = (uInt)room;

	hx::EnterGCFreeZone();
	rc = deflate(stream, Z_FINISH);
	hx::ExitGCFreeZone();

	int written = room - (int)stream->avail_out;
	stream->next_in = 0;
	stream->next_out = 0;

	if (rc != Z_STREAM_END) {
		// Left mid-stream: reset before anything else uses it.
		deflateReset(stream);
		hx::Throw(HX_CSTRING("zlib did not compress the whole input: ") + String(rc));
	}

	return written;
}
')
class NativeZlib {
	/** zlib's own default, which Node's `zlib.gzip` and Apache use. **/
	public static inline var LEVEL:Int = 6;

	/** A zlib stream (RFC 1950): what HTTP calls `deflate`. **/
	public static function zlib(input:Bytes):Bytes {
		var out:Bytes = __out(input, 0, 0);
		var written:Int = __deflate(input, out, 0);
		return out.sub(0, written);
	}

	/** Raw DEFLATE (RFC 1951): the zlib stream less its 2-byte header and 4-byte Adler-32. **/
	public static function raw(input:Bytes):Bytes {
		var out:Bytes = __out(input, 0, 0);
		var written:Int = __deflate(input, out, 0);
		return out.sub(2, written - 6);
	}

	/**
		An unnamed gzip member (RFC 1952), as `GZCompressor` writes one: the
		10-byte header with no flags, modification time or system named, the
		raw DEFLATE, then its CRC-32 and length.
	**/
	public static function gzip(input:Bytes):Bytes {
		// The zlib stream is written 8 bytes in, so its DEFLATE begins where a
		// gzip header ends. The header goes over the first 10 bytes, the zlib
		// header among them, and the CRC and length over the Adler-32 and the
		// 4 bytes left after it.
		var out:Bytes = __out(input, 8, 4);
		var written:Int = __deflate(input, out, 8);
		var trailer:Int = 8 + written - 4;
		out.set(0, 0x1f);
		out.set(1, 0x8b);
		out.set(2, 8);
		for (i in 3...10) {
			out.set(i, 0);
		}
		var crc = new CRC32();
		crc.updateBytes(input, 0, input.length);
		out.setInt32(trailer, crc.value);
		out.setInt32(trailer + 4, input.length);
		return out.sub(0, trailer + 8);
	}

	/** Room for `input` deflated, `before` bytes ahead of it and `after` behind. **/
	static inline function __out(input:Bytes, before:Int, after:Int):Bytes {
		var n:Int = input.length;
		// zlib's compressBound, header and Adler-32 included, with room over.
		var bound:Int = n + (n >> 12) + (n >> 14) + (n >> 25) + 13 + 16;
		return Bytes.alloc(before + bound + after);
	}

	/** `input` deflated as a zlib stream into `out` from `at`; answers the bytes written. **/
	static function __deflate(input:Bytes, out:Bytes, at:Int):Int {
		var room:Int = out.length - at;

		try {
			return __run(input.getData(), input.length, out.getData(), at, room, LEVEL);
		} catch (e:String) {
			throw new crossbyte.errors.IOError(e);
		}
	}

	@:native("crossbyte_zlib_deflate")
	extern static function __run(input:haxe.io.BytesData, length:Int, output:haxe.io.BytesData, at:Int, room:Int, level:Int):Int;
}
#end
