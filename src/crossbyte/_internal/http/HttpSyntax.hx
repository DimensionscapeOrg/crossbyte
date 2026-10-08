package crossbyte._internal.http;

/**
 * The rules of HTTP that hold wherever HTTP is spoken.
 *
 * They sit apart from `Http`, the client, which drives requests over a raw
 * socket with its own TLS and is therefore excluded from both JavaScript
 * targets. Which versions are supported, whether two framing headers
 * contradict each other, and which bytes may not appear in a header are
 * facts about the protocol, and a server needs them exactly as much as a
 * client does, so there is one copy, here, compiled everywhere. `Http`
 * keeps its four methods as forwards.
 */
class HttpSyntax {
	private static final SUPPORTED_VERSIONS:Array<HttpVersion> = [HttpVersion.HTTP_1, HttpVersion.HTTP_1_1];

	/**
	 * Whether `version` is one this framework speaks.
	 */
	public static function validateHttpVersion(version:HttpVersion):Bool {
		return SUPPORTED_VERSIONS.indexOf(version) > -1;
	}

	/**
	 * Whether a message carries both `Transfer-Encoding` and `Content-Length`.
	 *
	 * RFC 7230 §3.3.3 makes this a request smuggling risk rather than a matter
	 * of taste: two intermediaries that disagree about which header wins will
	 * disagree about where one request ends and the next begins.
	 */
	public static function hasConflictingFraming(hasTransferEncoding:Bool, hasContentLength:Bool):Bool {
		return hasTransferEncoding && hasContentLength;
	}

	/**
	 * Returns `true` when adding `incoming` bytes to an already-accumulated
	 * `accumulated` total would exceed `limit`. A `limit <= 0` disables the cap.
	 */
	public static function exceedsChunkedBodyLimit(accumulated:Int, incoming:Int, limit:Int):Bool {
		if (limit <= 0) {
			return false;
		}

		return (accumulated + incoming) > limit;
	}

	/**
	 * A request path with its spelling settled, or null when its `..` steps
	 * climb above the root.
	 *
	 * Repeated separators collapse, `.` and `..` steps are applied (RFC 3986
	 * 5.2.4), a backslash separates segments as it does on the filesystem
	 * Windows reads, and the result starts with `/`. A trailing separator, or
	 * a trailing step, leaves the result ending in `/`, since it names a
	 * directory. `*`, the target of a server-wide `OPTIONS`, is left alone.
	 *
	 * This is what lets a guard and the file it guards agree: one
	 * normalisation, before middleware, means the path a guard checks is the
	 * path served, so a middleware refusing `/private/` also refuses
	 * `//private/report.txt` and `/./private/report.txt`.
	 *
	 * No browser sends a `..` that climbs above the root (it applies the
	 * steps itself), so answering null for one, and 400 for the request,
	 * refuses only what was written by hand to escape. A `..` inside a
	 * segment, as in `/compare/v1.2..v1.3`, is part of a name and not a step.
	 *
	 * Allocates nothing for a path that is already settled, which is every
	 * path a browser sends.
	 */
	public static function normalizePath(path:String):Null<String> {
		if (path == null || path.length == 0) {
			return "/";
		}

		if (path == "*" || !__needsNormalizing(path)) {
			return path;
		}

		var segments:Array<String> = [];
		var length:Int = path.length;
		var directory:Bool = false;
		var i:Int = 0;

		while (i < length) {
			var code:Int = StringTools.fastCodeAt(path, i);
			if (code == "/".code || code == "\\".code) {
				i++;
				continue;
			}

			var start:Int = i;
			while (i < length) {
				code = StringTools.fastCodeAt(path, i);
				if (code == "/".code || code == "\\".code) {
					break;
				}
				i++;
			}

			var size:Int = i - start;
			if (size == 1 && StringTools.fastCodeAt(path, start) == ".".code) {
				directory = true;
			} else if (size == 2 && StringTools.fastCodeAt(path, start) == ".".code && StringTools.fastCodeAt(path, start + 1) == ".".code) {
				if (segments.length == 0) {
					return null;
				}
				segments.pop();
				directory = true;
			} else {
				segments.push(path.substr(start, size));
				// A separator after the last segment makes it a directory.
				directory = i < length;
			}
		}

		if (segments.length == 0) {
			return "/";
		}

		return "/" + segments.join("/") + (directory ? "/" : "");
	}

	/**
	 * Whether `normalizePath` would change `path`: it does not start with
	 * `/`, or it holds a backslash, an empty segment, or a `.` or `..` step.
	 */
	private static function __needsNormalizing(path:String):Bool {
		var length:Int = path.length;
		if (StringTools.fastCodeAt(path, 0) != "/".code) {
			return true;
		}

		for (i in 0...length) {
			var code:Int = StringTools.fastCodeAt(path, i);
			if (code == "\\".code) {
				return true;
			}
			if (code != "/".code || i + 1 >= length) {
				continue;
			}

			var next:Int = StringTools.fastCodeAt(path, i + 1);
			if (next == "/".code) {
				return true;
			}
			if (next == ".".code) {
				var after:Int = i + 2 < length ? StringTools.fastCodeAt(path, i + 2) : -1;
				if (after == -1 || after == "/".code || after == "\\".code) {
					return true;
				}
				if (after == ".".code) {
					var third:Int = i + 3 < length ? StringTools.fastCodeAt(path, i + 3) : -1;
					if (third == -1 || third == "/".code || third == "\\".code) {
						return true;
					}
				}
			}
		}

		return false;
	}

	/**
	 * What `Host` and `:authority` carry: `host`, in brackets when it is an
	 * IPv6 literal, then `:port` unless `port` is `defaultPort` (the scheme's
	 * own, or `-1` to always name it).
	 *
	 * `URL` takes the brackets off an IPv6 literal, and they go back on here:
	 * `[2001:db8::1]:8080` written bare would be `2001:db8::1:8080`, which no
	 * server can split. The port is compared with the scheme's own, so
	 * `http://host:443/` is sent as `Host: host:443`, not as `Host: host`,
	 * which means port 80.
	 */
	public static function authority(host:String, port:Int, defaultPort:Int):String {
		var name:String = host.indexOf(":") >= 0 ? "[" + host + "]" : host;
		return port == defaultPort ? name : name + ":" + port;
	}

	/**
	 * Whether `text` is an RFC 9110 5.6.2 token: one or more of the letters,
	 * digits and ``!#$%&'*+-.^_`|~``. A method has to be one, and so does a
	 * field name.
	 */
	public static function isToken(text:Null<String>):Bool {
		if (text == null || text.length == 0) {
			return false;
		}

		for (i in 0...text.length) {
			if (!isTokenChar(StringTools.fastCodeAt(text, i))) {
				return false;
			}
		}
		return true;
	}

	/** Whether `code` may appear in a token; see `isToken`. */
	public static function isTokenChar(code:Int):Bool {
		if ((code >= "a".code && code <= "z".code) || (code >= "A".code && code <= "Z".code) || (code >= "0".code && code <= "9".code)) {
			return true;
		}
		return switch (code) {
			case "!".code, "#".code, "$".code, "%".code, "&".code, "'".code, "*".code, "+".code, "-".code, ".".code, "^".code, "_".code, "`".code,
				"|".code, "~".code:
				true;
			default:
				false;
		}
	}

	/**
	 * `target` (a path, with its query) as a request line can carry it:
	 * a space, a control character or DEL becomes its `%XX`, and anything
	 * past ASCII its UTF-8 bytes, each as `%XX`. Everything else is left as it
	 * is, `%` included, so a target already encoded is not encoded twice.
	 *
	 * Unencoded, a space would end the target early (`GET /a b HTTP/1.1` gives
	 * a server a version of `b`), and a line break would end the request line.
	 * Returns `target` itself, allocating nothing, when there is nothing to
	 * encode.
	 */
	public static function encodeRequestTarget(target:String):String {
		var clean:Bool = true;
		for (i in 0...target.length) {
			var code:Int = StringTools.fastCodeAt(target, i);
			if (code <= 0x20 || code >= 0x7F) {
				clean = false;
				break;
			}
		}
		if (clean) {
			return target;
		}

		// Through the bytes, so a character past ASCII is its UTF-8 encoding
		// on every target, whatever each takes a String's units to be.
		var bytes:haxe.io.Bytes = haxe.io.Bytes.ofString(target);
		var out:StringBuf = new StringBuf();
		for (i in 0...bytes.length) {
			var byte:Int = bytes.get(i);
			if (byte <= 0x20 || byte >= 0x7F) {
				out.add("%" + StringTools.hex(byte, 2));
			} else {
				out.addChar(byte);
			}
		}
		return out.toString();
	}

	/**
	 * `text.toLowerCase()`, and `text` itself when that would change nothing,
	 * as for nearly every field name a client sends: `toLowerCase` makes a
	 * new string every time natively, whatever it holds.
	 */
	public static function lowerAscii(text:String):String {
		for (i in 0...text.length) {
			var code:Int = StringTools.fastCodeAt(text, i);
			if ((code >= "A".code && code <= "Z".code) || code >= 0x80) {
				return text.toLowerCase();
			}
		}
		return text;
	}

	/**
	 * `name` as HTTP/2 sends it, lowercase (RFC 9113 8.2.1): the fields this
	 * server writes on every response from constants, and anything else
	 * through `lowerAscii`, so no new string is made for each field of every
	 * response.
	 */
	public static function fieldNameForH2(name:String):String {
		return switch (name) {
			case "Date": "date";
			case "Content-Type": "content-type";
			case "X-Content-Type-Options": "x-content-type-options";
			case "Server": "server";
			case "Content-Length": "content-length";
			case "Content-Encoding": "content-encoding";
			case "Vary": "vary";
			case "Last-Modified": "last-modified";
			case "Accept-Ranges": "accept-ranges";
			case "ETag": "etag";
			case "Cache-Control": "cache-control";
			case "Location": "location";
			case "Set-Cookie": "set-cookie";
			case "Access-Control-Allow-Origin": "access-control-allow-origin";
			case _: lowerAscii(name);
		}
	}

	/**
	 * Whether `a` and `b` are the same text but for the case of ASCII
	 * letters, as field names and media types compare. Allocates nothing.
	 */
	public static function equalsIgnoreCase(a:String, b:String):Bool {
		if (a.length != b.length) {
			return false;
		}
		for (i in 0...a.length) {
			var x:Int = StringTools.fastCodeAt(a, i);
			var y:Int = StringTools.fastCodeAt(b, i);
			if (x != y && __lowerCode(x) != __lowerCode(y)) {
				return false;
			}
		}
		return true;
	}

	/** Whether `text` starts with `prefix`, ASCII letters compared without case. */
	public static function startsWithIgnoreCase(text:String, prefix:String):Bool {
		if (text.length < prefix.length) {
			return false;
		}
		for (i in 0...prefix.length) {
			var x:Int = StringTools.fastCodeAt(text, i);
			var y:Int = StringTools.fastCodeAt(prefix, i);
			if (x != y && __lowerCode(x) != __lowerCode(y)) {
				return false;
			}
		}
		return true;
	}

	private static inline function __lowerCode(code:Int):Int {
		return (code >= "A".code && code <= "Z".code) ? code + 32 : code;
	}

	/**
	 * Strips from a header value everything that could end the header early.
	 */
	public static function sanitizeHeaderValue(v:String):String {
		if (v == null) {
			return "";
		}

		// Read before anything is built: nearly every value is clean, and
		// comes back as it was rather than rebuilt a character at a time on
		// every response.
		for (i in 0...v.length) {
			if (__dropsFromValue(StringTools.fastCodeAt(v, i))) {
				return __stripValue(v);
			}
		}
		return v;
	}

	// CR, LF and all C0 control characters except horizontal tab.
	private static inline function __dropsFromValue(c:Int):Bool {
		return c == 13 || c == 10 || (c < 32 && c != 9) || c == 127;
	}

	private static function __stripValue(v:String):String {
		var out:StringBuf = new StringBuf();
		for (i in 0...v.length) {
			var c:Int = StringTools.fastCodeAt(v, i);
			if (!__dropsFromValue(c)) {
				out.addChar(c);
			}
		}
		return out.toString();
	}

	/**
	 * Strips from a header name everything that could end the name early or
	 * turn one header into two.
	 */
	public static function sanitizeHeaderName(n:String):String {
		if (n == null) {
			return "";
		}

		// Read first, as sanitizeHeaderValue is: a clean name comes back as it was.
		for (i in 0...n.length) {
			if (__dropsFromName(StringTools.fastCodeAt(n, i))) {
				return __stripName(n);
			}
		}
		return n;
	}

	// Control chars (incl. CR/LF/tab), space, DEL and the colon separator.
	private static inline function __dropsFromName(c:Int):Bool {
		return c < 32 || c == 127 || c == 32 || c == 58;
	}

	private static function __stripName(n:String):String {
		var out:StringBuf = new StringBuf();
		for (i in 0...n.length) {
			var c:Int = StringTools.fastCodeAt(n, i);
			if (!__dropsFromName(c)) {
				out.addChar(c);
			}
		}
		return out.toString();
	}
}
