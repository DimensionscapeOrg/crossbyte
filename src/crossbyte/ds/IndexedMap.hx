package crossbyte.ds;

#if (cpp && !cppia)
import crossbyte.ds._internal.NativeMap;
#end

/**
 * ...
 * @author Christopher Speciale
 */
/**
 * A map-like data structure that maintains a compact internal array of values,
 * allowing efficient indexed access and fast iteration.
 *
 * Each value is associated with an integer key, but the internal array remains
 * dense for performance.
 *
 * Removing the entry a loop is on is safe: the entry swapped into its place
 * is visited next, where the array's own iterator skipped it. Removing one
 * the loop has already passed swaps the last entry, which it has not reached,
 * into the place behind it, so that entry is skipped.
 *
 * Adding, finding and removing an entry box no key or index, natively or on
 * the jvm.
 *
 * @param T The type of the stored values.
 */
class IndexedMap<T> {
	private var values:Array<T>;
	// Each key's index: natively plus one, so the 0 a map's typed read gives
	// for a key it does not hold is told apart from the first index.
	private var keyToIndex:Map<Int, Int>;
	// Each entry's key, in the order of `values`. Natively and on the jvm in
	// a Vector, which only grows: on the jvm an Array<Int> holds each element
	// boxed, and natively an Array<Int> taking one off the end and putting one
	// back measured 23 bytes at 1,000 keys.
	private var indexToKey:#if (cpp || jvm) haxe.ds.Vector<Int> #else Array<Int> #end;
	#if jvm
	// Each index past 127 boxed once: the jvm's map holds an Integer for
	// every key, and Integer.valueOf makes a new one past 127 each time.
	private var __boxes:haxe.ds.Vector<Dynamic> = null;
	#end

	public function new() {
		values = [];
		keyToIndex = new Map();
		indexToKey = #if (cpp || jvm) new haxe.ds.Vector<Int>(8) #else [] #end;
	}

	/**
	 * Adds a value associated with the given key.
	 * If the key already exists, the value is updated.
	 *
	 * @param value The value to store.
	 * @param key The integer key to associate with the value.
	 */
	public function add(value:T, key:Int):Void {
		var index:Int = __indexOf(key);
		if (index >= 0) {
			values[index] = value;
		} else {
			index = values.length;
			__place(key, index);
			#if (cpp || jvm)
			if (index == indexToKey.length) {
				var grown = new haxe.ds.Vector<Int>(index * 2);
				haxe.ds.Vector.blit(indexToKey, 0, grown, 0, index);
				indexToKey = grown;
			}
			indexToKey[index] = key;
			#else
			indexToKey.push(key);
			#end
			values.push(value);
		}
	}

	/**
	 * Removes the value associated with the given key, if present.
	 * Performs a fast remove by swapping the element with the last item.
	 *
	 * @param key The key to remove.
	 * @return `true` if the key existed and was removed, `false` otherwise.
	 */
	public function remove(key:Int):Bool {
		var idx:Int = __indexOf(key);
		if (idx < 0)
			return false;

		var lastIdx = values.length - 1;
		var lastKey = indexToKey[lastIdx];

		// Swap removed with last if it's not already last
		if (idx != lastIdx) {
			values[idx] = values[lastIdx];
			__place(lastKey, idx);
			indexToKey[idx] = lastKey;
		}

		// Remove last item
		values.pop();
		#if !(cpp || jvm)
		indexToKey.pop();
		#end
		keyToIndex.remove(key);

		return true;
	}

	/**
	 * Gets the value associated with the given key.
	 *
	 * @param key The key to look up.
	 * @return The associated value, or `null` if the key does not exist.
	 */
	public function get(key:Int):Null<T> {
		var idx:Int = __indexOf(key);
		return idx >= 0 ? values[idx] : null;
	}

	/**
	 * Sets the value for a given key.
	 * If the key does not exist, it will be added.
	 *
	 * @param key The key to set.
	 * @param value The value to associate with the key.
	 */
	public function set(key:Int, value:T):Void {
		add(value, key);
	}

	/**
	 * The number of values stored.
	 */
	public var length(get, never):Int;

	@:noCompletion private inline function get_length():Int {
		return values.length;
	}

	/**
	 * Returns a shallow copy of the internal value array.
	 * This array may be in arbitrary order.
	 *
	 * @return A copy of the internal values array.
	 */
	public function toArray():Array<T> {
		return values.copy();
	}

	/**
	 * Removes all values and keys from the map.
	 */
	public function clear():Void {
		values.resize(0);
		#if !(cpp || jvm)
		indexToKey.resize(0);
		#end
		keyToIndex = new Map();
	}

	/**
	 * Returns an array of all keys in the map.
	 * The keys correspond to the order of values in `toArray()`.
	 *
	 * @return A copy of the list of keys.
	 */
	public function keys():Array<Int> {
		#if (cpp || jvm)
		return [for (i in 0...values.length) indexToKey[i]];
		#else
		return indexToKey.copy();
		#end
	}

	/**
	 * Checks whether a key exists in the map.
	 *
	 * @param key The key to check.
	 * @return `true` if the key exists, `false` otherwise.
	 */
	public function exists(key:Int):Bool {
		return keyToIndex.exists(key);
	}

	/**
	 * Returns an iterator over all values in the map.
	 * The iteration order matches the internal array.
	 *
	 * @return An iterator over the stored values.
	 */
	public inline function iterator():IndexedMapIterator<T> {
		return new IndexedMapIterator<T>(this);
	}

	// The index held for `key`, or -1. Natively through the map's typed
	// read: its get boxes an index past 255.
	private inline function __indexOf(key:Int):Int {
		#if (cpp && !cppia)
		return NativeMap.intOf(keyToIndex, key) - 1;
		#elseif jvm
		// Read as the Integer the map holds: read as a Null<Int> it would be
		// unboxed and boxed again, past 127 a new one each time.
		var held:Dynamic = (cast keyToIndex : haxe.ds.IntMap<Dynamic>).get(key);
		return held == null ? -1 : (held : Int);
		#else
		var index:Null<Int> = keyToIndex.get(key);
		return index == null ? -1 : index;
		#end
	}

	private inline function __place(key:Int, index:Int):Void {
		#if (cpp && !cppia)
		keyToIndex.set(key, index + 1);
		#elseif jvm
		(cast keyToIndex : haxe.ds.IntMap<Dynamic>).set(key, __boxed(index));
		#else
		keyToIndex.set(key, index);
		#end
	}

	#if jvm
	private function __boxed(index:Int):Dynamic {
		if (index < 128) {
			// Integer.valueOf's own cache.
			return (index : Dynamic);
		}
		var boxes:haxe.ds.Vector<Dynamic> = __boxes;
		if (boxes == null || index >= boxes.length) {
			var grown:haxe.ds.Vector<Dynamic> = new haxe.ds.Vector<Dynamic>(index < 512 ? 1024 : index * 2);
			if (boxes != null) {
				haxe.ds.Vector.blit(boxes, 0, grown, 0, boxes.length);
			}
			__boxes = boxes = grown;
		}
		var box:Dynamic = boxes[index];
		if (box == null) {
			box = (index : Dynamic);
			boxes[index] = box;
		}
		return box;
	}
	#end
}

/**
 * Walks an `IndexedMap`'s values in their current order, with the entry just
 * returned free to be removed: if another was swapped into its place, that
 * place is visited again. Keys, not values, say whether it was: two keys
 * can hold one value.
 */
@:noCompletion
@:access(crossbyte.ds.IndexedMap)
class IndexedMapIterator<T> {
	private var __map:IndexedMap<T>;
	private var __next:Int = 0;
	private var __returnedAt:Int = -1;
	private var __returnedKey:Int = 0;

	public inline function new(map:IndexedMap<T>) {
		__map = map;
	}

	public inline function hasNext():Bool {
		__settle();
		return __next < __map.values.length;
	}

	public inline function next():T {
		__settle();
		__returnedAt = __next;
		__returnedKey = __map.indexToKey[__next];
		return __map.values[__next++];
	}

	private inline function __settle():Void {
		if (__returnedAt >= 0) {
			if (__returnedAt >= __map.values.length || __map.indexToKey[__returnedAt] != __returnedKey) {
				__next = __returnedAt;
			}
			__returnedAt = -1;
		}
	}
}
