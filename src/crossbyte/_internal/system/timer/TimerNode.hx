package crossbyte._internal.system.timer;

// Declared in the order hxcpp lays the fields out: the first two Ints share a
// word, and the Bools sit beside `armPass`, so the node carries no padding.
@:structInit
class TimerNode {
	public var id:Int;

	/**
	 * Where this node sits in the scheduler's heap, or -1 when it is not in
	 * one. Carried here so sifting writes a field instead of a hash entry:
	 * a generic queue has to keep positions in a side map, and at scale that
	 * map is almost the entire cost of scheduling.
	 */
	public var heapIndex:Int = -1;

	public var time:Float;
	public var interval:Float;
	public var enabled:Bool = true;

	/**
	 * Whether its callback is running. A node is reused once its timer is
	 * done, and one whose callback is still running is not done whatever the
	 * callback does to it: clearing itself frees the timer's slot, but the
	 * node waits for the callback to return before it can carry another
	 * timer. Kept on the node rather than in one field of the scheduler, so a
	 * callback that runs a pass of its own, a nested pump, does not lose
	 * track of the one that called it.
	 */
	public var firing:Bool = false;

	/**
	 * Whether the callback running gave its own timer a new time, a
	 * reschedule, a delay or a resume through its handle, which settling it
	 * afterwards has to respect.
	 */
	public var rearmed:Bool = false;

	/** Whether the scheduler holds it back for its next pass. **/
	public var held:Bool = false;

	/**
	 * The scheduler's pass number when this node was last armed. A node armed
	 * during a pass is never fired by that pass, however soon it is due: a
	 * callback that re-arms itself for "now" would otherwise run again and
	 * again inside one pass, with nothing to stop it but a time budget.
	 */
	public var armPass:Int = 0;

	public var pausedAt:Null<Float> = null;
	public var callback:TimerHandle->Void;

	/**
	 * A `Void->Void` callback, kept as it was given and called directly; null
	 * for one that takes its handle. It used to be wrapped in a closure that
	 * took the handle and dropped it: a closure made per timer armed, two
	 * dynamic calls per fire, and the handle boxed for each, an allocation
	 * once a reused slot's generation put it past hxcpp's small-int cache.
	 */
	public var voidCallback:Void->Void;

	public inline function new(id:Int, time:Float, interval:Float, callback:TimerHandle->Void, voidCallback:Void->Void) {
		this.id = id;
		this.time = time;
		this.interval = interval;
		this.callback = callback;
		this.voidCallback = voidCallback;
	}

	/**
	 * Makes a node that carried a timer before carry a new one: everything a
	 * new node starts with. Taken from a scheduler's spares only, which hold
	 * nodes no list, heap or pass refers to any more.
	 */
	public inline function rearm(id:Int, time:Float, interval:Float, callback:TimerHandle->Void, voidCallback:Void->Void):Void {
		this.id = id;
		this.time = time;
		this.interval = interval;
		this.callback = callback;
		this.voidCallback = voidCallback;
		enabled = true;
		pausedAt = null;
		heapIndex = -1;
		armPass = 0;
		firing = false;
		rearmed = false;
		held = false;
	}

	/**
	 * Lets go of what the timer it carried referred to, as it goes into a
	 * scheduler's spares: a spare node holding a cleared timer's callback
	 * would keep whatever that closure captured alive until it was reused.
	 */
	public inline function release():Void {
		callback = null;
		voidCallback = null;
		pausedAt = null;
	}
}
