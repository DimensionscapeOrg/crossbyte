package crossbyte.ds;

/**
 * ...
 * @author Chris__topher Speciale
 */
/**
 * A generic stack implementation.
 *
 * This class represents a simple stack data structure, which operates on the Last In, First Out (LIFO) principle.
 *
 * @param T The type of elements held in this stack.
 */
@:generic
final class Stack<T> {
	/**
	 * The current number of elements in the stack.
	 *
	 * @return The number of elements currently in the stack.
	 */
	public var length(get, never):Int;

	/**
	 * Determines if the stack is empty.
	 *
	 * @return True if the stack has no elements; false otherwise.
	 */
	public var isEmpty(get, never):Bool;

	private var __items:Array<Null<T>>;
	private var __top:Int;

	private inline function get_isEmpty():Bool {
		return __top == 0;
	}

	private inline function get_length():Int {
		return __top;
	}

	/**
	 * Creates a new stack.
	 *
	 * @param length Optional. The initial size of the internal array used to store elements.
	 */
	public function new(length:Int = 0) {
		__items = new Array();
		__items.resize(length);
		__top = 0;
	}

	/**
	 * Pushes an element onto the top of the stack.
	 *
	 * @param item The element to push onto the stack.
	 */
	public inline function push(item:T):Void {
		if (__top >= __items.length) {
			__grow(__top + 1);
		}
		__items[__top++] = item; // T is assignable to Null<T>
	}

	/**
	 * Pops an element from the top of the stack.
	 *
	 * @return The element at the top of the stack, or `null` if the stack is empty.
	 */
	public inline function pop():Null<T> {
		var top = __top - 1;
		var ret:Null<T> = null;
		if (top >= 0) {
			ret = __items[top];
			__items[top] = null;
			__top = top;
		}
		return ret;
	}

	/**
	 * Clears all elements from the stack.
	 *
	 * @param dispose Optional. If `true`, the internal array is resized to zero.
	 */
	public inline function clear(dispose:Bool = false):Void {
		__top = 0;
		if (dispose) {
			__items.resize(0);
		}
	}

	/**
	 * Iterates over the elements of the stack **from bottom to top**.
	 *
	 * This method traverses the stack in insertion order (FIFO order),
	 * starting from the earliest pushed element up to the top of the stack.
	 * The provided callback function is invoked once for each element.
	 *
	 * While less cache-friendly for typical LIFO access, this can be useful
	 * if you need to process items in the same order they were added.
	 *
	 * @param fn The function to invoke for each element. Receives the
	 *           element as its single argument.
	 *
	 * @example
	 * ```haxe
	 * stack.forEach(item -> trace(item));
	 * ```
	 */
	public inline function forEach(fn:T->Void):Void {
		var a:Array<Null<T>> = __items;
		var i:Int = 0;
		var top = __top;
		while (i < top) {
			fn((a[i++] : T));
		}
	}

	/**
	 * Iterates over the elements of the stack **from top to bottom**.
	 *
	 * This method traverses the stack in reverse order (LIFO order),
	 * starting from the most recently pushed element down to the bottom.
	 * The provided callback function is invoked once for each element.
	 *
	 * This is generally the most cache-friendly iteration order, since it
	 * matches the natural access pattern of a stack (recently pushed values
	 * are near the end of the backing array).
	 *
	 * @param fn The function to invoke for each element. Receives the
	 *           element as its single argument.
	 *
	 * @example
	 * ```haxe
	 * stack.forEachReverse(item -> trace(item));
	 * ```
	 */
	public inline function forEachReverse(fn:T->Void):Void {
		var a:Array<Null<T>> = __items;
		var i:Int = __top;
		while (i > 0) {
			fn((a[--i] : T));
		}
	}

	/**
	 * Retrieves the element at the top of the stack without removing it.
	 *
	 * @return The element at the top of the stack, or `null` if the stack is empty.
	 */
	public inline function last():Null<T> {
		return __top > 0 ? __items[__top - 1] : null;
	}

	/**
	 * Provides an iterator to traverse the stack from top to bottom.
	 */
	public inline function iterator():Iterator<T> {
		return new StackIter<T>(__items, __top);
	}

	public inline function toString():String {
		if (__top == 0)
			return "Stack[]";

		var sb = new StringBuf();
		sb.add("Stack[");

		var items = __items;
		var top = __top;

		sb.add(Std.string(items[0]));

		var i = 1;
		while (i < top) {
			sb.add(", ");
			sb.add(Std.string(items[i]));
			i++;
		}

		sb.add("]");
		return sb.toString();
	}

	private inline function __grow(min:Int):Void {
		var cap:Int = __items.length;
		if (cap >= min) {
			return;
		}

		var newCap:Int = cap > 0 ? cap + (cap >> 1) : 1;
		if (newCap < min) {
			newCap = min;
		}
		__items.resize(newCap);
	}
}

@:noCompletion private final class StackIter<U> {
	var items:Array<Null<U>>;
	var i:Int;

	public inline function new(items:Array<Null<U>>, top:Int) {
		this.items = items;
		this.i = top;
	}

	public inline function hasNext():Bool
		return i > 0;

	public inline function next():U
		return (items[--i] : U);
}
