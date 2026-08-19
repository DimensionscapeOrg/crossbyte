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
	 * Where this node sits in the scheduler's heap, or -1 when it is not in
	 * one. Carried here so sifting writes a field instead of a hash entry:
	 * a generic queue has to keep positions in a side map, and at scale that
	 * map is almost the entire cost of scheduling.
	 */
	public var heapIndex:Int = -1;

	public inline function new(id:Int, time:Float, interval:Float, callback:TimerHandle->Void) {
		this.id = id;
		this.time = time;
		this.interval = interval;
		this.callback = callback;
	}
}
