package crossbyte._internal.system.timer.heap;

import crossbyte._internal.system.timer.TimerNode;
import haxe.ds.Vector;

/**
 * Min-heap of timer nodes ordered by due time, and among those due at the
 * same time by when they were armed: first armed, first fired, as
 * JavaScript's and ActionScript's timers are. Ordered by time alone, the heap
 * fired a run of timers armed together the first and then the rest
 * backwards.
 *
 * This exists rather than reusing `crossbyte.ds.PriorityQueue` because of one
 * difference that turns out to dominate the cost. A generic queue cannot
 * require its elements to carry anything, so it tracks each element's position
 * in a side `ObjectMap`, and every swap while sifting is then two hash
 * writes. A timer node can carry its own index, so the same algorithm does two
 * field writes instead.
 *
 * At thirty thousand live timers, firing and re-arming, that is 372ms
 * through the mapped queue against 39ms through this one, for identical
 * ordering and identical complexity. For a runtime carrying a timer per
 * entity that is the difference between the scheduler taking half a frame
 * at sixty ticks a second and taking a rounding error.
 *
 * What sifting compares, each node's due time and the number it was armed
 * under, is kept in heap order beside the heap rather than read through the
 * nodes, which at that scale lie megabytes apart. Kept in `Vector`s, which
 * are primitive arrays on the jvm, where an `Array<Float>` boxes what it
 * holds.
 *
 * Natively, per timer fired and re-armed at thirty thousand recurring timers:
 * 189 ns where their times differ, where it took 222, and 208 ns where many
 * are due together, where it took 187. Ordered by time alone, a sift could
 * stop at the first time equal to its own; ordered by arming too, it cannot.
 *
 * `PriorityQueue` is still right for callers that cannot make this trade.
 */
class TimerQueue {
	@:noCompletion private var __heap:Array<TimerNode> = [];

	// In heap order, beside __heap, as long as it or longer: each node's due
	// time, and the number it was armed under.
	@:noCompletion private var __times:Vector<Float>;
	@:noCompletion private var __armings:Vector<Int>;

	// The number the next arming is given. It wraps, and two are compared by
	// their difference, as Seq32 compares, which orders any two armed within
	// 2^31 armings of each other.
	@:noCompletion private var __nextArming:Int = 0;

	public var size(get, never):Int;
	public var isEmpty(get, never):Bool;

	public inline function new() {
		__times = new Vector<Float>(16);
		__armings = new Vector<Int>(16);
	}

	private inline function get_size():Int {
		return __heap.length;
	}

	private inline function get_isEmpty():Bool {
		return __heap.length == 0;
	}

	/** The node due soonest, or null when nothing is scheduled. */
	public inline function peek():Null<TimerNode> {
		return __heap.length > 0 ? __heap[0] : null;
	}

	/**
	 * Adds a node, armed now: among those due at its time, it is the last.
	 * One already held is repositioned, as the generic queue does for an
	 * element enqueued twice.
	 */
	public function enqueue(node:TimerNode):Void {
		if (node.heapIndex >= 0) {
			update(node);
			return;
		}

		var i:Int = __heap.length;
		if (i == __times.length) {
			__grow();
		}
		__heap[i] = node;
		__times[i] = node.time;
		__armings[i] = __arm();
		node.heapIndex = i;
		__siftUp(i);
	}

	/**
	 * Removes and returns the soonest node, or null when empty.
	 *
	 * The hole it leaves goes down to the bottom by the sooner child, which
	 * moves up into it: one comparison a level, between the two children,
	 * where sifting the last node down from the top compares it as well. The
	 * last node then goes into the hole at the bottom, and up only as far as
	 * it belongs, which for the timer armed last is mostly nowhere.
	 */
	public function dequeue():Null<TimerNode> {
		var last:Int = __heap.length - 1;
		if (last < 0) {
			return null;
		}

		var root:TimerNode = __heap[0];
		root.heapIndex = -1;
		var moved:TimerNode = __heap.pop();
		if (last == 0) {
			return root;
		}
		var movedTime:Float = __times[last];
		var movedArming:Int = __armings[last];

		var i:Int = 0;
		while (true) {
			var child:Int = (i << 1) + 1;
			if (child >= last) {
				break;
			}
			var childTime:Float = __times[child];
			var childArming:Int = __armings[child];
			var right:Int = child + 1;
			if (right < last) {
				var rightTime:Float = __times[right];
				var rightArming:Int = __armings[right];
				if (__before(rightTime, rightArming, childTime, childArming)) {
					child = right;
					childTime = rightTime;
					childArming = rightArming;
				}
			}
			var up:TimerNode = __heap[child];
			__heap[i] = up;
			__times[i] = childTime;
			__armings[i] = childArming;
			up.heapIndex = i;
			i = child;
		}

		__heap[i] = moved;
		__times[i] = movedTime;
		__armings[i] = movedArming;
		moved.heapIndex = i;
		__siftUp(i);
		return root;
	}

	/** Removes `node` if it is held. */
	public function remove(node:TimerNode):Bool {
		var i:Int = node.heapIndex;
		if (i < 0) {
			return false;
		}

		var last:Int = __heap.length - 1;
		node.heapIndex = -1;
		var moved:TimerNode = __heap.pop();
		if (i == last) {
			return true;
		}

		// The last node into its place, and up or down from there: removed
		// from anywhere but the top, it mostly belongs near where it is put.
		__heap[i] = moved;
		__times[i] = __times[last];
		__armings[i] = __armings[last];
		moved.heapIndex = i;
		__siftUp(i);
		__siftDown(moved.heapIndex);
		return true;
	}

	/**
	 * Restores heap order after `node`'s time changed. It counts as armed
	 * now, after any other due at its new time.
	 */
	public function update(node:TimerNode):Void {
		var i:Int = node.heapIndex;
		if (i < 0) {
			return;
		}

		__times[i] = node.time;
		__armings[i] = __arm();
		__siftUp(i);
		// Read again rather than reusing the index from before: sifting up
		// moves the node, and sifting a stale position would order a
		// different node than the one whose time changed.
		__siftDown(node.heapIndex);
	}

	/**
	 * Counts the enabled nodes due at or before `time` that were not armed
	 * during pass `pass`. A heap orders parents before children, so a node
	 * not yet due has no due descendants: the walk visits only the due part
	 * of the heap and the boundary around it.
	 */
	public function countDue(time:Float, pass:Int):Int {
		var count:Int = 0;
		var length:Int = __heap.length;
		if (length == 0 || __times[0] > time) {
			return 0;
		}

		var pending:Array<Int> = [0];
		while (pending.length > 0) {
			var i:Int = pending.pop();
			if (__times[i] > time) {
				continue;
			}
			var node:TimerNode = __heap[i];
			if (node.enabled && node.armPass != pass) {
				count++;
			}
			var left:Int = (i << 1) + 1;
			if (left < length) {
				pending.push(left);
				if (left + 1 < length) {
					pending.push(left + 1);
				}
			}
		}
		return count;
	}

	public inline function clear():Void {
		for (i in 0...__heap.length) {
			__heap[i].heapIndex = -1;
		}
		__heap.resize(0);
	}

	// The next arming's number.
	@:noCompletion private inline function __arm():Int {
		var arming:Int = __nextArming;
		__nextArming = (arming + 1) | 0;
		return arming;
	}

	// Whether what is due at `time`, armed as `arming`, fires before what is
	// due at `otherTime`, armed as `otherArming`.
	@:noCompletion private static inline function __before(time:Float, arming:Int, otherTime:Float, otherArming:Int):Bool {
		return time < otherTime || (time == otherTime && ((arming - otherArming) | 0) < 0);
	}

	@:noCompletion private function __grow():Void {
		var capacity:Int = __times.length << 1;
		var times:Vector<Float> = new Vector<Float>(capacity);
		var armings:Vector<Int> = new Vector<Int>(capacity);
		Vector.blit(__times, 0, times, 0, __times.length);
		Vector.blit(__armings, 0, armings, 0, __armings.length);
		__times = times;
		__armings = armings;
	}

	@:noCompletion private function __siftUp(i:Int):Void {
		var node:TimerNode = __heap[i];
		var time:Float = __times[i];
		var arming:Int = __armings[i];

		while (i > 0) {
			var parent:Int = (i - 1) >> 1;
			var parentTime:Float = __times[parent];
			var parentArming:Int = __armings[parent];

			if (!__before(time, arming, parentTime, parentArming)) {
				break;
			}

			var moved:TimerNode = __heap[parent];
			__heap[i] = moved;
			__times[i] = parentTime;
			__armings[i] = parentArming;
			moved.heapIndex = i;
			i = parent;
		}

		__heap[i] = node;
		__times[i] = time;
		__armings[i] = arming;
		node.heapIndex = i;
	}

	@:noCompletion private function __siftDown(i:Int):Void {
		var length:Int = __heap.length;
		var node:TimerNode = __heap[i];
		var time:Float = __times[i];
		var arming:Int = __armings[i];

		while (true) {
			var child:Int = (i << 1) + 1;
			if (child >= length) {
				break;
			}

			var childTime:Float = __times[child];
			var childArming:Int = __armings[child];
			var right:Int = child + 1;
			if (right < length) {
				var rightTime:Float = __times[right];
				var rightArming:Int = __armings[right];
				if (__before(rightTime, rightArming, childTime, childArming)) {
					child = right;
					childTime = rightTime;
					childArming = rightArming;
				}
			}

			if (!__before(childTime, childArming, time, arming)) {
				break;
			}

			var moved:TimerNode = __heap[child];
			__heap[i] = moved;
			__times[i] = childTime;
			__armings[i] = childArming;
			moved.heapIndex = i;
			i = child;
		}

		__heap[i] = node;
		__times[i] = time;
		__armings[i] = arming;
		node.heapIndex = i;
	}
}
