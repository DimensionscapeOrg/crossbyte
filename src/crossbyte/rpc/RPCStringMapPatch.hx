package crossbyte.rpc;

import crossbyte.ds.IdList;
import crossbyte.errors.ArgumentError;
import crossbyte.errors.RangeError;
import crossbyte.io.ByteArray;
import crossbyte.io.ByteArrayInput;
import crossbyte.rpc._internal.RPCFrame;
import crossbyte.rpc._internal.RPCKeys;
import crossbyte.rpc._internal.RPCMaps;
import haxe.ds.StringMap;

/**
	`RPCMapPatch` for maps of `String` keys: the same members, with key
	lists of `Array<String>`. Keys are written whole (a varint length and
	UTF-8), in the order maps order them on the wire (by UTF-16 code unit,
	as RFC 8785 orders JSON names), each group strictly ascending, so a
	reader can be handed no key twice. A key read is a `String` made for it,
	so a received patch allocates its keys.

	```haxe
	import crossbyte.rpc.RPCStringMapPatch;
	import crossbyte.rpc.RPCStruct;

	class Member implements RPCStruct {
		public var level:Int = 0;
		public var ready:Bool = false;

		public function new() {}
	}

	interface MembersContract {
		function members(base:Int, members:RPCStringMapPatch<Member>):Void;
	}
	```

	**Threading.** None: one patch is used by one thread at a time.
**/
@:access(crossbyte.ds.IdList)
final class RPCStringMapPatch<V> {
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

	/** The keys removed, ascending. Its own, reused for the next patch: copy what is kept. **/
	public var removed(default, null):Array<String> = [];

	@:noCompletion public var __added:Array<String> = [];
	@:noCompletion public var __updated:Array<String> = [];
	@:noCompletion public var __addedMasks:IdList = new IdList();
	@:noCompletion public var __addedMasksHigh:IdList = new IdList();
	@:noCompletion public var __updatedMasks:IdList = new IdList();
	@:noCompletion public var __updatedMasksHigh:IdList = new IdList();
	@:noCompletion public var __baseValues:Null<StringMap<V>> = null;
	@:noCompletion public var __currentValues:Null<StringMap<V>> = null;
	@:noCompletion public var __sending:Bool = false;
	// Sending: each added and updated entry's values, as the diff found
	// them, so writing looks nothing up again.
	@:noCompletion public var __sentAdded:Array<V> = [];
	@:noCompletion public var __sentBase:Array<V> = [];
	@:noCompletion public var __sentCurrent:Array<V> = [];
	@:noCompletion private var __wide:Bool;
	@:noCompletion public var __received:Bool = false;
	@:noCompletion public var __addedValues:Array<V> = [];
	@:noCompletion public var __addedState:Any = null;
	@:noCompletion public var __updatedStates:Array<Any> = [];
	@:noCompletion private var __spare:Array<V> = [];
	@:noCompletion private var __spareCount:Int = 0;
	@:noCompletion private var __current:Array<String> = [];
	@:noCompletion private var __old:Array<String> = [];
	@:noCompletion private var __kept:Array<String> = [];
	@:noCompletion private var __result:Array<String> = [];
	@:noCompletion private var __into:Array<String> = [];
	@:noCompletion private var __frame:Null<RPCFrame> = null;

	/**
		@param codec The values' codec: `RPCCodecs.of(Member)`.
		@throws ArgumentError For a `null` codec.
	**/
	public function new(codec:RPCCodec<V>) {
		if (codec == null) {
			throw new ArgumentError("An RPCStringMapPatch needs its values' codec: RPCCodecs.of(Type).");
		}
		this.codec = codec;
		__wide = codec.fieldCount > 32;
	}

	/** As `RPCMapPatch.diff`. **/
	public function diff(base:Null<StringMap<V>>, current:StringMap<V>):RPCStringMapPatch<V> {
		if (current == null) {
			throw new ArgumentError("RPCStringMapPatch.diff needs the current map.");
		}
		__keysOf(current, __kept);
		if (base != null) {
			__keysOf(base, __into);
		}
		return diffKeys(base, base == null ? null : __into, current, __kept);
	}

	/** As `RPCMapPatch.diffKeys`, the keys in `Array<String>`s, in any order. **/
	public function diffKeys(baseValues:Null<StringMap<V>>, baseKeys:Null<Array<String>>, currentValues:StringMap<V>,
			currentKeys:Array<String>):RPCStringMapPatch<V> {
		if (currentValues == null || currentKeys == null) {
			throw new ArgumentError("RPCStringMapPatch.diffKeys needs the current values and keys.");
		}
		final full:Bool = baseValues == null || baseKeys == null;
		__sending = true;
		__received = false;
		isFull = full;
		__baseValues = full ? null : baseValues;
		__currentValues = currentValues;
		removed.resize(0);
		__added.resize(0);
		__updated.resize(0);
		__addedMasks.length = 0;
		__addedMasksHigh.length = 0;
		__updatedMasks.length = 0;
		__updatedMasksHigh.length = 0;
		final cur:Array<String> = __copy(currentKeys, __current);
		RPCKeys.sortUniqueStrings(cur);
		final old:Array<String> = __old;
		old.resize(0);
		if (!full) {
			__copy(baseKeys, old);
			RPCKeys.sortUniqueStrings(old);
		}
		final wide:Bool = __wide;
		final initial:V = codec.__default();
		var i:Int = 0;
		var j:Int = 0;
		final nc:Int = cur.length;
		final no:Int = old.length;
		while (i < nc || j < no) {
			final c:Null<String> = i < nc ? cur[i] : null;
			final o:Null<String> = j < no ? old[j] : null;
			if (j >= no || (i < nc && RPCMaps.before(c, o))) {
				final value:Null<V> = currentValues.get(c);
				if (value == null) {
					throw new ArgumentError('RPCStringMapPatch: key "$c" is in the current keys and not in the current values.');
				}
				__keepSent(__sentAdded, __added.length, value);
				__added.push(c);
				__addedMasks.push(codec.__mask(initial, value));
				if (wide) {
					__addedMasksHigh.push(codec.__maskHigh(initial, value));
				}
				i++;
			} else if (i >= nc || RPCMaps.before(o, c)) {
				removed.push(o);
				j++;
			} else {
				final was:Null<V> = baseValues.get(o);
				final value:Null<V> = currentValues.get(c);
				if (was == null || value == null) {
					throw new ArgumentError('RPCStringMapPatch: key "$c" is in a list of keys and not in its values.');
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

	/** As `RPCMapPatch.sizeBound`; -1, since keys are strings, unless nothing is added or updated. **/
	public function sizeBound():Int {
		var keys:Int = 0;
		for (key in removed) {
			keys += 5 + key.length * 3;
		}
		for (key in __added) {
			keys += 5 + key.length * 3;
		}
		for (key in __updated) {
			keys += 5 + key.length * 3;
		}
		final each:Int = codec.__patchBound();
		if (each < 0) {
			return -1;
		}
		return 15 + keys + (addedCount + updatedCount) * each;
	}

	/** The i-th added key, in key order. **/
	public function addedKey(i:Int):String {
		__require(i, __added.length, "addedCount");
		return __added[i];
	}

	/** As `RPCMapPatch.addedValue`. **/
	public function addedValue(i:Int):V {
		__require(i, __added.length, "addedCount");
		return __received ? __addedValues[i] : __currentValues.get(__added[i]);
	}

	/** The i-th updated key, in key order. **/
	public function updatedKey(i:Int):String {
		__require(i, __updated.length, "updatedCount");
		return __updated[i];
	}

	/** As `RPCMapPatch.applyUpdate`. **/
	public function applyUpdate(i:Int, target:V):V {
		__require(i, __updated.length, "updatedCount");
		if (target == null) {
			throw new ArgumentError("RPCStringMapPatch.applyUpdate needs the value to patch.");
		}
		if (!__received) {
			return codec.copy(__currentValues.get(__updated[i]), target);
		}
		return codec.__apply(__updatedStates[i], target, target);
	}

	/** As `RPCMapPatch.apply`. **/
	public function apply(base:Null<StringMap<V>>, into:StringMap<V>, recycle:Bool = false):Void {
		__requireApply(base, into);
		if (!isFull && into == base) {
			__applyInPlace(into, recycle);
			return;
		}
		if (!isFull) {
			__keysOf(base, __old);
			RPCKeys.sortUniqueStrings(__old);
		}
		__keysOf(into, __into);
		__applyKeys(isFull ? null : base, __old, into, __into, recycle);
	}

	/** As `RPCMapPatch.applyKeys`, the keys in `Array<String>`s; `intoKeys` becomes the new map's, in key order. **/
	public function applyKeys(baseValues:Null<StringMap<V>>, baseKeys:Null<Array<String>>, intoValues:StringMap<V>, intoKeys:Array<String>,
			recycle:Bool = false):Void {
		__requireApply(baseValues, intoValues);
		if (intoKeys == null || (!isFull && baseKeys == null)) {
			throw new ArgumentError("RPCStringMapPatch.applyKeys needs the maps' key lists.");
		}
		if (!isFull) {
			__copy(baseKeys, __old);
			RPCKeys.sortUniqueStrings(__old);
		}
		if (!isFull && intoValues == baseValues) {
			__applyInPlace(intoValues, recycle);
			__resultKeys(__old);
			__copy(__result, intoKeys);
			return;
		}
		__copy(intoKeys, __into);
		__applyKeys(isFull ? null : baseValues, __old, intoValues, __into, recycle);
		__copy(__result, intoKeys);
	}

	/** As `RPCMapPatch.write`. **/
	public function write(out:ByteArray):Void {
		if (out == null) {
			throw new ArgumentError("RPCStringMapPatch.write needs a ByteArray to write into.");
		}
		var frame:Null<RPCFrame> = __frame;
		if (frame == null) {
			frame = __frame = new RPCFrame(128);
		}
		frame.beginScratch();
		codec.__writeStringMapPatch(frame, this);
		out.writeBytes(frame, 0, frame.position);
	}

	/** As `RPCMapPatch.read`. **/
	public function read(input:ByteArray):RPCStringMapPatch<V> {
		if (input == null) {
			throw new ArgumentError("RPCStringMapPatch.read needs a ByteArray to read.");
		}
		final from:ByteArrayInput = input;
		codec.__readStringMapPatch(from, input.length, this);
		if (from.position > input.length) {
			throw "RPC map patch read past its end";
		}
		return this;
	}

	@:noCompletion public function __beginRead(full:Bool, added:Int, updated:Int):Void {
		__sending = false;
		__received = true;
		isFull = full;
		__baseValues = null;
		__currentValues = null;
		removed.resize(0);
		__added.resize(0);
		__updated.resize(0);
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
		removed.resize(0);
		__added.resize(0);
		__updated.resize(0);
		__received = false;
		__sending = false;
	}

	function __requireApply(base:Null<StringMap<V>>, into:StringMap<V>):Void {
		if (into == null) {
			throw new ArgumentError("RPCStringMapPatch.apply needs a map to set: the base to patch in place, or another.");
		}
		if (!isFull && base == null) {
			throw new ArgumentError("This map patch is against a base, and none was given: keep the map it names, or wait for a full one.");
		}
		if (!__received && !__sending) {
			throw new ArgumentError("This map patch has not been diffed or received.");
		}
	}

	function __applyInPlace(into:StringMap<V>, recycle:Bool):Void {
		for (key in removed) {
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
			final target:Null<V> = into.get(__updated[u]);
			if (target == null) {
				__missing(__updated[u], "updates");
			}
			__update(u, target, target);
		}
		for (a in 0...__added.length) {
			final key:String = __added[a];
			var target:Null<V> = into.get(key);
			if (target == null) {
				target = __take();
				into.set(key, target);
			}
			codec.copy(addedValue(a), target);
		}
	}

	function __applyKeys(base:Null<StringMap<V>>, baseKeys:Array<String>, into:StringMap<V>, intoKeys:Array<String>, recycle:Bool):Void {
		__resultKeys(base == null ? null : baseKeys);
		final result:Array<String> = __result;
		for (key in intoKeys) {
			if (RPCKeys.indexOfString(result, key) < 0) {
				final value:Null<V> = into.get(key);
				into.remove(key);
				if (recycle && value != null) {
					__keep(value);
				}
			}
		}
		for (key in result) {
			var target:Null<V> = into.get(key);
			final fresh:Bool = target == null;
			if (fresh) {
				target = __take();
			}
			final u:Int = RPCKeys.indexOfString(__updated, key);
			if (u >= 0) {
				__update(u, base.get(key), target);
			} else {
				final a:Int = RPCKeys.indexOfString(__added, key);
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

	function __resultKeys(baseKeys:Null<Array<String>>):Void {
		final kept:Array<String> = __kept;
		kept.resize(0);
		if (baseKeys != null) {
			var r:Int = 0;
			for (key in baseKeys) {
				if (r < removed.length && RPCMaps.before(removed[r], key)) {
					__missing(removed[r], "removes");
				}
				if (r < removed.length && removed[r] == key) {
					r++;
				} else {
					kept.push(key);
				}
			}
			if (r < removed.length) {
				__missing(removed[r], "removes");
			}
			for (key in __updated) {
				if (RPCKeys.indexOfString(kept, key) < 0) {
					__missing(key, "updates");
				}
			}
		}
		final result:Array<String> = __result;
		result.resize(0);
		var i:Int = 0;
		var j:Int = 0;
		while (i < kept.length || j < __added.length) {
			if (j >= __added.length || (i < kept.length && RPCMaps.before(kept[i], __added[j]))) {
				result.push(kept[i++]);
			} else if (i >= kept.length || RPCMaps.before(__added[j], kept[i])) {
				result.push(__added[j++]);
			} else {
				result.push(kept[i++]);
				j++;
			}
		}
	}

	inline function __update(u:Int, base:V, target:V):Void {
		if (__received) {
			codec.__apply(__updatedStates[u], base, target);
		} else {
			codec.copy(__currentValues.get(__updated[u]), target);
		}
	}

	function __missing(key:String, what:String):Void {
		throw new ArgumentError('This map patch $what key "$key", which its base does not hold: the base is not the one the sender used.');
	}

	function __require(i:Int, count:Int, what:String):Void {
		if (i < 0 || i >= count) {
			throw new RangeError('Index $i is out of bounds ($what $count)');
		}
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

	static function __copy(from:Array<String>, into:Array<String>):Array<String> {
		if (from == into) {
			return into;
		}
		into.resize(from.length);
		for (i in 0...from.length) {
			into[i] = from[i];
		}
		return into;
	}

	static function __keysOf<V>(map:StringMap<V>, into:Array<String>):Void {
		into.resize(0);
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
