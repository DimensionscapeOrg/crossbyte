package crossbyte._internal.serial;

import crossbyte.errors.IOError;
import haxe.Unserializer;

/**
	`haxe.Unserializer` that refuses a value nested more than `limit` deep,
	before the stack does, and one holding more than `values` values, before
	memory does, with an `IOError`.

	Unserializing takes a frame or two per level, so natively a payload
	another process or a peer wrote nested 6,000 deep (12 KB, inside a
	region's, a message's or a socket's limit) would overflow the stack and
	end the process reading it, where no catch can see it. On Windows'
	1 MB thread stacks nested objects overflow past 2,000 levels and arrays
	past 3,000, and a macOS worker thread has half the stack. What reads
	HXSF from elsewhere reads it through this: `ByteArray.readObject` (and
	so every socket's), `SharedObject` and `SharedChannel`.

	Every level goes through `unserialize()`, a class's own `hxUnserialize`
	included, so counting there bounds them all.

	Counting values there bounds what a payload can make of its bytes. Every
	value costs a byte at least, but for one: a run of nulls in an array, `u`
	and a count, which makes an array of that many slots from twelve bytes
	(`au100000000h`, 800 MB natively). And the standard library moves the
	read back by a negative string or bytes length, so a six-byte payload
	would read the same value again for ever, adding it to an array until
	memory ran out. Both are refused.
**/
class BoundedUnserializer extends Unserializer {
	/**
		Values within values, at most: deeper than any structure a program
		keeps, and well inside the smallest stack a reader runs on: a macOS
		worker thread's, or the interpreter's, where this class's own frame
		per level runs out near 510 levels.
	**/
	public static inline var LIMIT:Int = 256;

	/** The values one read may hold unless changed; see `maxValues`. **/
	public static inline var VALUES:Int = 1000000;

	/**
		The values one read may hold, every read in the process: what
		`ByteArray.maxObjectValues` sets. Zero or less is no limit.
	**/
	public static var maxValues:Int = VALUES;

	@:noCompletion private var __depth:Int = 0;
	@:noCompletion private var __limit:Int;

	// The values this read may make, and how many it still may; see __count.
	@:noCompletion private var __most:Int;
	@:noCompletion private var __left:Int;

	/**
		@param values The most values the read may hold, or zero or less
		       for no limit. `maxValues` unless given.
	**/
	public function new(buffer:String, limit:Int = LIMIT, ?values:Int) {
		super(buffer);
		__limit = limit;
		var most:Int = values != null ? values : maxValues;
		__most = most > 0 ? most : 0x7FFFFFFF;
		__left = __most;
	}

	/**
		Unserializes `buffer`, refusing a value nested more than `limit` deep
		or holding more than `values` values, `maxValues` unless given.
	**/
	public static function run(buffer:String, limit:Int = LIMIT, ?values:Int):Dynamic {
		return new BoundedUnserializer(buffer, limit, values).unserialize();
	}

	override public function unserialize():Dynamic {
		if (++__depth > __limit) {
			throw new IOError('nested more than $__limit levels deep');
		}
		__count(1);
		var start:Int = pos;
		var code:Int = get(pos);
		var value:Dynamic;
		if (code == "a".code) {
			value = __array();
		} else if (code == "y".code) {
			value = __string();
		} else {
			if (code == "s".code) {
				// Bytes: the length looked at before the standard library
				// sizes a buffer by it.
				pos++;
				var size:Int = readDigits();
				pos = start;
				if (size < 0) {
					__negative(start);
				}
			}
			value = super.unserialize();
		}
		if (pos <= start) {
			// Every value takes a byte at least, and one that took none
			// would be read again, and again.
			__negative(start);
		}
		__depth--;
		return value;
	}

	@:noCompletion private function __negative(at:Int):Void {
		throw new IOError('malformed: a negative length at position $at');
	}

	// `haxe.Unserializer`'s string, refusing a negative length: the standard
	// library moves the read back by it, onto bytes it has read already.
	@:noCompletion private function __string():String {
		var start:Int = pos++;
		var len:Int = readDigits();
		if (len < 0) {
			__negative(start);
		}
		if (get(pos++) != ":".code || length - pos < len) {
			throw "Invalid string length";
		}
		var s:String = buf.substr(pos, len);
		pos += len;
		s = StringTools.urlDecode(s);
		scache.push(s);
		return s;
	}

	// One less value the read may make, or `n` less for a run of nulls; the
	// read is refused past the last. Counted from what is left, so a count
	// near 2^31 cannot wrap past the check.
	@:noCompletion private inline function __count(n:Int):Void {
		if (n > __left) {
			throw new IOError('more than $__most values');
		}
		__left -= n;
	}

	// `haxe.Unserializer`'s array, its runs of nulls counted as values: a
	// run is the one way a value costs no byte of its own. Otherwise as the
	// standard library reads it.
	@:noCompletion private function __array():Dynamic {
		pos++;
		var a:Array<Dynamic> = new Array<Dynamic>();
		#if cpp
		var cachePos:Int = cache.length;
		#end
		cache.push(a);
		while (true) {
			var c:Int = get(pos);
			if (c == "h".code) {
				pos++;
				break;
			}
			if (c == "u".code) {
				pos++;
				var n:Int = readDigits();
				if (n < 1) {
					// One of no nulls or fewer set an element already read.
					throw new IOError('malformed: a run of $n nulls');
				}
				__count(n);
				a[a.length + n - 1] = null;
			} else {
				a.push(unserialize());
			}
		}
		#if cpp
		return cache[cachePos] = cpp.NativeArray.resolveVirtualArray(a);
		#else
		return a;
		#end
	}
}
