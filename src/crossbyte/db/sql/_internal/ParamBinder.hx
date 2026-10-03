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
 * - **Postgres escape strings**, `E'...'`, which honour backslash escapes
 *   whatever `standard_conforming_strings` says. They are read so in every
 *   dialect: elsewhere it can only make the scan take more of a statement
 *   for a literal than the server does, which leaves a placeholder
 *   unsubstituted, the loud failure, never the unsafe one.
 * - **Postgres dollar-quoting**, `$$ ... $$` and `$tag$ ... $tag$`, when the
 *   caller asks (`dollarQuotes`): everything up to the closing tag is
 *   literal, quotes included. Unmodelled, a placeholder inside one was
 *   substituted, and a value holding the tag ended the string there.
 *   Asked for by the Postgres driver only: SQLite reads `$name` as a
 *   parameter of its own.
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
	private static inline var DOLLAR:Int = 36; // $

	/**
	 * @param text    The source SQL/command text containing `:name` placeholders.
	 * @param lookup  Maps a placeholder name to its raw value, or `null` when the
	 *                name is unknown (placeholder is then left untouched).
	 * @param escape  Turns a raw value into the safe literal spliced into `text`
	 *                (e.g. SQL quoting/escaping, or JSON encoding for command text).
	 * @return The substituted text.
	 */
	public static function substitute(text:String, lookup:String->Null<Dynamic>, escape:Dynamic->String):String {
		// One lookup per placeholder, as before: `has` keeps what it found for
		// the `get` that follows it.
		var found:Null<Dynamic> = null;
		return substituteWith(text, name -> (found = lookup(name)) != null, _ -> found, escape, false);
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
	 * @param dollarQuotes Whether `$$ ... $$` and `$tag$ ... $tag$` quote, as
	 *                in Postgres.
	 */
	public static function substituteWith(text:String, has:String->Bool, get:String->Null<Dynamic>, escape:Dynamic->String,
			backslashEscapes:Bool, dollarQuotes:Bool = false):String {
		if (text == null || text.indexOf(":") < 0) {
			// No placeholder can be in it.
			return text;
		}

		return ParamTemplate.parse(text, backslashEscapes, dollarQuotes).render(has, get, escape);
	}

	/**
		Where `text`'s placeholders are, by the rules above: the start of
		each `:name` substituted in turn, and the end of its name, as pairs.
		Empty when it has none.
	**/
	@:noCompletion public static function placeholders(text:String, backslashEscapes:Bool, dollarQuotes:Bool):Array<Int> {
		var found:Array<Int> = [];
		var len:Int = text.length;
		var i:Int = 0;

		// The closing character of the quoted run being scanned, or 0 outside
		// one. Single quotes delimit literals and the other two delimit
		// identifiers, but for this scan they behave alike: a doubled quote
		// stands for itself, and nothing inside is substituted.
		var quote:Int = 0;
		// Whether a backslash escapes inside the run being scanned: always in
		// the dialect's mode, and in a Postgres E'...' string whatever it is.
		var runBackslashes:Bool = false;
		var lineComment:Bool = false;
		var blockDepth:Int = 0;

		while (i < len) {
			var c:Int = StringTools.fastCodeAt(text, i);
			var next:Int = (i + 1 < len) ? StringTools.fastCodeAt(text, i + 1) : 0;

			if (lineComment) {
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
					i += 2;
					continue;
				}

				if (c == STAR && next == SLASH) {
					blockDepth--;
					i += 2;
					continue;
				}

				i++;
				continue;
			}

			if (quote != 0) {
				if (runBackslashes && c == BACKSLASH && i + 1 < len) {
					// The next character is escaped, a quote included, and
					// does not end the run.
					i += 2;
					continue;
				}

				if (c == quote) {
					if (next == quote) {
						// A doubled quote stands for the character itself and
						// does not end the run.
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
				runBackslashes = backslashEscapes || (c == SINGLE_QUOTE && __isEscapeStringPrefix(text, i));
				i++;
				continue;
			}

			if (dollarQuotes && c == DOLLAR && (i == 0 || !__isIdentPartOrDollar(StringTools.fastCodeAt(text, i - 1)))) {
				var tagEnd:Int = __dollarTagEnd(text, i);

				if (tagEnd > 0) {
					// Literal up to and including the closing tag, or to the
					// end, unterminated, where the server will refuse it.
					var tag:String = text.substring(i, tagEnd);
					var close:Int = text.indexOf(tag, tagEnd);
					i = close < 0 ? len : close + tag.length;
					continue;
				}
			}

			if (c == DASH && next == DASH) {
				lineComment = true;
				i += 2;
				continue;
			}

			if (c == SLASH && next == STAR) {
				blockDepth = 1;
				i += 2;
				continue;
			}

			if (c == COLON && __isIdentStart(next)) {
				var j:Int = i + 1;
				while (j < len && __isIdentPart(StringTools.fastCodeAt(text, j))) {
					j++;
				}
				found.push(i);
				found.push(j);
				i = j;
				continue;
			}

			i++;
		}

		return found;
	}

	/**
		Whether the quote at `at` opens a Postgres escape string: an `E` or
		`e` before it that does not end a name, as in `E'it\'s'` and not in
		`typE'...'`.
	**/
	private static function __isEscapeStringPrefix(text:String, at:Int):Bool {
		if (at < 1) {
			return false;
		}

		var prefix:Int = StringTools.fastCodeAt(text, at - 1);

		if (prefix != "E".code && prefix != "e".code) {
			return false;
		}

		return at < 2 || !__isIdentPartOrDollar(StringTools.fastCodeAt(text, at - 2));
	}

	/**
		Where the dollar-quote tag opening at `at` ends, just past its
		second `$`, or -1 when there is none: `$$`, or `$` and a name and
		`$`. A digit cannot start the name, so `$1` is a parameter.
	**/
	private static function __dollarTagEnd(text:String, at:Int):Int {
		var j:Int = at + 1;

		if (j < text.length && StringTools.fastCodeAt(text, j) == DOLLAR) {
			return j + 1;
		}

		if (j >= text.length || !__isIdentStart(StringTools.fastCodeAt(text, j))) {
			return -1;
		}

		while (j < text.length && __isIdentPart(StringTools.fastCodeAt(text, j))) {
			j++;
		}

		return j < text.length && StringTools.fastCodeAt(text, j) == DOLLAR ? j + 1 : -1;
	}

	/** A character that continues a Postgres name, where `$` may follow the first. **/
	private static inline function __isIdentPartOrDollar(c:Int):Bool {
		return __isIdentPart(c) || c == DOLLAR;
	}

	private static inline function __isIdentStart(c:Int):Bool {
		return (c >= "A".code && c <= "Z".code) || (c >= "a".code && c <= "z".code) || c == "_".code;
	}

	private static inline function __isIdentPart(c:Int):Bool {
		return __isIdentStart(c) || (c >= "0".code && c <= "9".code);
	}
}

/**
	A statement's text split once at its placeholders, by `ParamBinder`'s
	rules, for substituting values into it again and again: a statement run
	repeatedly scans its text once, not on every run.

	The scan copied the statement into a buffer a character at a time on
	every run, and ran even with no placeholder in the text: 270-460 ns for a
	55-character SELECT with none, 1.5-2.8 µs with six (the audit's
	SqlitePerf). Rendering is now its pieces joined, and text with no
	placeholder is itself.
**/
@:noCompletion
class ParamTemplate {
	/** The text it was made from. **/
	public var text(default, null):String;

	public var backslashEscapes(default, null):Bool;
	public var dollarQuotes(default, null):Bool;

	// The text between placeholders: one more than there are names.
	@:noCompletion private var __pieces:Array<String>;
	// Each placeholder's name, and as it was written, `:name`.
	@:noCompletion private var __names:Array<String>;
	@:noCompletion private var __written:Array<String>;

	@:noCompletion private function new(text:String, backslashEscapes:Bool, dollarQuotes:Bool) {
		this.text = text;
		this.backslashEscapes = backslashEscapes;
		this.dollarQuotes = dollarQuotes;
	}

	/** `text`, split at its placeholders. **/
	public static function parse(text:String, backslashEscapes:Bool, dollarQuotes:Bool):ParamTemplate {
		var template:ParamTemplate = new ParamTemplate(text, backslashEscapes, dollarQuotes);
		var pieces:Array<String> = [];
		var names:Array<String> = [];
		var written:Array<String> = [];

		if (text != null && text.indexOf(":") >= 0) {
			var found:Array<Int> = ParamBinder.placeholders(text, backslashEscapes, dollarQuotes);
			var at:Int = 0;
			var k:Int = 0;

			while (k < found.length) {
				var start:Int = found[k];
				var end:Int = found[k + 1];
				pieces.push(text.substring(at, start));
				names.push(text.substring(start + 1, end));
				written.push(text.substring(start, end));
				at = end;
				k += 2;
			}

			pieces.push(text.substring(at));
		}

		template.__pieces = pieces;
		template.__names = names;
		template.__written = written;
		return template;
	}

	/** Whether it was made from `text`, read the same way. **/
	public inline function matches(text:String, backslashEscapes:Bool, dollarQuotes:Bool):Bool {
		return this.text == text && this.backslashEscapes == backslashEscapes && this.dollarQuotes == dollarQuotes;
	}

	/** The text with each placeholder `has` knows replaced by `escape` of its value. **/
	public function render(has:String->Bool, get:String->Null<Dynamic>, escape:Dynamic->String):String {
		var count:Int = __names.length;

		if (count == 0) {
			return text;
		}

		var out:StringBuf = new StringBuf();

		for (i in 0...count) {
			out.add(__pieces[i]);
			var name:String = __names[i];
			out.add(has(name) ? escape(get(name)) : __written[i]);
		}

		out.add(__pieces[count]);
		return out.toString();
	}

	/**
		`render` from a map of values: a placeholder whose name the map has
		is replaced, even by `escape` of a null value; one it has not is left
		as written.
	**/
	public function renderMap(values:haxe.ds.StringMap<Dynamic>, escape:Dynamic->String):String {
		var count:Int = __names.length;

		if (count == 0) {
			return text;
		}

		var out:StringBuf = new StringBuf();

		for (i in 0...count) {
			out.add(__pieces[i]);
			var name:String = __names[i];
			out.add(values.exists(name) ? escape(values.get(name)) : __written[i]);
		}

		out.add(__pieces[count]);
		return out.toString();
	}
}
