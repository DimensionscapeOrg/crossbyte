package crossbyte._internal.system.timer;

import haxe.ds.Vector;

/**
	A scheduler's live timers by handle: open addressing over a power-of-two
	table kept no more than half full, a collision taking the next free place.

	A handle's home is its Fibonacci hash, the top bits of it times 2^32 over
	the golden ratio, so consecutive handles land spread across the table.
	Handles are counted, so with the low bits as the home, long-lived timers
	armed together would sit in one solid run of places, and every handle the
	count later brought home inside the run would be placed, found and
	removed by walking it.

	Nothing here allocates but growth, which doubles the table: a lookup is
	a read or two, and a removal pulls the
	entries after it back over the hole rather than leaving a marker, so a
	table that churns does not fill up with them.
**/
@:generic
class TimerTable<T> {
	// An empty place holds TimerHandle.INVALID, which no timer is given. (A
	// generic class can have no static fields to name it with.)

	/** Timers held. **/
	public var size(default, null):Int = 0;

	@:noCompletion private var __keys:Vector<Int>;
	@:noCompletion private var __values:Vector<T>;
	@:noCompletion private var __mask:Int;

	// 32 less the table's bits: a hash shifted right by this is a place.
	@:noCompletion private var __shift:Int;

	public function new() {
		__allocate(4);
	}

	/** The timer `handle` names, or null for one not held. **/
	public function get(handle:Int):Null<T> {
		if (handle < 0) {
			return null;
		}
		var mask:Int = __mask;
		var at:Int = __home(handle);
		while (true) {
			var key:Int = __keys[at];
			if (key == handle) {
				return __values[at];
			}
			if (key == TimerHandle.INVALID) {
				return null;
			}
			at = (at + 1) & mask;
		}
		return null;
	}

	/** Holds `value` under `handle`, which is not held already. **/
	public function add(handle:Int, value:T):Void {
		if ((size + 1) << 1 > __keys.length) {
			__grow();
		}
		__place(handle, value);
		size++;
	}

	/** Lets go of the timer `handle` names; false for one not held. **/
	public function remove(handle:Int):Bool {
		if (handle < 0) {
			return false;
		}
		var mask:Int = __mask;
		var hole:Int = __home(handle);
		while (true) {
			var key:Int = __keys[hole];
			if (key == handle) {
				break;
			}
			if (key == TimerHandle.INVALID) {
				return false;
			}
			hole = (hole + 1) & mask;
		}

		// Each entry after the hole, up to the next empty place, moves back
		// into it unless its home lies between the hole and where it is.
		var at:Int = hole;
		while (true) {
			at = (at + 1) & mask;
			var key:Int = __keys[at];
			if (key == TimerHandle.INVALID) {
				break;
			}
			var home:Int = __home(key);
			var stays:Bool = hole <= at ? (home > hole && home <= at) : (home > hole || home <= at);
			if (!stays) {
				__keys[hole] = key;
				__values[hole] = __values[at];
				hole = at;
			}
		}
		__keys[hole] = TimerHandle.INVALID;
		__values[hole] = null;
		size--;
		return true;
	}

	// The place a handle is looked for first. haxe.Int32 so the multiply
	// wraps at 32 bits on js too, where it is Math.imul.
	@:noCompletion private inline function __home(handle:Int):Int {
		var hash:haxe.Int32 = (handle : haxe.Int32) * (0x9E3779B1 : haxe.Int32);
		return (hash : Int) >>> __shift;
	}

	@:noCompletion private function __place(handle:Int, value:T):Void {
		var mask:Int = __mask;
		var at:Int = __home(handle);
		while (__keys[at] != TimerHandle.INVALID) {
			at = (at + 1) & mask;
		}
		__keys[at] = handle;
		__values[at] = value;
	}

	@:noCompletion private function __allocate(bits:Int):Void {
		var capacity:Int = 1 << bits;
		__keys = new Vector<Int>(capacity);
		__values = new Vector<T>(capacity);
		for (i in 0...capacity) {
			__keys[i] = TimerHandle.INVALID;
			__values[i] = null;
		}
		__mask = capacity - 1;
		__shift = 32 - bits;
	}

	@:noCompletion private function __grow():Void {
		var keys:Vector<Int> = __keys;
		var values:Vector<T> = __values;
		__allocate(33 - __shift);
		for (i in 0...keys.length) {
			if (keys[i] != TimerHandle.INVALID) {
				__place(keys[i], values[i]);
			}
		}
	}
}
