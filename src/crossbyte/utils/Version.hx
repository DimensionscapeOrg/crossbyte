package crossbyte.utils;

/**
 * ...
 * @author Christopher Speciale
 */
abstract Version(String) from String to String {
	public var major(get, set):Int;

	public var minor(get, set):Int;

	public var patch(get, set):Int;

	public var hash(get, never):Int;

	public inline function new(major:Int, minor:Int, patch:Int) {
		if (Std.string(major).length > 3) {
			throw "Major version can only be max length of 3 digits";
		}

		if (Std.string(major).length > 3) {
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
		var majorVal:String = StringTools.lpad(Std.string(major), "0", 3);
		var minorVal:String = StringTools.lpad(Std.string(minor), "0", 3);
		var patchVal:String = StringTools.lpad(Std.string(patch), "0", 3);

		var hashVal:String = majorVal + minorVal + patchVal;

		return Std.parseInt(hashVal);
	}

	private function getSub(index:Int):Int {
		return Std.parseInt(this.split(".")[index]);
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
