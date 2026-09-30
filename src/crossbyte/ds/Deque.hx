package crossbyte.ds;

import haxe.ds.Vector;

/**
 * ...
 * @author Christopher Speciale
 */
/**
 * A double-ended queue: `add` and `pop` at the front, `push` and `remove` at
 * the back, each in constant time.
 *
 * The items sit in a ring that doubles when it fills, so adding one allocates
 * nothing once the ring has grown to fit; it was a linked list, which made a
 * node for every item added. The ring keeps its size when emptied.
 *
 * `for (item in deque)` walks from the front to the back.
 */
class Deque<T> {
	private var __items:Vector<Null<T>>;
	private var __head:Int = 0;
	private var _size:Int = 0;

	/**
	 * @param capacity Items to make room for at the start; the ring grows to
	 *        the next power of two past it as needed.
	 */
	public function new(capacity:Int = 16) {
		var size:Int = 16;
		while (size < capacity && size < (1 << 30)) {
			size <<= 1;
		}
		__items = new Vector<Null<T>>(size);
	}

	/** Adds `item` at the front. **/
	public function add(item:T):Void {
		if (_size == __items.length) {
			__grow();
		}
		__head = (__head - 1) & (__items.length - 1);
		__items[__head] = item;
		_size++;
	}

	/** Adds `item` at the back. **/
	public function push(item:T):Void {
		if (_size == __items.length) {
			__grow();
		}
		__items[(__head + _size) & (__items.length - 1)] = item;
		_size++;
	}

	/**
	 * Removes and returns the item at the front.
	 *
	 * @throws String If the deque is empty.
	 */
	public function pop():T {
		if (_size == 0)
			throw "Deque is empty";
		var value:T = __items[__head];
		__items[__head] = null;
		__head = (__head + 1) & (__items.length - 1);
		_size--;
		return value;
	}

	/**
	 * Removes and returns the item at the back.
	 *
	 * @throws String If the deque is empty.
	 */
	public function remove():T {
		if (_size == 0)
			throw "Deque is empty";
		var at:Int = (__head + _size - 1) & (__items.length - 1);
		var value:T = __items[at];
		__items[at] = null;
		_size--;
		return value;
	}

	/**
	 * The item at the front, left in place.
	 *
	 * @throws String If the deque is empty.
	 */
	public function first():T {
		if (_size == 0)
			throw "Deque is empty";
		return __items[__head];
	}

	/**
	 * The item at the back, left in place.
	 *
	 * @throws String If the deque is empty.
	 */
	public function last():T {
		if (_size == 0)
			throw "Deque is empty";
		return __items[(__head + _size - 1) & (__items.length - 1)];
	}

	public function isEmpty():Bool {
		return _size == 0;
	}

	public function size():Int {
		return _size;
	}

	/** Takes every item out, letting go of each, and keeps the ring. **/
	public function clear():Void {
		var mask:Int = __items.length - 1;
		for (i in 0..._size) {
			__items[(__head + i) & mask] = null;
		}
		__head = 0;
		_size = 0;
	}

	/**
	 * Walks the items from the front to the back. Adding or taking items out
	 * while it walks changes what it walks.
	 */
	public inline function iterator():DequeIterator<T> {
		return new DequeIterator<T>(this);
	}

	// The item `offset` from the front. Not inline, and what the iterator
	// reads through: inlined where T is known, the jvm would read `__items`
	// as an array of T, which the erased Object[] cannot be cast to.
	@:noCompletion private function __at(offset:Int):T {
		return __items[(__head + offset) & (__items.length - 1)];
	}

	// Twice the room, with the items laid out from the start again.
	private function __grow():Void {
		var grown:Vector<Null<T>> = new Vector<Null<T>>(__items.length * 2);
		var mask:Int = __items.length - 1;
		for (i in 0..._size) {
			grown[i] = __items[(__head + i) & mask];
		}
		__items = grown;
		__head = 0;
	}
}

/**
 * Walks a `Deque` from the front to the back. Made by `Deque.iterator()`; a
 * `for` loop over the deque is the usual way to use one.
 */
@:access(crossbyte.ds.Deque)
class DequeIterator<T> {
	private var __deque:Deque<T>;
	private var __next:Int = 0;

	public inline function new(deque:Deque<T>) {
		__deque = deque;
	}

	public inline function hasNext():Bool {
		return __next < __deque._size;
	}

	public inline function next():T {
		return __deque.__at(__next++);
	}
}
