package crossbyte.rpc;

import crossbyte.ds.IdList;
import crossbyte.errors.ArgumentError;
import crossbyte.errors.RangeError;
import crossbyte.io.ByteArray;
import crossbyte.io.ByteArrayInput;
import crossbyte.rpc._internal.RPCFrame;
import crossbyte.rpc._internal.RPCKeys;
import haxe.ds.IntMap;

/**
	A map of `Int` keys (entity ids) to structures, sent as what changed
	since a base both ends hold: the keys removed, the entries added (each
	a patch from the structure as its constructor makes it), and for each
	entry both hold whose value differs, a patch of its fields. An argument or
	an answer of a contract method, `V` a class that implements `RPCStruct`.

	```haxe
	import crossbyte.rpc.Float32;
	import crossbyte.rpc.RPCMapPatch;
	import crossbyte.rpc.RPCStruct;
	import crossbyte.rpc.VarUInt;

	class OtherShip implements RPCStruct {
		public var x:Float32 = 0;
		public var y:Float32 = 0;

		public function new() {}
	}

	interface ShipsContract {
		function ships(tick:VarUInt, base:VarUInt, others:RPCMapPatch<OtherShip>):Void;
	}
	```

	**Sending.** `diff(base, current)` sorts the difference out between two
	maps, and `diffKeys` between views of shared frames: the keys of one list
	looked up in one map of values, against another's. Nothing is copied per
	observer: a frame of the world's values per tick, and a list of the ids
	each observer sees, as Quake 3 keeps its snapshots. Keys in any order.

	```haxe
	import crossbyte.ds.IdList;
	import haxe.ds.IntMap;

	// Given patch:RPCMapPatch<OtherShip>, world:IntMap<OtherShip>, acked:Null<IntMap<OtherShip>>, ackedView:Null<IdList>, view:IdList.
	patch.diffKeys(acked, ackedView, world, view);
	```

	A `null` base sends every entry as added (`isFull`): the receiver clears
	what it holds first. An entry both hold whose value is the same bytes is
	not sent at all, so values that never change once made (a projectile)
	are only ever added and removed.

	**Received**, it is valid only during the call. `apply(base, into)` makes
	the map the sender had, from the base it named. A value already in
	`into` under a key is patched in place, so a ring of frames allocates
	only for keys new to a frame, and with `recycle` not even for those:

	```haxe
	// Given others:RPCMapPatch<OtherShip>, from:Null<IntMap<OtherShip>>, frame:IntMap<OtherShip>.
	others.apply(from, frame, true);
	```

	`apply` finds the keys of `base` and `into` by iterating them, which
	allocates an iterator natively and on the jvm; `applyKeys`, given the
	maps' key lists (`IdList`s, as `diffKeys` takes them), allocates nothing.
	Into the base itself (`into == base`) neither iterates.

	One by one: `removed` (ascending), `addedKey(i)` and `addedValue(i)`,
	`updatedKey(i)` and `applyUpdate(i, target)`.

	On the wire, after the counts (a varint of the removed count twice, plus
	one when full; then the added count and the updated count), each group
	of keys is ascending, the first as a zigzag varint and each next as a
	varint of its distance from the one before, less one: a byte for ids
	that sit close together, where a whole `Int` is four. Each added and
	updated entry is its key, then its value's patch.

	**Threading.** None: one patch is used by one thread at a time.
**/
@:access(crossbyte.ds.IdList)
final class RPCMapPatch<V> {
	/** The values' codec. **/
	public final codec:RPCCodec<V>;

	/** Whether it is against nothing: every entry is added, and the receiver clears what it holds. **/
	public var isFull(default, null):Bool = true;

	/** How many keys were removed. **/
	public var removedCount(get, never):Int;

	/** How many entries were added. **/
	public var addedCount(get, never):Int;

	/** How many entries both hold have values that differ. **/
	public var updatedCount(get, never):Int;

	/** Whether nothing changed: no key removed or added, every shared entry the same bytes, and not `isFull`. **/
	public var isEmpty(get, never):Bool;

	/** The keys removed, ascending. **/
	public var removed(default, null):IdList = new IdList();

	@:noCompletion public var __added:IdList = new IdList();
	@:noCompletion public var __updated:IdList = new IdList();
	@:noCompletion public var __addedMasks:IdList = new IdList();
	@:noCompletion public var __addedMasksHigh:IdList = new IdList();
	@:noCompletion public var __updatedMasks:IdList = new IdList();
	@:noCompletion public var __updatedMasksHigh:IdList = new IdList();
	@:noCompletion public var __baseValues:Null<IntMap<V>> = null;
	@:noCompletion public var __currentValues:Null<IntMap<V>> = null;
	@:noCompletion public var __sending:Bool = false;
	// Sending: each added and updated entry's values, as the diff found
	// them, so writing looks nothing up again.
	@:noCompletion public var __sentAdded:Array<V> = [];
	@:noCompletion public var __sentBase:Array<V> = [];
	@:noCompletion public var __sentCurrent:Array<V> = [];
	@:noCompletion private var __wide:Bool;
	@:noCompletion public var __received:Bool = false;
	// Received: each added entry's value, and each updated one's state, in
	// pools grown to the most a patch has held.
	@:noCompletion public var __addedValues:Array<V> = [];
	@:noCompletion public var __addedState:Any = null;
	@:noCompletion public var __updatedStates:Array<Any> = [];
	@:noCompletion private var __spare:Array<V> = [];
	@:noCompletion private var __spareCount:Int = 0;
	@:noCompletion private var __current:IdList = new IdList();
	@:noCompletion private var __old:IdList = new IdList();
	@:noCompletion private var __kept:IdList = new IdList();
	@:noCompletion private var __result:IdList = new IdList();
	@:noCompletion private var __into:IdList = new IdList();
	@:noCompletion private var __frame:Null<RPCFrame> = null;

	/**
		@param codec The values' codec: `RPCCodecs.of(OtherShip)`.
		@throws ArgumentError For a `null` codec.
	**/
	public function new(codec:RPCCodec<V>) {
		if (codec == null) {
			throw new ArgumentError("An RPCMapPatch needs its values' codec: RPCCodecs.of(Type).");
		}
		this.codec = codec;
		__wide = codec.fieldCount > 32;
	}

	/**
		Sorts out the difference from `base` to `current` and answers this
		patch, to pass as the argument. The maps are held, not copied, until
		the patch is sent. Finding their keys iterates them, which allocates
		natively and on the jvm; `diffKeys` does not.

		@param base What the receiver holds, or `null` for every entry added.
		@throws ArgumentError For a `null` `current`.
	**/
	public function diff(base:Null<IntMap<V>>, current:IntMap<V>):RPCMapPatch<V> {
		if (current == null) {
			throw new ArgumentError("RPCMapPatch.diff needs the current map.");
		}
		__keysOf(current, __kept);
		if (base != null) {
			__keysOf(base, __into);
		}
		return diffKeys(base, base == null ? null : __into, current, __kept);
	}

	/**
		The same as `diff`, for views of shared frames: the keys in `baseKeys`
		looked up in `baseValues`, against the keys in `currentKeys` in
		`currentValues`, each list in any order (a key given twice counts
		once). Allocates nothing once its lists have grown to the largest
		view. A `null` base (either part) sends every entry as added.

		@throws ArgumentError For a `null` `currentValues` or `currentKeys`,
		        or a key a list names that its map does not hold.
	**/
	public function diffKeys(baseValues:Null<IntMap<V>>, baseKeys:Null<IdList>, currentValues:IntMap<V>, currentKeys:IdList):RPCMapPatch<V> {
		if (currentValues == null || currentKeys == null) {
			throw new ArgumentError("RPCMapPatch.diffKeys needs the current values and keys.");
		}
		final full:Bool = baseValues == null || baseKeys == null;
		__sending = true;
		__received = false;
		isFull = full;
		__baseValues = full ? null : baseValues;
		__currentValues = currentValues;
		removed.length = 0;
		__added.length = 0;
		__updated.length = 0;
		__addedMasks.length = 0;
		__addedMasksHigh.length = 0;
		__updatedMasks.length = 0;
		__updatedMasksHigh.length = 0;
		final cur:IdList = __current.copyFrom(currentKeys);
		RPCKeys.sortUnique(cur);
		final old:IdList = __old;
		old.length = 0;
		if (!full) {
			old.copyFrom(baseKeys);
			RPCKeys.sortUnique(old);
		}
		final wide:Bool = __wide;
		final initial:V = codec.__default();
		var i:Int = 0;
		var j:Int = 0;
		final nc:Int = cur.length;
		final no:Int = old.length;
		while (i < nc || j < no) {
			final c:Int = i < nc ? cur.__ids[i] : 0;
			final o:Int = j < no ? old.__ids[j] : 0;
			if (j >= no || (i < nc && c < o)) {
				final value:Null<V> = currentValues.get(c);
				if (value == null) {
					throw new ArgumentError('RPCMapPatch: key $c is in the current keys and not in the current values.');
				}
				__keepSent(__sentAdded, __added.length, value);
				__added.push(c);
				__addedMasks.push(codec.__mask(initial, value));
				if (wide) {
					__addedMasksHigh.push(codec.__maskHigh(initial, value));
				}
				i++;
			} else if (i >= nc || o < c) {
				removed.push(o);
				j++;
			} else {
				final was:Null<V> = baseValues.get(o);
				final value:Null<V> = currentValues.get(c);
				if (was == null || value == null) {
					throw new ArgumentError('RPCMapPatch: key $c is in a list of keys and not in its values.');
				}
				final mask:Int = codec.__mask(was, value);
				final high:Int = wide ? codec.__maskHigh(was, value) : 0;
				if (mask != 0 || high != 0) {
					__keepSent(__sentBase, __updated.length, was);
					__keepSent(__sentCurrent, __updated.length, value);
					__updated.push(c);
					__updatedMasks.push(mask);
					if (wide) {
						__updatedMasksHigh.push(high);
					}
				}
				i++;
				j++;
			}
		}
		return this;
	}

	/**
		An upper bound on the bytes the patch takes as an argument, from its
		counts and its values' largest patch: for a call that must fit a
		datagram, checked before it is made. -1 when a value's size depends on
		it (a `String`, an array).
	**/
	public function sizeBound():Int {
		final each:Int = codec.__patchBound();
		if (each < 0) {
			return -1;
		}
		return 15 + removedCount * 5 + (addedCount + updatedCount) * (5 + each);
	}

	/** The i-th added key, ascending. **/
	public inline function addedKey(i:Int):Int {
		return __added.get(i);
	}

	/**
		The i-th added entry's value. Received, the patch applied to the
		structure as its constructor makes it, valid during the call: copy
		what is kept.
	**/
	public function addedValue(i:Int):V {
		final key:Int = __added.get(i);
		if (__received) {
			return __addedValues[i];
		}
		return __currentValues.get(key);
	}

	/** The i-th updated key, ascending. **/
	public inline function updatedKey(i:Int):Int {
		return __updated.get(i);
	}

	/**
		Received: the i-th updated entry's patch applied onto `target`, the
		value the base held under its key, in place. Answers `target`.
	**/
	public function applyUpdate(i:Int, target:V):V {
		if (i < 0 || i >= __updated.length) {
			throw new RangeError('Index $i is out of bounds (updatedCount ${__updated.length})');
		}
		if (target == null) {
			throw new ArgumentError("RPCMapPatch.applyUpdate needs the value to patch.");
		}
		if (!__received) {
			return codec.copy(__currentValues.get(__updated.__ids[i]), target);
		}
		return codec.__apply(__updatedStates[i], target, target);
	}

	/**
		Received: makes `into` the map the sender had, `base` patched. `base`
		is ignored when `isFull`; `into` may be `base`. A value already in
		`into` under a key is patched in place; one for a key new to it is
		made (or, with `recycle`, taken from those `into` dropped earlier),
		and nothing is shared between the two maps. With `recycle`, values
		`into` drops are kept for the next adds instead of left to the
		collector: only for values nothing else holds.

		Finding the maps' keys iterates them, which allocates natively and on
		the jvm, except into the base itself; `applyKeys` does not.

		@throws ArgumentError When `into` is `null`, the patch is not full and
		        `base` is `null`, or `base` lacks a key the patch removes or
		        updates: it is not the base the sender used.
	**/
	public function apply(base:Null<IntMap<V>>, into:IntMap<V>, recycle:Bool = false):Void {
		__requireApply(base, into);
		if (!isFull && into == base) {
			__applyInPlace(into, recycle);
			return;
		}
		if (!isFull) {
			__keysOf(base, __old);
			RPCKeys.sortUnique(__old);
		}
		__keysOf(into, __into);
		__applyKeys(isFull ? null : base, __old, into, __into, recycle);
	}

	/**
		`apply`, for maps whose keys are kept in lists beside them: the keys of
		`base` in `baseKeys`, and of `into` in `intoKeys`, which becomes the
		new map's keys, ascending. Allocates nothing once its lists have grown
		(with `recycle`, not even a value for a key new to `into`).

		@throws ArgumentError As `apply`, and for a `null` key list.
	**/
	public function applyKeys(baseValues:Null<IntMap<V>>, baseKeys:Null<IdList>, intoValues:IntMap<V>, intoKeys:IdList, recycle:Bool = false):Void {
		__requireApply(baseValues, intoValues);
		if (intoKeys == null || (!isFull && baseKeys == null)) {
			throw new ArgumentError("RPCMapPatch.applyKeys needs the maps' key lists.");
		}
		if (!isFull) {
			__old.copyFrom(baseKeys);
			RPCKeys.sortUnique(__old);
		}
		if (!isFull && intoValues == baseValues) {
			__applyInPlace(intoValues, recycle);
			__resultKeys(__old);
			intoKeys.copyFrom(__result);
			return;
		}
		__into.copyFrom(intoKeys);
		__applyKeys(isFull ? null : baseValues, __old, intoValues, __into, recycle);
		intoKeys.copyFrom(__result);
	}

	/**
		Writes the patch at `out.position` as it goes on the wire, and moves
		`position` past it: for a test, a recording, a resync frame kept for
		later, or a patch carried in a `Bytes` argument. `read` reads it.
	**/
	public function write(out:ByteArray):Void {
		if (out == null) {
			throw new ArgumentError("RPCMapPatch.write needs a ByteArray to write into.");
		}
		var frame:Null<RPCFrame> = __frame;
		if (frame == null) {
			frame = __frame = new RPCFrame(128);
		}
		frame.beginScratch();
		codec.__writeMapPatch(frame, this);
		out.writeBytes(frame, 0, frame.position);
	}

	/**
		Reads a patch `write` wrote at `input.position` into this one, moving
		`position` past it, and answers this patch, to apply as one that
		arrived in a call.

		@throws String When the bytes are not a whole patch.
	**/
	public function read(input:ByteArray):RPCMapPatch<V> {
		if (input == null) {
			throw new ArgumentError("RPCMapPatch.read needs a ByteArray to read.");
		}
		final from:ByteArrayInput = input;
		codec.__readMapPatch(from, input.length, this);
		if (from.position > input.length) {
			throw "RPC map patch read past its end";
		}
		return this;
	}

	// ------------------------------------------------------------ received

	/** Readies the patch for a read of these counts: lists emptied, pools grown. **/
	@:noCompletion public function __beginRead(full:Bool, added:Int, updated:Int):Void {
		__sending = false;
		__received = true;
		isFull = full;
		__baseValues = null;
		__currentValues = null;
		removed.length = 0;
		__added.length = 0;
		__updated.length = 0;
		if (__addedState == null) {
			__addedState = codec.__newState();
		}
		while (__addedValues.length < added) {
			__addedValues.push(codec.make());
		}
		while (__updatedStates.length < updated) {
			__updatedStates.push(codec.__newState());
		}
	}

	/** Empties the patch, so one kept past its call reads as no patch at all (-D crossbyte_check_events). **/
	@:noCompletion public function __poison():Void {
		removed.length = 0;
		__added.length = 0;
		__updated.length = 0;
		__received = false;
		__sending = false;
	}

	// ------------------------------------------------------------ applying

	function __requireApply(base:Null<IntMap<V>>, into:IntMap<V>):Void {
		if (into == null) {
			throw new ArgumentError("RPCMapPatch.apply needs a map to set: the base to patch in place, or another.");
		}
		if (!isFull && base == null) {
			throw new ArgumentError("This map patch is against a base, and none was given: keep the map it names, or wait for a full one.");
		}
		if (!__received && !__sending) {
			throw new ArgumentError("This map patch has not been diffed or received.");
		}
	}

	// `into` is the base: removals, updates and adds made where they are.
	function __applyInPlace(into:IntMap<V>, recycle:Bool):Void {
		for (k in 0...removed.length) {
			final key:Int = removed.__ids[k];
			final value:Null<V> = into.get(key);
			if (value == null) {
				__missing(key, "removes");
			}
			into.remove(key);
			if (recycle) {
				__keep(value);
			}
		}
		for (u in 0...__updated.length) {
			final key:Int = __updated.__ids[u];
			final target:Null<V> = into.get(key);
			if (target == null) {
				__missing(key, "updates");
			}
			__update(u, target, target);
		}
		for (a in 0...__added.length) {
			final key:Int = __added.__ids[a];
			var target:Null<V> = into.get(key);
			if (target == null) {
				target = __take();
				into.set(key, target);
			}
			codec.copy(addedValue(a), target);
		}
	}

	/**
		`into` becomes `base` (`null`: nothing) patched. `baseKeys` and
		`intoKeys` are sorted; the new keys are left in `__result`.
	**/
	function __applyKeys(base:Null<IntMap<V>>, baseKeys:IdList, into:IntMap<V>, intoKeys:IdList, recycle:Bool):Void {
		__resultKeys(base == null ? null : baseKeys);
		final result:IdList = __result;
		// What `into` holds that the new map does not.
		for (k in 0...intoKeys.length) {
			final key:Int = intoKeys.__ids[k];
			if (RPCKeys.indexOf(result, key) < 0) {
				final value:Null<V> = into.get(key);
				into.remove(key);
				if (recycle && value != null) {
					__keep(value);
				}
			}
		}
		for (k in 0...result.length) {
			final key:Int = result.__ids[k];
			var target:Null<V> = into.get(key);
			final fresh:Bool = target == null;
			if (fresh) {
				target = __take();
			}
			final u:Int = RPCKeys.indexOf(__updated, key);
			if (u >= 0) {
				__update(u, base.get(key), target);
			} else {
				final a:Int = RPCKeys.indexOf(__added, key);
				if (a >= 0) {
					codec.copy(addedValue(a), target);
				} else {
					final was:V = base.get(key);
					if (was != target) {
						codec.copy(was, target);
					}
				}
			}
			if (fresh) {
				into.set(key, target);
			}
		}
	}

	/**
		The keys of the map the patch makes from a base of `baseKeys` (sorted;
		`null` for none): those less the removed, with the added, ascending,
		in `__result`. A removed or updated key the base lacks throws.
	**/
	function __resultKeys(baseKeys:Null<IdList>):Void {
		final kept:IdList = __kept;
		kept.length = 0;
		if (baseKeys != null) {
			var r:Int = 0;
			for (k in 0...baseKeys.length) {
				final key:Int = baseKeys.__ids[k];
				while (r < removed.length && removed.__ids[r] < key) {
					__missing(removed.__ids[r], "removes");
				}
				if (r < removed.length && removed.__ids[r] == key) {
					r++;
				} else {
					kept.push(key);
				}
			}
			if (r < removed.length) {
				__missing(removed.__ids[r], "removes");
			}
			for (u in 0...__updated.length) {
				if (RPCKeys.indexOf(kept, __updated.__ids[u]) < 0) {
					__missing(__updated.__ids[u], "updates");
				}
			}
		}
		// Merged with the added.
		final result:IdList = __result;
		result.length = 0;
		var i:Int = 0;
		var j:Int = 0;
		while (i < kept.length || j < __added.length) {
			if (j >= __added.length || (i < kept.length && kept.__ids[i] < __added.__ids[j])) {
				result.push(kept.__ids[i++]);
			} else if (i >= kept.length || __added.__ids[j] < kept.__ids[i]) {
				result.push(__added.__ids[j++]);
			} else {
				result.push(kept.__ids[i++]);
				j++;
			}
		}
	}

	inline function __update(u:Int, base:V, target:V):Void {
		if (__received) {
			codec.__apply(__updatedStates[u], base, target);
		} else {
			codec.copy(__currentValues.get(__updated.__ids[u]), target);
		}
	}

	function __missing(key:Int, what:String):Void {
		throw new ArgumentError('This map patch $what key $key, which its base does not hold: the base is not the one the sender used.');
	}

	static inline function __keepSent<V>(list:Array<V>, at:Int, value:V):Void {
		if (at < list.length) {
			list[at] = value;
		} else {
			list.push(value);
		}
	}

	inline function __keep(value:V):Void {
		if (__spareCount < __spare.length) {
			__spare[__spareCount] = value;
		} else {
			__spare.push(value);
		}
		__spareCount++;
	}

	inline function __take():V {
		if (__spareCount > 0) {
			__spareCount--;
			final value:V = __spare[__spareCount];
			__spare[__spareCount] = null;
			return value;
		}
		return codec.make();
	}

	static function __keysOf<V>(map:IntMap<V>, into:IdList):Void {
		into.length = 0;
		for (key in map.keys()) {
			into.push(key);
		}
	}

	private inline function get_removedCount():Int {
		return removed.length;
	}

	private inline function get_addedCount():Int {
		return __added.length;
	}

	private inline function get_updatedCount():Int {
		return __updated.length;
	}

	private inline function get_isEmpty():Bool {
		return !isFull && removed.length == 0 && __added.length == 0 && __updated.length == 0;
	}
}
