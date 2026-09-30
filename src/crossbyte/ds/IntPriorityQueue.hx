package crossbyte.ds;

import crossbyte.errors.ArgumentError;
import crossbyte.errors.IllegalOperationError;
import crossbyte.utils.Hash;
import haxe.ds.Vector;

/**
 * A priority queue of `Int` ids, each held with its own priority.
 *
 * For what a `PriorityQueue` cannot hold: plain ids -- players, sessions,
 * entity slots -- rather than objects. An id carries no priority of its own,
 * so the queue keeps one beside it, given when the id is enqueued; nothing
 * is looked up while the heap is sifted and no comparator is called. That
 * keeps it free of allocation per operation on every target: a comparator
 * call on hxcpp boxes any `Int` argument outside -1 to 255, and one held in
 * an `Array` on the jvm is boxed above 127.
 *
 * The lowest priority is served first, and equal priorities in the order they
 * were enqueued. For highest first, enqueue the negated priority.
 *
 * ```haxe
 * var queue = new IntPriorityQueue();
 * queue.enqueue(playerId, rating);
 * while (queue.size >= 2) {
 * 	startMatch(queue.dequeue(), queue.dequeue());
 * }
 * ```
 *
 * **Threading.** None.
 */
final class IntPriorityQueue {
	/** How many ids are held. **/
	public var size(default, null):Int = 0;

	/** Whether no id is held. **/
	public var isEmpty(get, never):Bool;

	// As in PriorityQueue: each id held has a slot, fixed while it is held,
	// and the heap orders slot numbers, so the table from id to slot is
	// written only when an id comes and goes.
	@:noCompletion private var __slotOf:IdTable;
	@:noCompletion private var __ids:Vector<Int>;
	@:noCompletion private var __priority:Vector<Float>;
	@:noCompletion private var __order:Vector<Float>;
	@:noCompletion private var __position:Vector<Int>;
	@:noCompletion private var __heap:Vector<Int>;
	@:noCompletion private var __free:Vector<Int>;
	@:noCompletion private var __freeCount:Int = 0;
	@:noCompletion private var __slotCount:Int = 0;
	@:noCompletion private var __nextOrder:Float = 0.0;

	/**
	 * @param capacity Ids to make room for at the start; the queue grows past
	 *        it as needed.
	 */
	public function new(capacity:Int = 16) {
		if (capacity < 0) {
			throw new ArgumentError("capacity cannot be negative.");
		}
		__slotOf = new IdTable(capacity);
		__allocate(capacity < 1 ? 1 : capacity);
	}

	@:noCompletion private inline function get_isEmpty():Bool {
		return size == 0;
	}

	/** Whether `id` is held. **/
	public inline function contains(id:Int):Bool {
		return __slotOf.get(id) >= 0;
	}

	/**
	 * Adds `id` with `priority`, behind every id already held at that
	 * priority. An id already held is given the new priority instead, and
	 * keeps its place in line among its new equals.
	 *
	 * @throws ArgumentError If `priority` is NaN, which orders against
	 *         nothing.
	 */
	public function enqueue(id:Int, priority:Float):Void {
		if (Math.isNaN(priority)) {
			throw new ArgumentError("A priority cannot be NaN.");
		}

		var held:Int = __slotOf.get(id);
		if (held >= 0) {
			__priority[held] = priority;
			var at:Int = __position[held];
			if (!__siftUp(at)) {
				__siftDown(at);
			}
			return;
		}

		var slot:Int;
		if (__freeCount > 0) {
			slot = __free[--__freeCount];
		} else {
			if (__slotCount == __ids.length) {
				__allocate(__ids.length * 2);
			}
			slot = __slotCount++;
		}
		__ids[slot] = id;
		__priority[slot] = priority;
		__order[slot] = __nextOrder;
		__nextOrder += 1.0;
		__slotOf.set(id, slot);

		var i:Int = size++;
		__heap[i] = slot;
		__position[slot] = i;
		__siftUp(i);
	}

	/**
	 * Removes and returns the id with the lowest priority, the one enqueued
	 * first among equals.
	 *
	 * @throws IllegalOperationError If the queue is empty. No `Int` could say
	 *         so without also being an id.
	 */
	public function dequeue():Int {
		if (size == 0) {
			throw new IllegalOperationError("The queue is empty.");
		}
		var id:Int = __ids[__heap[0]];
		__removeAt(0);
		return id;
	}

	/**
	 * The id `dequeue` would return, left in place.
	 *
	 * @throws IllegalOperationError If the queue is empty.
	 */
	public function peek():Int {
		if (size == 0) {
			throw new IllegalOperationError("The queue is empty.");
		}
		return __ids[__heap[0]];
	}

	/**
	 * The priority of the id `dequeue` would return.
	 *
	 * @throws IllegalOperationError If the queue is empty.
	 */
	public function peekPriority():Float {
		if (size == 0) {
			throw new IllegalOperationError("The queue is empty.");
		}
		return __priority[__heap[0]];
	}

	/**
	 * The priority `id` is held with, or NaN when it is not held -- which no
	 * held id can have, since `enqueue` refuses it.
	 */
	public function priorityOf(id:Int):Float {
		var slot:Int = __slotOf.get(id);
		return slot < 0 ? Math.NaN : __priority[slot];
	}

	/**
	 * Takes `id` out.
	 *
	 * @return Whether it was held.
	 */
	public function remove(id:Int):Bool {
		var slot:Int = __slotOf.get(id);
		if (slot < 0) {
			return false;
		}
		__removeAt(__position[slot]);
		return true;
	}

	/** Takes every id out. **/
	public function clear():Void {
		__slotOf.clear();
		size = 0;
		__freeCount = 0;
		__slotCount = 0;
		__nextOrder = 0.0;
	}

	@:noCompletion private inline function __before(a:Int, b:Int):Bool {
		var pa:Float = __priority[a];
		var pb:Float = __priority[b];
		return pa < pb || (pa == pb && __order[a] < __order[b]);
	}

	@:noCompletion private function __removeAt(i:Int):Void {
		var slot:Int = __heap[i];
		__slotOf.remove(__ids[slot]);
		__free[__freeCount++] = slot;

		var last:Int = --size;
		if (i != last) {
			var moved:Int = __heap[last];
			__heap[i] = moved;
			__position[moved] = i;
			if (!__siftUp(i)) {
				__siftDown(i);
			}
		}
	}

	/** @return Whether the id at `i` moved. **/
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
		var n:Int = size;
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
		var ids:Vector<Int> = new Vector<Int>(capacity);
		var priority:Vector<Float> = new Vector<Float>(capacity);
		var order:Vector<Float> = new Vector<Float>(capacity);
		var position:Vector<Int> = new Vector<Int>(capacity);
		var heap:Vector<Int> = new Vector<Int>(capacity);
		var free:Vector<Int> = new Vector<Int>(capacity);
		if (__ids != null) {
			Vector.blit(__ids, 0, ids, 0, __slotCount);
			Vector.blit(__priority, 0, priority, 0, __slotCount);
			Vector.blit(__order, 0, order, 0, __slotCount);
			Vector.blit(__position, 0, position, 0, __slotCount);
			Vector.blit(__heap, 0, heap, 0, size);
			Vector.blit(__free, 0, free, 0, __freeCount);
		}
		__ids = ids;
		__priority = priority;
		__order = order;
		__position = position;
		__heap = heap;
		__free = free;
	}
}

/**
	Ids to slots: open addressing, linear probing, and no tombstones --
	removal shifts the entries after it back instead, so a lookup always ends
	at the first empty bucket.

	Not an `IntMap` because the jvm's does not end there. Its probe for a
	missing key visits every bucket, so the check each new id is given cost
	a pass over the whole table: 50,000 ids took a second where Node took
	17 ms.
**/
private class IdTable {
	private var __keys:Vector<Int>;
	// The slot plus one, so that a zeroed bucket reads as empty.
	private var __slots:Vector<Int>;
	private var __mask:Int;
	private var __shift:Int;
	private var __count:Int = 0;

	public function new(capacity:Int) {
		var buckets:Int = 16;
		while (buckets < capacity * 2 && buckets < (1 << 30)) {
			buckets <<= 1;
		}
		__init(buckets);
	}

	/** The slot `key` is held in, or -1. **/
	public function get(key:Int):Int {
		var i:Int = __home(key);
		while (true) {
			var slot:Int = __slots[i];
			if (slot == 0) {
				return -1;
			}
			if (__keys[i] == key) {
				return slot - 1;
			}
			i = (i + 1) & __mask;
		}
	}

	/** Files `key` under `slot`. `key` must not be held already. **/
	public function set(key:Int, slot:Int):Void {
		if ((__count + 1) * 2 > __mask + 1) {
			__rehash((__mask + 1) * 2);
		}
		var i:Int = __home(key);
		while (__slots[i] != 0) {
			i = (i + 1) & __mask;
		}
		__keys[i] = key;
		__slots[i] = slot + 1;
		__count++;
	}

	public function remove(key:Int):Void {
		var i:Int = __home(key);
		while (true) {
			if (__slots[i] == 0) {
				return;
			}
			if (__keys[i] == key) {
				break;
			}
			i = (i + 1) & __mask;
		}

		// Each entry after the hole moves back into it unless the hole lies
		// before its home, cyclically, which is what would lose it.
		var j:Int = i;
		while (true) {
			j = (j + 1) & __mask;
			if (__slots[j] == 0) {
				break;
			}
			var home:Int = __home(__keys[j]);
			var stays:Bool = i <= j ? (i < home && home <= j) : (i < home || home <= j);
			if (!stays) {
				__keys[i] = __keys[j];
				__slots[i] = __slots[j];
				i = j;
			}
		}
		__slots[i] = 0;
		__count--;
	}

	public function clear():Void {
		for (i in 0...__slots.length) {
			__slots[i] = 0;
		}
		__count = 0;
	}

	private inline function __home(key:Int):Int {
		return Hash.mul32(key, 0x9E3779B1) >>> __shift;
	}

	private function __init(buckets:Int):Void {
		__keys = new Vector<Int>(buckets);
		__slots = new Vector<Int>(buckets);
		// Zeroed natively; undefined on JavaScript and null on eval.
		for (i in 0...buckets) {
			__slots[i] = 0;
		}
		__mask = buckets - 1;
		var bits:Int = 0;
		while ((1 << bits) < buckets) {
			bits++;
		}
		__shift = 32 - bits;
		__count = 0;
	}

	private function __rehash(buckets:Int):Void {
		var keys:Vector<Int> = __keys;
		var slots:Vector<Int> = __slots;
		__init(buckets);
		for (i in 0...slots.length) {
			var slot:Int = slots[i];
			if (slot != 0) {
				set(keys[i], slot - 1);
			}
		}
	}
}
