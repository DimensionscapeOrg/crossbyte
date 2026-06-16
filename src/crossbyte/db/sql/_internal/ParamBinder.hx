package crossbyte.db.sql._internal;

/**
 * Pure, DB-agnostic named-parameter substitution.
 *
 * Replaces `:name` placeholders in a SQL/command string with the literal
 * produced by an injected `escape` function, so the actual escaping/quoting
 * stays owned by the concrete connection while the (security-sensitive) scan
 * is shared and unit-testable without a live database.
 *
 * Rules:
 * - A placeholder token is `:` followed by an identifier `[A-Za-z_][A-Za-z0-9_]*`.
 * - Tokens are matched WHOLE: `:user` must not match the `:user` prefix of `:username`.
 * - Occurrences inside single-quoted string literals are left untouched, honoring
 *   SQL `''` escaping for an embedded quote.
 * - A placeholder whose name has no matching parameter (`lookup` returns `null`)
 *   is left verbatim.
 */
class ParamBinder {
	/**
	 * @param text    The source SQL/command text containing `:name` placeholders.
	 * @param lookup  Maps a placeholder name to its raw value, or `null` when the
	 *                name is unknown (placeholder is then left untouched).
	 * @param escape  Turns a raw value into the safe literal spliced into `text`
	 *                (e.g. SQL quoting/escaping, or JSON encoding for command text).
	 * @return The substituted text.
	 */
	public static function substitute(text:String, lookup:String->Null<Dynamic>, escape:Dynamic->String):String {
		if (text == null || text == "") {
			return text;
		}

		var out:StringBuf = new StringBuf();
		var len:Int = text.length;
		var i:Int = 0;
		var inString:Bool = false;

		while (i < len) {
			var c:Int = StringTools.fastCodeAt(text, i);

			if (inString) {
				out.addChar(c);
				if (c == "'".code) {
					// Look ahead for an escaped '' quote inside the literal.
					if (i + 1 < len && StringTools.fastCodeAt(text, i + 1) == "'".code) {
						out.addChar("'".code);
						i += 2;
						continue;
					}
					inString = false;
				}
				i++;
				continue;
			}

			if (c == "'".code) {
				inString = true;
				out.addChar(c);
				i++;
				continue;
			}

			if (c == ":".code && i + 1 < len && __isIdentStart(StringTools.fastCodeAt(text, i + 1))) {
				var j:Int = i + 1;
				while (j < len && __isIdentPart(StringTools.fastCodeAt(text, j))) {
					j++;
				}
				var name:String = text.substring(i + 1, j);
				var raw:Null<Dynamic> = lookup(name);
				if (raw != null) {
					out.add(escape(raw));
				} else {
					out.add(text.substring(i, j));
				}
				i = j;
				continue;
			}

			out.addChar(c);
			i++;
		}

		return out.toString();
	}

	private static inline function __isIdentStart(c:Int):Bool {
		return (c >= "A".code && c <= "Z".code) || (c >= "a".code && c <= "z".code) || c == "_".code;
	}

	private static inline function __isIdentPart(c:Int):Bool {
		return __isIdentStart(c) || (c >= "0".code && c <= "9".code);
	}
}
