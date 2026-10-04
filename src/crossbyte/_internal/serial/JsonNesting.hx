package crossbyte._internal.serial;

/**
	How deep a JSON document's objects and arrays nest, measured before it is
	parsed.

	`haxe.Json` parses a frame per level, so natively a document nested a few
	thousand deep, 12 KB of brackets, overflows the stack and ends the
	process, where no catch can see it. JSON read from elsewhere is measured
	first: a token's header, a JWK Set and a token endpoint's answer at
	`LIMIT`, and an object `ByteArray.readObject` reads at
	`BoundedUnserializer.LIMIT`.
**/
class JsonNesting {
	/**
		The deepest a JWK Set or a token endpoint's answer may nest, objects
		and arrays together. Real ones nest three or four levels.
	**/
	public static inline var LIMIT:Int = 32;

	/**
		Whether the objects and arrays in `json` nest no deeper than `limit`.
		Brackets inside strings are text, escaped quotes included. One pass,
		allocating nothing; `null` nests nothing.

		Sound for `haxe.Json`'s parser: on any prefix of valid JSON the two
		agree on what is open, and the parser stops at the first character
		that would make them disagree.
	**/
	public static function within(json:String, limit:Int):Bool {
		if (json == null) {
			return true;
		}
		var depth:Int = 0;
		var inString:Bool = false;
		var i:Int = 0;
		var length:Int = json.length;
		while (i < length) {
			var code:Int = StringTools.fastCodeAt(json, i);
			if (inString) {
				if (code == "\\".code) {
					// Whatever is escaped, a quote included, is not structure.
					i++;
				} else if (code == '"'.code) {
					inString = false;
				}
			} else if (code == '"'.code) {
				inString = true;
			} else if (code == "{".code || code == "[".code) {
				depth++;
				if (depth > limit) {
					return false;
				}
			} else if (code == "}".code || code == "]".code) {
				depth--;
			}
			i++;
		}
		return true;
	}

	/**
		How many values `json` holds, objects, arrays, strings, names
		included, and the numbers, `true`, `false` and `null`, counted
		where each starts, without parsing; or `limit + 1` as soon as it is
		past `limit`. One pass, allocating nothing.

		What the parser makes of the text is no more than this: it makes a
		value only where one starts.
	**/
	public static function values(json:String, limit:Int):Int {
		if (json == null) {
			return 0;
		}
		var count:Int = 0;
		var inString:Bool = false;
		var inWord:Bool = false;
		var i:Int = 0;
		var length:Int = json.length;
		while (i < length) {
			var code:Int = StringTools.fastCodeAt(json, i);
			if (inString) {
				if (code == "\\".code) {
					i++;
				} else if (code == '"'.code) {
					inString = false;
				}
			} else {
				switch (code) {
					case '"'.code:
						inString = true;
						inWord = false;
						count++;
					case "{".code | "[".code:
						inWord = false;
						count++;
					case "}".code | "]".code | ",".code | ":".code | " ".code | "\t".code | "\n".code | "\r".code:
						inWord = false;
					default:
						// A number or a literal: one value however long.
						if (!inWord) {
							inWord = true;
							count++;
						}
				}
				if (count > limit) {
					return count;
				}
			}
			i++;
		}
		return count;
	}
}
