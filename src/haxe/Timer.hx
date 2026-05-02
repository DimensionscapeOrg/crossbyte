package haxe;

#if lime_cffi
import lime.system.System;
import haxe.Log;
import haxe.PosInfos;

/**
	A Lime-compatible `haxe.Timer` shape for projects where CrossByte shares a
	classpath with Lime's native backend.

	Lime's native application loop reaches into these private fields through
	`@:access(haxe.Timer)`, so CrossByte's global timer shadow needs to expose
	the same storage contract when `lime_cffi` is active.
**/
class Timer {
	private static var sRunningTimers:Array<Timer> = [];

	private var mTime:Float;
	private var mFireAt:Float;
	private var mRunning:Bool;

	public function new(time_ms:Int) {
		mTime = time_ms;
		mFireAt = System.getTimer() + mTime;
		mRunning = true;
		sRunningTimers.push(this);
	}

	public function stop():Void {
		mRunning = false;
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
		var timer = System.getTimer();
		return timer > 0 ? timer / 1000 : 0;
	}
}
#else
import crossbyte.core.CrossByte;
import crossbyte.errors.IllegalOperationError;
import crossbyte.events.TickEvent;
import haxe.ds.IntMap;
import haxe.Log;
import haxe.PosInfos;
#if cpp
import sys.thread.Mutex;
#end

/**
	A `haxe.Timer` implementation backed by CrossByte's tick-driven runtime.
**/
class Timer {
	private static var timerCount:Int = 0;
	private static var timers:IntMap<Timer> = new IntMap<Timer>();
	private static var __currentId:Int = 0;
	#if cpp
	private static final __mutex:Mutex = new Mutex();
	#end

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
		__withLock(() -> {
			timerCount++;
			timers.set(id, this);
			if (timerCount == 1) {
				__getGlobalRuntime().addEventListener(TickEvent.TICK, onTick);
			}
		});
	}

	private static inline function __getGlobalRuntime():CrossByte {
		@:privateAccess var runtime:CrossByte = CrossByte.__primordial;
		if (runtime == null) {
			throw new IllegalOperationError("haxe.Timer requires a primordial CrossByte runtime. Create an Application, HostApplication, ServerApplication, or primordial CrossByte before using global timers.");
		}
		return runtime;
	}

	private static function onTick(event:TickEvent):Void {
		var snapshot = new Array<Timer>();
		__withLock(() -> {
			for (timer in timers) {
				snapshot.push(timer);
			}
		});

		for (timer in snapshot) {
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
		__withLock(() -> {
			timers.remove(id);
			if (--timerCount == 0) {
				__getGlobalRuntime().removeEventListener(TickEvent.TICK, onTick);
			}
		});
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

	private static inline function __withLock(fn:Void->Void):Void {
		#if cpp
		__mutex.acquire();
		try {
			fn();
		} catch (e:Dynamic) {
			__mutex.release();
			throw e;
		}
		__mutex.release();
		#else
		fn();
		#end
	}
}
#end
