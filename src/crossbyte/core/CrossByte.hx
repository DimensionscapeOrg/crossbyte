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
import crossbyte.events.UncaughtErrorEvent;
import crossbyte.utils.Logger;
import haxe.EntryPoint;
import haxe.Timer;
import haxe.ds.Map;
#if target.threaded
import sys.thread.Mutex;
import sys.thread.Thread;
import sys.thread.Tls;
#end
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
	
	#if target.threaded
	// Guards cross-thread access to the list of runtimes (__runtimes) and the
	// published primordial state (__primordial/__primordialThread). Acquired
	// around mutation in __setup()/__runEventLoop()/exit()/__finalizeExit()
	// and around the happens-before publish/read of the primordial fields.
	@:noCompletion private static var __registryLock:Mutex = new Mutex();

	// Every runtime other than the primordial one that has not yet exited.
	// A list rather than a map keyed by thread: eval hands out a new Thread
	// value for every Thread.current() call, so keys by identity never match.
	@:noCompletion private static var __runtimes:Array<CrossByte> = [];

	// Which runtime each thread belongs to. On every threaded target: this
	// used to be native only, and elsewhere current() answered the primordial
	// runtime on every thread, so a child runtime on the jvm registered its
	// sockets and timers with the main one, from the wrong thread.
	@:noCompletion private static var __threadLocalStorage:Tls<CrossByte> = new Tls();
	@:noCompletion private static var __primordialThread:Thread;
	#end

	#if cpp
	@:noCompletion private var __socketRegistry:NativeSocketRegistry;
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
	 * On every threaded target -- native, the jvm, the interpreter, hl and
	 * neko -- a thread with no runtime of its own is refused rather than
	 * handed the primordial one: anything it registered there would be
	 * touched from two threads. JavaScript has one thread and one runtime.
	 *
	 * @return The current thread's CrossByte instance, or the primordial
	 *         application runtime when called from the primordial thread.
	 * @throws IllegalOperationError On a thread no runtime belongs to.
	 */
	public static inline function current():CrossByte {
		#if target.threaded
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

	/**
	 * `current()` without the throw: the thread's runtime, or null on a
	 * thread that has none. For code that has an answer for that case, where
	 * a try/catch around `current()` would cost an exception to find out.
	 */
	@:noCompletion public static function __currentOrNull():Null<CrossByte> {
		#if target.threaded
		var instance:CrossByte = __threadLocalStorage.value;
		if (instance != null) {
			return instance;
		}
		var primordial:CrossByte = __primordial;
		var primordialThread:Thread = __primordialThread;
		return (primordial != null && primordialThread != null && Thread.current() == primordialThread) ? primordial : null;
		#else
		return __primordial;
		#end
	}

	/**
	 * Whether the calling thread is the one this runtime runs on: its loop's
	 * thread, or the thread that pumps it. On JavaScript, always.
	 */
	@:noCompletion public function __isOwnThread():Bool {
		#if target.threaded
		var owner:Thread = __ownerThread;
		return owner != null ? Thread.current() == owner : __currentOrNull() == this;
		#else
		return true;
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

	/**
	 * Timers that are due and still waiting because a frame's timer budget
	 * ran out before it reached them. Zero while the runtime keeps up; a
	 * figure that stays above zero means timers are asking for more time than
	 * a frame has. Counted when read, at a cost proportional to the count.
	 */
	public var timerBacklog(get, never):Int;

	/**
	 * How late the most overdue timer is, in seconds, or zero when none is.
	 */
	public var timerLag(get, never):Float;

	/**
	 * How many frames have run out of timer budget with timers still due,
	 * since the runtime started.
	 */
	public var timerOverruns(get, never):Int;

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
	@:noCompletion private var __timerOverruns:Int = 0;

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

	/**
	 * When the current frame began. A field rather than a local of the loop
	 * body so that a frame cut short by a failure can still be waited out
	 * from where it started.
	 */
	@:noCompletion private var __frameStart:Float = 0.0;

	// Set while UNCAUGHT_ERROR is being dispatched, so a listener for it that
	// throws is logged rather than reported through itself.
	@:noCompletion private var __reportingUncaught:Bool = false;
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

	// What another thread handed this runtime to run on its own; see __post.
	// The flag is read each tick without the lock: a stale false costs one
	// tick, and a runtime nobody posts to pays a field read.
	@:noCompletion private var __posted:Null<Array<Void->Void>> = null;
	@:noCompletion private var __hasPosted:Bool = false;
	#if target.threaded
	@:noCompletion private final __postLock:Mutex = new Mutex();
	#end
	#if js
	@:noCompletion private var __passFlushScheduled:Bool = false;
	@:noCompletion private var __passFlushTurn:Void->Void = null;
	#end

	#if cpp
	@:noCompletion private var __threadPriority:ThreadPriority = NORMAL;
	#end
	#if target.threaded
	// The thread this runtime is bound to (its loop thread, or the host pump
	// thread). exit() deregisters the runtime even when called from another
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
		#if target.threaded
		__registryLock.acquire();
		if (!__didDeregister) {
			__didDeregister = true;
			__runtimes.remove(this);
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

		#if target.threaded
		__ownerThread = Thread.current();
		__threadLocalStorage.value = this;
		#end
		CBTimer.bindCurrentThread(__timer);
		__dispatchInitIfNeeded();

		if (!__getRunning()) {
			__finalizeExit();
			return;
		}

		// Contained here as well as per callback, for what fails between
		// them -- a flush, a poll. A host's own frame is the last place a
		// CrossByte handler's failure should surface.
		try {
			__stepHost(delta, socketTimeout);
		} catch (error:Dynamic) {
			__uncaught(error, UncaughtErrorEvent.LOOP);
		}

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
		__advanceTimers(delta);
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
		Runs `callback` on this runtime's thread, at the start of its next tick.
		Safe from any thread: the one way to hand a runtime something from
		another.

		What a runtime owns -- its sockets, its event listeners -- is not
		thread-safe, so code finishing on another thread has to come back to
		the owner's before touching them. Each component used to do that with
		a tick listener of its own, attached on the owner's thread for exactly
		that reason; this is one queue for all of them, costing a runtime
		nobody posts to a field read a tick.

		The loop does not wake early for it: a callback posted mid-frame waits
		for the next tick, as a `Worker` or `Task` result does. What throws is
		reported like any other callback's failure -- logged, and dispatched
		as `UncaughtErrorEvent.UNCAUGHT_ERROR` -- and does not stop the rest.
	**/
	@:noCompletion public function __post(callback:Void->Void):Void {
		#if target.threaded
		__postLock.acquire();
		#end
		if (__posted == null) {
			__posted = [];
		}
		__posted.push(callback);
		__hasPosted = true;
		#if target.threaded
		__postLock.release();
		#end
	}

	@:noCompletion private function __runPosted():Void {
		#if target.threaded
		__postLock.acquire();
		#end
		final batch = __posted;
		__posted = null;
		__hasPosted = false;
		#if target.threaded
		__postLock.release();
		#end

		if (batch == null) {
			return;
		}
		for (callback in batch) {
			try {
				callback();
			} catch (error:Dynamic) {
				__uncaught(error, UncaughtErrorEvent.POSTED);
			}
		}
	}

	/**
		Reports something a callback threw that nothing caught, once the
		runtime has contained it: logs it with `Logger.error`, then dispatches
		`UncaughtErrorEvent.UNCAUGHT_ERROR` on this runtime.

		The runtime calls this for every callback it runs itself -- timers,
		tick and lifecycle listeners, socket handlers, posted callbacks, and
		the loop around them. Public for code that delivers callbacks of its
		own on the runtime's behalf, such as a socket fed by the platform's
		event loop rather than by this runtime's poll, so that a failure
		there is reported the same way rather than ending the process.

		@param source Where it was caught: one of the `UncaughtErrorEvent`
		       source constants.
		@param origin What the failing callback belonged to, if known.
	**/
	@:noCompletion public function __uncaught(error:Dynamic, source:String, ?origin:Dynamic):Void {
		// Read before anything below can catch something else and replace it.
		var stack:String = __caughtStack();

		// Logged first and unconditionally, since a listener may be the very
		// thing that is broken. A sink that throws is not allowed to turn one
		// contained failure into an escaping one.
		try {
			var fields:Map<String, String> = ["source" => source];
			var from:String = __describeOrigin(origin);
			if (from != null) {
				fields.set("origin", from);
			}
			if (stack != null) {
				fields.set("stack", stack);
			}
			Logger.error(__uncaughtMessage(source) + ": " + Std.string(error), fields);
		} catch (_:Dynamic) {}

		if (__reportingUncaught || !hasEventListener(UncaughtErrorEvent.UNCAUGHT_ERROR)) {
			return;
		}

		// A listener for this that throws is logged by `__listenerThrew` and
		// not reported again, so a broken reporter cannot recurse.
		__reportingUncaught = true;
		__dispatchContained(new UncaughtErrorEvent(UncaughtErrorEvent.UNCAUGHT_ERROR, error, source, origin));
		__reportingUncaught = false;
	}

	@:noCompletion private static function __uncaughtMessage(source:String):String {
		return switch (source) {
			case UncaughtErrorEvent.TIMER: "A timer callback threw; the timer was kept and the runtime carries on";
			case UncaughtErrorEvent.TICK: "A tick listener threw; the other listeners still ran";
			case UncaughtErrorEvent.LIFECYCLE: "A lifecycle listener threw; the other listeners still ran";
			case UncaughtErrorEvent.SOCKET: "A socket handler threw; that socket is closed and the others carry on";
			case UncaughtErrorEvent.POSTED: "A callback posted to the runtime threw";
			default: "The runtime loop threw; the frame was cut short and the loop carries on";
		}
	}

	@:noCompletion private static function __caughtStack():Null<String> {
		try {
			var stack = haxe.CallStack.exceptionStack();
			return stack == null || stack.length == 0 ? null : haxe.CallStack.toString(stack);
		} catch (_:Dynamic) {
			return null;
		}
	}

	@:noCompletion private static function __describeOrigin(origin:Dynamic):Null<String> {
		if (origin == null) {
			return null;
		}

		try {
			if (Std.isOfType(origin, CBSocket)) {
				var socket:CBSocket = cast origin;
				return Type.getClassName(Type.getClass(origin)) + " " + socket.remoteAddress + ":" + socket.remotePort;
			}
			var type = Type.getClass(origin);
			return type != null ? Type.getClassName(type) : Std.string(origin);
		} catch (_:Dynamic) {
			return null;
		}
	}

	@:noCompletion private function __timerThrew(error:Dynamic):Void {
		__uncaught(error, UncaughtErrorEvent.TIMER);
	}

	#if !js
	/**
		A socket's handler threw. The failure is reported, and then a stream
		socket is closed: its handler stopped partway through what it had
		read, and a connection whose state is whatever that left is not one
		to keep serving. Closing it dispatches `CLOSE`, so whatever the
		application holds for the connection is released the usual way.

		A datagram socket is not closed. It is usually the one socket a whole
		UDP service answers on, each datagram arrives whole with nothing left
		half-read, and closing it would turn one bad datagram into an outage
		for every peer -- the opposite of containing it.
	**/
	@:noCompletion private function __socketThrew(error:Dynamic, socket:crossbyte._internal.socket.IPollableSocket):Void {
		__uncaught(error, UncaughtErrorEvent.SOCKET, socket);

		if (Std.isOfType(socket, CBSocket) && !socket.registryClosed) {
			try {
				(cast socket : CBSocket).close();
			} catch (closeError:Dynamic) {
				__uncaught(closeError, UncaughtErrorEvent.SOCKET, socket);
			}
		}
	}
	#end

	@:noCompletion override private function __listenerThrew(error:Dynamic, event:Event):Void {
		if (__reportingUncaught) {
			// An UNCAUGHT_ERROR listener: logged, never reported again.
			try {
				Logger.error("An uncaughtError listener threw: " + Std.string(error));
			} catch (_:Dynamic) {}
			return;
		}

		__uncaught(error, event.type == TickEvent.TICK ? UncaughtErrorEvent.TICK : UncaughtErrorEvent.LIFECYCLE);
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
		// and that one belongs to this pass too. A holder that throws is
		// reported and the walk goes on: this used to rethrow, leaving the
		// rest for a next pass that the throw had just cancelled along with
		// the loop.
		__flushingPass = true;
		while (__passFlushAt < __passFlushes.length) {
			var item:PassFlush = __passFlushes[__passFlushAt];
			__passFlushes[__passFlushAt] = null;
			__passFlushAt++;
			try {
				item.__flushPass();
			} catch (error:Dynamic) {
				__uncaught(error, UncaughtErrorEvent.LOOP, item);
			}
		}
		__passFlushes.resize(0);
		__passFlushAt = 0;
		__flushingPass = false;
	}

	@:noCompletion private inline function get_uptime():Float {
		return __timer.time;
	}

	/**
	 * Fires the timers due this frame, within a budget of one tick interval.
	 *
	 * Every due timer fires; there used to be a cap of 256 a frame, which a
	 * runtime with more than that due -- a few hundred sessions each keeping
	 * a 50ms retransmit clock -- could never catch up with, so every timer
	 * ran later the longer it stayed up. The budget is what bounds a pass
	 * now: time, not a count, and only reached by a burst that would
	 * otherwise hold the frame past its end and keep the sockets waiting.
	 * What it leaves fires next frame and is counted by `timerBacklog`.
	 */
	@:noCompletion private inline function __advanceTimers(dt:Float):Void {
		__timer.advanceTime(dt, 0x7FFFFFFF, __tickInterval);
		if (__timer.cutShort) {
			__timerOverruns++;
		}
	}

	@:noCompletion private function get_timerBacklog():Int {
		return __timer.overdue();
	}

	@:noCompletion private function get_timerLag():Float {
		var due:Null<Float> = __timer.nextDue();
		if (due == null) {
			return 0.0;
		}
		var behind:Float = __timer.time - due;
		return behind > 0 ? behind : 0.0;
	}

	@:noCompletion private inline function get_timerOverruns():Int {
		return __timerOverruns;
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
		__socketRegistry = new NativeSocketRegistry(__initialSocketCapacity());
		#elseif !js
		__socketRegistry = new SocketRegistry(__initialSocketCapacity());
		#end
		#if !js
		__socketRegistry.onHandlerError = __socketThrew;
		#end

		__timer = new TimerScheduler(__timerStrategy);
		__timer.onError = __timerThrew;
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
			#if target.threaded
			// Publish registry + primordial state under the lock so it is visible
			// (happens-before) to any threads that later read it via current().
			var currentThread:Thread = Thread.current();
			__registryLock.acquire();
			if (__isPrimordial) {
				__primordial = this;
				__primordialThread = currentThread;
			} else {
				__runtimes.push(this);
			}
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
			#if target.threaded
			// Publish primordial state under the lock before any child runtimes
			// (and their threads) can be created, establishing happens-before for
			// reads through current().
			var t:Thread = Thread.current();
			__registryLock.acquire();
			__primordial = this;
			__primordialThread = t;
			__registryLock.release();
			#else
			__primordial = this;
			#end
			__adoptEarlyTimers();
		} else {
			#if target.threaded
			__registryLock.acquire();
			__runtimes.push(this);
			__registryLock.release();
			#end
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

		#if target.threaded
		__ownerThread = Thread.current();
		__threadLocalStorage.value = this;
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
			// Each callback the loop runs is contained where it runs; this is
			// for what fails between them. Whatever it was, the loop goes on:
			// ending it here would skip EXIT, the final flush and every other
			// connection, for one failure.
			try {
				mainLoop();
			} catch (error:Dynamic) {
				__uncaught(error, UncaughtErrorEvent.LOOP);
				__afterLoopFailure();
			}
		}
		__finalizeExit();
		#end
	}

	/**
	 * Waits out what is left of a frame a failure cut short. Without it a
	 * failure that recurs every pass -- a broken poll backend, a custom loop
	 * body with a bug -- would skip the wait each time and spin a core
	 * logging it, where this costs a line per tick.
	 */
	@:noCompletion private function __afterLoopFailure():Void {
		#if !js
		// A custom loop body never marks where its frames begin; measure from
		// now, rather than from zero, so the next frame is not told that every
		// second since the clock's origin has just elapsed.
		try {
			__wait(__frameStart != 0 ? __frameStart : Timer.stamp());
		} catch (_:Dynamic) {}
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
			// A throw here would leave the platform's own loop to report it,
			// which on Node ends the process and in a page stops the runtime
			// for good: the next frame is only asked for below.
			try {
				mainLoop();
			} catch (error:Dynamic) {
				__uncaught(error, UncaughtErrorEvent.LOOP);
			}

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
				__dispatchContained(new Event(Event.INIT));
			}
		}
	}

	@:noCompletion private inline function __dispatchTick(delta:Float):Void {
		if (__hasPosted) {
			__runPosted();
		}

		if (!hasEventListener(TickEvent.TICK)) {
			return;
		}

		// Contained per listener: the listeners on a runtime's tick belong to
		// unrelated components, and one's failure skipped every listener after
		// it and then ended the loop.
		if (__pooledTickEventInUse) {
			__dispatchContained(new TickEvent(TickEvent.TICK, delta));
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
		__dispatchContained(__pooledTickEvent);
		__pooledTickEventInUse = false;
	}

	// Hands the thread's current runtime back when it still points at this stopped
	// instance. __finalizeExit does this too, but only on the one call that flips
	// __didExit, so it cannot repair a claim made after that.
	@:noCompletion private function __releaseThreadLocal():Void {
		#if target.threaded
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
			__dispatchContained(new Event(Event.EXIT));
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
		#if target.threaded
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
		__advanceTimers(delta);
		__dispatchTick(delta);
		__flushHeld();
		__cpuTime = Timer.stamp() - frameStart;
		#else
		var frameStart:Float = __frameStart = Timer.stamp();
		__advanceTimers(__dt);
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
		var frameStart:Float = __frameStart = Timer.stamp();
		__advanceTimers(__dt);
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
