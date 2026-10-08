package crossbyte._internal.system.timer;
interface ITimerScheduler {
	public var size(get, never):Int;
	public var isEmpty(get, never):Bool;	
	public var time(get, never):Float;
	public final startTime:Float;

	/**
		Given what a timer's callback threw, once the scheduler has settled
		that timer as if the callback had returned: a recurring one re-armed,
		a one-shot freed. Null rethrows it out of `advanceTime` instead, which
		is what a scheduler driven by hand wants; a runtime sets this, so a
		timer's failure costs that timer and not the loop.
	**/
	public var onError:Dynamic->Void;

	public function setTimeout(delay:Float, callback:TimerHandle->Void):TimerHandle;
	public function setTimeoutVoid(delay:Float, callback:Void->Void):TimerHandle;
	public function setInterval(delay:Float, interval:Float, callback:TimerHandle->Void):TimerHandle;
	public function setIntervalVoid(delay:Float, interval:Float, callback:Void->Void):TimerHandle;
	public function clear(handle:TimerHandle, immediate:Bool = true):Bool;
	public function isActive(handle:TimerHandle):Bool;
	public function schedule(time:Float, callback:TimerHandle->Void):TimerHandle;
	public function scheduleVoid(time:Float, callback:Void->Void):TimerHandle;
	public function reschedule(handle:TimerHandle, time:Float):Bool;
	public function delay(handle:TimerHandle, dt:Float):Bool;
	public function setEnabled(handle:TimerHandle, enabled:Bool, policy:ResumePolicy = ResumePolicy.KeepPhase, time:Float = 0.0):Bool;

	/**
		`setEnabled` with every argument given: what `crossbyte.Timer`'s
		`pause` and `resume` call. On the jvm an argument with a default is an
		object, so the forms with defaults would box the time a pause passes
		on, and the time and the policy of a resume.
	**/
	public function setEnabledBy(handle:TimerHandle, enabled:Bool, policy:ResumePolicy, time:Float):Bool;

	public function nextDue():Null<Float>;

	/**
		Fires what is due by `time + dt`. Nothing is capped by count unless
		`maxFires` says so; `budget`, when above zero, is the wall-clock
		seconds the call may spend before leaving the rest for the next one.
		A timer armed during the call waits for the next one.
	**/
	public function advanceTime(dt:Float, maxFires:Int = 0x7FFFFFFF, budget:Float = 0.0):Int;

	/**
		`advanceTime` with every argument given: what the runtime calls each
		frame. On the jvm an argument with a default is an object, so the
		form with defaults would box `maxFires` and `budget` every frame.
	**/
	public function advanceBy(dt:Float, maxFires:Int, budget:Float):Int;

	/** Whether the last `advanceTime` stopped with timers still due. **/
	public var cutShort(get, never):Bool;

	/**
		How many timers are due and still waiting because the last pass was
		cut short. Costs what it counts; for a metric, not for every frame.
	**/
	public function overdue():Int;
}
