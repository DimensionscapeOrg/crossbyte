package crossbyte._internal.http.h2;

/**
 * What an HTTP/2 field may hold, by RFC 9113 8.2.1, for either direction.
 *
 * HPACK carries any byte in a name or a value, so nothing below the frame
 * layer stops a CR, LF or NUL arriving inside one. A message holding one is
 * malformed, which 8.1.1 makes a stream error: the connection is fine, and
 * only that request or response is refused.
 */
class H2FieldRules {
	/**
	 * Why `name` and `value` do not make a well-formed field, or null when
	 * they do.
	 *
	 * A name holds no character below 0x21, no uppercase letter, nothing at
	 * or past DEL, and no colon except a pseudo-header's leading one. A value
	 * holds no NUL, CR or LF.
	 *
	 * 8.2.1 also forbids a value that starts or ends with a space or a tab.
	 * That one is not enforced: it guards nothing a line break does not, and
	 * nghttp2 had to make its own check of it optional after it refused
	 * clients and servers in use. The HTTP/1.1 parser trims such a value.
	 */
	public static function violation(name:String, value:String):Null<String> {
		var length:Int = name.length;
		for (i in 0...length) {
			var code:Int = StringTools.fastCodeAt(name, i);
			if (code >= "A".code && code <= "Z".code) {
				return 'Header field name "${__visible(name)}" is not lowercase';
			}
			if (code <= 0x20 || code >= 0x7F || (code == ":".code && i > 0)) {
				return 'Header field name "${__visible(name)}" holds a character a field name may not';
			}
		}

		for (i in 0...value.length) {
			var code:Int = StringTools.fastCodeAt(value, i);
			if (code == 0 || code == 0x0A || code == 0x0D) {
				return 'Header field "${__visible(name)}" holds a NUL, CR or LF in its value';
			}
		}
		return null;
	}

	/**
	 * `text` with its control characters shown as `\xNN`, for a message: a
	 * NUL in one hides everything after it in some reports, and a line break
	 * forges a line in a log.
	 */
	private static function __visible(text:String):String {
		var out:StringBuf = new StringBuf();
		for (i in 0...text.length) {
			var code:Int = StringTools.fastCodeAt(text, i);
			if (code < 0x20 || code == 0x7F) {
				out.add("\\x" + StringTools.hex(code, 2));
			} else {
				out.addChar(code);
			}
		}
		return out.toString();
	}
}
