package crossbyte.rpc._internal;

import haxe.ds.IntMap;
import haxe.ds.StringMap;

/**
	The compiled lane's maps at run time: a map's keys, in the order they go
	on the wire.

	A map is written as its count and then each entry, key then value, in
	its keys' order, so one map is the same bytes whichever target, build or
	insertion order wrote it. `String` keys are ordered by their UTF-16 code
	units, as JSON's canonical form (RFC 8785) orders a member's names and as
	Haxe compares strings natively, on the jvm, JavaScript and HashLink;
	where a target compares by code point (eval, PHP, Python, Lua) or by
	UTF-8 byte (neko) the comparison here does it by unit itself. `Int`
	keys go in ascending order, signed.

	The keys are copied into an array of their own (natively the one the
	map's own `keys` makes), sorted in place there with no closure and no
	value boxed, by an introsort: quicksort, insertion sort for short runs,
	and heapsort past a depth, so no set of keys a peer sends makes it
	quadratic.
**/
@:noCompletion
class RPCMaps {
	/** The keys of `map`, in an array of their own, in wire order. **/
	public static function stringKeys<T>(map:StringMap<T>):Array<String> {
		#if cpp
		final keys:Array<String> = untyped __global__.__string_hash_keys(@:privateAccess map.h);
		#elseif jvm
		final keys:Array<String> = [];
		keys.resize(@:privateAccess map.hashMap.size());
		var at:Int = 0;
		for (key in map.keys()) {
			keys[at++] = key;
		}
		#else
		final keys:Array<String> = [for (key in map.keys()) key];
		#end
		sortStrings(keys);
		return keys;
	}

	/** The keys of `map`, in an array of their own, in ascending order. **/
	public static function intKeys<T>(map:IntMap<T>):Array<Int> {
		#if cpp
		final keys:Array<Int> = untyped __global__.__int_hash_keys(@:privateAccess map.h);
		#else
		final keys:Array<Int> = [for (key in map.keys()) key];
		#end
		sortInts(keys);
		return keys;
	}

	/**
		Whether `a` comes before `b`: by UTF-16 code unit, a string before
		any it begins.
	**/
	public static inline function before(a:String, b:String):Bool {
		#if (cpp || jvm || java || js || hl || cs)
		// What these compare natively.
		return a < b;
		#else
		return __byUnits(a, b) < 0;
		#end
	}

	/**
		`a` against `b` by UTF-16 code unit, on a target whose strings are
		code points (or bytes): the first code point that differs is compared
		as the units it would be.
	**/
	@:noCompletion public static function __byUnits(a:String, b:String):Int {
		final shorter:Int = a.length < b.length ? a.length : b.length;
		#if neko
		// Neko's strings are UTF-8 bytes. The two agree up to the first byte
		// that differs, so the code point holding it starts at the same place
		// in both: back up to that start and compare the two code points.
		var i:Int = 0;
		while (i < shorter && StringTools.fastCodeAt(a, i) == StringTools.fastCodeAt(b, i)) {
			i++;
		}
		if (i == shorter) {
			return a.length - b.length;
		}
		while (i > 0 && (StringTools.fastCodeAt(a, i) & 0xC0) == 0x80) {
			i--;
		}
		return byUnitsOf(codePointAt(a, i), codePointAt(b, i));
		#else
		for (i in 0...shorter) {
			final x:Int = StringTools.fastCodeAt(a, i);
			final y:Int = StringTools.fastCodeAt(b, i);
			if (x != y) {
				return byUnitsOf(x, y);
			}
		}
		return a.length - b.length;
		#end
	}

	/** Two different code points against each other as their UTF-16 units. **/
	static inline function byUnitsOf(x:Int, y:Int):Int {
		final xUnit:Int = x >= 0x10000 ? 0xD800 + ((x - 0x10000) >> 10) : x;
		final yUnit:Int = y >= 0x10000 ? 0xD800 + ((y - 0x10000) >> 10) : y;
		// Two code points past the first plane with one high surrogate: their
		// low ones decide.
		return xUnit != yUnit ? xUnit - yUnit : ((x - 0x10000) & 0x3FF) - ((y - 0x10000) & 0x3FF);
	}

	#if neko
	/** The code point whose UTF-8 starts at byte `at` of `s` (a stray byte as itself). **/
	static function codePointAt(s:String, at:Int):Int {
		final lead:Int = StringTools.fastCodeAt(s, at);
		final count:Int = lead >= 0xF0 ? 3 : (lead >= 0xE0 ? 2 : (lead >= 0xC0 ? 1 : 0));
		if (count == 0 || at + count >= s.length) {
			return lead;
		}
		var code:Int = lead & (0x3F >> count);
		for (k in 1...count + 1) {
			code = (code << 6) | (StringTools.fastCodeAt(s, at + k) & 0x3F);
		}
		return code;
	}
	#end

	// ------------------------------------------------------------ sorting

	/** Below this many, a run is sorted by insertion. **/
	static inline final SHORT_RUN:Int = 16;

	/** How deep the quicksort goes before the rest of a run is heapsorted: twice the bits of `n`. **/
	static function depthOf(n:Int):Int {
		var depth:Int = 0;
		while (n > 0) {
			depth += 2;
			n >>= 1;
		}
		return depth;
	}

	public static function sortStrings(a:Array<String>):Void {
		__sortStringsWithin(a, depthOf(a.length));
	}

	/** `sortStrings`, the quicksort going `depth` deep before it heapsorts: for a test to reach every path. **/
	@:noCompletion public static function __sortStringsWithin(a:Array<String>, depth:Int):Void {
		final n:Int = a.length;
		if (n > 1) {
			stringRun(a, 0, n - 1, depth);
		}
	}

	static function stringRun(a:Array<String>, low:Int, high:Int, depth:Int):Void {
		var lo:Int = low;
		var hi:Int = high;
		while (hi - lo >= SHORT_RUN) {
			if (depth == 0) {
				stringHeap(a, lo, hi);
				return;
			}
			depth--;
			// The median of three at the middle, and the ends ordered, which
			// stop each scan below.
			final mid:Int = lo + ((hi - lo) >> 1);
			if (before(a[mid], a[lo])) {
				swapString(a, mid, lo);
			}
			if (before(a[hi], a[lo])) {
				swapString(a, hi, lo);
			}
			if (before(a[hi], a[mid])) {
				swapString(a, hi, mid);
			}
			final pivot:String = a[mid];
			var i:Int = lo;
			var j:Int = hi;
			while (i <= j) {
				while (before(a[i], pivot)) {
					i++;
				}
				while (before(pivot, a[j])) {
					j--;
				}
				if (i <= j) {
					swapString(a, i, j);
					i++;
					j--;
				}
			}
			// The smaller side by recursion, the larger by the loop: the
			// stack stays within the depth of the bits of n.
			if (j - lo < hi - i) {
				if (lo < j) {
					stringRun(a, lo, j, depth);
				}
				lo = i;
			} else {
				if (i < hi) {
					stringRun(a, i, hi, depth);
				}
				hi = j;
			}
		}
		for (k in lo + 1...hi + 1) {
			final key:String = a[k];
			var at:Int = k - 1;
			while (at >= lo && before(key, a[at])) {
				a[at + 1] = a[at];
				at--;
			}
			a[at + 1] = key;
		}
	}

	static function stringHeap(a:Array<String>, lo:Int, hi:Int):Void {
		final count:Int = hi - lo + 1;
		var start:Int = (count >> 1) - 1;
		while (start >= 0) {
			stringSift(a, lo, start, count);
			start--;
		}
		var end:Int = count - 1;
		while (end > 0) {
			swapString(a, lo, lo + end);
			stringSift(a, lo, 0, end);
			end--;
		}
	}

	static function stringSift(a:Array<String>, lo:Int, root:Int, count:Int):Void {
		var at:Int = root;
		while (true) {
			var child:Int = 2 * at + 1;
			if (child >= count) {
				return;
			}
			if (child + 1 < count && before(a[lo + child], a[lo + child + 1])) {
				child++;
			}
			if (!before(a[lo + at], a[lo + child])) {
				return;
			}
			swapString(a, lo + at, lo + child);
			at = child;
		}
	}

	static inline function swapString(a:Array<String>, i:Int, j:Int):Void {
		final held:String = a[i];
		a[i] = a[j];
		a[j] = held;
	}

	public static function sortInts(a:Array<Int>):Void {
		__sortIntsWithin(a, depthOf(a.length));
	}

	/** `sortInts`, the quicksort going `depth` deep before it heapsorts. **/
	@:noCompletion public static function __sortIntsWithin(a:Array<Int>, depth:Int):Void {
		final n:Int = a.length;
		if (n > 1) {
			intRun(a, 0, n - 1, depth);
		}
	}

	static function intRun(a:Array<Int>, low:Int, high:Int, depth:Int):Void {
		var lo:Int = low;
		var hi:Int = high;
		while (hi - lo >= SHORT_RUN) {
			if (depth == 0) {
				intHeap(a, lo, hi);
				return;
			}
			depth--;
			final mid:Int = lo + ((hi - lo) >> 1);
			if (a[mid] < a[lo]) {
				swapInt(a, mid, lo);
			}
			if (a[hi] < a[lo]) {
				swapInt(a, hi, lo);
			}
			if (a[hi] < a[mid]) {
				swapInt(a, hi, mid);
			}
			final pivot:Int = a[mid];
			var i:Int = lo;
			var j:Int = hi;
			while (i <= j) {
				while (a[i] < pivot) {
					i++;
				}
				while (pivot < a[j]) {
					j--;
				}
				if (i <= j) {
					swapInt(a, i, j);
					i++;
					j--;
				}
			}
			if (j - lo < hi - i) {
				if (lo < j) {
					intRun(a, lo, j, depth);
				}
				lo = i;
			} else {
				if (i < hi) {
					intRun(a, i, hi, depth);
				}
				hi = j;
			}
		}
		for (k in lo + 1...hi + 1) {
			final key:Int = a[k];
			var at:Int = k - 1;
			while (at >= lo && key < a[at]) {
				a[at + 1] = a[at];
				at--;
			}
			a[at + 1] = key;
		}
	}

	static function intHeap(a:Array<Int>, lo:Int, hi:Int):Void {
		final count:Int = hi - lo + 1;
		var start:Int = (count >> 1) - 1;
		while (start >= 0) {
			intSift(a, lo, start, count);
			start--;
		}
		var end:Int = count - 1;
		while (end > 0) {
			swapInt(a, lo, lo + end);
			intSift(a, lo, 0, end);
			end--;
		}
	}

	static function intSift(a:Array<Int>, lo:Int, root:Int, count:Int):Void {
		var at:Int = root;
		while (true) {
			var child:Int = 2 * at + 1;
			if (child >= count) {
				return;
			}
			if (child + 1 < count && a[lo + child] < a[lo + child + 1]) {
				child++;
			}
			if (!(a[lo + at] < a[lo + child])) {
				return;
			}
			swapInt(a, lo + at, lo + child);
			at = child;
		}
	}

	static inline function swapInt(a:Array<Int>, i:Int, j:Int):Void {
		final held:Int = a[i];
		a[i] = a[j];
		a[j] = held;
	}
}
