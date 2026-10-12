package crossbyte.ds;

import crossbyte.errors.RangeError;
import haxe.ds.ReadOnlyArray;
import haxe.ds.Map;
#if (cpp && !cppia)
import crossbyte.ds._internal.NativeMap;
#end

/**
 * ...
 * @author Christopher Speciale
 */
/**
 * Represents a lightweight key-value mapping with efficient iteration
 * and removal
 * `ListedMap` is a hybrid data structure that maintains an associative mapping of keys to values 
 * while allowing for fast iteration via an internal array. It supports **swap-and-pop** removals, 
 * meaning that the order of elements is **not preserved** when removing entries.
 *
 * This structure is useful when maintaining a **dynamic** set of key-value pairs where iteration 
 * performance is crucial, and ordering is not a requirement.
 *
 * **Removing while iterating.** Removing the entry a loop is on is safe:
 * the entry moved into its place is visited next, and every other entry
 * once. Removing an entry the loop has already passed moves one it has not
 * yet reached behind it, which is then skipped.
 *
 * A value is kept in a map of its own as well as in the list, so `get` is
 * one lookup. Natively and on the jvm no key, value or position is boxed to
 * reach either map.
 *
 * @param K The type of keys stored in the map.
 * @param V The type of values associated with the keys.
 */
@:generic
final class ListedMap<K:Dynamic, V> {
	// Map for fast key -> value access.
	private var __map:Map<K, V>;
	// Array holding key–value entries.
	private var __keyValuePairs:Array<KeyValuePair<K, V>>;
	// Map from keys to indices in the __keyValuePairs array: natively plus
	// one, so a map's 0 for a key it does not hold is told apart from the
	// first index.
	private var __indices:Map<K, Int>;
	#if jvm
	// Each index past 127 boxed once: the jvm's map holds an Integer for
	// every key, and Integer.valueOf makes a new one past 127 each time.
	private var __boxes:haxe.ds.Vector<Dynamic> = null;
	#end

	/**
	 * Provides a read-only view of the internal key-value pairs.
	 *
	 * This property grants access to the stored key-value pairs in `ListedMap`
	 * without allowing modifications to the underlying array. The returned 
	 * `ReadOnlyArray<KeyValuePair<K, V>>` ensures that users can iterate 
	 * over the elements safely while preventing accidental mutations.
	 *
	 * **Warning:** While it is possible to obtain a reference to the underlying 
	 * array through certain means (e.g., reflection), users **must not** attempt 
	 * to modify it, as doing so may corrupt the internal indexing system.
	 *
	 * @see `ReadOnlyArray` for details on read-only behavior.
	 */
	public var keyValuePairs(get, never):ReadOnlyArray<KeyValuePair<K, V>>;

	private function get_keyValuePairs():ReadOnlyArray<KeyValuePair<K, V>> {
		return __keyValuePairs;
	}

	/**
	 * Retrieves the number of key-value pairs currently stored in the map.
	 */
	public var length(get, null):Int;

	private function get_length():Int {
		return __keyValuePairs.length;
	}

	/**
	 * Constructs a new, empty `ListedMap` instance.
	 */
	public function new() {
		__map = new Map<K, V>();
		__keyValuePairs = new Array<KeyValuePair<K, V>>();
		__indices = new Map<K, Int>();
	}

	/**
	 * Determines whether a given key exists in the map.
	 *
	 * @param key The key to check.
	 * @return `true` if the key exists, otherwise `false`.
	 */
	public function exists(key:K):Bool {
		#if (cpp && !cppia)
		return NativeMap.has(__map, key);
		#else
		return __map.exists(key);
		#end
	}

	/**
	 * Adds or updates an entry in the map.
	 *
	 * - If the key does not exist, a new entry is appended to the list.
	 * - If the key already exists, its associated value is updated in both the map and the list.
	 *
	 * @param key The key to insert or update.
	 * @param value The value to associate with the key.
	 */
	public function set(key:K, value:V):Bool {
		var idx:Int = __indexOf(key);
		__keep(key, value);
		if (idx < 0) {
			var entry:KeyValuePair<K, V> = new KeyValuePair(key, value);
			__place(key, __keyValuePairs.length);
			__keyValuePairs.push(entry);
			return true;
		} else {
			__keyValuePairs[idx].value = value;
			return false;
		}
	}

	/**
	 * Retrieves the value associated with a given key.
	 *
	 * @param key The key to look up.
	 * @return The associated value, or `null` if the key does not exist.
	 */
	public inline function get(key:K):Null<V> {
		#if (cpp && !cppia)
		return cast NativeMap.get(__map, key);
		#else
		return __map.get(key);
		#end
	}

	/**
	 * Retrieves the value at the specified index in the internal key-value pair array.
	 *
	 * This method provides direct indexed access to values stored in `ListedMap`, 
	 * which can be useful for iteration and performance-critical operations.
	 *
	 * **Warning:** Since `ListedMap` does not guarantee a stable ordering of elements,
	 * the value at a given index may change over time due to swap-and-pop removals.
	 * Avoid relying on index positions for persistent references.
	 *
	 * @param i The index of the value to retrieve.
	 * @return The value at the given index, or `null` if the index is out of bounds.
	 * @throws An error if the index has an invaid range. (only in debug mode).
	 */
	public #if !debug inline #end function valueAt(i:Int):Null<V> {
		#if debug
		if (i < 0 || i >= __keyValuePairs.length)
			throw new RangeError('Index $i is out of bounds (size: ${__keyValuePairs.length})');
		#end

		return __keyValuePairs[i].value;
	}

	/**
	 * Removes an entry from the map using the swap-and-pop technique.
	 *
	 * - The last element in the list replaces the removed element, preserving **O(1)** deletion time.
	 * - The order of elements is **not preserved**.
	 *
	 * @param key The key to remove.
	 * @return `true` if the key was found and removed, otherwise `false`.
	 */
	public function remove(key:K):Bool {
		var index:Int = __indexOf(key);
		if (index < 0)
			return false;

		#if (cpp && !cppia)
		NativeMap.remove(__map, key);
		#else
		__map.remove(key);
		#end
		var lastIndex = __keyValuePairs.length - 1;

		// If the entry is not the last, swap it with the last entry.
		if (index != lastIndex) {
			var lastEntry = __keyValuePairs[lastIndex];
			__keyValuePairs[index] = lastEntry;
			__place(lastEntry.key, index);
		}

		// Remove the last element.
		__keyValuePairs.pop();
		#if (cpp && !cppia)
		NativeMap.remove(__indices, key);
		#else
		__indices.remove(key);
		#end
		return true;
	}

	/**
	 * Removes all key-value pairs from the map.
	 */
	public function clear():Void {
		__map.clear();
		__keyValuePairs.resize(0);
		__indices.clear();
	}

	/**
	 * Returns an iterator over the keys stored in the data structure.
	 *
	 * @return An array containing all keys in the map.
	 */
	public inline function keys():Iterator<K> {
		return __map.keys();
	}

	/**
	 * Returns an iterator over the values stored in the map.
	 *
	 * @return An `Iterator<V>` over the values.
	 */
	public inline function iterator():ListedMapValueIterator<K, V> {
		return new ListedMapValueIterator<K, V>(this);
	}

	/**
	 * Returns an iterator over the key-value pairs in the map.
	 *
	 * Each element in the iterator contains both the key and its corresponding value.
	 *
	 * @return An `Iterator<KeyValuePair<K, V>>` over the stored entries.
	 */
	public inline function keyValueIterator():ListedMapPairIterator<K, V> {
		return new ListedMapPairIterator<K, V>(this);
	}

	// Natively through each map's own class: through haxe.IMap a String
	// key, or an Int key or index past 255, is boxed for every call.
	private inline function __keep(key:K, value:V):Void {
		#if (cpp && !cppia)
		NativeMap.set(__map, key, value);
		#else
		__map.set(key, value);
		#end
	}

	private inline function __indexOf(key:K):Int {
		#if (cpp && !cppia)
		return NativeMap.intOf(__indices, key) - 1;
		#elseif jvm
		// Read as the Integer the map holds: read as a Null<Int> it would be
		// unboxed and boxed again, past 127 a new one each time.
		var held:Dynamic = (cast __indices : haxe.Constraints.IMap<K, Dynamic>).get(key);
		return held == null ? -1 : (held : Int);
		#else
		var index:Null<Int> = __indices.get(key);
		return index == null ? -1 : index;
		#end
	}

	private inline function __place(key:K, index:Int):Void {
		#if (cpp && !cppia)
		NativeMap.set(__indices, key, index + 1);
		#elseif jvm
		(cast __indices : haxe.Constraints.IMap<K, Dynamic>).set(key, __boxed(index));
		#else
		__indices.set(key, index);
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
 * Walks a `ListedMap`'s entries in their current order, with the entry just
 * returned free to be removed: if another was swapped into its place, that
 * place is visited again.
 */
@:generic
@:noCompletion
@:access(crossbyte.ds.ListedMap)
class ListedMapPairIterator<K:Dynamic, V> {
	private var __map:ListedMap<K, V>;
	private var __next:Int = 0;
	private var __returned:KeyValuePair<K, V> = null;
	private var __returnedAt:Int = -1;

	public inline function new(map:ListedMap<K, V>) {
		__map = map;
	}

	public inline function hasNext():Bool {
		__settle();
		return __next < __map.__keyValuePairs.length;
	}

	public inline function next():KeyValuePair<K, V> {
		__settle();
		var pair:KeyValuePair<K, V> = __map.__keyValuePairs[__next];
		__returned = pair;
		__returnedAt = __next++;
		return pair;
	}

	// The entry returned last is no longer where it was: whatever is there
	// now was swapped in from the end and has not been visited.
	private inline function __settle():Void {
		if (__returned != null) {
			var pairs:Array<KeyValuePair<K, V>> = __map.__keyValuePairs;
			if (__returnedAt >= pairs.length || pairs[__returnedAt] != __returned) {
				__next = __returnedAt;
			}
			__returned = null;
		}
	}
}

/** `ListedMapPairIterator`, answering the values. **/
@:generic
@:noCompletion
class ListedMapValueIterator<K:Dynamic, V> {
	private var __pairs:ListedMapPairIterator<K, V>;

	public inline function new(map:ListedMap<K, V>) {
		__pairs = new ListedMapPairIterator<K, V>(map);
	}

	public inline function hasNext():Bool {
		return __pairs.hasNext();
	}

	public inline function next():V {
		return __pairs.next().value;
	}
}

/**
 * A key and its value, as `ListedMap` keeps them and `OrderedMap` hands them
 * out.
 *
 * A class that a literal builds: `{key: k, value: v}` makes one, and hxcpp
 * reads its fields directly rather than by name. It fits where
 * `{key:K, value:V}` is asked for, so `for (k => v in ...)` and code typed
 * against the structure work with it.
 *
 * @param K The type of the key.
 * @param V The type of the value.
 */
@:structInit
final class KeyValuePair<K, V> {
	public var key:K;
	public var value:V;

	public inline function new(key:K, value:V) {
		this.key = key;
		this.value = value;
	}
}
