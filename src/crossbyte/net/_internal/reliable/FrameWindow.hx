package crossbyte.net._internal.reliable;

import haxe.ds.Vector;

/**
	A session's frames in flight, sent, and not yet acknowledged, found
	by sequence: a ring, each frame in the slot its sequence's low bits name.

	They were in an `IntMap`, which hashed every sequence, allocated an
	entry natively for every frame sent, and on the jvm grew its table with
	the window. What is in flight is one run of sequences, from the first
	not acknowledged to the next to send, never more than a session's window
	of 500 long, so a ring longer than the run holds each in a slot of its
	own. One whose slot holds another frame is a run that has outgrown the
	ring, which then doubles.

	It starts at `INITIAL_CAPACITY` slots: a session that never has more
	than a few frames in flight, as a game's does not, holds a ring of 16,
	and one sending in bulk grows to the 512 its window needs. `shrink`
	lets a grown one go once it is empty.

	**Threading.** None.
**/
final class FrameWindow {
	/** The slots a window starts with, and goes back to when it shrinks. **/
	public static inline var INITIAL_CAPACITY:Int = 16;

	@:noCompletion private var __slots:Vector<OutstandingFrame>;
	@:noCompletion private var __mask:Int;

	/** How many frames it holds. **/
	public var count(default, null):Int = 0;

	public function new() {
		__slots = __empty(INITIAL_CAPACITY);
		__mask = INITIAL_CAPACITY - 1;
	}

	/** How many slots the ring has. **/
	public var capacity(get, never):Int;

	@:noCompletion private inline function get_capacity():Int {
		return __mask + 1;
	}

	/** The frame in flight under `sequence`, or null. **/
	public inline function get(sequence:Int):Null<OutstandingFrame> {
		var frame:Null<OutstandingFrame> = __slots[sequence & __mask];
		return frame != null && frame.sequence == sequence ? frame : null;
	}

	/** Files `frame` under `sequence`, which it takes as its own. **/
	public function set(sequence:Int, frame:OutstandingFrame):Void {
		frame.sequence = sequence;
		var held:Null<OutstandingFrame> = __slots[sequence & __mask];
		while (held != null && held.sequence != sequence) {
			__grow();
			held = __slots[sequence & __mask];
		}
		if (held == null) {
			count++;
		}
		__slots[sequence & __mask] = frame;
	}

	/** Takes out the frame under `sequence`, and says what it was, or null. **/
	public function remove(sequence:Int):Null<OutstandingFrame> {
		var slot:Int = sequence & __mask;
		var frame:Null<OutstandingFrame> = __slots[slot];
		if (frame == null || frame.sequence != sequence) {
			return null;
		}
		__slots[slot] = null;
		count--;
		return frame;
	}

	/** Lets every frame go. **/
	public function clear():Void {
		if (count == 0) {
			return;
		}
		for (i in 0...__slots.length) {
			__slots[i] = null;
		}
		count = 0;
	}

	/** Back to `INITIAL_CAPACITY` slots, if it is empty and has grown. **/
	public function shrink():Void {
		if (count == 0 && __mask + 1 > INITIAL_CAPACITY) {
			__slots = __empty(INITIAL_CAPACITY);
			__mask = INITIAL_CAPACITY - 1;
		}
	}

	@:noCompletion private function __grow():Void {
		var old:Vector<OutstandingFrame> = __slots;
		var size:Int = old.length << 1;
		__slots = __empty(size);
		__mask = size - 1;
		for (i in 0...old.length) {
			var frame:Null<OutstandingFrame> = old[i];
			if (frame != null) {
				__slots[frame.sequence & __mask] = frame;
			}
		}
	}

	@:noCompletion private static function __empty(size:Int):Vector<OutstandingFrame> {
		var slots = new Vector<OutstandingFrame>(size);
		for (i in 0...size) {
			slots[i] = null;
		}
		return slots;
	}
}
