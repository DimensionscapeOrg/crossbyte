package crossbyte.core;

import crossbyte.events.Event;
import crossbyte.events.EventDispatcher;
import crossbyte.events.EventType;
import crossbyte.core.MainLoopType;
import sys.thread.Thread;

/**
 * The base primordial CrossByte application.
 *
 * Extend `Application` when CrossByte should own the primary application
 * runtime on the process main thread using its default main-loop behavior.
 *
 * This class establishes:
 * - the single primordial `CrossByte` instance
 * - the global application event dispatcher
 * - the root runtime context used by child CrossByte instances
 *
 * Choose a more specific application type when appropriate:
 * - use `HostApplication` when another framework already owns the main thread
 *   and CrossByte must be advanced from that host's update loop
 * - use `ServerApplication` for a primordial poll-driven server runtime
 *
 * Additional threaded CrossByte runtimes should be created as child instances
 * via `CrossByte.make(...)` after the primordial application has been
 * established.
 */
@:access(crossbyte.core.CrossByte)
class Application extends EventDispatcher {
	public static var application(get, never):Application;
	private static var __application:Application;
	private static var __mainThread:Thread = Thread.current();

	/**
	 * Adds an event listener to the global application dispatcher.
	 *
	 * This is a convenience wrapper around the singleton `Application`
	 * instance so callers can subscribe to application-wide events without
	 * holding a direct reference to the primordial application object.
	 *
	 * @param type The event type to listen for.
	 * @param listener The callback to invoke when the event is dispatched.
	 * @param priority The listener priority. Higher values run first.
	 */
	public static function addGlobalListener<T>(type:EventType<T>, listener:T->Void, priority:Int = 0):Void {
		if (__application != null) {
			__application.addEventListener(type, listener);
		} else {
			throw("Application instance is not initialized.");
		}
	}

	/**
	 * Removes an event listener from the global application dispatcher.
	 *
	 * @param type The event type originally registered.
	 * @param listener The listener callback to remove.
	 * @param priority The listener priority that was used during registration.
	 */
	public static function removeGlobalListener<T>(type:EventType<T>, listener:T->Void, priority:Int = 0):Void {
		if (__application != null) {
			__application.removeEventListener(type, listener);
		} else {
			throw("Application instance is not initialized.");
		}
	}

	/**
	 * Dispatches an event through the global application dispatcher.
	 *
	 * @param event The event instance to dispatch.
	 */
	public static function dispatchGlobalEvent<T:Event>(event:T):Void {
		if (__application != null) {
			__application.dispatchEvent(event);
		} else {
			throw("Application instance is not initialized.");
		}
	}

	private static inline function get_application():Application {
		return __application;
	}

	/**
	 * The primordial CrossByte runtime owned by this application.
	 */
	public var crossByte(get, never):CrossByte;

	private var __crossByte:CrossByte;
	private var __crossByteHostDriven:Bool;
	private var __crossByteLoopType:MainLoopType;

	private inline function get_crossByte():CrossByte {
		return __crossByte;
	}

	/**
	 * Creates the primordial application.
	 *
	 * `loopType` and `hostDriven` are framework-level configuration details
	 * used by specialized subclasses such as `ServerApplication` and
	 * `HostApplication`.
	 *
	 * @param loopType The main-loop strategy for the primordial `CrossByte`.
	 * @param hostDriven Whether the host application, rather than CrossByte,
	 *        is responsible for advancing the primordial runtime.
	 */
	private function new(loopType:MainLoopType = DEFAULT, hostDriven:Bool = false) {
		super();
		__crossByteLoopType = loopType;
		__crossByteHostDriven = hostDriven;

		initialize();
	}

	/**
	 * Initializes the primordial application and its root CrossByte runtime.
	 *
	 * This may only happen once, and it must happen on the process main thread.
	 */
	private function initialize():Void {
		if (__application != null) {
			throw "Application must only be instantiated once by extending it.";
		}

		// Ensure we're in the main thread
		if (Thread.current() != __mainThread) {
			throw "Application must only be instantiated in the main thread!";
		}

		__application = this;
		__crossByte = new CrossByte(true, __crossByteLoopType, __crossByteHostDriven);
		__crossByte.addEventListener(Event.INIT, __onInit);
		__crossByte.addEventListener(Event.EXIT, __onExit);
	}

	/**
	 * Shuts down the primordial CrossByte runtime.
	 *
	 * This requests orderly application teardown and eventually dispatches the
	 * normal CrossByte exit event sequence.
	 */
	public function shutdown():Void {
		if (__crossByte != null) {
			__crossByte.exit();
		}
	}

	private function __cleanup():Void {
		__crossByte = null;
		__application.removeAllListeners();
		__application = null;
	}

	private function __onInit(evt:Event):Void {
		__crossByte.removeEventListener(Event.INIT, __onInit);
		dispatchEvent(evt);
	}

	private function __onExit(evt:Event):Void {
		__crossByte.removeEventListener(Event.EXIT, __onExit);
		dispatchEvent(evt);
		__cleanup();
	}
}
