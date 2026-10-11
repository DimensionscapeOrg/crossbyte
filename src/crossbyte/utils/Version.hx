package crossbyte.utils;

import crossbyte.errors.ArgumentError;

/**
	A `major.minor.patch` version, held as its string, that compares part by
	part.

	```haxe
	var installed:Version = "2.4";
	if (installed < new Version(2, 10, 0)) {
		upgrade();
	}
	```

	A string is read leniently: a missing part is 0, a part reads as its
	leading digits (so `3-beta` is 3, and a pre-release or build suffix is
	not compared: `1.2.3-beta == 1.2.3`), a part with no digits is 0, and a
	`v` before the first part is allowed. A part with more digits than an
	`Int` holds reads as the largest `Int`, alike on every target.

	`==` and `!=` take `null`: it is equal to `null` and to no version.
	`<`, `>`, `<=`, `>=` and `compare` refuse it.
**/
abstract Version(String) from String to String {
	public var major(get, set):Int;

	public var minor(get, set):Int;

	public var patch(get, set):Int;

	/**
		`major * 1000000 + minor * 1000 + patch`, each part held to 999.

		It orders only versions whose parts are all below 1000; the
		comparisons do not use it, and compare the parts themselves.
	**/
	public var hash(get, never):Int;

	/**
		@throws ArgumentError If a part is below zero.
	**/
	public inline function new(major:Int, minor:Int, patch:Int) {
		__check(major, minor, patch);
		this = '${major}.${minor}.${patch}';
	}

	private inline function get_major():Int {
		return __part(this, 0);
	}

	private inline function set_major(value:Int):Int {
		__check(value, 0, 0);
		this = '${value}.${minor}.${patch}';
		return value;
	}

	private inline function get_minor():Int {
		return __part(this, 1);
	}

	private inline function set_minor(value:Int):Int {
		__check(0, value, 0);
		this = '${major}.${value}.${patch}';
		return value;
	}

	private inline function get_patch():Int {
		return __part(this, 2);
	}

	private inline function set_patch(value:Int):Int {
		__check(0, 0, value);
		this = '${major}.${minor}.${value}';
		return value;
	}

	private inline function get_hash():Int {
		return __held(__part(this, 0)) * 1000000 + __held(__part(this, 1)) * 1000 + __held(__part(this, 2));
	}

	private static inline function __held(part:Int):Int {
		return part > 999 ? 999 : part;
	}

	private static function __check(major:Int, minor:Int, patch:Int):Void {
		if (major < 0 || minor < 0 || patch < 0) {
			throw new ArgumentError('A version part cannot be below zero ($major.$minor.$patch).');
		}
	}

	/**
		Part `index`'s leading digits, read in place rather than through
		`split`, and not through `Std.parseInt`, whose answer for more digits
		than an Int holds differs by target (0 on Linux native, a throw on the
		jvm). Spaces before the digits are passed over, as is a `v` before the
		first part's.
	**/
	private static function __part(text:String, index:Int):Int {
		var length:Int = text.length;
		var at:Int = 0;
		for (_ in 0...index) {
			var dot:Int = text.indexOf(".", at);
			if (dot < 0) {
				return 0;
			}
			at = dot + 1;
		}
		while (at < length && StringTools.isSpace(text, at)) {
			at++;
		}
		if (index == 0 && at < length) {
			var first:Int = StringTools.fastCodeAt(text, at);
			if (first == "v".code || first == "V".code) {
				at++;
			}
		}
		var value:Int = 0;
		while (at < length) {
			var digit:Int = StringTools.fastCodeAt(text, at) - "0".code;
			if (digit < 0 || digit > 9) {
				break;
			}
			// Past 214748364, or at it with a digit past 7, the next step
			// would pass the largest Int: it stays there instead.
			value = value > 214748364 || (value == 214748364 && digit > 7) ? 0x7FFFFFFF : value * 10 + digit;
			at++;
		}
		return value;
	}

	/**
		Below zero when `a` is the older, zero when the two are the same
		version, and above zero when `a` is the newer: for `Array.sort`.

		@throws ArgumentError If either is `null`.
	**/
	public static function compare(a:Version, b:Version):Int {
		var left:String = a;
		var right:String = b;
		if (left == null || right == null) {
			throw new ArgumentError('A null Version has no order (comparing $left with $right).');
		}
		var order:Int = 0;
		var index:Int = 0;
		while (order == 0 && index < 3) {
			var x:Int = __part(left, index);
			var y:Int = __part(right, index);
			order = x < y ? -1 : (x > y ? 1 : 0);
			index++;
		}
		return order;
	}

	@:op(A < B)
	public static inline function lessThan(v1:Version, v2:Version):Bool {
		return compare(v1, v2) < 0;
	}

	@:op(A > B)
	public static inline function greaterThan(v1:Version, v2:Version):Bool {
		return compare(v1, v2) > 0;
	}

	@:op(A <= B)
	public static inline function lessThanOrEqual(v1:Version, v2:Version):Bool {
		return compare(v1, v2) <= 0;
	}

	@:op(A >= B)
	public static inline function greaterThanOrEqual(v1:Version, v2:Version):Bool {
		return compare(v1, v2) >= 0;
	}

	/** The same version: `1.2` is `1.2.0`. `null` is equal only to `null`. **/
	@:op(A == B)
	public static function equals(v1:Version, v2:Version):Bool {
		var left:String = v1;
		var right:String = v2;
		return left == null || right == null ? left == right : compare(v1, v2) == 0;
	}

	@:op(A != B)
	public static inline function notEquals(v1:Version, v2:Version):Bool {
		return !equals(v1, v2);
	}
}
