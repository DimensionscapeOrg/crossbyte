package crossbyte.rpc._internal;

import crossbyte.ds.IdList;
import crossbyte.io.ByteArrayInput;
import haxe.ds.Vector;

/**
	What patches share at run time: counting a mask's bits, and the keys of
	a map patch.

	**Key coding.** A map patch's keys go in groups (removed, added,
	updated), each ascending. The first key of a group is a zigzag varint;
	each after it is a varint of how far past the one before it is, less
	one, as 32 bits unsigned. Entity ids that sit close together cost a byte
	each, and a reader can be handed no key twice or out of order; one past
	2^31 - 1 is refused.
**/
@:noCompletion
@:access(crossbyte.ds.IdList)
class RPCKeys {
	/** How many bits of `mask` are set: one step a set bit, the same arithmetic on every target. **/
	public static inline function bitCount(mask:Int):Int {
		var v:Int = mask;
		var count:Int = 0;
		while (v != 0) {
			// wrap32 is `v - 1` but on PHP: there `v - 1` of a mask with bit 31
			// set goes below -2^31, each step then clears one bit past 32, and
			// at PHP's own sign bit `v` never comes to 0.
			v &= crossbyte.utils.Hash.wrap32(v - 1);
			count++;
		}
		return count;
	}

	/** The id at `index` of `list`, which the caller knows is below its length. **/
	public static inline function at(list:IdList, index:Int):Int {
		return list.__ids[index];
	}

	/** Writes `key`, the first of its group or the next after `previous`. **/
	public static inline function putKey(frame:RPCFrame, first:Bool, previous:Int, key:Int):Void {
		if (first) {
			frame.putVarInt(key);
		} else {
			frame.putVarUInt(key - previous - 1);
		}
	}

	/**
		Reads a key, the first of its group or the next after `previous`.

		@throws String When it is not past `previous`, or is past 2^31 - 1.
	**/
	public static inline function getKey(input:ByteArrayInput, first:Bool, previous:Int):Int {
		return first ? input.readVarInt() : nextKey(previous, input.readVarUInt());
	}

	/** The key `gap + 1` past `previous`, or a throw when that is past 2^31 - 1. **/
	public static function nextKey(previous:Int, gap:Int):Int {
		// `| 0` so the sum wraps on JavaScript as elsewhere; past 2^31 - 1 it
		// comes out at or below `previous`.
		final next:Int = (previous + 1 + gap) | 0;
		if (gap < 0 || previous == 0x7FFFFFFF || next <= previous) {
			throw "RPC map patch key past 2^31 - 1";
		}
		return next;
	}

	/** Writes a group of keys, ascending. **/
	public static function putKeys(frame:RPCFrame, keys:IdList):Void {
		var previous:Int = 0;
		for (i in 0...keys.length) {
			final key:Int = keys.__ids[i];
			putKey(frame, i == 0, previous, key);
			previous = key;
		}
	}

	/** Reads a group of `count` keys into `into`. **/
	public static function getKeys(input:ByteArrayInput, count:Int, into:IdList):Void {
		var previous:Int = 0;
		for (i in 0...count) {
			previous = getKey(input, i == 0, previous);
			into.push(previous);
		}
	}

	/** Where `key` is in `list`, ascending, or -1. **/
	public static function indexOf(list:IdList, key:Int):Int {
		var lo:Int = 0;
		var hi:Int = list.length - 1;
		final ids:Vector<Int> = list.__ids;
		while (lo <= hi) {
			final mid:Int = (lo + hi) >>> 1;
			final at:Int = ids[mid];
			if (at < key) {
				lo = mid + 1;
			} else if (at > key) {
				hi = mid - 1;
			} else {
				return mid;
			}
		}
		return -1;
	}

	/** Sorts `list` ascending and drops ids given more than once. **/
	public static function sortUnique(list:IdList):Void {
		final ids:Vector<Int> = list.__ids;
		final n:Int = list.length;
		if (n > 1) {
			run(ids, 0, n - 1, depthOf(n));
		}
		var kept:Int = n > 0 ? 1 : 0;
		for (i in 1...n) {
			if (ids[i] != ids[kept - 1]) {
				ids[kept++] = ids[i];
			}
		}
		list.length = kept;
	}

	/** Sorts `keys` in the order maps put them on the wire and drops keys given more than once. **/
	public static function sortUniqueStrings(keys:Array<String>):Void {
		RPCMaps.sortStrings(keys);
		final n:Int = keys.length;
		var kept:Int = n > 0 ? 1 : 0;
		for (i in 1...n) {
			if (keys[i] != keys[kept - 1]) {
				keys[kept++] = keys[i];
			}
		}
		if (kept < n) {
			keys.resize(kept);
		}
	}

	/** Where `key` is in `keys`, in wire order, or -1. **/
	public static function indexOfString(keys:Array<String>, key:String):Int {
		var lo:Int = 0;
		var hi:Int = keys.length - 1;
		while (lo <= hi) {
			final mid:Int = (lo + hi) >>> 1;
			final at:String = keys[mid];
			if (RPCMaps.before(at, key)) {
				lo = mid + 1;
			} else if (RPCMaps.before(key, at)) {
				hi = mid - 1;
			} else {
				return mid;
			}
		}
		return -1;
	}

	/** Reads a group of `count` keys, each strictly after the one before, into `into`. **/
	public static function getStringKeys(input:ByteArrayInput, count:Int, into:Array<String>):Void {
		var previous:String = null;
		for (i in 0...count) {
			previous = nextStringKey(input, previous);
			into.push(previous);
		}
	}

	/** Reads a key, which must come after `previous` (`null` for the first). **/
	public static function nextStringKey(input:ByteArrayInput, previous:Null<String>):String {
		final key:String = input.readVarUtf();
		if (previous != null && !RPCMaps.before(previous, key)) {
			throw "RPC map patch keys out of order";
		}
		return key;
	}

	/** Writes a group of keys, in order. **/
	public static function putStringKeys(frame:RPCFrame, keys:Array<String>):Void {
		for (key in keys) {
			frame.putString(key);
		}
	}

	// ------------------------------------------------------------ sorting

	// An introsort, as RPCMaps sorts a map's keys: quicksort, insertion for
	// short runs, heapsort past twice the bits of n, on the list's own
	// storage, with no closure and nothing boxed.

	static inline final SHORT_RUN:Int = 16;

	static function depthOf(n:Int):Int {
		var depth:Int = 0;
		while (n > 0) {
			depth += 2;
			n >>= 1;
		}
		return depth;
	}

	static function run(a:Vector<Int>, low:Int, high:Int, depth:Int):Void {
		var lo:Int = low;
		var hi:Int = high;
		while (hi - lo >= SHORT_RUN) {
			if (depth == 0) {
				heap(a, lo, hi);
				return;
			}
			depth--;
			final mid:Int = lo + ((hi - lo) >> 1);
			if (a[mid] < a[lo]) {
				swap(a, mid, lo);
			}
			if (a[hi] < a[lo]) {
				swap(a, hi, lo);
			}
			if (a[hi] < a[mid]) {
				swap(a, hi, mid);
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
					swap(a, i, j);
					i++;
					j--;
				}
			}
			if (j - lo < hi - i) {
				if (lo < j) {
					run(a, lo, j, depth);
				}
				lo = i;
			} else {
				if (i < hi) {
					run(a, i, hi, depth);
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

	static function heap(a:Vector<Int>, lo:Int, hi:Int):Void {
		final count:Int = hi - lo + 1;
		var start:Int = (count >> 1) - 1;
		while (start >= 0) {
			sift(a, lo, start, count);
			start--;
		}
		var end:Int = count - 1;
		while (end > 0) {
			swap(a, lo, lo + end);
			sift(a, lo, 0, end);
			end--;
		}
	}

	static function sift(a:Vector<Int>, lo:Int, root:Int, count:Int):Void {
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
			swap(a, lo + at, lo + child);
			at = child;
		}
	}

	static inline function swap(a:Vector<Int>, i:Int, j:Int):Void {
		final held:Int = a[i];
		a[i] = a[j];
		a[j] = held;
	}
}
