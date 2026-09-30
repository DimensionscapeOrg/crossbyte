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
 * - A placeholder whose name has no matching parameter (`lookup` returns `null`)
 *   is left verbatim. `substituteWith` tells a parameter that is absent from
 *   one whose value is null, which it substitutes.
 * - Occurrences anywhere the surrounding text is not plain SQL are left
 *   untouched: single-quoted literals, double-quoted and backtick-quoted
 *   identifiers, `--` line comments and `/* *\/` block comments.
 *
 * That last rule is the security-relevant one, and it is deliberately wider
 * than it needs to be for any single dialect. `escape` can only make a value
 * safe for the context it is actually spliced into, so substituting anywhere
 * the scanner does not model is substituting under an assumption that may not
 * hold. Skipping a context this scanner cannot reason about produces a query
 * with an unsubstituted `:name` in it, a loud, immediate failure, while
 * substituting into one produces a query that runs and may not mean what it
 * says.
 *
 * Comments are the sharpest case: quoting carries no meaning inside one, so a
 * value containing a newline ends the comment and everything after it becomes
 * statement text, no matter how correctly the value was escaped.
 *
 * - **Backslash escapes inside literals**, when the caller says the server
 *   honours them: MySQL does unless `NO_BACKSLASH_ESCAPES` is set, and
 *   Postgres does not with `standard_conforming_strings` on. `substitute`
 *   ends a literal at the first undoubled quote, so against MySQL a literal
 *   holding a backslash-escaped quote left the scanner and the server
 *   disagreeing about where the string ended, in one direction a
 *   placeholder was left unsubstituted, in the other one was substituted at a
 *   point the server still read as inside a literal. `substituteWith` takes
 *   `backslashEscapes`, which the MySQL driver sets from the session's mode.
 *
 * Still not modelled, and named here rather than left to be discovered:
 *
 * - **Postgres dollar-quoting** (`$$ ... $$`, `$tag$ ... $tag$`).
 */
class ParamBinder {
	// Character codes, spelled out rather than written as escapes, because the
	// set includes both quote characters and a backslash-adjacent one.
	private static inline var SINGLE_QUOTE:Int = 39; // '
	private static inline var DOUBLE_QUOTE:Int = 34; // "
	private static inline var BACKTICK:Int = 96; // `
	private static inline var COLON:Int = 58; // :
	private static inline var DASH:Int = 45; // -
	private static inline var SLASH:Int = 47; // /
	private static inline var STAR:Int = 42; // *
	private static inline var NEWLINE:Int = 10;
	private static inline var BACKSLASH:Int = 92;

	/**
	 * @param text    The source SQL/command text containing `:name` placeholders.
	 * @param lookup  Maps a placeholder name to its raw value, or `null` when the
	 *                name is unknown (placeholder is then left untouched).
	 * @param escape  Turns a raw value into the safe literal spliced into `text`
	 *                (e.g. SQL quoting/escaping, or JSON encoding for command text).
	 * @return The substituted text.
	 */
	public static function substitute(text:String, lookup:String->Null<Dynamic>, escape:Dynamic->String):String {
		return substituteWith(text, name -> lookup(name) != null, lookup, escape, false);
	}

	/**
	 * `substitute`, for a caller whose values can be null and whose dialect
	 * escapes quotes with a backslash.
	 *
	 * @param has     Whether a parameter of that name exists. One that does is
	 *                substituted even when `get` gives `null`, as `NULL`, or
	 *                whatever `escape` makes of null, where `substitute`
	 *                left it in the SQL as `:name`.
	 * @param get     The raw value of a parameter `has` said exists.
	 * @param escape  As for `substitute`.
	 * @param backslashEscapes Whether a backslash inside a quoted run escapes
	 *                the character after it, as in MySQL's default mode.
	 */
	public static function substituteWith(text:String, has:String->Bool, get:String->Null<Dynamic>, escape:Dynamic->String,
			backslashEscapes:Bool):String {
		if (text == null || text == "") {
			return text;
		}

		var out:StringBuf = new StringBuf();
		var len:Int = text.length;
		var i:Int = 0;

		// The closing character of the quoted run being scanned, or 0 outside
		// one. Single quotes delimit literals and the other two delimit
		// identifiers, but for this scan they behave alike: a doubled quote
		// stands for itself, and nothing inside is substituted.
		var quote:Int = 0;
		var lineComment:Bool = false;
		var blockDepth:Int = 0;

		while (i < len) {
			var c:Int = StringTools.fastCodeAt(text, i);
			var next:Int = (i + 1 < len) ? StringTools.fastCodeAt(text, i + 1) : 0;

			if (lineComment) {
				out.addChar(c);
				if (c == NEWLINE) {
					lineComment = false;
				}
				i++;
				continue;
			}

			if (blockDepth > 0) {
				// Nested, because Postgres nests. A dialect that does not will
				// simply keep the scanner inside the comment longer than the
				// server does, which costs a substitution rather than making
				// an unsafe one.
				if (c == SLASH && next == STAR) {
					blockDepth++;
					out.addChar(c);
					out.addChar(next);
					i += 2;
					continue;
				}

				if (c == STAR && next == SLASH) {
					blockDepth--;
					out.addChar(c);
					out.addChar(next);
					i += 2;
					continue;
				}

				out.addChar(c);
				i++;
				continue;
			}

			if (quote != 0) {
				out.addChar(c);

				if (backslashEscapes && c == BACKSLASH && i + 1 < len) {
					// The next character is escaped, a quote included, and
					// does not end the run.
					out.addChar(next);
					i += 2;
					continue;
				}

				if (c == quote) {
					if (next == quote) {
						// A doubled quote stands for the character itself and
						// does not end the run.
						out.addChar(next);
						i += 2;
						continue;
					}

					quote = 0;
				}

				i++;
				continue;
			}

			if (c == SINGLE_QUOTE || c == DOUBLE_QUOTE || c == BACKTICK) {
				quote = c;
				out.addChar(c);
				i++;
				continue;
			}

			if (c == DASH && next == DASH) {
				lineComment = true;
				out.addChar(c);
				out.addChar(next);
				i += 2;
				continue;
			}

			if (c == SLASH && next == STAR) {
				blockDepth = 1;
				out.addChar(c);
				out.addChar(next);
				i += 2;
				continue;
			}

			if (c == COLON && __isIdentStart(next)) {
				var j:Int = i + 1;
				while (j < len && __isIdentPart(StringTools.fastCodeAt(text, j))) {
					j++;
				}
				var name:String = text.substring(i + 1, j);
				if (has(name)) {
					out.add(escape(get(name)));
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
