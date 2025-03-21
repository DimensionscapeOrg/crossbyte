package crossbyte.ds;

import haxe.ds.ReadOnlyArray;
import haxe.ds.Map;

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
 * @param K The type of keys stored in the map.
 * @param V The type of values associated with the keys.
 */
@:generic
final class ListedMap<K:Dynamic, V> {
	// Map for fast key -> value access.
	private var __map:Map<K, V>;
	// Array holding key–value entries.
	private var __keyValuePairs:Array<KeyValuePair<K, V>>;
	// Map from keys to indices in the __keyValuePairs array.
	private var __indices:Map<K, Int>;

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
		return __map.exists(key);
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
	public function set(key:K, value:V):Void {
		if (!__map.exists(key)) {
			__map.set(key, value);
			// Create a new entry inline.
			var entry:KeyValuePair<K, V> = {key: key, value: value};
			__indices.set(key, __keyValuePairs.length);
			__keyValuePairs.push(entry);
		} else {
			__map.set(key, value);
			var index = __indices.get(key);
			__keyValuePairs[index].value = value;
		}
	}

	/**
	 * Retrieves the value associated with a given key.
	 *
	 * @param key The key to look up.
	 * @return The associated value, or `null` if the key does not exist.
	 */
	public inline function get(key:K):Null<V> {
		return __map.get(key);
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
	public #if !debug inline #end function ofIndex(i:Int):Null<V> {
		#if debug
		if (i < 0 || i >= __keyValuePairs.length) 
			throw 'Index $i is out of bounds (size: ${__keyValuePairs.length})';
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
		if (!__map.exists(key))
			return false;

		__map.remove(key);
		var index = __indices.get(key);
		var lastIndex = __keyValuePairs.length - 1;

		// If the entry is not the last, swap it with the last entry.
		if (index != lastIndex) {
			var lastEntry = __keyValuePairs[lastIndex];
			__keyValuePairs[index] = lastEntry;
			__indices.set(lastEntry.key, index);
		}

		// Remove the last element.
		__keyValuePairs.pop();
		__indices.remove(key);
		return true;
	}

	/**
	 * Removes all key-value pairs from the map.
	 */
	public function clear():Void {
		__map.clear();
		__keyValuePairs = [];
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
	public function iterator():Iterator<V> {
		var i = 0;
		return {
			hasNext: function():Bool {
				return i < __keyValuePairs.length;
			},
			next: function():V {
				return __keyValuePairs[i++].value;
			}
		};
	}

	/**
	 * Returns an iterator over the key-value pairs in the map.
	 *
	 * Each element in the iterator contains both the key and its corresponding value.
	 *
	 * @return An `Iterator<KeyValuePair<K, V>>` over the stored entries.
	 */
	public function keyValueIterator():Iterator<KeyValuePair<K, V>> {
		var i = 0;
		return {
			hasNext: function():Bool {
				return i < __keyValuePairs.length;
			},
			next: function():KeyValuePair<K, V> {
				return __keyValuePairs[i++];
			}
		};
	}
}

/**
 * Represents a simple key-value pair used within `ListedMap`.
 *
 * This inline structure allows for efficient key-value storage.
 *
 * @param K The type of the key.
 * @param V The type of the value.
 */
typedef KeyValuePair<K, V> = {
	key:K,
	value:V
};
