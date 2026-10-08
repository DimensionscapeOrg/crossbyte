package crossbyte.ds;

import haxe.ds.Vector;

/**
 * A list of `Int` ids for results gathered every tick: it holds them
 * unboxed on every target, and keeps its storage when it is emptied.
 *
 * An `Array<Int>` does neither everywhere. On the jvm it holds each value
 * above 127 as a boxed `Integer`, one allocation per id pushed; on
 * JavaScript, emptying one with `resize(0)` hands V8's backing store back,
 * so the next round grows it again from nothing. For 1,000 views of 50 ids
 * that is 2.2 MB a tick, 130 MB a second at 60 Hz, spent on the list
 * alone. hxcpp has neither problem, and this costs it nothing either.
 *
 * ```haxe
 * var found = new IdList();
 *
 * // For each observer, every tick.
 * found.clear();
 * grid.queryCircleIds(observer.x, observer.y, VIEW_RADIUS, found);
 * observer.interest.addAll(found);
 * observer.interest.commit(onEnter, onLeave);
 * ```
 *
 * **Threading.** None.
 */
final class IdList {
	/** Ids held. **/
	public var length(default, null):Int = 0;

	@:noCompletion private var __ids:Vector<Int>;

	/**
	 * @param capacity Ids to make room for at the start; the list grows past
	 *        it as needed and never shrinks.
	 */
	public function new(capacity:Int = 16) {
		// Filled, so V8 holds it as a packed array rather than a holey one.
		__ids = new Vector<Int>(capacity < 1 ? 1 : capacity, 0);
	}

	/** Adds `id` at the end. **/
	public inline function push(id:Int):Void {
		if (length == __ids.length) {
			__grow();
		}
		__ids[length++] = id;
	}

	/**
	 * The id at `index`, counting from 0.
	 *
	 * @throws String If `index` is not below `length`.
	 */
	public inline function get(index:Int):Int {
		if (index < 0 || index >= length) {
			throw 'Index $index is out of bounds (length $length)';
		}
		return __ids[index];
	}

	/** Empties the list and keeps its storage for the next round. **/
	public inline function clear():Void {
		length = 0;
	}

	/**
	 * Iterates the ids in the order they were pushed. Written as a `for`
	 * loop, the iteration allocates nothing.
	 */
	public inline function iterator():IdListIterator {
		return new IdListIterator(this);
	}

	/** A new `Array` holding the same ids. **/
	public function toArray():Array<Int> {
		return [for (i in 0...length) __ids[i]];
	}

	public function toString():String {
		return toArray().toString();
	}

	@:noCompletion private function __grow():Void {
		var grown:Vector<Int> = new Vector<Int>(__ids.length * 2, 0);
		Vector.blit(__ids, 0, grown, 0, length);
		__ids = grown;
	}
}

/**
 * Walks an `IdList` in order. Made by `IdList.iterator()`; a `for` loop over
 * the list is the usual way to use one.
 */
@:access(crossbyte.ds.IdList)
class IdListIterator {
	private var __list:IdList;
	private var __next:Int = 0;

	public inline function new(list:IdList) {
		__list = list;
	}

	public inline function hasNext():Bool {
		return __next < __list.length;
	}

	public inline function next():Int {
		return __list.__ids[__next++];
	}
}
