package crossbyte.core;

import crossbyte.events.Event;
import crossbyte.events.EventDispatcher;
import crossbyte.events.EventType;
import sys.thread.Thread;

@:access(crossbyte.core.CrossByte)
class Application extends EventDispatcher {
	public static var application(get, never):Application;
	private static var __application:Application;
	private static var __mainThread:Thread = Thread.current();

	public static function addGlobalListener<T>(type:EventType<T>, listener:T->Void, priority:Int = 0):Void {
		if (__application != null) {
			__application.addEventListener(type, listener);
		} else {
			throw("Application instance is not initialized.");
		}
	}

	public static function removeGlobalListener<T>(type:EventType<T>, listener:T->Void, priority:Int = 0):Void {
		if (__application != null) {
			__application.removeEventListener(type, listener);
		} else {
			throw("Application instance is not initialized.");
		}
	}

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

	public var crossByte(get, never):CrossByte;

	private var __crossByte:CrossByte;

	private inline function get_crossByte():CrossByte {
		return __crossByte;
	}

	private function new() {
		super();

		initialize();
	}

	private function initialize():Void {
		if (__application != null) {
			throw "Application must only be instantiated once by extending it.";
		}

		// Ensure we're in the main thread
		if (Thread.current() != __mainThread) {
			throw "Application must only be instantiated in the main thread!";
		}

		__application = this;
		__crossByte = new CrossByte(true);
		__crossByte.addEventListener(Event.INIT, __onInit);
		__crossByte.addEventListener(Event.EXIT, __onExit);
	}

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
