package crossbyte.ds;

/**
 * ...
 * @author Christopher Speciale
 */
/**
 * A simple __map that preserves insertion order of __keys.
 * 
 * Combines fast key-based lookup with ordered iteration.
 * Useful when you need predictable iteration order along with __map semantics.
 *
 * @param K The type of __keys used in the __map.
 * @param V The type of values stored in the __map.
 */
@:generic
final class OrderedMap<K:Dynamic, V> {
	private var __map:Map<K, V>;
	private var __keys:Array<K>;

	/**
	 * Creates a new, empty `Ordered__map`.
	 */
	public function new() {
		__map = new Map();
		__keys = [];
	}

	/**
	 * Sets a value for the given key.
	 * If the key does not already exist, it is appended to the key order.
	 *
	 * @param key The key to set.
	 * @param value The value to associate with the key.
	 */
	public function set(key:K, value:V):Void {
		if (!__map.exists(key))
			__keys.push(key);
		__map.set(key, value);
	}

	/**
	 * Retrieves the value associated with the given key.
	 *
	 * @param key The key to retrieve.
	 * @return The value associated with the key, or `null` if not found.
	 */
	public function get(key:K):Null<V> {
		return __map.get(key);
	}

	/**
	 * Checks if the __map contains the specified key.
	 *
	 * @param key The key to check.
	 * @return `true` if the key exists, `false` otherwise.
	 */
	public function exists(key:K):Bool {
		return __map.exists(key);
	}

	/**
	 * Removes the specified key and its associated value from the __map.
	 *
	 * @param key The key to remove.
	 * @return `true` if the key existed and was removed, `false` otherwise.
	 */
	public function remove(key:K):Bool {
		if (!__map.exists(key))
			return false;
		__map.remove(key);
		__keys.remove(key);
		return true;
	}

	/**
	 * Returns an iterator over the __keys in insertion order.
	 *
	 * @return An iterator of __keys.
	 */
	public function __keysIterator():Iterator<K> {
		return __keys.iterator();
	}

	/**
	 * Returns an iterator over the values in insertion order.
	 *
	 * @return An iterator of values.
	 */
	public function valuesIterator():Iterator<V> {
		return __keys.map(k -> __map.get(k)).iterator();
	}

	/**
	 * Returns an iterator over `{ key, value }` pairs in insertion order.
	 *
	 * @return An iterator of objects with `key` and `value` fields.
	 */
	public function keyValuePairs():Iterator<{key:K, value:V}> {
		return __keys.map(k -> {key: k, value: __map.get(k)}).iterator();
	}

	/**
	 * Removes all __keys and values from the __map.
	 */
	public function clear():Void {
		__map.clear();
		__keys = [];
	}

	/**
	 * Returns the number of key-value pairs stored in the __map.
	 *
	 * @return The number of entries in the __map.
	 */
	public #if !debug inline #end function length():Int {
		return __keys.length;
	}

	public #if !debug inline #end function ofIndex(x:Int):Null<V> {
		return __map.get(__keys[x]);
	}

	public #if !debug inline #end function indexOf(key:K, ?fromIndex:Int):Int {
		return __keys.indexOf(key, fromIndex);
	}
}
