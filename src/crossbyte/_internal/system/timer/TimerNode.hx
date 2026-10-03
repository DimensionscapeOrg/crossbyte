package crossbyte._internal.system.timer;

@:structInit
class TimerNode {
	public var id:Int;
	public var time:Float;
	public var interval:Float;
	public var enabled:Bool = true; 
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

	/**
	 * Where this node sits in the scheduler's heap, or -1 when it is not in
	 * one. Carried here so sifting writes a field instead of a hash entry:
	 * a generic queue has to keep positions in a side map, and at scale that
	 * map is almost the entire cost of scheduling.
	 */
	public var heapIndex:Int = -1;

	/**
	 * The scheduler's pass number when this node was last armed. A node armed
	 * during a pass is never fired by that pass, however soon it is due: a
	 * callback that re-arms itself for "now" would otherwise run again and
	 * again inside one pass, with nothing to stop it but a time budget.
	 */
	public var armPass:Int = 0;

	public inline function new(id:Int, time:Float, interval:Float, callback:TimerHandle->Void, voidCallback:Void->Void) {
		this.id = id;
		this.time = time;
		this.interval = interval;
		this.callback = callback;
		this.voidCallback = voidCallback;
	}
}
