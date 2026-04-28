package haxe;

import crossbyte.core.CrossByte;
import crossbyte.events.TickEvent;
import haxe.ds.IntMap;
import haxe.Log;
import haxe.PosInfos;

/**
	A `haxe.Timer` implementation backed by CrossByte's tick-driven runtime.
**/
class Timer {
	private static var timerCount:Int = 0;
	private static var timers:IntMap<Timer> = new IntMap<Timer>();
	private static var __currentId:Int = 0;

	private var delayCount:Float;
	private var timeRemaining:Float;
	private var running:Bool;
	private var stopped:Bool;
	private var id:Int;

	public function new(time_ms:Int) {
		delayCount = time_ms / 1000;
		timeRemaining = delayCount;
		running = true;
		stopped = false;
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
		if (stopped) {
			return;
		}

		stopped = true;
		timers.remove(id);
		if (--timerCount == 0) {
			CrossByte.current().removeEventListener(TickEvent.TICK, onTick);
		}
	}

	public function stop():Void {
		if (stopped) {
			return;
		}

		running = false;
		cleanup();
	}

	public function start():Void {
		if (stopped) {
			return;
		}

		running = true;
	}

	public dynamic function run():Void {}

	public static function delay(f:Void->Void, time_ms:Int):Timer {
		var timer = new Timer(time_ms);
		timer.run = function() {
			timer.stop();
			f();
		};
		return timer;
	}

	public static function measure<T>(f:Void->T, ?pos:PosInfos):T {
		var t0 = stamp();
		var result = f();
		Log.trace((stamp() - t0) + "s", pos);
		return result;
	}

	public static inline function stamp():Float {
		#if js
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
