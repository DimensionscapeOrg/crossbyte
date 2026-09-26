package crossbyte._internal.http;

/**
 * The rules of HTTP that hold wherever HTTP is spoken.
 *
 * These lived in `Http`, which is the client: a class that drives requests over
 * a raw socket with its own TLS, and is therefore excluded from both JavaScript
 * targets. The rules themselves have nothing to do with a socket. Which
 * versions are supported, whether two framing headers contradict each other,
 * and which bytes may not appear in a header are facts about the protocol, and
 * a server needs them exactly as much as a client does, so leaving them
 * behind a class that cannot compile on Node would have meant a second copy,
 * and two copies of a header sanitiser is one too many for the thing it
 * prevents.
 *
 * `Http` keeps its four methods as forwards, so its callers and their tests are
 * unchanged and there is still only one implementation.
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
	 *
	 * Left behind in `Http` when the other four rules moved here, which is the
	 * whole reason the extraction did not buy what it was for: the tests kept
	 * pointing at the forwarder, and the forwarder is native-only, so rules
	 * that hold on every target were still only checked on some of them.
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
	 * This is what lets a guard and the file it guards agree. The server
	 * decoded the path once for middleware and the static resolver normalised
	 * it again on its own, so a middleware refusing `/private/` saw
	 * `//private/report.txt` and `/./private/report.txt` go past, and the
	 * resolver then served `/private/report.txt` for both. One normalisation,
	 * before middleware, means the path a guard checks is the path served.
	 *
	 * No browser sends a `..` that climbs above the root, it applies the
	 * steps itself, so answering null for one, and 400 for the request,
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
	 * Strips from a header value everything that could end the header early.
	 */
	public static function sanitizeHeaderValue(v:String):String {
		if (v == null) {
			return "";
		}

		var out:StringBuf = new StringBuf();
		for (i in 0...v.length) {
			var c:Int = v.charCodeAt(i);
			// Drop CR, LF and all C0 control characters except horizontal tab.
			if (c == 13 || c == 10 || (c < 32 && c != 9) || c == 127) {
				continue;
			}
			out.addChar(c);
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

		var out:StringBuf = new StringBuf();
		for (i in 0...n.length) {
			var c:Int = n.charCodeAt(i);
			// Reject control chars (incl. CR/LF/tab), space, DEL and the colon separator.
			if (c < 32 || c == 127 || c == 32 || c == 58) {
				continue;
			}
			out.addChar(c);
		}
		return out.toString();
	}
}
