package crossbyte.db.mongodb.bson;

import crossbyte.errors.ArgumentError;

/**
	A BSON regular expression: a pattern and its option letters, stored as
	text for the server to run, not compiled here.

	The options are kept in alphabetical order, as the BSON specification
	requires of an encoder.
**/
final class BsonRegex {
	public var pattern(default, null):String;
	public var options(default, null):String;

	public function new(pattern:String, options:String = "") {
		if (pattern == null) {
			throw new ArgumentError("A BSON regular expression needs a pattern.");
		}

		// Both travel as C strings, which end at the first NUL.
		if (pattern.indexOf("\x00") >= 0 || (options != null && options.indexOf("\x00") >= 0)) {
			throw new ArgumentError("A BSON regular expression cannot contain a NUL character.");
		}

		this.pattern = pattern;
		this.options = __sorted(options == null ? "" : options);
	}

	public function equals(other:BsonRegex):Bool {
		return other != null && other.pattern == pattern && other.options == options;
	}

	public function toString():String {
		return '/$pattern/$options';
	}

	@:noCompletion private static function __sorted(options:String):String {
		if (options.length < 2) {
			return options;
		}

		var letters:Array<String> = options.split("");
		letters.sort((a, b) -> a < b ? -1 : (a > b ? 1 : 0));
		return letters.join("");
	}
}
