package crossbyte.core;

#if cpp
import cpp.AtomicInt;
import crossbyte.utils.ThreadPriority;
#end
#if (cpp && windows)
import crossbyte.core._internal.NativeWindowsRuntime;
#end
import crossbyte.core._internal.PassFlush;
import crossbyte.errors.IllegalOperationError;
#if !js
import sys.net.Socket;
#end
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
#if cpp
import sys.thread.Mutex;
#end
import haxe.ds.ObjectMap;
#if cpp
import crossbyte._internal.socket.NativeSocketRegistry;
#elseif !js
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
	/**
	 * Sockets a new runtime's poll backend is sized for up front.
	 *
	 * This is a starting allocation, not a ceiling: the registry grows
	 * automatically when it is exceeded. What a larger value buys is
	 * avoiding that growth, since each step disposes the poll backend,
	 * allocates a new one, and re-registers every socket. Starting at 64,
	 * a server ramping to a thousand connections pays for roughly seven
	 * such rebuilds — precisely while it is busiest.
	 *
	 * Costs on the order of tens of kilobytes per runtime at the default.
	 * Lower it for memory-constrained processes that hold few sockets;
	 * raise it when a runtime is known to carry far more.
	 *
	 * Assign before creating a runtime; runtimes already created are
	 * unaffected.
	 */
	public static var defaultSocketCapacity:Int = 1024;

	// ==== Private Static Variables ====
	@:noCompletion private static inline var DEFAULT_TICKS_PER_SECOND:UInt = 12;

	/**
	 * Shortest remaining frame budget worth handing to poll.
	 *
	 * Below this the syscall costs more than the wait is worth, and a backend
	 * that returns immediately would spin on the remainder instead of
	 * sleeping it off.
	 */
	@:noCompletion private static inline var MIN_POLL_WAIT:Float = 0.001;

	/**
	 * Slack left at the end of a long sleep for the operating system to
	 * overshoot into, before the remainder is finished in short sleeps.
	 *
	 * A frame used to be waited out entirely in one-millisecond steps, which
	 * at the default tick rate is over eighty sleeps per frame to accomplish
	 * nothing. Sleeping the bulk in one call and stepping only the tail costs
	 * a handful, and is why this margin exists rather than sleeping the whole
	 * remainder and hoping.
	 */
	@:noCompletion private static inline var SLEEP_SLACK:Float = 0.002;

	/**
	 * Longest schedule debt, in seconds, the loop will try to repay.
	 *
	 * Internal on purpose. This bounds the loop's own recovery rather than
	 * anything a listener is told, and a tick reports real elapsed time with
	 * nothing to configure, so there is no setting for one to be confused
	 * with the other.
	 */
	@:noCompletion private static inline var MAX_SCHEDULE_DEBT:Float = 0.25;
	@:noCompletion private static inline var DEFAULT_MAX_SOCKETS:Int = 64;

	/**
	 * Resolves the starting poll capacity, falling back to the historical
	 * default if a caller sets a nonsensical value.
	 */
	@:noCompletion private static inline function __initialSocketCapacity():Int {
		return defaultSocketCapacity > 0 ? defaultSocketCapacity : DEFAULT_MAX_SOCKETS;
	}
	
	#if cpp
	// Guards cross-thread access to the shared runtime registry
	// (__instances/__instanceCount) and the published primordial state
	// (__primordial/__primordialThread). Acquired around mutation in
	// __setup()/__runEventLoop()/exit()/__finalizeExit() and around the
	// happens-before publish/read of the primordial fields.
	@:noCompletion private static var __registryLock:Mutex = new Mutex();
	@:noCompletion private static var __instances:Map<Thread, CrossByte> = new ObjectMap();
	@:noCompletion private static var __instanceCount:AtomicInt = 0;
	@:noCompletion private var __socketRegistry:NativeSocketRegistry;
	@:noCompletion private static var __threadLocalStorage:Tls<CrossByte> = new Tls();
	@:noCompletion private static var __primordialThread:Thread;

	#elseif !js
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
	 * @param timers Which structure schedules its timers. Per runtime rather
	 *        than per process, so a thread holding a timer per entity and one
	 *        holding a handful need not agree.
	 * @return The newly created non-primordial CrossByte instance.
	 */
	public static function make(loopType:MainLoopType = DEFAULT, timers:TimerStrategy = HEAP):CrossByte {
		if (__primordial == null) {
			throw new IllegalOperationError("CrossByte.make() requires a primordial CrossByte instance. Create an Application, HostApplication, ServerApplication, or primordial CrossByte before creating child runtimes.");
		}

		var instance:CrossByte = new CrossByte(false, loopType, false, timers);
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
			// Fast path stays lock-free. The primordial fields are published under
			// __registryLock in __setup() before any child runtime/thread is
			// created (happens-before), and the fallback below only consults them
			// from the primordial thread itself -- which performed that publish in
			// program order. A single snapshot avoids a torn read between the
			// null-check and use.
			var primordial:CrossByte = __primordial;
			var primordialThread:Thread = __primordialThread;
			if (primordial != null && primordialThread != null && Thread.current() == primordialThread) {
				instance = primordial;
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
	public var cpuLoad(get, never):Float;
	public var uptime(get, never):Float;

	// ==== Private Variables ====
	@:noCompletion private var __tickInterval:Float;

	/** Structure this runtime schedules timers with; see `TimerStrategy`. */
	@:noCompletion private var __timerStrategy:TimerStrategy;
	// Stop flag observed by the loop thread and written by exit() (possibly from
	// another thread). On cpp it is an atomic 0/1 flag so the loop reliably sees
	// the stop request; elsewhere a plain Bool is sufficient (single-threaded).
	#if cpp
	@:noCompletion private var __isRunning:AtomicInt = 1;
	#else
	@:noCompletion private var __isRunning:Bool = true;
	#end
	@:noCompletion private var __tps:UInt;
	@:noCompletion private var __dt:Float = 0.0;

	/**
	 * When the current frame is due to end, as an absolute time.
	 *
	 * Carried forward by one tick interval per frame rather than recomputed
	 * from whenever a frame happened to begin. Measuring the wait from the
	 * frame's own start makes every overrun permanent — a frame that runs
	 * two milliseconds long simply ends two milliseconds late and the next
	 * one starts from there — so a runtime configured for 60 ticks a second
	 * delivered closer to 55, silently, and anything counting ticks as
	 * elapsed time drifted behind the clock for as long as it ran.
	 *
	 * Zero until the first frame establishes it.
	 */
	@:noCompletion private var __frameDeadline:Float = 0.0;
	@:noCompletion private var __cpuTime:Float = 0.0;
	@:noCompletion private var __sleepAccuracy:Float = 0.0;

	@:noCompletion private var __isPrimordial:Bool;
	@:noCompletion private var __usesHostLoop:Bool = false;
	@:noCompletion private var __didInit:Bool = false;
	@:noCompletion private var __didExit:Bool = false;
	// Hot-path tick events are reused to reduce per-frame allocation churn.
	// These events are ephemeral during dispatch and must not be retained.
	@:noCompletion private var __pooledTickEvent:TickEvent;
	@:noCompletion private var __pooledTickEventInUse:Bool = false;

	// What asked to send its held output when this pass ends, in the order
	// it asked, and how far the current flush has got through it.
	@:noCompletion private var __passFlushes:Array<PassFlush> = [];
	@:noCompletion private var __passFlushAt:Int = 0;
	@:noCompletion private var __flushingPass:Bool = false;
	#if js
	@:noCompletion private var __passFlushScheduled:Bool = false;
	@:noCompletion private var __passFlushTurn:Void->Void = null;
	#end

	#if cpp
	@:noCompletion private var __threadPriority:ThreadPriority = NORMAL;
	// The thread this runtime is bound to (its loop thread, or the host pump
	// thread). exit() deregisters this entry even when called from another
	// thread, and __didDeregister makes the deregistration idempotent.
	@:noCompletion private var __ownerThread:Thread;
	@:noCompletion private var __didDeregister:Bool = false;
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
		// Guard against tps == 0, which would make __tickInterval +Infinity and
		// hang the frame-wait loop forever.
		if (value < 1) {
			value = 1;
		}
		__tps = value;
		__tickInterval = 1 / __tps;

		// The schedule restarts from here. Carrying the old deadline across a
		// rate change would either stall for an interval that no longer
		// applies, or read as debt and burn catch-up frames repaying it.
		__frameDeadline = Timer.stamp() + __tickInterval;

		return value;
	}

	// Localized stop-flag access so the loop-condition reads and exit()'s write
	// agree across threads. On cpp the field is an atomic 0/1 int.
	@:noCompletion private inline function __getRunning():Bool {
		#if cpp
		return __isRunning != 0;
		#else
		return __isRunning;
		#end
	}

	@:noCompletion private inline function __setRunning(value:Bool):Void {
		#if cpp
		__isRunning = value ? 1 : 0;
		#else
		__isRunning = value;
		#end
	}

	// ==== Constructor ====
	private function new(isPrimordial:Bool, loopType:MainLoopType = DEFAULT, hostDriven:Bool = false, timers:TimerStrategy = HEAP) {
		__timerStrategy = timers;
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
		__setRunning(false);
		#if cpp
		__registryLock.acquire();
		if (!__didDeregister) {
			__didDeregister = true;
			// Remove the runtime's own thread entry, not the caller's, so a
			// cross-thread exit() does not leak the owning thread's entry or
			// drift __instanceCount.
			var owner:Thread = __ownerThread != null ? __ownerThread : Thread.current();
			__instances.remove(owner);
			__instanceCount--;
		}
		__registryLock.release();
		#end
		if (__usesHostLoop) {
			__finalizeExit();
		}
	}

	@:noCompletion public function pump(delta:Float, socketTimeout:Float = 0.0):Void {
		if (!__usesHostLoop) {
			throw "CrossByte.pump(delta) is only available for host-driven application instances.";
		}

		// Read the stop flag before claiming the thread, not after. This used to
		// publish `this` as the thread's current runtime and rebind the thread's
		// timer scheduler on the way in, so pumping a runtime that had already
		// exited left a runtime which can never tick again as CrossByte.current()
		// for the rest of that thread's life -- __finalizeExit's hand-back is
		// guarded by __didExit and so does not run a second time. Everything that
		// resolves the current runtime afterwards (a Worker's completion listener,
		// a timer, a socket registration) then attached to the dead runtime and
		// simply never fired, with nothing raised to say so.
		if (!__getRunning()) {
			__finalizeExit();
			__releaseThreadLocal();
			return;
		}

		#if cpp
		__ownerThread = Thread.current();
		__threadLocalStorage.value = this;
		#end
		CBTimer.bindCurrentThread(__timer);
		__dispatchInitIfNeeded();

		if (!__getRunning()) {
			__finalizeExit();
			return;
		}

		__stepHost(delta, socketTimeout);

		if (!__getRunning()) {
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
		__dispatchTick(delta);
		__flushHeld();
		if (!__getRunning()) {
			__cpuTime = Timer.stamp() - frameStart;
			return;
		}

		#if !js
		__socketRegistry.update(socketTimeout);
		__flushHeld();
		#end
		__cpuTime = Timer.stamp() - frameStart;
	}

	/**
		Asks for `item` to be flushed when this pass of the loop ends: after the
		tick's handlers have run, and again after each round of socket polling,
		so what a handler sends in answer to what just arrived goes out before
		the loop waits. The host loop ends its pass the same way, so the end of
		`HostApplication.advance` is one too.

		On JavaScript, datagrams are delivered by the platform's own loop
		between passes, so a turn of that loop is a pass as well: the first
		request in one arranges for the flush once the turn's callbacks have run.
	**/
	@:noCompletion public function __queuePassFlush(item:PassFlush):Void {
		__passFlushes.push(item);
		#if js
		if (!__passFlushScheduled) {
			__passFlushScheduled = true;
			if (__passFlushTurn == null) {
				__passFlushTurn = __flushPassFromTurn;
			}
			#if nodejs
			js.Node.setImmediate(__passFlushTurn);
			#else
			js.Browser.window.setTimeout(__passFlushTurn, 0);
			#end
		}
		#end
	}

	#if js
	@:noCompletion private function __flushPassFromTurn():Void {
		__passFlushScheduled = false;
		__flushHeld();
	}
	#end

	@:noCompletion private function __flushHeld():Void {
		if (__flushingPass || __passFlushAt >= __passFlushes.length) {
			return;
		}

		// Walked by index rather than copied, because a flush can make another
		// holder ask -- an error handler that sends on a different session --
		// and that one belongs to this pass too. If a handler throws, the rest
		// stay where they are, and the next pass carries on from there.
		__flushingPass = true;
		try {
			while (__passFlushAt < __passFlushes.length) {
				var item:PassFlush = __passFlushes[__passFlushAt];
				__passFlushes[__passFlushAt] = null;
				__passFlushAt++;
				item.__flushPass();
			}
		} catch (error:Dynamic) {
			__flushingPass = false;
			#if cpp
			cpp.Lib.rethrow(error);
			#else
			throw error;
			#end
		}
		__passFlushes.resize(0);
		__passFlushAt = 0;
		__flushingPass = false;
	}

	@:noCompletion private inline function get_uptime():Float {
		return __timer.time;
	}

	// ==== Private Methods ====

	// Socket polling is now shared across cpp and non-cpp targets.
	// `SocketRegistry` already exists on non-cpp, and both TCP/UDP transports rely on it.
	#if !js
	@:noCompletion private inline function registerSocket(socket:Socket):Void {
		if (__socketRegistry != null) {
			__socketRegistry.register(socket);
		}
	}

	@:noCompletion private inline function deregisterSocket(socket:Socket):Void {
		if (__socketRegistry != null) {
			__socketRegistry.deregister(socket);
		}
	}

	@:noCompletion private inline function queueWritable(socket:Socket):Void {
		if (__socketRegistry != null) {
			__socketRegistry.queueWritable(socket);
		}
	}
	#end

	@:noCompletion private inline function __setup():Void {
		#if cpp
		__registryLock.acquire();
		__instanceCount++;
		__registryLock.release();
		__socketRegistry = new NativeSocketRegistry(__initialSocketCapacity());
		#elseif !js
		__socketRegistry = new SocketRegistry(__initialSocketCapacity());
		#end

		__timer = new TimerScheduler(__timerStrategy);
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
			#if cpp
			// Publish registry + primordial state under the lock so it is visible
			// (happens-before) to any threads that later read it via current().
			var currentThread:Thread = Thread.current();
			__registryLock.acquire();
			if (__isPrimordial) {
				__primordial = this;
				__primordialThread = currentThread;
			}
			__instances.set(currentThread, this);
			__registryLock.release();
			__ownerThread = currentThread;
			__threadLocalStorage.value = this;
			#else
			if (__isPrimordial) {
				__primordial = this;
			}
			#end
			if (__isPrimordial) {
				__adoptEarlyTimers();
			}
			return;
		}

		if (__isPrimordial) {
			EntryPoint.runInMainThread(__runEventLoop);
			#if cpp
			// Publish primordial state under the lock before any child runtimes
			// (and their threads) can be created, establishing happens-before for
			// reads through current().
			var t:Thread = Thread.current();
			__registryLock.acquire();
			__primordial = this;
			__primordialThread = t;
			__instances.set(t, this);
			__registryLock.release();
			#else
			__primordial = this;
			#end
			__adoptEarlyTimers();
		} else {
			EntryPoint.addThread(__runEventLoop);
		}
	}

	// Timers made before any runtime existed -- by a library's static
	// initializer, which runs before main -- start on this one's ticks.
	@:noCompletion private function __adoptEarlyTimers():Void {
		#if !lime_cffi
		@:privateAccess haxe.Timer.__primordialReady(this);
		#end
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
		__ownerThread = Thread.current();
		__threadLocalStorage.value = this;
		if (!__isPrimordial) {
			__registryLock.acquire();
			__instances.set(__ownerThread, this);
			__registryLock.release();
		}
		#end
		CBTimer.bindCurrentThread(__timer);

		__dispatchInitIfNeeded();

		#if js
		// One turn of the JavaScript event loop at a time, rather than a loop
		// that never gives it back. Spinning here would be the same code as
		// below and would work in the sense that ticks would dispatch -- and
		// nothing else would ever run: not a socket, not an HTTP response, not
		// a repaint, because every one of those is delivered by the loop this
		// would be holding.
		__lastFrameStamp = Timer.stamp();
		__frameDeadline = __lastFrameStamp + __tickInterval;
		__scheduleFrame();
		#else
		while (__getRunning()) {
			mainLoop();
		}
		__finalizeExit();
		#end
	}

	#if js
	/**
	 * Asks the runtime for the next turn.
	 *
	 * The two targets are asked differently because they are paced
	 * differently. Node is told when to come back, so the configured rate is
	 * the rate, down to the millisecond its timers resolve to. A browser is
	 * not: `requestAnimationFrame` arrives on the display's schedule and no
	 * other, which is the right thing to align with in a page, and means a tps
	 * above the refresh rate cannot be delivered. `__jsFrame` drops the turns
	 * that arrive early, so a rate below it still means what it says.
	 *
	 * A browser also asks for both a frame and a timer, because a page that is
	 * not visible is given no frames at all -- the callback is held until the
	 * tab comes back. On its own that would stop the entire runtime for as long
	 * as the user looked at something else: no timers, no socket handling, a
	 * connection left to time out. Timers do keep running while hidden, so one
	 * is armed beside the frame request and whichever arrives first takes the
	 * turn. Browsers throttle a hidden page's timers to roughly one a second,
	 * which the tick delta reports rather than conceals.
	 */
	@:noCompletion private function __scheduleFrame():Void {
		#if nodejs
		__frameTimeout = js.Node.setTimeout(__jsFrame, __frameWaitMs());
		#else
		__frameRequest = js.Browser.window.requestAnimationFrame(function(_):Void {
			__jsFrame();
		});
		__frameTimeout = js.Browser.window.setTimeout(function():Void {
			__jsFrame();
		}, __frameWaitMs());
		#end
	}

	/**
	 * How long is left of the current frame, in whole milliseconds, floored at
	 * zero for a frame already overdue.
	 */
	@:noCompletion private inline function __frameWaitMs():Int {
		var remaining:Int = Math.round((__frameDeadline - Timer.stamp()) * 1000);
		return remaining < 0 ? 0 : remaining;
	}

	@:noCompletion private function __jsFrame():Void {
		// Whichever of the two did not fire is cancelled here, so exactly one
		// pair is ever outstanding. Without this every early frame would leave
		// its timer behind and the pending callbacks would multiply.
		#if (js && !nodejs)
		js.Browser.window.cancelAnimationFrame(__frameRequest);
		js.Browser.window.clearTimeout(__frameTimeout);
		#end

		if (!__getRunning()) {
			__finalizeExit();
			return;
		}

		if (Timer.stamp() >= __frameDeadline) {
			__advanceDeadline();
			mainLoop();

			if (!__getRunning()) {
				__finalizeExit();
				return;
			}
		}

		__scheduleFrame();
	}
	#end

	@:noCompletion private inline function __dispatchInitIfNeeded():Void {
		if (!__didInit) {
			__didInit = true;
			if (hasEventListener(Event.INIT)) {
				dispatchEvent(new Event(Event.INIT));
			}
		}
	}

	@:noCompletion private inline function __dispatchTick(delta:Float):Void {
		if (!hasEventListener(TickEvent.TICK)) {
			return;
		}

		if (__pooledTickEventInUse) {
			dispatchEvent(new TickEvent(TickEvent.TICK, delta));
			return;
		}

		if (__pooledTickEvent == null) {
			__pooledTickEvent = new TickEvent(TickEvent.TICK, delta);
		} else {
			__pooledTickEvent.delta = delta;
			@:privateAccess {
				__pooledTickEvent.target = null;
				__pooledTickEvent.currentTarget = null;
			}
		}

		__pooledTickEventInUse = true;
		try {
			dispatchEvent(__pooledTickEvent);
		} catch (error:Dynamic) {
			__pooledTickEventInUse = false;
			throw error;
		}
		__pooledTickEventInUse = false;
	}

	// Hands the thread's current runtime back when it still points at this stopped
	// instance. __finalizeExit does this too, but only on the one call that flips
	// __didExit, so it cannot repair a claim made after that.
	@:noCompletion private function __releaseThreadLocal():Void {
		#if cpp
		if (__threadLocalStorage.value != this) {
			return;
		}

		__registryLock.acquire();
		var primordial:CrossByte = __primordial;
		var primordialThread:Thread = __primordialThread;
		__registryLock.release();

		if (!__isPrimordial && primordial != null && primordialThread != null && Thread.current() == primordialThread) {
			__threadLocalStorage.value = primordial;
		} else {
			__threadLocalStorage.value = null;
		}
		#end
	}

	@:noCompletion private function __finalizeExit():Void {
		if (__didExit) {
			return;
		}

		__didExit = true;
		if (hasEventListener(Event.EXIT)) {
			dispatchEvent(new Event(Event.EXIT));
		}
		// Whatever the last pass, or an exit handler, left held goes out while
		// the sockets are still there to send it.
		__flushHeld();
		#if !js
		if (__socketRegistry != null) {
			__socketRegistry.clear();
			__socketRegistry = null;
		}
		#end
		__releaseThreadLocal();
		#if (cpp && windows)
		if (__isPrimordial) {
			NativeWindowsRuntime.endTimingPeriod(1);
		}
		#end
		#if cpp
		if (__isPrimordial) {
			__registryLock.acquire();
			if (__primordial == this) {
				__primordial = null;
				__primordialThread = null;
			}
			__registryLock.release();
		}
		#else
		if (__isPrimordial && __primordial == this) {
			__primordial = null;
		}
		#end
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
	#if js
	// When the last frame ran, so the next one can report how long ago that
	// was. The threaded loops measure a frame from inside their own wait;
	// there is no wait here to measure from.
	@:noCompletion private var __lastFrameStamp:Float = 0;
	@:noCompletion private var __frameTimeout:Dynamic = null;
	#if !nodejs
	@:noCompletion private var __frameRequest:Int = 0;
	#end
	#end
	private #if final inline #end function __defaultMainLoop():Void {
#if js
		// No wait at the end, because there is nothing to wait with: the
		// scheduler already asked to be woken at the deadline and gave the
		// thread back in the meantime. What is left is the frame itself.
		var frameStart:Float = Timer.stamp();
		var delta:Float = frameStart - __lastFrameStamp;
		__lastFrameStamp = frameStart;
		__dt = delta;
		__timer.advanceTime(delta);
		__dispatchTick(delta);
		__flushHeld();
		__cpuTime = Timer.stamp() - frameStart;
		#else
		var frameStart:Float = Timer.stamp();
		__timer.advanceTime(__dt);
		__dispatchTick(__dt);
		__flushHeld();
		if (!__getRunning()) {
			return;
		}
		#if !js
		__socketRegistry.update();
		__flushHeld();
		#end

		__cpuTime = __dt = Timer.stamp() - frameStart;
		__wait(frameStart);
		#end
	}
	private #if final inline #end function __pollBasedMainLoop():Void {
#if js
		// Not a gap to be filled later: neither JavaScript target has a socket
		// set to poll. A browser's WebSocket and Node's net sockets both
		// deliver through callbacks, so there is no descriptor to wait on and
		// nothing for a poll budget to spend. The DEFAULT loop is the whole of
		// what a poll loop would do here.
		throw new IllegalOperationError("The POLL main loop needs a pollable socket set, which no JavaScript target has -- sockets there are delivered by the runtime, not polled for. Use the DEFAULT main loop.");
		#else
		var frameStart:Float = Timer.stamp();
		__timer.advanceTime(__dt);
		__dispatchTick(__dt);
		__flushHeld();
		if (!__getRunning()) {
			return;
		}

		__cpuTime = __dt = Timer.stamp() - frameStart;

		if (__socketRegistry.isEmpty) {
			// Nothing to wait on but the clock.
			__wait(frameStart);
			return;
		}

		// Spend what is left of the frame inside poll rather than beside it.
		//
		// This used to poll with a zero timeout and then sleep the remainder
		// out, which meant sockets were serviced exactly once per tick: at the
		// default 12 ticks a second, measured, a socket was polled every 84ms,
		// so data arriving just after a poll waited that long to be seen and a
		// request/response pair could pay it twice. Blocking here instead
		// wakes the loop the moment a descriptor is ready, and returns at the
		// deadline when nothing is, so the tick cadence is unchanged while the
		// latency between the two disappears.
		//
		// The loop re-enters for whatever remains after dispatching, so a
		// frame carrying several arrivals is not cut short by the first. The
		// MIN_POLL_WAIT floor stops that becoming a spin when a backend
		// returns immediately and repeatedly — the failure this replaces was
		// Windows UDP poll doing exactly that with an idle socket registered,
		// which is why the frame wait was kept out of poll's hands
		// originally. Timers cannot be starved by it: the budget is bounded
		// by the frame, and whatever it does not consume is slept off below.
		var remaining:Float = __frameDeadline - Timer.stamp();

		while (remaining >= MIN_POLL_WAIT && __getRunning()) {
			#if !js
			__socketRegistry.update(remaining);
			#end
			__flushHeld();
			remaining = __frameDeadline - Timer.stamp();
		}

		__wait(frameStart);
		#end
	}

	/**
	 * Moves the deadline on by one interval, giving up the debt when the
	 * runtime has fallen further behind than a stall is worth chasing.
	 *
	 * Keeping the debt is what holds the configured rate: a frame that runs
	 * long leaves the next one a shorter wait, so the average lands on the
	 * interval instead of drifting past it. Keeping it without limit is the
	 * other failure — after a suspend or a breakpoint the loop would run a
	 * burst of zero-wait frames trying to repay minutes of debt, starving
	 * everything else to catch up with a schedule nobody is watching. Past
	 * `MAX_SCHEDULE_DEBT`, the stall is declared
	 * unrecoverable and the schedule restarts from now.
	 */
	@:noCompletion private #if final inline #end function __advanceDeadline():Void {
		__frameDeadline += __tickInterval;

		var now:Float = Timer.stamp();
		var cap:Float = MAX_SCHEDULE_DEBT > __tickInterval ? MAX_SCHEDULE_DEBT : __tickInterval;

		if (now - __frameDeadline > cap) {
			__frameDeadline = now + __tickInterval;
		}
	}

	private #if final inline #end function __wait(frameStartTime:Float):Void {
#if js
		#else
		#if precision_tick
		var minSleep = 0.001;

		while (Timer.stamp() < __frameDeadline) {
			if (Timer.stamp() + __sleepAccuracy > __frameDeadline) {
				minSleep = 0;
			}

			Sys.sleep(minSleep);
		}

		__dt = Timer.stamp() - frameStartTime;
		__advanceDeadline();
		#else
		// The bulk of the wait goes in one sleep, and only the last couple of
		// milliseconds are stepped out. Stepping the whole remainder — which
		// is what this did — costs a syscall per millisecond, so better than
		// eighty per frame at the default tick rate, all of them to arrive at
		// the same moment one sleep would have.
		while (true) {
			var remaining:Float = __frameDeadline - Timer.stamp();

			if (remaining <= 0) {
				break;
			}

			Sys.sleep(remaining > SLEEP_SLACK ? remaining - SLEEP_SLACK : 0.001);
		}

		__dt = Timer.stamp() - frameStartTime;
		__advanceDeadline();
		#end
		#end
	}
}
