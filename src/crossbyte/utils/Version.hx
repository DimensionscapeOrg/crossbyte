package crossbyte.utils;

/** Semantic version helper with comparable major/minor/patch accessors. */
abstract Version(String) from String to String {
	public var major(get, set):Int;

	public var minor(get, set):Int;

	public var patch(get, set):Int;

	public var hash(get, never):Int;

	public inline function new(major:Int, minor:Int, patch:Int) {
		if (Std.string(major).length > 3) {
			throw "Major version can only be max length of 3 digits";
		}

		if (Std.string(minor).length > 3) {
			throw "Minor version can only be max length of 3 digits";
		}

		if (Std.string(patch).length > 3) {
			throw "Patch version can only be max length of 3 digits";
		}

		this = '${major}.${minor}.${patch}';
	}

	private inline function get_major():Int {
		return getSub(0);
	}

	private inline function set_major(value:Int):Int {
		this = '${value}.${minor}.${patch}';
		return value;
	}

	private inline function get_minor():Int {
		return getSub(1);
	}

	private inline function set_minor(value:Int):Int {
		this = '${major}.${value}.${patch}';
		return value;
	}

	private inline function get_patch():Int {
		return getSub(2);
	}

	private inline function set_patch(value:Int):Int {
		this = '${major}.${minor}.${value}';
		return value;
	}

	private inline function get_hash():Int {
		// Parse the string once and combine the three components directly,
		// avoiding several Array splits and padded-string allocations per call.
		// Matches the legacy zero-padded-concat semantics: major*1000000 + minor*1000 + patch.
		var parts:Array<String> = this.split(".");
		var majorVal:Int = parseSegment(parts, 0);
		var minorVal:Int = parseSegment(parts, 1);
		var patchVal:Int = parseSegment(parts, 2);
		return majorVal * 1000000 + minorVal * 1000 + patchVal;
	}

	private inline function getSub(index:Int):Int {
		return parseSegment(this.split("."), index);
	}

	private static inline function parseSegment(parts:Array<String>, index:Int):Int {
		if (index < 0 || index >= parts.length) {
			return 0;
		}
		var parsed:Null<Int> = Std.parseInt(parts[index]);
		return parsed != null ? parsed : 0;
	}

	// Overload the < operator

	@:op(A < B)
	public static function lessThan(v1:Version, v2:Version):Bool {
		return v1.hash < v2.hash;
	}

	// Overload the > operator

	@:op(A > B)
	public static function greaterThan(v1:Version, v2:Version):Bool {
		return v1.hash > v2.hash;
	}

	// Overload the <= operator

	@:op(A <= B)
	public static function lessThanOrEqual(v1:Version, v2:Version):Bool {
		return v1.hash <= v2.hash;
	}

	// Overload the >= operator

	@:op(A >= B)
	public static function greaterThanOrEqual(v1:Version, v2:Version):Bool {
		return v1.hash >= v2.hash;
	}

	// Overload the == operator

	@:op(A == B)
	public static function equals(v1:Version, v2:Version):Bool {
		return v1.hash == v2.hash;
	}
}
