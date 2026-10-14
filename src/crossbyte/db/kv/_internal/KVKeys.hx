package crossbyte.db.kv._internal;

import crossbyte.db.kv.KVScanOptions;
import crossbyte.errors.ArgumentError;

/**
	Keys as every store orders and bounds them: by code point, which is the
	order of their UTF-8 bytes, and so the order SQLite's BINARY collation and
	PostgreSQL's "C" collation give text. A string compared as a target holds
	it would not do: JavaScript, the jvm, HashLink and hxcpp compare UTF-16
	units, which put a character past U+FFFF (an emoji) before U+E000 to
	U+FFFF, where its UTF-8 sorts after them.

	A key holds no NUL (SQLite would bind it as a blob, which sorts apart from
	text), no surrogate that is not half of a pair (it has no UTF-8), and not
	U+10FFFF, the last code point: with none holding it, a string of it alone
	is above every key, and a prefix followed by it above every key that starts
	with the prefix, so every scan is one range, from a low key to a high one.
**/
@:noCompletion
class KVKeys {
	/**
		U+10FFFF, which no key holds: above every key. A literal, which every
		target holds as its own text (`String.fromCharCode` makes a byte of it
		on neko).
	**/
	public static inline var END:String = "\u{10FFFF}";

	/** U+0001: the least a key can go on with, so `key + SUCCESSOR` is the first key after `key`. **/
	public static inline var SUCCESSOR:String = "\u{1}";

	/**
		Refuses `text` as a key: null, empty unless `allowEmpty`, holding a NUL,
		an unpaired surrogate or U+10FFFF, or past `maxBytes` in UTF-8. `what`
		names it in the message.
	**/
	public static function check(text:String, maxBytes:Int, what:String, allowEmpty:Bool):Void {
		if (text == null) {
			throw new ArgumentError('$what is null.');
		}

		if (text.length == 0) {
			if (allowEmpty) {
				return;
			}

			throw new ArgumentError('$what is empty: a key is at least one character.');
		}

		var size:Int = __utf8Size(text, what);

		if (size > maxBytes) {
			throw new ArgumentError('$what is $size bytes in UTF-8, past the store\'s maxKeyBytes of $maxBytes.');
		}
	}

	/** `a` against `b` by code point: negative when `a` comes first, 0 when they are equal. **/
	public static function compare(a:String, b:String):Int {
		#if php
		return php.Global.strcmp(a, b);
		#else
		#if cpp
		// A string held a byte a character is ASCII: compared as hxcpp
		// compares it, byte by byte.
		var wideA:Bool = untyped __cpp__("{0}.isUTF16Encoded()", a);
		var wideB:Bool = untyped __cpp__("{0}.isUTF16Encoded()", b);

		if (!wideA && !wideB) {
			return a < b ? -1 : (a == b ? 0 : 1);
		}
		#end
		var shorter:Int = a.length < b.length ? a.length : b.length;

		for (i in 0...shorter) {
			var x:Int = StringTools.fastCodeAt(a, i);
			var y:Int = StringTools.fastCodeAt(b, i);

			if (x != y) {
				#if (cpp || jvm || java || js || hl)
				// UTF-16 units into code point order, as ICU compares them: a
				// surrogate (half of a code point past U+FFFF) above every other
				// unit, and U+E000 to U+FFFF moved down below it.
				if (x >= 0xD800 && y >= 0xD800) {
					x = x >= 0xE000 ? x - 0x800 : x + 0x2000;
					y = y >= 0xE000 ? y - 0x800 : y + 0x2000;
				}
				#end
				// Elsewhere these are code points (eval) or UTF-8 bytes (neko),
				// both already in code point order.
				return x < y ? -1 : 1;
			}
		}

		return a.length < b.length ? -1 : (a.length > b.length ? 1 : 0);
		#end
	}

	/**
		The keys a scan with `options` reads, from `low`, inclusive, to
		`high`, exclusive, with `base` before every bound (a repository's
		prefix); null when that is none. Refuses a bound that is not a key's
		text, or a limit not from 1 to `maxScanLimit`.
	**/
	public static function rangeOf(options:KVScanOptions, base:String, maxKeyBytes:Int, maxScanLimit:Int):Null<KVRange> {
		if (options.limit < 1 || options.limit > maxScanLimit) {
			throw new ArgumentError('A scan\'s limit is from 1 to the store\'s maxScanLimit of $maxScanLimit: ${options.limit} is not.');
		}

		var low:String = base;
		var high:String = base.length > 0 ? base + END : END;

		if (options.prefix != null && options.prefix.length > 0) {
			check(options.prefix, maxKeyBytes, "A scan's prefix", true);
			var prefix:String = base + options.prefix;
			low = max(low, prefix);
			high = min(high, prefix + END);
		}

		if (options.startAt != null) {
			check(options.startAt, maxKeyBytes, "A scan's startAt", true);
			low = max(low, base + options.startAt);
		}

		if (options.startAfter != null) {
			check(options.startAfter, maxKeyBytes, "A scan's startAfter", true);
			// The first key after it: nothing holds a NUL to come between.
			low = max(low, base + options.startAfter + SUCCESSOR);
		}

		if (options.endBefore != null) {
			check(options.endBefore, maxKeyBytes, "A scan's endBefore", true);
			high = min(high, base + options.endBefore);
		}

		return compare(low, high) < 0 ? new KVRange(low, high) : null;
	}

	/** The greater of two keys by code point. **/
	public static inline function max(a:String, b:String):String {
		return compare(a, b) >= 0 ? a : b;
	}

	/** The lesser of two keys by code point. **/
	public static inline function min(a:String, b:String):String {
		return compare(a, b) <= 0 ? a : b;
	}

	/**
		How many bytes `text` is in UTF-8, refusing a NUL, an unpaired
		surrogate and U+10FFFF.
	**/
	@:noCompletion private static function __utf8Size(text:String, what:String):Int {
		#if php
		// PHP's strings are their UTF-8: asked of PHP once rather than a
		// character at a time, each of which is a search from the start there.
		if (!php.Global.mb_check_encoding(text, "UTF-8")) {
			throw new ArgumentError('$what is not well-formed UTF-8.');
		}

		if (php.Syntax.strictNotEqual(php.Global.strpos(text, String.fromCharCode(0)), false)) {
			throw __nul(what);
		}

		if (php.Syntax.strictNotEqual(php.Global.strpos(text, END), false)) {
			throw __end(what);
		}

		return php.Global.strlen(text);
		#elseif neko
		// Neko's strings are bytes, its UTF-8.
		var length:Int = text.length;

		for (i in 0...length) {
			var byte:Int = StringTools.fastCodeAt(text, i);

			if (byte == 0) {
				throw __nul(what);
			}

			if (byte == 0xF4 && i + 3 < length && StringTools.fastCodeAt(text, i + 1) == 0x8F && StringTools.fastCodeAt(text, i + 2) == 0xBF
				&& StringTools.fastCodeAt(text, i + 3) == 0xBF) {
				throw __end(what);
			}
		}

		return length;
		#elseif (cpp || jvm || java || js || hl)
		var length:Int = text.length;
		var size:Int = 0;
		var i:Int = 0;

		while (i < length) {
			var unit:Int = StringTools.fastCodeAt(text, i++);

			if (unit < 0x80) {
				if (unit == 0) {
					throw __nul(what);
				}

				size++;
			} else if (unit < 0x800) {
				size += 2;
			} else if (unit < 0xD800 || unit >= 0xE000) {
				size += 3;
			} else {
				var low:Int = i < length ? StringTools.fastCodeAt(text, i) : 0;

				if (unit >= 0xDC00 || low < 0xDC00 || low >= 0xE000) {
					throw new ArgumentError('$what holds a surrogate that is not half of a pair, which has no UTF-8.');
				}

				if (unit == 0xDBFF && low == 0xDFFF) {
					throw __end(what);
				}

				size += 4;
				i++;
			}
		}

		return size;
		#else
		// Code points (eval).
		var size:Int = 0;

		for (i in 0...text.length) {
			var code:Int = StringTools.fastCodeAt(text, i);

			if (code == 0) {
				throw __nul(what);
			}

			if (code >= 0xD800 && code < 0xE000) {
				throw new ArgumentError('$what holds a surrogate that is not half of a pair, which has no UTF-8.');
			}

			if (code == 0x10FFFF) {
				throw __end(what);
			}

			size += code < 0x80 ? 1 : (code < 0x800 ? 2 : (code < 0x10000 ? 3 : 4));
		}

		return size;
		#end
	}

	@:noCompletion private static inline function __nul(what:String):ArgumentError {
		return new ArgumentError('$what holds a NUL, which no key may.');
	}

	@:noCompletion private static inline function __end(what:String):ArgumentError {
		return new ArgumentError('$what holds U+10FFFF, which no key may: the store keeps it to bound its scans.');
	}
}

/** The keys a scan reads: from `low`, inclusive, to `high`, exclusive. **/
@:noCompletion
final class KVRange {
	public final low:String;
	public final high:String;

	public function new(low:String, high:String) {
		this.low = low;
		this.high = high;
	}
}
