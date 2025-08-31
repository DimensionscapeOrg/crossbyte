package crossbyte.ds;

import haxe.ds.ObjectMap;

/**
 * ...
 * @author Christopher Speciale
 */

 /**
 * A generic priority queue implemented as a binary heap.
 * 
 * Items are ordered according to a user-provided comparator function.
 * This structure supports fast `enqueue`, `dequeue`, and `update` operations.
 * 
 * @param T The type of elements stored in the queue. Must be an object type.
 */
final class PriorityQueue<T:{}> {
	/**
	 * Returns `true` if the queue is empty.
	 */
	public var isEmpty(get, never):Bool;

	/**
	 * Returns the number of elements currently in the queue.
	 */
	public var size(get, never):Int;

	@:noCompletion private var heap:Array<T>;
	@:noCompletion private var pos:ObjectMap<T, Int>; 
	@:noCompletion private var cmp:(T, T) -> Int;

	/**
	 * Creates a new priority queue with a given comparator function.
	 * 
	 * @param comparator A function that compares two elements. 
	 * Returns a negative number if the first is less than the second,
	 * zero if they are equal, or a positive number if greater.
	 */
	public function new(comparator:(T, T) -> Int) {
		this.heap = [];
		this.pos = new ObjectMap();
		this.cmp = comparator;
	}

	@:noCompletion private inline function get_isEmpty():Bool {
		return heap.length == 0;
	}

	@:noCompletion private inline function get_size():Int {
		return heap.length;
	}

	/**
	 * Returns `true` if the queue contains the given element.
	 * 
	 * @param x The element to check.
	 * @return Whether the element is in the queue.
	 */
	public inline function contains(x:T):Bool {
		return pos.exists(x);
	}

	/**
	 * Returns the element at the front of the queue (highest priority)
	 * without removing it. Returns `null` if the queue is empty.
	 */
	public inline function peek():Null<T> {
		return heap.length > 0 ? heap[0] : null;
	}

	/**
	 * Adds an element to the queue or updates its priority
	 * if it already exists.
	 * 
	 * @param x The element to insert or update.
	 */
	public inline function enqueueOrUpdate(x:T):Void {
		var i:Null<Int> = pos.get(x);
		if (i == null) {
			enqueue(x);
		} else {
			update(x);
		}
	}

	/**
	 * Adds an element to the queue.
	 * 
	 * @param x The element to insert.
	 */
	public inline function enqueue(x:T):Void {
		var i:Int = heap.length;
		heap[i] = x;
		pos.set(x, i);
		siftUp(i);
	}

	/**
	 * Removes and returns the element with the highest priority.
	 * Returns `null` if the queue is empty.
	 * 
	 * @return The highest-priority element, or `null`.
	 */
	public inline function dequeue():Null<T> {
		var n:Int = heap.length;
		var root:T = null;
		if (n > 0) {
			root = heap[0];
			removeAt(0);
		}
		return root;
	}

	/**
	 * Updates the priority of an element already in the queue.
	 * Has no effect if the element is not present.
	 * 
	 * @param x The element to update.
	 */
	public inline function update(x:T):Void {
		var i:Null<Int> = pos.get(x);
		if (i == null) {
			return;
		}

		siftUp(i);
		siftDown(i);
	}

	/**
	 * Removes an element from the queue if it exists.
	 * 
	 * @param x The element to remove.
	 * @return `true` if the element was found and removed.
	 */
	public inline function remove(x:T):Bool {
		var i:Null<Int> = pos.get(x);
		var removed:Bool = i != null;
		if (removed) {
			removeAt(i);
		}

		return removed;
	}

	/**
	 * Clears all elements from the queue.
	 */
	public inline function clear():Void {
		heap.resize(0);
		pos = new ObjectMap();
	}

	@:noCompletion private inline function less(i:Int, j:Int):Bool {
		var c = cmp(heap[i], heap[j]);
		return c < 0;
	}

	@:noCompletion private inline function swap(i:Int, j:Int):Void {
		var a:T = heap[i];
		var b:T = heap[j];

		heap[i] = b;
		heap[j] = a;
		pos.set(b, i);
		pos.set(a, j);
	}

	@:noCompletion private function removeAt(i:Int):Void {
		var n:Int = heap.length - 1;
		var victim:T = heap[i];
		pos.remove(victim);

		if (i != n) {
			heap[i] = heap[n];
			pos.set(heap[i], i);
		}
		heap.pop();

		if (i < heap.length) {
			siftUp(i);
			siftDown(i);
		}
	}

	@:noCompletion private function siftUp(i:Int):Void {
		while (i > 0) {
			var p:Int = (i - 1) >> 1;
			if (!less(i, p))
				break;
			swap(i, p);
			i = p;
		}
	}

	@:noCompletion private function siftDown(i:Int):Void {
		var n:Int = heap.length;
		while (true) {
			var l:Int = (i << 1) + 1;
			if (l >= n)
				break;

			var r:Int = l + 1;
			var m:Int = l;
			if (r < n && less(r, l)) {
				m = r;
			}

			if (!less(m, i)) {
				break;
			}

			swap(i, m);
			i = m;
		}
	}
}
