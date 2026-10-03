package crossbyte.http;

// Not built for the browser, for the same reason as HTTPServerConfig: it
// configures the server, which cannot run in a page.
#if !(js && !nodejs)
import crossbyte.utils.CompressionAlgorithm;
import crossbyte._internal.http.HttpSyntax;
import crossbyte._internal.http.KeptBodies;

/**
	What an `HTTPServer` compresses, and how hard: `HTTPServerConfig.compression`.

	A response is compressed only when all of these hold: compression is
	`enabled`, the status is not an error, the body is at least `minimumSize`
	bytes, its `Content-Type` is one of `types`, and the client asked for a
	coding. Everything else goes out as it is. It used to be every non-empty
	body, every time: a two-byte answer became 22 bytes of gzip, PNGs and
	archives grew, and a `429` cost the full setup of a Brotli encoder, so the
	rate limiter did not bound what a flood of refused requests cost.

	A static file is compressed once and kept, up to `cacheSize` bytes, and a
	`.br` or `.gz` beside it is served in its place when `precompressed` is on.
**/
class HTTPCompression {
	/**
		The `Content-Type`s compressed unless `types` says otherwise: text, and
		the structured formats that are text underneath. An entry ending in `/`
		matches every subtype. Images other than SVG and icons, audio, video,
		fonts past TrueType and OpenType, and archives are compressed already,
		and grow when compressed again.
	**/
	public static final DEFAULT_TYPES:Array<String> = [
		"text/", "application/javascript", "application/json", "application/xml", "application/manifest+json", "application/ld+json",
		"application/xhtml+xml", "application/rss+xml", "application/atom+xml", "application/wasm", "image/svg+xml", "image/x-icon", "font/ttf",
		"font/otf"
	];

	/** Whether responses are compressed at all. On by default. **/
	public var enabled:Bool = true;

	/**
		Bytes a body must reach before it is compressed. Defaults to 1024.

		Below that a coding's own framing takes back most of what it saves --
		a two-byte body came out as 22 bytes of gzip -- while the encoder is
		still set up in full, which for Brotli is the larger cost.
	**/
	public var minimumSize:Int = 1024;

	/**
		`Content-Type`s that are compressed, compared without their parameters
		and ignoring case. An entry ending in `/`, such as `text/`, matches
		every subtype. Defaults to a copy of `DEFAULT_TYPES`.
	**/
	public var types:Array<String>;

	/**
		How hard to compress, from 0 to 11, as Brotli counts quality. Defaults
		to 4, which is fast. gzip and deflate have a single setting here and
		ignore it. Higher levels cost markedly more time for a little less
		size, on the runtime's own thread, so raise it for bodies that are
		compressed once and kept -- static files -- rather than for every
		answer a route makes.
	**/
	public var level:Int = 4;

	/**
		Whether a static file's precompressed sibling -- `app.js.br` or
		`app.js.gz` beside `app.js` -- is sent in its place to a client that
		accepts that coding, provided the sibling is not older than the file.
		On by default. Such a file is compressed once, at build time and at any
		level, and costs nothing to serve; it is also the only way a static
		file too large to hold in memory, which is streamed, goes out
		compressed.

		With both there, the client's preference picks, and Brotli an equal
		one; with one, it is sent to any client that takes its coding. Only a
		Brotli sibling used to be looked for by a client that took Brotli, so
		every browser was sent a file with only a `.gz` beside it as Brotli
		encoded on the spot, or, too large to hold, as it is on disk.
	**/
	public var precompressed:Bool = true;

	/**
		Bytes of compressed static files kept in memory, so a file is
		compressed once for each coding rather than for every request. A kept
		body is used only while the file's size and modification time are
		unchanged. Defaults to 16 MB; `0` keeps nothing.

		A 150 KB script was recompressed on every request: 863 requests a second
		as it was, 64 as Brotli, natively.
	**/
	public var cacheSize(default, set):Int = 16 * 1024 * 1024;

	// A slot per coding under one budget. It takes a lock per call: a
	// configuration can be shared by servers on different runtimes' threads.
	@:noCompletion private final __kept:KeptBodies = new KeptBodies(16 * 1024 * 1024);

	@:noCompletion private function set_cacheSize(value:Int):Int {
		__kept.budget = value;
		return cacheSize = value;
	}

	public function new() {
		types = DEFAULT_TYPES.copy();
	}

	/**
		Whether a body of `contentType` is one `types` lists. `null` and an
		empty type are not.
	**/
	public function compresses(contentType:Null<String>):Bool {
		if (contentType == null) {
			return false;
		}
		var semi:Int = contentType.indexOf(";");
		var media:String = semi >= 0 ? contentType.substr(0, semi) : contentType;
		if (media.length > 0 && (StringTools.isSpace(media, 0) || StringTools.isSpace(media, media.length - 1))) {
			media = StringTools.trim(media);
		}
		if (media.length == 0 || types == null) {
			return false;
		}
		// Compared without regard to case, rather than lowercased: each of the
		// fourteen default types was lowercased afresh for every response.
		for (entry in types) {
			if (entry == null || entry.length == 0) {
				continue;
			}
			var matches:Bool = StringTools.fastCodeAt(entry, entry.length - 1) == "/".code ? HttpSyntax.startsWithIgnoreCase(media,
				entry) : HttpSyntax.equalsIgnoreCase(media, entry);
			if (matches) {
				return true;
			}
		}
		return false;
	}

	/**
		The kept compressed body for `path` in `algorithm`, if the file still
		has `size` bytes and was last modified at `modified`; `null` otherwise.
	**/
	@:noCompletion public function cached(path:String, algorithm:CompressionAlgorithm, size:Int, modified:Float):Null<haxe.io.Bytes> {
		if (cacheSize <= 0) {
			return null;
		}
		return __kept.get(__slot(algorithm), path, size, modified);
	}

	/** Keeps `body`, the file at `path` compressed with `algorithm`, while there is room. */
	@:noCompletion public function keep(path:String, algorithm:CompressionAlgorithm, size:Int, modified:Float, body:haxe.io.Bytes):Void {
		if (cacheSize <= 0 || body.length > cacheSize) {
			return;
		}
		__kept.put(__slot(algorithm), path, size, modified, body);
	}

	/** Forgets every kept body. */
	public function clearCache():Void {
		__kept.clear();
	}

	/** Bytes of compressed bodies kept right now. **/
	public var cachedBytes(get, never):Int;

	private function get_cachedBytes():Int {
		return __kept.bytes;
	}

	// The coding's own number, a small one: its slot in __kept.
	private static inline function __slot(algorithm:CompressionAlgorithm):Int {
		var value:Null<Int> = cast algorithm;
		return value == null ? 0 : value;
	}

}
#end
