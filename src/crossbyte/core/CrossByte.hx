package crossbyte.core;

#if cpp
import cpp.AtomicInt;
import cpp.Pointer;
import cpp.net.Poll;
import crossbyte.utils.ThreadPriority;
#end
import sys.net.Socket;
import crossbyte.events.Event;
import crossbyte.events.EventDispatcher;
import crossbyte.events.TickEvent;
import haxe.EntryPoint;
import haxe.Timer;
import haxe.ds.Map;
#if (cpp || neko || hl)
import sys.thread.Thread;
import sys.thread.Tls;
#end
import haxe.ds.ObjectMap;
#if cpp
import crossbyte._internal.socket.NativeSocketRegistry;
#else
import crossbyte._internal.socket.SocketRegistry;
#end
import crossbyte.net.Socket as CBSocket;
import crossbyte._internal.system.timer.TimerScheduler;
import crossbyte.Timer as CBTimer;

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
	@:noCompletion private static inline var DEFAULT_MAX_SOCKETS:Int = 64;
	
	#if cpp
	@:noCompletion private static var __instances:Map<Thread, CrossByte> = new ObjectMap();
	@:noCompletion private static var __instanceCount:AtomicInt = 0;
	@:noCompletion private var __socketRegistry:NativeSocketRegistry;
	@:noCompletion private static var __threadLocalStorage:Tls<CrossByte> = new Tls();

	#else
	@:noCompletion private var __socketRegistry:SocketRegistry;
	#end	

	@:noCompletion private static var __init:Bool = __onCrossByteInit();
	@:noCompletion private static var __primordial:CrossByte;

	// ==== Public Static Methods ====
	public static inline function make(loopType:MainLoopType = DEFAULT):CrossByte {
		var instance:CrossByte = new CrossByte(false, loopType);
		return instance;
	}

	public static inline function current():CrossByte {
		// is TLS better?
		/* var currentThread:Thread = Thread.current();
			var instance:CrossByte = __instances.get(currentThread);
			return instance; */
		#if cpp
		var instance:CrossByte = __threadLocalStorage.value;
		if (instance == null) {
			instance = __primordial;
		}
		return instance;
		#else
		return __primordial;
		#end
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
	public var uptime(get, never):Float;

	// ==== Private Variables ====
	@:noCompletion private var __tickInterval:Float;
	@:noCompletion private var __isRunning:Bool = true;
	@:noCompletion private var __tps:UInt;
	@:noCompletion private var __dt:Float = 0.0;
	@:noCompletion private var __cpuTime:Float = 0.0;
	@:noCompletion private var __sleepAccuracy:Float = 0.0;

	#if cpp
	@:noCompletion private var __socketRegistry:NativeSocketRegistry;
	#else
	@:noCompletion private var __socketRegsitry:SocketRegistry;
	#end

	@:noCompletion private var __isPrimordial:Bool;

	#if cpp
	@:noCompletion private var __threadPriority:ThreadPriority = NORMAL;
	#end

	@:noCompletion private var __loopType:MainLoopType;
	@:noCompletion private var __timer:TimerScheduler;

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
	private function new(isPrimordial:Bool, loopType:MainLoopType = DEFAULT) {
		super(this);
		__isPrimordial = isPrimordial;
		__loopType = loopType;
		__setup();
	}

	/* ==== Public Methods ==== */
	#if cpp
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
	#end

	// TODO

	/* public function runInThread(job:Function):Void{

	}*/
	public function exit():Void {
		// TODO: Thread safety
		__isRunning = false;
		#if cpp
		__instances.remove(Thread.current());
		__instanceCount--;
		#end
		__socketRegistry = null;
		
	}

	@:noCompletion private inline function get_uptime():Float {
		return __timer.time;
	}

	// ==== Private Methods ====

	@:noCompletion private inline function registerSocket(socket:Socket):Void {
		#if cpp
		__socketRegistry.register(socket);
		#else
		// no-op for now
		#end
	}

	@:noCompletion private inline function deregisterSocket(socket:Socket):Void {
		#if cpp
		__socketRegistry.deregister(socket);
		#else
		// no-op for now
		#end
	}

	@:noCompletion private inline function queueWritable(socket:Socket):Void {
		__socketRegistry.queueWritable(socket);
	}

	@:noCompletion private inline function __setup():Void {
		Sys.println("Initializing CrossByte Instance");
		#if cpp
		__instanceCount++;
		__socketRegistry = new NativeSocketRegistry(DEFAULT_MAX_SOCKETS);
		#else
		__socketRegistry = new SocketRegistry(DEFAULT_MAX_SOCKETS);
		#end

		__timer = new TimerScheduler();
		CBTimer.bindCurrentThread(__timer);
		tps = DEFAULT_TICKS_PER_SECOND;
		mainLoop = switch (__loopType) {
			case POLL: __pollBasedMainLoop;
			case CUSTOM(loop): loop;
			default: __defaultMainLoop;
		}

		#if precision_tick
		__getSleepAccuracy();
		#end

		if (__isPrimordial) {
			EntryPoint.runInMainThread(__runEventLoop);
			__primordial = this;
			// TODO: Thread safety
			#if cpp
			var t:Thread = Thread.current();
			__instances.set(t, this);
			#end			
		} else {
			EntryPoint.addThread(__runEventLoop);
		}
	}

	@:noCompletion private function get_cpuLoad():Float {
		var free:Float = ((__tickInterval - __cpuTime) / __tickInterval) * 100;

		return Math.min(Math.floor((100 - free) * 100) / 100, 100);
	}

	#if precision_tick
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

		#if cpp
		if (!__isPrimordial) {
			var t:Thread = Thread.current();
			__instances.set(t, this);
		}
		#end

		dispatchEvent(new Event(Event.INIT));
		while (__isRunning) {
			mainLoop();
		}
		dispatchEvent(new Event(Event.EXIT));
	}

	private var mainLoop:Void->Void;
	private #if final inline #end function __defaultMainLoop():Void {
		var frameStart:Float = Timer.stamp();
		var e:TickEvent = new TickEvent(TickEvent.TICK, __dt);
		__timer.advanceTime(__dt);
		dispatchEvent(e);
		__socketRegistry.update();

		__cpuTime = __dt = Timer.stamp() - frameStart;
		__wait(frameStart);
	}
	private #if final inline #end function __pollBasedMainLoop():Void {
		var frameStart:Float = Timer.stamp();
		var e:TickEvent = new TickEvent(TickEvent.TICK, __dt);
		__timer.advanceTime(__dt);
		dispatchEvent(e);

		__cpuTime = __dt = Timer.stamp() - frameStart;

		if (!__socketRegistry.isEmpty) {
			var deadline:Float = frameStart + __tickInterval;

			while (true) {
				var now:Float = Timer.stamp();
				var remaining:Float = deadline - now;
				if (remaining < 0) {
					remaining = 0;
				}

				__socketRegistry.update(remaining);

				__dt = Timer.stamp() - frameStart;

				if (remaining == 0) {
					break;
				}
			}
		} else {
			__wait(frameStart);
		}
	}
	private #if final inline #end function __wait(frameStartTime:Float):Void {
		#if precision_tick
		var minSleep = 0.001;
		#end

		while (__dt < __tickInterval) {
			#if precision_tick
			if (__dt + __sleepAccuracy > __tickInterval) {
				minSleep = 0;
			}

			Sys.sleep(minSleep);
			#else
			Sys.sleep(0.001);
			#end
			__dt = Timer.stamp() - frameStartTime;
		}
	}
}
