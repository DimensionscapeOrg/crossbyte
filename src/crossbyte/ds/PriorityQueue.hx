package crossbyte.ds;

import haxe.ds.ObjectMap;
import haxe.ds.Vector;

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
 * **Equal priorities are served first come, first served.** Each element
 * carries the order it was enqueued in, and that breaks every tie. A heap on
 * its own does not: dequeuing moves the newest element to the root, and a
 * strict comparison never sinks it past an equal, so a matchmaker holding
 * one priority would serve its newest ticket next and leave the oldest
 * waiting. `update` keeps an element's place in that order; only `dequeue`
 * and `remove` give it up.
 *
 * Elements are objects, held once each and told apart by identity: enqueuing
 * one already held updates it. A queue of plain `Int` ids is an
 * `IntPriorityQueue`, which holds each id's priority itself.
 *
 * ```haxe
 * var tickets = new PriorityQueue<Ticket>((a, b) -> a.priority - b.priority);
 * tickets.enqueue(ticket);
 * var next = tickets.dequeue(); // the lowest priority, the oldest among equals
 * ```
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

	@:noCompletion private var cmp:(T, T) -> Int;

	// Each element held has a slot, fixed for as long as it is held, and the
	// heap orders slot numbers. The map from element to slot is written once
	// when an element comes in and once when it goes; sifting moves slot
	// numbers through plain arrays, rather than writing the map for every
	// level an element moves.
	@:noCompletion private var __slotOf:ObjectMap<T, Int>;
	@:noCompletion private var __items:Vector<T>;
	// The order each slot's element was enqueued in, the tie-break. A Float
	// counts exactly to 2^53, where an Int would wrap after 2^32 enqueues and
	// put a waiting element behind every newer one.
	@:noCompletion private var __order:Vector<Float>;
	// Where each slot sits in the heap, and which slot sits at each position.
	@:noCompletion private var __position:Vector<Int>;
	@:noCompletion private var __heap:Vector<Int>;
	@:noCompletion private var __free:Vector<Int>;
	@:noCompletion private var __freeCount:Int = 0;
	@:noCompletion private var __slotCount:Int = 0;
	@:noCompletion private var __size:Int = 0;
	@:noCompletion private var __nextOrder:Float = 0.0;

	/**
	 * Creates a new priority queue with a given comparator function.
	 *
	 * @param comparator A function that compares two elements.
	 * Returns a negative number if the first is less than the second,
	 * zero if they are equal, or a positive number if greater.
	 */
	public function new(comparator:(T, T) -> Int) {
		this.cmp = comparator;
		__slotOf = new ObjectMap();
		__allocate(16);
	}

	@:noCompletion private inline function get_isEmpty():Bool {
		return __size == 0;
	}

	@:noCompletion private inline function get_size():Int {
		return __size;
	}

	/**
	 * Returns `true` if the queue contains the given element.
	 *
	 * @param x The element to check.
	 * @return Whether the element is in the queue.
	 */
	public inline function contains(x:T):Bool {
		return __slotOf.exists(x);
	}

	/**
	 * Returns the element with the **smallest key** according to the comparator
	 * (the current root of the min-heap) without removing it. Among equal keys,
	 * the one enqueued first.
	 *
	 * Returns `null` if the queue is empty.
	 */
	public function peek():Null<T> {
		// Not inline: inlined where T is known, the jvm reads `__items` as an
		// array of that type, which the erased Object[] it is cannot be cast
		// to.
		return __size > 0 ? __items[__heap[0]] : null;
	}

	/**
	 * Adds an element to the queue or updates its priority
	 * if it already exists.
	 *
	 * @param x The element to insert or update.
	 */
	public inline function enqueueOrUpdate(x:T):Void {
		enqueue(x);
	}

	/**
	 * Adds an element to the queue, behind every element already held with
	 * the same priority. An element already held is updated instead, and
	 * keeps its place among its equals.
	 *
	 * @param x The element to insert.
	 */
	public function enqueue(x:T):Void {
		if (__slotOf.exists(x)) {
			update(x);
			return;
		}

		var slot:Int;
		if (__freeCount > 0) {
			slot = __free[--__freeCount];
		} else {
			if (__slotCount == __items.length) {
				__allocate(__items.length * 2);
			}
			slot = __slotCount++;
		}
		__items[slot] = x;
		__order[slot] = __nextOrder;
		__nextOrder += 1.0;
		__slotOf.set(x, slot);

		var i:Int = __size++;
		__heap[i] = slot;
		__position[slot] = i;
		__siftUp(i);
	}

	/**
	 * Removes and returns the element with the highest priority: the
	 * smallest by the comparator, and the oldest among equals.
	 * Returns `null` if the queue is empty.
	 *
	 * @return The highest-priority element, or `null`.
	 */
	public function dequeue():Null<T> {
		if (__size == 0) {
			return null;
		}

		var root:T = __items[__heap[0]];
		__removeAt(0);
		return root;
	}

	/**
	 * Updates the priority of an element already in the queue.
	 * Has no effect if the element is not present.
	 *
	 * @param x The element to update.
	 */
	public function update(x:T):Void {
		if (!__slotOf.exists(x)) {
			return;
		}

		var slot:Int = __slotOf.get(x);
		var i:Int = __position[slot];
		if (!__siftUp(i)) {
			__siftDown(i);
		}
	}

	/**
	 * Removes an element from the queue if it exists.
	 *
	 * @param x The element to remove.
	 * @return `true` if the element was found and removed.
	 */
	public function remove(x:T):Bool {
		if (!__slotOf.exists(x)) {
			return false;
		}

		var slot:Int = __slotOf.get(x);
		__removeAt(__position[slot]);
		return true;
	}

	/**
	 * Clears all elements from the queue.
	 */
	public function clear():Void {
		for (i in 0...__size) {
			__items[__heap[i]] = null;
		}
		__slotOf = new ObjectMap();
		__size = 0;
		__freeCount = 0;
		__slotCount = 0;
		__nextOrder = 0.0;
	}

	// Whether slot `a`'s element goes before slot `b`'s: a smaller key, or an
	// equal key enqueued earlier. Never true both ways, which is what lets
	// the heap keep equals in the order they came.
	@:noCompletion private inline function __before(a:Int, b:Int):Bool {
		var c:Int = cmp(__items[a], __items[b]);
		return c < 0 || (c == 0 && __order[a] < __order[b]);
	}

	@:noCompletion private function __removeAt(i:Int):Void {
		var slot:Int = __heap[i];
		__slotOf.remove(__items[slot]);
		__items[slot] = null;
		__free[__freeCount++] = slot;

		var last:Int = --__size;
		if (i != last) {
			var moved:Int = __heap[last];
			__heap[i] = moved;
			__position[moved] = i;
			if (!__siftUp(i)) {
				__siftDown(i);
			}
		}
	}

	/** @return Whether the element at `i` moved. **/
	@:noCompletion private function __siftUp(i:Int):Bool {
		var slot:Int = __heap[i];
		var start:Int = i;
		while (i > 0) {
			var p:Int = (i - 1) >> 1;
			var parent:Int = __heap[p];
			if (!__before(slot, parent)) {
				break;
			}
			__heap[i] = parent;
			__position[parent] = i;
			i = p;
		}
		__heap[i] = slot;
		__position[slot] = i;
		return i != start;
	}

	@:noCompletion private function __siftDown(i:Int):Void {
		var slot:Int = __heap[i];
		var n:Int = __size;
		while (true) {
			var l:Int = (i << 1) + 1;
			if (l >= n) {
				break;
			}

			var m:Int = l;
			var child:Int = __heap[l];
			var r:Int = l + 1;
			if (r < n && __before(__heap[r], child)) {
				m = r;
				child = __heap[r];
			}

			if (!__before(child, slot)) {
				break;
			}

			__heap[i] = child;
			__position[child] = i;
			i = m;
		}
		__heap[i] = slot;
		__position[slot] = i;
	}

	@:noCompletion private function __allocate(capacity:Int):Void {
		var items:Vector<T> = new Vector<T>(capacity);
		var order:Vector<Float> = new Vector<Float>(capacity);
		var position:Vector<Int> = new Vector<Int>(capacity);
		var heap:Vector<Int> = new Vector<Int>(capacity);
		var free:Vector<Int> = new Vector<Int>(capacity);
		if (__items != null) {
			Vector.blit(__items, 0, items, 0, __slotCount);
			Vector.blit(__order, 0, order, 0, __slotCount);
			Vector.blit(__position, 0, position, 0, __slotCount);
			Vector.blit(__heap, 0, heap, 0, __size);
			Vector.blit(__free, 0, free, 0, __freeCount);
		}
		__items = items;
		__order = order;
		__position = position;
		__heap = heap;
		__free = free;
	}
}
