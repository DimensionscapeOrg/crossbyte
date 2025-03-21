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
@:final
@:generic
class Stack<T> {
	/**
	 * The current number of elements in the stack.
	 *
	 * @return The number of elements currently in the stack.
	 */
	public var length(get, never):Int;

	private var __items:Array<T>;
	private var __top:Int;

	private inline function get_length() {
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
			__items.resize(__items.length > 0 ? __items.length * 2 : 1);
		}
		__items[__top++] = item;
	}

	/**
	 * Pops an element from the top of the stack.
	 *
	 * @return The element at the top of the stack, or `null` if the stack is empty.
	 */
	public inline function pop():Null<T> {
		/*if (__top == 0)
			{
				return null;  // Return null instead of throwing an error
			}
			return __items[--__top]; */

		return __top > 0 ? __items[--__top] : null;
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
	 * Retrieves the element at the top of the stack without removing it.
	 *
	 * @return The element at the top of the stack, or `null` if the stack is empty.
	 */
	public inline function last():Null<T> {
		/*if (__top == 0)
			{
				return null; // Return null instead of throwing an error
			}
			return __items[__top - 1]; */
		return __top > 0 ? __items[__top - 1] : null;
	}

	/**
	 * Checks if the stack is empty.
	 *
	 * @return True if the stack has no elements; false otherwise.
	 */
	public inline function isEmpty():Bool {
		return __top == 0;
	}

	/**
	 * Provides an iterator to traverse the stack from top to bottom.
	 */
	public inline function iterator():Iterator<T> {
		var index = __top;
		return {
			hasNext: function() return index > 0,
			next: function() return __items[--index]
		};
	}
}
