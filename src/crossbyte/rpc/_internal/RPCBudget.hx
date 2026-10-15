package crossbyte.rpc._internal;

import crossbyte.ds.IdList;

/**
	What a map patch keeps to fill itself up to a budget, beside the lists
	every diff fills: per entry added or updated, whether it has been weighed
	and whether it is carried; where each update's base value came from; the
	keys of each kind as their groups will code them; and the scratch a
	baseline is committed in. Made the first time a patch is diffed within a
	budget and reused from then on, so a budgeted diff allocates nothing once
	its lists have grown.
**/
@:noCompletion
@:access(crossbyte.ds.IdList)
final class RPCBudget<V> {
	/** Set once an entry has been met in the priority order: a key given twice counts once, where it first is. **/
	public static inline final SEEN:Int = 1;

	/** Set when an entry is carried. **/
	public static inline final CHOSEN:Int = 2;

	/** The keys a budget left out, in the order of priority they were given. **/
	public final deferred:IdList = new IdList();

	/** The same for string keys. **/
	public final deferredStrings:Array<String> = [];

	/** Per update, where in the base's stale values its base value is, or -1 for the frame's. **/
	public final fromStale:IdList = new IdList();

	/** Per add and per update, `SEEN` and `CHOSEN`. **/
	public final addFlags:IdList = new IdList();

	public final updateFlags:IdList = new IdList();

	/** The adds and the updates chosen so far, as their groups will code their keys. **/
	public final adds:RPCKeyRun = new RPCKeyRun();

	public final updates:RPCKeyRun = new RPCKeyRun();

	/** The adds left out, ascending: keys the observer does not hold. **/
	public final leftAdds:IdList = new IdList();

	public final leftAddStrings:Array<String> = [];

	/** The updates left out, ascending, with their base values and where those came from: the baseline's stale entries. **/
	public final staleKeys:IdList = new IdList();

	public final staleStrings:Array<String> = [];
	public final staleFrom:IdList = new IdList();
	public final staleSource:Array<V> = [];
	public final staleMade:Array<V> = [];
	public final kept:IdList = new IdList();

	public function new() {}

	/** Sets `list[at]`, growing it by one when `at` is its length. **/
	public static inline function keep<T>(list:Array<T>, at:Int, value:T):Void {
		if (at < list.length) {
			list[at] = value;
		} else {
			list.push(value);
		}
	}

	/** `count` zeroes in `list`. **/
	public static inline function zeroes(list:IdList, count:Int):Void {
		list.length = 0;
		for (_ in 0...count) {
			list.push(0);
		}
	}

	/** The bytes `putVarUInt` writes for `value`, a negative `Int` as the unsigned value it holds. **/
	public static inline function varUIntSize(value:Int):Int {
		return RPCSizes.varUInt(value);
	}

	/** The bytes `putVarInt` writes for `value`: zigzagged, then a varint. **/
	public static inline function varIntSize(value:Int):Int {
		return RPCSizes.varInt(value);
	}

	/** The bytes a group of keys, ascending, takes on the wire, as `RPCKeys.putKeys` writes it. **/
	public static function keysSize(keys:IdList):Int {
		var size:Int = 0;
		var previous:Int = 0;
		for (i in 0...keys.length) {
			final key:Int = keys.__ids[i];
			size += i == 0 ? varIntSize(key) : varUIntSize((key - previous - 1) | 0);
			previous = key;
		}
		return size;
	}
}

/**
	The candidate keys of one group of a map patch (added or updated),
	ascending, and those chosen so far: what choosing one more adds to the
	group's bytes, exactly. A key goes as its distance from the one before it
	in the group, so its cost depends on its neighbours among the chosen;
	those are found by rank in a Fenwick tree of the chosen, in a time that
	grows with the log of the candidates whatever order they are chosen in.
**/
@:noCompletion
@:access(crossbyte.ds.IdList)
final class RPCKeyRun {
	/** How many have been chosen. **/
	public var chosen(default, null):Int = 0;

	var __keys:Null<IdList> = null;
	// Fenwick tree over the ranks, 1-based: counts of the chosen.
	final __tree:IdList = new IdList();
	var __size:Int = 0;
	var __top:Int = 0;

	public function new() {}

	/** Readies the run for the candidates in `keys`, ascending, none chosen. **/
	public function begin(keys:IdList):Void {
		__keys = keys;
		chosen = 0;
		final n:Int = keys.length;
		__size = n;
		RPCBudget.zeroes(__tree, n + 1);
		var top:Int = 1;
		while (top * 2 <= n) {
			top *= 2;
		}
		__top = n == 0 ? 0 : top;
	}

	/** What choosing the candidate of rank `rank` adds to the group's bytes, its key's and the group's count's. **/
	public function cost(rank:Int):Int {
		final ids = __keys.__ids;
		final key:Int = ids[rank];
		final before:Int = __below(rank);
		final hasPrevious:Bool = before > 0;
		final previous:Int = hasPrevious ? ids[__nth(before)] : 0;
		var size:Int = hasPrevious ? RPCBudget.varUIntSize((key - previous - 1) | 0) : RPCBudget.varIntSize(key);
		if (before < chosen) {
			// The next one chosen now goes as its distance from this key.
			final next:Int = ids[__nth(before + 1)];
			final was:Int = hasPrevious ? RPCBudget.varUIntSize((next - previous - 1) | 0) : RPCBudget.varIntSize(next);
			size += RPCBudget.varUIntSize((next - key - 1) | 0) - was;
		}
		return size + RPCBudget.varUIntSize(chosen + 1) - RPCBudget.varUIntSize(chosen);
	}

	/** Chooses the candidate of rank `rank`. **/
	public function choose(rank:Int):Void {
		final tree = __tree.__ids;
		var at:Int = rank + 1;
		while (at <= __size) {
			tree[at] = tree[at] + 1;
			at += at & -at;
		}
		chosen++;
	}

	// How many chosen have a rank below `rank`.
	inline function __below(rank:Int):Int {
		final tree = __tree.__ids;
		var sum:Int = 0;
		var at:Int = rank;
		while (at > 0) {
			sum += tree[at];
			at -= at & -at;
		}
		return sum;
	}

	// The rank of the `k`-th chosen, counting from 1.
	function __nth(k:Int):Int {
		final tree = __tree.__ids;
		var at:Int = 0;
		var left:Int = k;
		var step:Int = __top;
		while (step > 0) {
			final next:Int = at + step;
			if (next <= __size && tree[next] < left) {
				at = next;
				left -= tree[next];
			}
			step >>= 1;
		}
		return at;
	}
}
