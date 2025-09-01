package crossbyte._internal.system.timer;
interface ITimerScheduler {
	public var size(get, never):Int;
	public var isEmpty(get, never):Bool;	
	public var time(get, never):Float;
	public final startTime:Float;
	overload extern public function setTimeout(delay:Float, callback:TimerHandle->Void):TimerHandle;
	overload extern public function setTimeout(delay:Float, callback:Void->Void):TimerHandle;
	overload extern public function setInterval(delay:Float, interval:Float, callback:TimerHandle->Void):TimerHandle;
	overload extern public function setInterval(delay:Float, interval:Float, callback:Void->Void):TimerHandle;
	public function clear(handle:TimerHandle, immediate:Bool = false):Bool;
	public function isActive(handle:TimerHandle):Bool;
	public function reschedule(handle:TimerHandle, time:Float):Bool;
	public function delay(handle:TimerHandle, dt:Float):Bool;
	public function setEnabled(handle:TimerHandle, enabled:Bool, policy:ResumePolicy = ResumePolicy.KeepPhase, time:Float = 0.0):Bool;
	public function nextDue():Null<Float>;
	public function advanceTime(time:Float, maxFires:Int = 256):Int;
}
