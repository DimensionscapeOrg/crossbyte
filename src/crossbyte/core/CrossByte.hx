package crossbyte.core;

import cpp.Pointer;
import cpp.net.Poll;
import sys.net.Socket as SysSocket;
import crossbyte.net.Socket as CBSocket;
import crossbyte.events.Event;
import crossbyte.events.EventDispatcher;
import crossbyte.events.TickEvent;
import haxe.EntryPoint;
import haxe.Timer;
import haxe.ds.Map;
import sys.thread.Thread;
import haxe.ds.ObjectMap;
import crossbyte.utils.ThreadPriority;

/**
 * ...
 * @author Christopher Speciale
 */
#if (cpp && windows)
@:cppInclude("Windows.h")
@:cppNamespaceCode('#pragma comment(lib, "winmm.lib")')
#end
final class CrossByte extends EventDispatcher {
	// ==== Public Static Variables ====
	// ==== Private Static Variables ====
	@:noCompletion private static inline var DEFAULT_TICKS_PER_SECOND:UInt = 12;
	@:noCompletion private static var __instances:Map<Thread, CrossByte> = new ObjectMap();
	@:noCompletion private static var __primordial:CrossByte;
	@:noCompletion private static var __init:Bool = __onCrossByteInit();

	// ==== Public Static Methods ====
	public static inline function make():CrossByte {
		var instance:CrossByte = new CrossByte(false);
		return instance;
	}

	public static inline function current():CrossByte {
		var currentThread:Thread = Thread.current();
		var instance:CrossByte = __instances.get(currentThread);
		return instance;
	}

	// ==== Private Static Methods ====
	@:noCompletion private static function __onCrossByteInit():Bool {
		#if (cpp && windows)
		untyped __cpp__("timeBeginPeriod(1);");
		untyped __cpp__("HANDLE hProcess = GetCurrentProcess();");
		untyped __cpp__("SetPriorityClass(hProcess, HIGH_PRIORITY_CLASS)");

		__setAtSystemExit(__atExit);
		#end

		return true;
	}

	#if (cpp && windows)
	@:noCompletion private static function __atExit():Void {
		untyped __cpp__("timeEndPeriod(1);");
	}

	@:noCompletion
	private static function __setAtSystemExit(callback:Void->Void):Void {
		untyped __cpp__("static cpp::Function<void()> exitCallback = {0};", callback);
		untyped __cpp__("std::atexit([](){ exitCallback(); });");
	}
	#end

	// ==== Public Variables ====
	public var tps(get, set):UInt;
	public var cpuLoad(get, null):Float;

	// ==== Private Variables ====
	@:noCompletion private var __tickInterval:Float;
	@:noCompletion private var __isRunning:Bool = true;
	@:noCompletion private var __tps:UInt;
	@:noCompletion private var __time:Float;
	@:noCompletion private var __dt:Float = 0.0;
	@:noCompletion private var __cpuTime:Float = 0.0;
	@:noCompletion private var __sleepAccuracy:Float = 0.0;
	@:noCompletion private var __socketRegistry:Array<SysSocket> = [];
	@:noCompletion private var __socketPoll:Poll;
	@:noCompletion private var __isPrimordial:Bool;
	@:noCompletion private var __threadPriority:ThreadPriority = NORMAL;

	#if cpp
	@:noCompletion private var __threadHandle:Pointer<cpp.Void>;
	#end

	// ==== Getters/Setters ====
	@:noCompletion private function get_tps():UInt {
		return __tps;
	}

	@:noCompletion private function set_tps(value:UInt):UInt {
		__tickInterval = 1 / (__tps = value);

		return value;
	}

	// ==== Constructor ====
	private function new(isPrimordial:Bool) {
		super(this);
		__isPrimordial = isPrimordial;
		__setup();
	}

	/* ==== Public Methods ==== */
	public inline function getThreadPriority():ThreadPriority {
		return __threadPriority;
	}

	public function setThreadPriority(priority:ThreadPriority):Void {
		__threadPriority = priority;

		if (__threadHandle == null) {
			return;
		}

		switch (priority) {
			case IDLE:
				untyped __cpp__("SetThreadPriority(reinterpret_cast<HANDLE>({0}), THREAD_PRIORITY_IDLE);", __threadHandle.raw);
			case LOWEST:
				untyped __cpp__("SetThreadPriority(reinterpret_cast<HANDLE>({0}), THREAD_PRIORITY_LOWEST);", __threadHandle.raw);
			case LOW:
				untyped __cpp__("SetThreadPriority(reinterpret_cast<HANDLE>({0}), THREAD_PRIORITY_BELOW_NORMAL);", __threadHandle.raw);
			case NORMAL:
				untyped __cpp__("SetThreadPriority(reinterpret_cast<HANDLE>({0}), THREAD_PRIORITY_NORMAL);", __threadHandle.raw);
			case HIGH:
				untyped __cpp__("SetThreadPriority(reinterpret_cast<HANDLE>({0}), THREAD_PRIORITY_ABOVE_NORMAL);", __threadHandle.raw);
			case HIGHEST:
				untyped __cpp__("SetThreadPriority(reinterpret_cast<HANDLE>({0}), THREAD_PRIORITY_HIGHEST);", __threadHandle.raw);
			case CRITICAL:
				untyped __cpp__("SetThreadPriority(reinterpret_cast<HANDLE>({0}), THREAD_PRIORITY_TIME_CRITICAL);", __threadHandle.raw);
		}
	}

	// TODO

	/* public function runInThread(job:Function):Void{

	}*/
	public function exit():Void {
		__isRunning = false;
		__instances.remove(Thread.current());
		// should we clean things up after the exit event?
		__socketRegistry = null;
		// should we iterate the socket registery and close them all?
		__socketPoll = null;
	}

	// ==== Private Methods ====
	#if cpp
	@:noCompletion private inline function beginSocketPolling():Void {
		if (__socketPoll == null) {
			__socketPoll = new Poll(4096);
			this.addEventListener(TickEvent.TICK, __onPollSocket);
		}
	}

	@:noCompletion private function registerSocket(socket:SysSocket):Void {
		__socketRegistry.push(socket);
		__socketPoll.prepare(__socketRegistry, null);
	}

	@:noCompletion private function deregisterSocket(socket:SysSocket):Void {
		__socketRegistry.remove(socket);
		__socketPoll.prepare(__socketRegistry, null);
		// TODO: Conditional check here? maybe we dont care so much and only care about server performance
		if (__socketRegistry.length == 0) {
			this.removeEventListener(TickEvent.TICK, __onPollSocket);
			__socketPoll = null;
		}
	}

	@:noCompletion private function __onPollSocket(e:TickEvent):Void {
		var sockets:Array<SysSocket> = __socketPoll.poll(__socketRegistry, 0);
		for (i in 0...sockets.length) {
			var cur:SysSocket = sockets[i];
			var cbSocket:CBSocket = cur.custom;
			@:privateAccess
			if (!cbSocket.__closed) {
				cbSocket.this_onTick();
			}
		}
	}
	#end

	@:noCompletion private inline function __setup():Void {
		Sys.println("Initializing CrossByte Instance");

		tps = DEFAULT_TICKS_PER_SECOND;

		#if precisionTick
		__getSleepAccuracy();
		#end

		if (__isPrimordial) {
			EntryPoint.runInMainThread(__runEventLoop);
			__primordial = this;

			var t:Thread = Thread.current();
			__instances.set(t, this);
		} else {
			EntryPoint.addThread(__runEventLoop);
		}
	}

	@:noCompletion private function get_cpuLoad():Float {
		var free:Float = ((__tickInterval - __cpuTime) / __tickInterval) * 100;

		return Math.min(Math.floor((100 - free) * 100) / 100, 100);
	}

	#if precisionTick
	@:noCompletion private function __getSleepAccuracy():Void {
		var time:Float = Timer.stamp();
		var dtTotal:Float = 0.0;

		for (i in 0...100) {
			Sys.sleep(0.001);
			dtTotal += (Timer.stamp() - time);

			time = Timer.stamp();
		}

		__sleepAccuracy = dtTotal / 100;
	}
	#end

	@:noCompletion private function __runEventLoop():Void {
		#if (cpp && windows)
		untyped __cpp__("HANDLE hThread = GetCurrentThread();");
		__threadHandle = untyped __cpp__("hThread");
		setThreadPriority(__threadPriority);
		#end

		if (!__isPrimordial) {
			var t:Thread = Thread.current();
			__instances.set(t, this);
		}

		dispatchEvent(new Event(Event.INIT));

		while (__isRunning) {
			var currentTime:Float = Timer.stamp();
			var e:TickEvent = new TickEvent(TickEvent.TICK, __dt);

			dispatchEvent(e);
			__cpuTime = __dt = Timer.stamp() - currentTime;
			#if precisionTick
			var minSleep = 0.001;
			#end
			while (__dt < __tickInterval) {
				#if precisionTick
				if (__dt + __sleepAccuracy > __tickInterval) {
					minSleep = 0;
				}

				Sys.sleep(minSleep);
				#else
				Sys.sleep(0.001);
				#end
				__dt = Timer.stamp() - currentTime;
			}

			__time += __dt;
		}
		dispatchEvent(new Event(Event.EXIT));
	}
}
