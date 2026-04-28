package crossbyte._internal.system.timer;

@:structInit
class TimerNode {
	public var id:Int;
	public var time:Float;
	public var interval:Float;
	public var enabled:Bool = true; 
	public var pausedAt:Null<Float> = null;
	public var callback:TimerHandle->Void;

	public inline function new(id:Int, time:Float, interval:Float, callback:TimerHandle->Void) {
		this.id = id;
		this.time = time;
		this.interval = interval;
		this.callback = callback;
	}
}
