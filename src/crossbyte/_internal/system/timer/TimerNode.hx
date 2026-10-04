package crossbyte._internal.system.timer;

// Declared in the order hxcpp lays the fields out: the first two Ints share a
// word, and the Bools sit beside `armPass`, so the node carries no padding.
@:structInit
class TimerNode {
	/**
	 * The handle of the timer it carries, and `TimerHandle.INVALID` once that
	 * timer is cleared or done: whether a node is still its timer's is read
	 * from here.
	 */
	public var handle:Int;

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
	 * callback does to it: clearing itself ends the timer, but the node waits
	 * for the callback to return before it can carry another timer. Kept on
	 * the node rather than in one field of the scheduler, so a callback that
	 * runs a pass of its own, a nested pump, does not lose track of the
	 * one that called it.
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

	/**
	 * The scheduler's time when the timer was paused, or NaN while it is not
	 * paused; see `isPaused`. It was a `Null<Float>`, which natively and on
	 * the jvm is a boxed number: every pause allocated one. No timer's time
	 * is NaN, since the schedulers refuse it.
	 */
	public var pausedAt:Float = Math.NaN;

	public var callback:TimerHandle->Void;

	/**
	 * A `Void->Void` callback, kept as it was given and called directly; null
	 * for one that takes its handle. It used to be wrapped in a closure that
	 * took the handle and dropped it: a closure made per timer armed, two
	 * dynamic calls per fire, and the handle boxed for each, an allocation
	 * once handles were past hxcpp's small-int cache.
	 */
	public var voidCallback:Void->Void;

	#if cpp
	/**
	 * The handle as hxcpp passes it to a callback that takes one, boxed once
	 * for the timer rather than once per fire: a closure is called with its
	 * arguments boxed, and a handle is past the small-int cache from the
	 * 256th timer on, so an interval taking its handle allocated every time
	 * it fired. Null until the first fire.
	 */
	public var handleBox:Dynamic = null;
	#end

	public inline function new(handle:Int, time:Float, interval:Float, callback:TimerHandle->Void, voidCallback:Void->Void) {
		this.handle = handle;
		this.time = time;
		this.interval = interval;
		this.callback = callback;
		this.voidCallback = voidCallback;
	}

	/** Whether the timer is paused: `pausedAt` holds a time, not NaN. **/
	public inline function isPaused():Bool {
		return pausedAt == pausedAt;
	}

	/**
	 * Makes a node that carried a timer before carry a new one: everything a
	 * new node starts with. Taken from a scheduler's spares only, which hold
	 * nodes no list, heap or pass refers to any more.
	 */
	public inline function rearm(handle:Int, time:Float, interval:Float, callback:TimerHandle->Void, voidCallback:Void->Void):Void {
		this.handle = handle;
		this.time = time;
		this.interval = interval;
		this.callback = callback;
		this.voidCallback = voidCallback;
		enabled = true;
		pausedAt = Math.NaN;
		heapIndex = -1;
		armPass = 0;
		firing = false;
		rearmed = false;
		held = false;
		#if cpp
		handleBox = null;
		#end
	}

	/**
	 * Lets go of what the timer it carried referred to, as it goes into a
	 * scheduler's spares: a spare node holding a cleared timer's callback
	 * would keep whatever that closure captured alive until it was reused.
	 */
	public inline function release():Void {
		callback = null;
		voidCallback = null;
		pausedAt = Math.NaN;
		#if cpp
		handleBox = null;
		#end
	}
}
