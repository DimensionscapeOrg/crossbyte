package crossbyte.ds;

import haxe.ds.ReadOnlyArray;
import haxe.ds.Map;
#if (cpp && !cppia)
import crossbyte.ds._internal.NativeMap;
#end

/**
 * DenseSet is a packed set data structure offering **O(1)** operations
 * for adding, removing, and checking membership of elements.
 *
 * It maintains a dense array of unique elements and a reverse-index map
 * for fast lookup. Elements are unordered and removals use **swap-and-pop**,
 * so order is not preserved. Designed for performance-critical use cases like
 * polling APIs, ECS systems, or socket sets.
 *
 * **Removing while iterating.** Removing the element a loop is on is safe:
 * the element moved into its place is visited next, and every other one
 * once. Removing an element the loop has already passed moves one it has
 * not reached behind it, which is then skipped. An element added during the
 * loop is visited by it. A loop allocates nothing natively or on the jvm,
 * and looks for a moved element only after a removal.
 *
 * Adding, removing and finding an element box nothing, natively and on the
 * jvm, at any position: each one's position is kept in a `Map`, which
 * would box a position past 255 natively and past 127 on the jvm.
 *
 * @param K The element type. Keys are compared using `Map` semantics.
 */
@:generic
final class DenseSet<K:Dynamic> {
	@:noCompletion private var keys:Array<K>;
	// Each element's position: natively plus one, so a map's 0 for a key it
	// does not hold is told apart from the first position.
	@:noCompletion private var pos:Map<K, Int>;
	// Removals so far, so an iterator looks again only after one.
	@:noCompletion private var __removals:Int = 0;
	#if jvm
	// Each position past 127 boxed once: the jvm's map holds an Integer for
	// every element, and Integer.valueOf makes a new one past 127 each time.
	@:noCompletion private var __boxes:haxe.ds.Vector<Dynamic> = null;
	#end

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
		var canAdd:Bool = !__holds(x);
		if (canAdd) {
			__place(x, keys.length);
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
		var idx:Int = __positionOf(x);
		var ret:Bool = idx < 0 ? false : removeAt(idx);
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
			__place(lastVal, index);
		}
		keys.pop();
		#if (cpp && !cppia)
		NativeMap.remove(pos, removed);
		#else
		pos.remove(removed);
		#end
		__removals++;
		return true;
	}

	/**
	 * Checks whether an element is present in the set.
	 *
	 * @param x The element to check.
	 * @return `true` if the element exists in the set.
	 */
	public inline function contains(x:K):Bool {
		return __holds(x);
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
		return __positionOf(x);
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
	public inline function iterator():DenseSetIterator<K> {
		return new DenseSetIterator<K>(this);
	}

	/**
	 * Clears all elements from the set.
	 */
	public inline function clear():Void {
		keys.resize(0);
		pos.clear();
		__removals++;
	}

	/** The elements, in packed order, as an `Array` prints them. **/
	public inline function toString():String {
		return Std.string(keys);
	}

	// Natively through the map's own class: through haxe.IMap a String key,
	// or a position past 255, is boxed for every call.
	private inline function __holds(x:K):Bool {
		#if (cpp && !cppia)
		return NativeMap.has(pos, x);
		#else
		return pos.exists(x);
		#end
	}

	private inline function __positionOf(x:K):Int {
		#if (cpp && !cppia)
		return NativeMap.intOf(pos, x) - 1;
		#elseif jvm
		// Read as the Integer the map holds: read as a Null<Int> it would be
		// unboxed and boxed again, past 127 a new one each time.
		var held:Dynamic = (cast pos : haxe.Constraints.IMap<K, Dynamic>).get(x);
		return held == null ? -1 : (held : Int);
		#else
		var i:Null<Int> = pos.get(x);
		return i == null ? -1 : i;
		#end
	}

	private inline function __place(x:K, index:Int):Void {
		#if (cpp && !cppia)
		NativeMap.set(pos, x, index + 1);
		#elseif jvm
		(cast pos : haxe.Constraints.IMap<K, Dynamic>).set(x, __boxed(index));
		#else
		pos.set(x, index);
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
 * Walks a `DenseSet` in its current packed order, with the element just
 * returned free to be removed: if another was swapped into its place, that
 * place is visited again.
 */
@:generic
@:noCompletion
@:access(crossbyte.ds.DenseSet)
class DenseSetIterator<K:Dynamic> {
	private var __set:DenseSet<K>;
	private var __keys:Array<K>;
	private var __next:Int = 0;
	private var __removals:Int;
	private var __returnedAt:Int = -1;
	private var __returned:K;

	public inline function new(set:DenseSet<K>) {
		__set = set;
		__keys = set.keys;
		__removals = set.__removals;
		// Written here, though only read once next() has written it, so that
		// a loop keeps the iterator in locals rather than allocating it: the
		// compiler will not inline an object one of whose fields could be
		// read unwritten.
		__returned = __keys[0];
	}

	public inline function hasNext():Bool {
		if (__set.__removals != __removals) {
			__settle();
		}
		return __next < __keys.length;
	}

	public inline function next():K {
		if (__set.__removals != __removals) {
			__settle();
		}
		var key:K = __keys[__next];
		__returned = key;
		__returnedAt = __next++;
		return key;
	}

	// Something was removed since the last look. If the element returned
	// last is no longer where it was, whatever is there now was swapped in
	// from the end and has not been visited. Elements are distinct, so a
	// different one there is a different element.
	private inline function __settle():Void {
		__removals = __set.__removals;
		if (__returnedAt >= 0) {
			if (__returnedAt >= __keys.length || __keys[__returnedAt] != __returned) {
				__next = __returnedAt;
			}
			__returnedAt = -1;
		}
	}
}
