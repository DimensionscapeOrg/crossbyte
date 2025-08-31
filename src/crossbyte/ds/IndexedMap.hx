package crossbyte.ds;

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
 * @param T The type of the stored values.
 */
class IndexedMap<T> {
	private var values:Array<T>;
	private var keyToIndex:Map<Int, Int>;
	private var indexToKey:Array<Int>;

	public function new() {
		values = [];
		keyToIndex = new Map();
		indexToKey = [];
	}

	/**
	 * Adds a value associated with the given key.
	 * If the key already exists, the value is updated.
	 *
	 * @param value The value to store.
	 * @param key The integer key to associate with the value.
	 */
	public function add(value:T, key:Int):Void {
		if (keyToIndex.exists(key)) {
			values[keyToIndex[key]] = value;
		} else {
			keyToIndex[key] = values.length;
			indexToKey.push(key);
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
		var idx = keyToIndex.get(key);
		if (idx == null)
			return false;

		var lastIdx = values.length - 1;
		var lastKey = indexToKey[lastIdx];

		// Swap removed with last if it's not already last
		if (idx != lastIdx) {
			values[idx] = values[lastIdx];
			keyToIndex[lastKey] = idx;
			indexToKey[idx] = lastKey;
		}

		// Remove last item
		values.pop();
		indexToKey.pop();
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
		var idx = keyToIndex.get(key);
		return (idx != null) ? values[idx] : null;
	}

	/**
	 * Sets the value for a given key.
	 * If the key does not exist, it will be added.
	 *
	 * @param key The key to set.
	 * @param value The value to associate with the key.
	 */
	public function set(key:Int, value:T):Void {
		if (keyToIndex.exists(key)) {
			values[keyToIndex[key]] = value;
		} else {
			add(value, key);
		}
	}

	/**
	 * Returns the number of values stored.
	 *
	 * @return The number of entries in the map.
	 */
	public inline function length():Int {
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
		indexToKey.resize(0);
		keyToIndex = new Map();
	}

	/**
	 * Returns an array of all keys in the map.
	 * The keys correspond to the order of values in `toArray()`.
	 *
	 * @return A copy of the list of keys.
	 */
	public function keys():Array<Int> {
		return indexToKey.copy();
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
	public function iterator():Iterator<T> {
		return values.iterator();
	}
}
