package haxe;

#if lime_cffi
import lime.system.System;
#else
import crossbyte.core.CrossByte;
import crossbyte.events.TickEvent;
import haxe.ds.IntMap;
#end
import haxe.Log;
import haxe.PosInfos;

/**
	A hybrid `haxe.Timer` implementation that preserves CrossByte's tick-driven
	behavior in standalone CrossByte runtimes while remaining compatible with
	Lime-based hosts that expect the legacy `lime_cffi` timer surface.
**/
class Timer {
	#if lime_cffi
	private static var sRunningTimers:Array<Timer> = [];

	private var mTime:Float;
	private var mFireAt:Float;
	private var mRunning:Bool;

	public function new(time:Float) {
		mTime = time;
		sRunningTimers.push(this);
		mFireAt = getMS() + mTime;
		mRunning = true;
	}

	private static inline function getMS():Float {
		return System.getTimer();
	}

	public function stop():Void {
		mRunning = false;
	}

	@:noCompletion private function __check(inTime:Float):Void {
		if (inTime >= mFireAt) {
			mFireAt += mTime;
			run();
		}
	}
	#else
	private static var timerCount:Int = 0;
	private static var timers:IntMap<Timer> = new IntMap<Timer>();
	private static var __currentId:Int = 0;

	private var delayCount:Float;
	private var timeRemaining:Float;
	private var running:Bool;
	private var id:Int;

	public function new(time_ms:Int) {
		delayCount = time_ms / 1000;
		timeRemaining = delayCount;
		running = false;
		id = ++__currentId;
		timerCount++;

		timers.set(id, this);
		if (timerCount == 1) {
			CrossByte.current().addEventListener(TickEvent.TICK, onTick);
		}
	}

	private static function onTick(event:TickEvent):Void {
		for (timer in timers) {
			timer.__update(event.delta);
		}
	}

	private function __update(dt:Float):Void {
		if (running) {
			timeRemaining -= dt;
			if (timeRemaining <= 0) {
				run();
				if (!running) {
					return;
				}
				timeRemaining = delayCount;
			}
		}
	}

	private function cleanup():Void {
		timers.remove(id);
		if (--timerCount == 0) {
			CrossByte.current().removeEventListener(TickEvent.TICK, onTick);
		}
	}

	public function stop():Void {
		running = false;
		cleanup();
	}

	public function start():Void {
		running = true;
	}
	#end

	public dynamic function run():Void {}

	public static function delay(f:Void->Void, time_ms:Int):Timer {
		var timer = new Timer(time_ms);
		timer.run = function() {
			timer.stop();
			f();
		};
		#if !lime_cffi
		timer.start();
		#end
		return timer;
	}

	public static function measure<T>(f:Void->T, ?pos:PosInfos):T {
		var t0 = stamp();
		var result = f();
		Log.trace((stamp() - t0) + "s", pos);
		return result;
	}

	public static inline function stamp():Float {
		#if lime_cffi
		var timer = System.getTimer();
		return (timer > 0 ? timer / 1000 : 0);
		#elseif js
		return Date.now().getTime() / 1000;
		#elseif cpp
		return untyped __global__.__time_stamp();
		#elseif python
		return Sys.cpuTime();
		#elseif sys
		return Sys.time();
		#else
		return 0;
		#end
	}
}
