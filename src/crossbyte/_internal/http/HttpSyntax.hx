package crossbyte._internal.http;

/**
 * The rules of HTTP that hold wherever HTTP is spoken.
 *
 * These lived in `Http`, which is the client: a class that drives requests over
 * a raw socket with its own TLS, and is therefore excluded from both JavaScript
 * targets. The rules themselves have nothing to do with a socket. Which
 * versions are supported, whether two framing headers contradict each other,
 * and which bytes may not appear in a header are facts about the protocol, and
 * a server needs them exactly as much as a client does -- so leaving them
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
