package crossbyte.core;

#if cpp
import cpp.AtomicInt;
import crossbyte.utils.ThreadPriority;
#end
#if (cpp && windows)
import crossbyte.core._internal.NativeWindowsRuntime;
#end
import crossbyte.errors.IllegalOperationError;
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
 * The core CrossByte runtime.
 *
 * A `CrossByte` instance owns:
 * - a timer scheduler
 * - a socket registry / polling context
 * - a tick-driven event loop
 * - thread-local runtime state for the thread it runs on
 *
 * In normal application usage there is exactly one primordial `CrossByte`
 * created by extending `Application`, `HostApplication`, or
 * `ServerApplication`.
 *
 * Additional `CrossByte` instances may then be created as child runtimes,
 * typically to simplify threaded work while keeping each thread's timer and
 * socket state isolated.
 *
 * Child runtimes are created with `CrossByte.make(...)`. They are not
 * primordial applications and should be treated as worker/runtime instances
 * under the main application context.
 *
 * @author Christopher Speciale
 */
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
	@:noCompletion private static var __primordialThread:Thread;

	#else
	@:noCompletion private var __socketRegistry:SocketRegistry;
	#end	

	@:noCompletion private static var __init:Bool = __onCrossByteInit();
	@:noCompletion private static var __primordial:CrossByte;

	// ==== Public Static Methods ====
	/**
	 * Creates a non-primordial CrossByte child runtime.
	 *
	 * This is the intended entry point for additional threaded CrossByte
	 * instances after the primordial application has already been established.
	 *
	 * @param loopType The loop strategy to use for the child runtime.
	 * @return The newly created non-primordial CrossByte instance.
	 */
	public static function make(loopType:MainLoopType = DEFAULT):CrossByte {
		if (__primordial == null) {
			throw new IllegalOperationError("CrossByte.make() requires a primordial CrossByte instance. Create an Application, HostApplication, ServerApplication, or primordial CrossByte before creating child runtimes.");
		}

		var instance:CrossByte = new CrossByte(false, loopType);
		return instance;
	}

	/**
	 * Returns the CrossByte runtime associated with the current thread.
	 *
	 * On threaded targets, this first resolves the thread-local CrossByte
	 * instance. If none is attached, it falls back to the primordial runtime
	 * only when called from the primordial thread.
	 *
	 * @return The current thread's CrossByte instance, or the primordial
	 *         application runtime when called from the primordial thread.
	 */
	public static inline function current():CrossByte {
		#if cpp
		var instance:CrossByte = __threadLocalStorage.value;
		if (instance == null) {
			if (__primordial != null && __primordialThread != null && Thread.current() == __primordialThread) {
				instance = __primordial;
			} else {
				throw new IllegalOperationError("CrossByte runtime not attached to this thread. Create a child runtime with CrossByte.make(...), or access the primordial runtime only from its owning thread.");
			}
		}
		return instance;
		#else
		return __primordial;
		#end
	}

	// ==== Private Static Methods ====
	@:noCompletion private static function __onCrossByteInit():Bool {
		#if (cpp && windows)
		NativeWindowsRuntime.beginTimingPeriod(1);
		NativeWindowsRuntime.setHighPriorityProcess();
		#end

		return true;
	}

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

	@:noCompletion private var __isPrimordial:Bool;
	@:noCompletion private var __usesHostLoop:Bool = false;
	@:noCompletion private var __didInit:Bool = false;
	@:noCompletion private var __didExit:Bool = false;

	#if cpp
	@:noCompletion private var __threadPriority:ThreadPriority = NORMAL;
	#end

	@:noCompletion private var __loopType:MainLoopType;
	@:noCompletion private var __timer:TimerScheduler;

	#if (cpp && windows)
	@:noCompletion private var __threadId:Int = 0;
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
	private function new(isPrimordial:Bool, loopType:MainLoopType = DEFAULT, hostDriven:Bool = false) {
		super(this);
		__isPrimordial = isPrimordial;
		__loopType = loopType;
		__usesHostLoop = hostDriven;
		__setup();
	}

	/* ==== Public Methods ==== */
	#if cpp
	public inline function getThreadPriority():ThreadPriority {
		return __threadPriority;
	}

	public function setThreadPriority(priority:ThreadPriority):Void {
		__threadPriority = priority;

		#if windows
		if (__threadId == 0) {
			return;
		}

		NativeWindowsRuntime.setThreadPriority(__threadId, __nativeThreadPriority(priority));
		#end
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
		if (__usesHostLoop) {
			__finalizeExit();
		}
	}

	@:noCompletion public function pump(delta:Float, socketTimeout:Float = 0.0):Void {
		if (!__usesHostLoop) {
			throw "CrossByte.pump(delta) is only available for host-driven application instances.";
		}

		#if cpp
		__threadLocalStorage.value = this;
		#end
		CBTimer.bindCurrentThread(__timer);
		__dispatchInitIfNeeded();

		if (!__isRunning) {
			__finalizeExit();
			return;
		}

		__stepHost(delta, socketTimeout);

		if (!__isRunning) {
			__finalizeExit();
		}
	}

	@:noCompletion private function __stepHost(delta:Float, socketTimeout:Float = 0.0):Void {
		if (delta < 0) {
			delta = 0;
		}

		if (socketTimeout < 0) {
			socketTimeout = 0;
		}

		var frameStart:Float = Timer.stamp();
		__dt = delta;
		__timer.advanceTime(delta);
		if (hasEventListener(TickEvent.TICK)) {
			dispatchEvent(new TickEvent(TickEvent.TICK, delta));
		}
		if (!__isRunning) {
			__cpuTime = Timer.stamp() - frameStart;
			return;
		}

		__socketRegistry.update(socketTimeout);
		__cpuTime = Timer.stamp() - frameStart;
	}

	@:noCompletion private inline function get_uptime():Float {
		return __timer.time;
	}

	// ==== Private Methods ====

	// Socket polling is now shared across cpp and non-cpp targets.
	// `SocketRegistry` already exists on non-cpp, and both TCP/UDP transports rely on it.
	@:noCompletion private inline function registerSocket(socket:Socket):Void {
		__socketRegistry.register(socket);
	}

	@:noCompletion private inline function deregisterSocket(socket:Socket):Void {
		__socketRegistry.deregister(socket);
	}

	@:noCompletion private inline function queueWritable(socket:Socket):Void {
		if (__socketRegistry != null) {
			__socketRegistry.queueWritable(socket);
		}
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

		if (__usesHostLoop) {
			if (__isPrimordial) {
				__primordial = this;
			}

			#if cpp
			var currentThread:Thread = Thread.current();
			__instances.set(currentThread, this);
			__threadLocalStorage.value = this;
			if (__isPrimordial) {
				__primordialThread = currentThread;
			}
			#end
			return;
		}

		if (__isPrimordial) {
			EntryPoint.runInMainThread(__runEventLoop);
			__primordial = this;
			// TODO: Thread safety
			#if cpp
			var t:Thread = Thread.current();
			__instances.set(t, this);
			__primordialThread = t;
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
		__threadId = NativeWindowsRuntime.getCurrentThreadId();
		setThreadPriority(__threadPriority);
		#end

		#if cpp
		__threadLocalStorage.value = this;
		if (!__isPrimordial) {
			var t:Thread = Thread.current();
			__instances.set(t, this);
		}
		#end
		CBTimer.bindCurrentThread(__timer);

		__dispatchInitIfNeeded();
		while (__isRunning) {
			mainLoop();
		}
		__finalizeExit();
	}

	@:noCompletion private inline function __dispatchInitIfNeeded():Void {
		if (!__didInit) {
			__didInit = true;
			if (hasEventListener(Event.INIT)) {
				dispatchEvent(new Event(Event.INIT));
			}
		}
	}

	@:noCompletion private function __finalizeExit():Void {
		if (__didExit) {
			return;
		}

		__didExit = true;
		if (hasEventListener(Event.EXIT)) {
			dispatchEvent(new Event(Event.EXIT));
		}
		if (__socketRegistry != null) {
			__socketRegistry.clear();
			__socketRegistry = null;
		}
		#if cpp
		if (__threadLocalStorage.value == this) {
			if (!__isPrimordial && __primordial != null && __primordialThread != null && Thread.current() == __primordialThread) {
				__threadLocalStorage.value = __primordial;
			} else {
				__threadLocalStorage.value = null;
			}
		}
		#end
		#if (cpp && windows)
		if (__isPrimordial) {
			NativeWindowsRuntime.endTimingPeriod(1);
		}
		#end
		if (__isPrimordial && __primordial == this) {
			__primordial = null;
			#if cpp
			__primordialThread = null;
			#end
		}
	}

	#if (cpp && windows)
	@:noCompletion private static inline function __nativeThreadPriority(priority:ThreadPriority):Int {
		return switch (priority) {
			case IDLE: -15;
			case LOWEST: -2;
			case LOW: -1;
			case NORMAL: 0;
			case HIGH: 1;
			case HIGHEST: 2;
			case CRITICAL: 15;
		}
	}
	#end

	private var mainLoop:Void->Void;
	private #if final inline #end function __defaultMainLoop():Void {
		var frameStart:Float = Timer.stamp();
		__timer.advanceTime(__dt);
		if (hasEventListener(TickEvent.TICK)) {
			dispatchEvent(new TickEvent(TickEvent.TICK, __dt));
		}
		if (!__isRunning) {
			return;
		}
		__socketRegistry.update();

		__cpuTime = __dt = Timer.stamp() - frameStart;
		__wait(frameStart);
	}
	private #if final inline #end function __pollBasedMainLoop():Void {
		var frameStart:Float = Timer.stamp();
		__timer.advanceTime(__dt);
		if (hasEventListener(TickEvent.TICK)) {
			dispatchEvent(new TickEvent(TickEvent.TICK, __dt));
		}
		if (!__isRunning) {
			return;
		}

		__cpuTime = __dt = Timer.stamp() - frameStart;

		if (!__socketRegistry.isEmpty) {
			// Keep Poll as the readiness backend, but never let it own the frame
			// wait. Windows UDP poll can otherwise starve CrossByte timers while
			// an idle socket is registered.
			__socketRegistry.update(0);
			__dt = Timer.stamp() - frameStart;
		}
		__wait(frameStart);
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
