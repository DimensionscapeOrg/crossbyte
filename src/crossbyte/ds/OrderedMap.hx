package crossbyte.ds;

import crossbyte.ds.ListedMap.KeyValuePair;
#if (cpp && !cppia)
import crossbyte.ds._internal.NativeMap;
#end

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
 * A `for` loop over the values, the keys (`keysIterator()`) or the pairs
 * (`for (key => value in map)`) allocates nothing natively or on the jvm;
 * `keyValuePairs()` hands out a `KeyValuePair` for each entry.
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
		var entry = __entryOf(key);
		if (entry != null) {
			entry.value = value;
			return;
		}

		entry = new OrderedMapEntry<K, V>(key, value);
		#if (cpp && !cppia)
		NativeMap.set(__map, key, entry);
		#else
		__map.set(key, entry);
		#end
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
		var entry = __entryOf(key);
		return entry == null ? null : entry.value;
	}

	/**
	 * Checks if the map contains the specified key.
	 *
	 * @param key The key to check.
	 * @return `true` if the key exists, `false` otherwise.
	 */
	public function exists(key:K):Bool {
		return __holds(key);
	}

	/**
	 * Removes the specified key and its associated value from the map.
	 *
	 * @param key The key to remove.
	 * @return `true` if the key existed and was removed, `false` otherwise.
	 */
	public function remove(key:K):Bool {
		var entry = __entryOf(key);
		if (entry == null) {
			return false;
		}

		#if (cpp && !cppia)
		NativeMap.remove(__map, key);
		#else
		__map.remove(key);
		#end
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
	 * @return An iterator of keys, which fits where an `Iterator<K>` is
	 *         asked for.
	 */
	public inline function keysIterator():OrderedMapKeyIterator<K, V> {
		return new OrderedMapKeyIterator<K, V>(__first);
	}

	/**
	 * Returns an iterator over the values in insertion order.
	 *
	 * @return An iterator of values, which fits where an `Iterator<V>` is
	 *         asked for.
	 */
	public inline function iterator():OrderedMapValueIterator<K, V> {
		return new OrderedMapValueIterator<K, V>(__first);
	}

	/** The values, in insertion order as it happens. **/
	public inline function unorderedIterator():OrderedMapValueIterator<K, V> {
		return iterator();
	}

	/**
	 * Returns an iterator over `{ key, value }` pairs in insertion order.
	 *
	 * @return An iterator of `KeyValuePair`s: classes, which fit where
	 *         `{key, value}` structures are asked for. Each `next()` makes
	 *         one, which a `for (key => value in map)` loop does not.
	 */
	public inline function keyValuePairs():OrderedMapPairIterator<K, V> {
		return new OrderedMapPairIterator<K, V>(__first);
	}

	/**
	 * What `for (key => value in map)` walks: the pairs in insertion order,
	 * as `keyValuePairs()` hands them out, but in a loop allocating none.
	 */
	public inline function keyValueIterator():OrderedMapPairIterator<K, V> {
		return keyValuePairs();
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
	 * The number of key-value pairs stored in the map.
	 */
	public var length(get, never):Int;

	@:noCompletion private #if final inline #end function get_length():Int {
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
		if (!__holds(key)) {
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

	// Natively through the map's own class: through haxe.IMap a String key,
	// or an Int key past 255, is boxed for every call.
	private inline function __entryOf(key:K):Null<OrderedMapEntry<K, V>> {
		#if (cpp && !cppia)
		return cast NativeMap.get(__map, key);
		#else
		return __map.get(key);
		#end
	}

	private inline function __holds(key:K):Bool {
		#if (cpp && !cppia)
		return NativeMap.has(__map, key);
		#else
		return __map.exists(key);
		#end
	}
}

/**
 * One entry of an `OrderedMap`, and its neighbours in insertion order.
 *
 * Not generic, on purpose: natively a primitive value is held boxed, so
 * `get`, which answers a `Null<V>`, hands back the box it holds. Held as an
 * `Int`, every `get` past 255 would box it again, where now only a `set`
 * does. (On the jvm a `get` of an `Int` past 127 boxes it again either way:
 * the jvm target reads a `Null<Int>` out of a generic value by unboxing it
 * and boxing it anew.)
 */
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

	/**
		The first entry still held from `entry` on, or null. A removed entry
		keeps its `next`, and the chain from it reaches the live entries
		after it. Out of line, so a loop's step holds no loop of its own.
	**/
	public static function liveFrom<K, V>(entry:OrderedMapEntry<K, V>):Null<OrderedMapEntry<K, V>> {
		while (entry != null && entry.removed) {
			entry = entry.next;
		}
		return entry;
	}
}

// The iterators walk the entries themselves and do no Map operation, so
// Map's @:multiType key-type selection is never resolved through an
// unspecialized K. Each is one object whose one field its constructor
// writes, and all of it inline, so a `for` loop keeps it in locals rather
// than allocating it.

/**
 * Walks an `OrderedMap`'s values in insertion order, skipping entries removed
 * since. Made by `OrderedMap.iterator()`.
 */
@:noCompletion
class OrderedMapValueIterator<K, V> {
	private var __at:OrderedMapEntry<K, V>;

	public inline function new(first:OrderedMapEntry<K, V>) {
		__at = first;
	}

	public inline function hasNext():Bool {
		if (__at != null && __at.removed) {
			__at = OrderedMapEntry.liveFrom(__at);
		}
		return __at != null;
	}

	public inline function next():V {
		var entry:OrderedMapEntry<K, V> = __at;
		if (entry.removed) {
			entry = OrderedMapEntry.liveFrom(entry);
		}
		__at = entry.next;
		return entry.value;
	}
}

/** `OrderedMapValueIterator`, answering the keys. Made by `OrderedMap.keysIterator()`. **/
@:noCompletion
class OrderedMapKeyIterator<K, V> {
	private var __at:OrderedMapEntry<K, V>;

	public inline function new(first:OrderedMapEntry<K, V>) {
		__at = first;
	}

	public inline function hasNext():Bool {
		if (__at != null && __at.removed) {
			__at = OrderedMapEntry.liveFrom(__at);
		}
		return __at != null;
	}

	public inline function next():K {
		var entry:OrderedMapEntry<K, V> = __at;
		if (entry.removed) {
			entry = OrderedMapEntry.liveFrom(entry);
		}
		__at = entry.next;
		return entry.key;
	}
}

/**
 * `OrderedMapValueIterator`, answering `{ key, value }` pairs, each built
 * only when `next()` is called. Made by `OrderedMap.keyValuePairs()`.
 */
@:noCompletion
class OrderedMapPairIterator<K, V> {
	private var __at:OrderedMapEntry<K, V>;

	public inline function new(first:OrderedMapEntry<K, V>) {
		__at = first;
	}

	public inline function hasNext():Bool {
		if (__at != null && __at.removed) {
			__at = OrderedMapEntry.liveFrom(__at);
		}
		return __at != null;
	}

	public inline function next():KeyValuePair<K, V> {
		var entry:OrderedMapEntry<K, V> = __at;
		if (entry.removed) {
			entry = OrderedMapEntry.liveFrom(entry);
		}
		__at = entry.next;
		return new KeyValuePair<K, V>(entry.key, entry.value);
	}
}
