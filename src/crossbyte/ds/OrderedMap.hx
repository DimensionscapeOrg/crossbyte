package crossbyte.ds;

import crossbyte.ds.ListedMap.KeyValuePair;

/**
 * ...
 * @author Christopher Speciale
 */
/**
 * A simple map that preserves insertion order of keys.
 *
 * Combines fast key-based lookup with ordered iteration.
 * Useful when you need predictable iteration order along with map semantics.
 *
 * Each entry sits on a list in the order its key was first set, so `remove`
 * unlinks it in constant time. Positions are counted along the list, so
 * `ofIndex` and `indexOf` cost the position they reach.
 *
 * **Removing while iterating** is safe: an entry removed before the loop
 * reaches it is not visited, and every other entry is visited once. An
 * entry added while iterating may or may not be visited.
 *
 * @param K The type of keys used in the map.
 * @param V The type of values stored in the map.
 */
@:generic
final class OrderedMap<K:Dynamic, V> {
	private var __map:Map<K, OrderedMapEntry<K, V>>;
	private var __first:OrderedMapEntry<K, V>;
	private var __last:OrderedMapEntry<K, V>;
	private var __count:Int = 0;

	/**
	 * Creates a new, empty `Orderedmap`.
	 */
	public function new() {
		__map = new Map();
	}

	/**
	 * Sets a value for the given key.
	 * If the key does not already exist, it is appended to the key order.
	 *
	 * @param key The key to set.
	 * @param value The value to associate with the key.
	 */
	public function set(key:K, value:V):Void {
		var entry = __map.get(key);
		if (entry != null) {
			entry.value = value;
			return;
		}

		entry = new OrderedMapEntry<K, V>(key, value);
		__map.set(key, entry);
		entry.previous = __last;
		if (__last == null) {
			__first = entry;
		} else {
			__last.next = entry;
		}
		__last = entry;
		__count++;
	}

	/**
	 * Retrieves the value associated with the given key.
	 *
	 * @param key The key to retrieve.
	 * @return The value associated with the key, or `null` if not found.
	 */
	public function get(key:K):Null<V> {
		var entry = __map.get(key);
		return entry == null ? null : entry.value;
	}

	/**
	 * Checks if the map contains the specified key.
	 *
	 * @param key The key to check.
	 * @return `true` if the key exists, `false` otherwise.
	 */
	public function exists(key:K):Bool {
		return __map.exists(key);
	}

	/**
	 * Removes the specified key and its associated value from the map.
	 *
	 * @param key The key to remove.
	 * @return `true` if the key existed and was removed, `false` otherwise.
	 */
	public function remove(key:K):Bool {
		var entry = __map.get(key);
		if (entry == null) {
			return false;
		}

		__map.remove(key);
		// Out of the list, but its own `next` is left as it was: an iterator
		// standing on it still finds its way on.
		if (entry.previous == null) {
			__first = entry.next;
		} else {
			entry.previous.next = entry.next;
		}
		if (entry.next == null) {
			__last = entry.previous;
		} else {
			entry.next.previous = entry.previous;
		}
		entry.previous = null;
		entry.removed = true;
		__count--;
		return true;
	}

	/**
	 * Returns an iterator over the keys in insertion order.
	 *
	 * @return An iterator of keys.
	 */
	public function keysIterator():Iterator<K> {
		return new OrderedMapKeyIterator<K, V>(__first);
	}

	/**
	 * Returns an iterator over the values in insertion order.
	 *
	 * @return An iterator of values.
	 */
	public function iterator():Iterator<V> {
		return new OrderedMapValueIterator<K, V>(__first);
	}

	/** The values, in insertion order as it happens. **/
	public inline function unorderedIterator():Iterator<V> {
		return iterator();
	}

	/**
	 * Returns an iterator over `{ key, value }` pairs in insertion order.
	 *
	 * @return An iterator of `KeyValuePair`s: classes, which fit where
	 *         `{key, value}` structures are asked for.
	 */
	public function keyValuePairs():Iterator<KeyValuePair<K, V>> {
		return new OrderedMapPairIterator<K, V>(__first);
	}

	/**
	 * Removes all keys and values from the map.
	 */
	public function clear():Void {
		// Each entry is marked and cut loose, so an iterator part way through
		// the map ends rather than walking what was cleared.
		var entry:OrderedMapEntry<K, V> = __first;
		while (entry != null) {
			var next:OrderedMapEntry<K, V> = entry.next;
			entry.removed = true;
			entry.previous = null;
			entry.next = null;
			entry = next;
		}
		__map.clear();
		__first = null;
		__last = null;
		__count = 0;
	}

	/**
	 * Returns the number of key-value pairs stored in the map.
	 *
	 * @return The number of entries in the map.
	 */
	public #if final inline #end function length():Int {
		return __count;
	}

	/** The value at position `x` in insertion order, or null past the end. **/
	public function ofIndex(x:Int):Null<V> {
		if (x < 0 || x >= __count) {
			return null;
		}
		var entry:OrderedMapEntry<K, V> = __first;
		for (_ in 0...x) {
			entry = entry.next;
		}
		return entry.value;
	}

	/**
	 * The position of `key` in insertion order, or -1 if it is not held or
	 * comes before `fromIndex` (counted from the end when negative, as
	 * `Array.indexOf` counts it).
	 */
	public function indexOf(key:K, ?fromIndex:Int):Int {
		if (!__map.exists(key)) {
			return -1;
		}
		var from:Int = fromIndex == null ? 0 : fromIndex;
		if (from < 0) {
			from += __count;
			if (from < 0) {
				from = 0;
			}
		}
		var at:Int = 0;
		var entry:OrderedMapEntry<K, V> = __first;
		while (entry != null) {
			if (at >= from && entry.key == key) {
				return at;
			}
			entry = entry.next;
			at++;
		}
		return -1;
	}
}

/** One entry of an `OrderedMap`, and its neighbours in insertion order. **/
@:noCompletion
private class OrderedMapEntry<K, V> {
	public var key:K;
	public var value:V;
	public var previous:OrderedMapEntry<K, V>;
	public var next:OrderedMapEntry<K, V>;
	public var removed:Bool = false;

	public function new(key:K, value:V) {
		this.key = key;
		this.value = value;
	}
}

// The iterators walk the entries themselves and do no Map operation, so
// Map's @:multiType key-type selection is never resolved through an
// unspecialized K.

/** The entries of an `OrderedMap` from `first` on, skipping removed ones. **/
@:noCompletion
private class OrderedMapWalk<K, V> {
	private var __at:OrderedMapEntry<K, V>;

	public inline function new(first:OrderedMapEntry<K, V>) {
		__at = first;
	}

	public inline function hasNext():Bool {
		// A removed entry keeps its `next`, and the chain from it reaches the
		// live entries after it.
		while (__at != null && __at.removed) {
			__at = __at.next;
		}
		return __at != null;
	}

	public inline function take():OrderedMapEntry<K, V> {
		hasNext();
		var entry:OrderedMapEntry<K, V> = __at;
		__at = entry.next;
		return entry;
	}
}

@:noCompletion
private class OrderedMapValueIterator<K, V> {
	private var __walk:OrderedMapWalk<K, V>;

	public inline function new(first:OrderedMapEntry<K, V>) {
		__walk = new OrderedMapWalk<K, V>(first);
	}

	public inline function hasNext():Bool {
		return __walk.hasNext();
	}

	public inline function next():V {
		return __walk.take().value;
	}
}

@:noCompletion
private class OrderedMapKeyIterator<K, V> {
	private var __walk:OrderedMapWalk<K, V>;

	public inline function new(first:OrderedMapEntry<K, V>) {
		__walk = new OrderedMapWalk<K, V>(first);
	}

	public inline function hasNext():Bool {
		return __walk.hasNext();
	}

	public inline function next():K {
		return __walk.take().key;
	}
}

/** The `{ key, value }` pair is built only when `next()` is called. **/
@:noCompletion
private class OrderedMapPairIterator<K, V> {
	private var __walk:OrderedMapWalk<K, V>;

	public inline function new(first:OrderedMapEntry<K, V>) {
		__walk = new OrderedMapWalk<K, V>(first);
	}

	public inline function hasNext():Bool {
		return __walk.hasNext();
	}

	public inline function next():KeyValuePair<K, V> {
		var entry:OrderedMapEntry<K, V> = __walk.take();
		return new KeyValuePair(entry.key, entry.value);
	}
}
