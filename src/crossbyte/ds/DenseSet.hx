package crossbyte.ds;

import haxe.ds.ReadOnlyArray;
import haxe.ds.Map;

/**
 * DenseSet is a packed set data structure offering **O(1)** operations
 * for adding, removing, and checking membership of elements.
 *
 * It maintains a dense array of unique elements and a reverse-index map
 * for fast lookup. Elements are unordered and removals use **swap-and-pop**,
 * so order is not preserved. Designed for performance-critical use cases like
 * polling APIs, ECS systems, or socket sets.
 *
 * @param K The element type. Keys are compared using `Map` semantics.
 */
@:generic
final class DenseSet<K:Dynamic> {
	@:noCompletion private var keys:Array<K>;
	@:noCompletion private var pos:Map<K, Int>;

	public var length(get, never):Int;
	public var isEmpty(get, never):Bool;

	/**
	 * Creates a new DenseSet
	 * 
	 */
	public function new() {
		keys = [];
		pos = new Map<K, Int>();
	}

	/**
	 * Returns the number of elements currently in the set.
	 */
	public inline function get_length():Int {
		return keys.length;
	}

	/**
	 * Returns `true` if the set contains no elements.
	 */
	public inline function get_isEmpty():Bool {
		return keys.length == 0;
	}

	/**
	 * Adds an element to the set if it is not already present.
	 *
	 * @param x The element to add.
	 * @return `true` if the element was added, `false` if it was already present.
	 */
	public inline function add(x:K):Bool {
		var canAdd:Bool = !pos.exists(x);
		if (canAdd) {
			pos.set(x, keys.length);
			keys.push(x);
		}
		return canAdd;
	}

	/**
	 * Removes an element from the set if it is present.
	 *
	 * @param x The element to remove.
	 * @return `true` if the element was removed, `false` if it was not found.
	 */
	public inline function remove(x:K):Bool {
		var idx = pos.get(x);
		var ret:Bool = (idx == null) ? false : removeAt(idx);
		return ret;
	}

	/**
	 * Removes the element at the given index (dense array position).
	 * Uses swap-and-pop for constant-time removal.
	 *
	 * @param index The dense array index of the element to remove.
	 * @return `true` if the element was removed, `false` if the index was out of bounds.
	 */
	public function removeAt(index:Int):Bool {
		if (index < 0 || index >= keys.length) {
			return false;
		}

		var last = keys.length - 1;
		var lastVal = keys[last];
		var removed = keys[index];

		if (index != last) {
			keys[index] = lastVal;
			pos.set(lastVal, index);
		}
		keys.pop();
		pos.remove(removed);
		return true;
	}

	/**
	 * Checks whether an element is present in the set.
	 *
	 * @param x The element to check.
	 * @return `true` if the element exists in the set.
	 */
	public inline function contains(x:K):Bool {
		return pos.exists(x);
	}

	/**
	 * Returns a read-only view of the packed array of elements.
	 * 
	 * Do not mutate this array externally since doing so may corrupt internal state.
	 */
	public inline function readArray():ReadOnlyArray<K> {
		return keys;
	}

	/**
	 * Returns a new array containing the current elements in packed order.
	 * 
	 * @return A copy of the dense array.
	 */
	public inline function toArray():Array<K> {
		return keys.copy();
	}

	/**
	 * Gets the current dense array index of the given element.
	 *
	 * @param x The element to locate.
	 * @return The index if found, or `-1` if not present.
	 */
	public inline function indexOf(x:K):Int {
		var i = pos.get(x);
		return (i == null) ? -1 : i;
	}

	/**
	 * Retrieves the element at the given dense array index.
	 * 
	 * No bounds checking is performed.
	 *
	 * @param i The index to access.
	 * @return The element at the specified index.
	 */
	public inline function valueAt(i:Int):K
		return keys[i];

	/**
	 * Returns an iterator over the elements in packed array order.
	 *
	 * @return An `Iterator<K>` for the set.
	 */
	public inline function iterator():Iterator<K>
		return keys.iterator();

	/**
	 * Clears all elements from the set.
	 */
	public inline function clear():Void {
		keys.resize(0);
		pos.clear();
	}

	public inline function toString():String {
		return pos.toString();
	}
}
