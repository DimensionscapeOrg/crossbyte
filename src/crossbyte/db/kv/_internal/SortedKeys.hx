package crossbyte.db.kv._internal;

/**
	Keys kept in code point order, for `MemoryKVStore`'s scans: a list of
	sorted runs of at most `SPLIT` keys, each run's keys all before the next
	run's, as Python's sortedcontainers keeps a sorted list.

	Finding a key is a binary search over the runs' last keys and one inside a
	run; adding or removing one moves at most a run's worth of references, and
	splitting a full run moves one entry of the list of runs. A single sorted
	array would move up to every key on each insert: 100,000 of them for a
	store that size. A balanced tree would allocate a node per key and chase
	pointers on every step of a scan, where a run is read straight through.
**/
@:noCompletion
final class SortedKeys {
	/** A run past this many keys is split in two. **/
	public static inline var SPLIT:Int = 1024;

	/** How many keys it holds. **/
	public var length(default, null):Int = 0;

	@:noCompletion private var __runs:Array<Array<String>> = [];

	public function new() {}

	/** Adds `key`, which it does not hold. **/
	public function insert(key:String):Void {
		if (__runs.length == 0) {
			__runs.push([key]);
			length = 1;
			return;
		}

		var r:Int = __runFor(key);

		if (r == __runs.length) {
			// After every key: the last run's end.
			r--;
		}

		var run:Array<String> = __runs[r];
		run.insert(__indexIn(run, key), key);
		length++;

		if (run.length > SPLIT) {
			var half:Int = run.length >> 1;
			__runs.insert(r + 1, run.splice(half, run.length - half));
		}
	}

	/** Removes `key`; whether it held it. **/
	public function remove(key:String):Bool {
		var r:Int = __runFor(key);

		if (r == __runs.length) {
			return false;
		}

		var run:Array<String> = __runs[r];
		var i:Int = __indexIn(run, key);

		if (i >= run.length || run[i] != key) {
			return false;
		}

		run.splice(i, 1);
		length--;

		if (run.length == 0) {
			__runs.splice(r, 1);
		}

		return true;
	}

	/** Empties it. **/
	public function clear():Void {
		__runs = [];
		length = 0;
	}

	/** A cursor at the first key at or after `key`. **/
	public function from(key:String):SortedKeysCursor {
		var r:Int = __runFor(key);
		return new SortedKeysCursor(__runs, r, r < __runs.length ? __indexIn(__runs[r], key) : 0);
	}

	/** The first run whose last key is at or after `key`; the number of runs when there is none. **/
	@:noCompletion private function __runFor(key:String):Int {
		var lo:Int = 0;
		var hi:Int = __runs.length;

		while (lo < hi) {
			var mid:Int = (lo + hi) >>> 1;
			var run:Array<String> = __runs[mid];

			if (KVKeys.compare(run[run.length - 1], key) < 0) {
				lo = mid + 1;
			} else {
				hi = mid;
			}
		}

		return lo;
	}

	/** Where in `run` the first key at or after `key` is; `run.length` when none is. **/
	@:noCompletion private static function __indexIn(run:Array<String>, key:String):Int {
		var lo:Int = 0;
		var hi:Int = run.length;

		while (lo < hi) {
			var mid:Int = (lo + hi) >>> 1;

			if (KVKeys.compare(run[mid], key) < 0) {
				lo = mid + 1;
			} else {
				hi = mid;
			}
		}

		return lo;
	}
}

/** Keys from a place in `SortedKeys` on, in order. Valid until the keys next change. **/
@:noCompletion
final class SortedKeysCursor {
	@:noCompletion private final __runs:Array<Array<String>>;
	@:noCompletion private var __run:Int;
	@:noCompletion private var __index:Int;

	public function new(runs:Array<Array<String>>, run:Int, index:Int) {
		__runs = runs;
		__run = run;
		__index = index;
	}

	public function hasNext():Bool {
		while (__run < __runs.length && __index >= __runs[__run].length) {
			__run++;
			__index = 0;
		}

		return __run < __runs.length;
	}

	public function next():String {
		return __runs[__run][__index++];
	}
}
