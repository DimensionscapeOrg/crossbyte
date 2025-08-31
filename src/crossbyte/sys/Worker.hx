package crossbyte.sys;

#if cpp
import cpp.Function;
import crossbyte.core.CrossByte;
import crossbyte.events.ThreadEvent;
import crossbyte.events.TickEvent;
import sys.thread.Deque;
import sys.thread.Thread;
import crossbyte.events.EventDispatcher;

/**
 * ...
 * @author Christopher Speciale
 */
class Worker extends EventDispatcher {
	private static var MESSAGE_COMPLETE = "__COMPLETE__";
	private static var MESSAGE_ERROR = "__ERROR__";

	public var canceled(default, null):Bool;
	public var completed(default, null):Bool;
	public var doWork:Dynamic->Void;

	@:noCompletion private var __runMessage:Dynamic;

	@:noCompletion private var __messageQueue:Deque<Dynamic>;
	@:noCompletion private var __workerThread:Thread;

	public function new() {
		super();
	}

	public function cancel(doClean:Bool = true):Void {
		canceled = true;

		__workerThread = null;
		CrossByte.current().removeEventListener(TickEvent.TICK, __update);

		if (doClean) {
			clean();
		}
	}

	public function clean():Void {
		if (!canceled) {
			cancel();
			canceled = false;
		} else {
			__workerThread = null;
		}

		completed = false;
		__runMessage = null;
		__messageQueue = null;
		doWork = null;
	}

	public function run(message:Dynamic = null):Void {
		canceled = false;
		completed = false;
		__runMessage = message;

		#if (cpp || neko)
		__messageQueue = new Deque<Dynamic>();
		__workerThread = Thread.create(__doWork);

		CrossByte.current().addEventListener(TickEvent.TICK, __update);
		#else
		__doWork();
		#end
	}

	public function sendComplete(message:Dynamic = null):Void {
		completed = true;

		if (!canceled) {
			#if (cpp || neko)
			__messageQueue.add(MESSAGE_COMPLETE);
			__messageQueue.add(message);
			#else
			canceled = true;
			dispatchEvent(new ThreadEvent(ThreadEvent.COMPLETE, message));
			#end
		}
	}

	public function sendError(message:Dynamic = null):Void {
		if (!canceled) {
			#if (cpp || neko)
			__messageQueue.add(MESSAGE_ERROR);
			__messageQueue.add(message);
			#else
			canceled = true;
			dispatchEvent(new ThreadEvent(ThreadEvent.ERROR, message));
			#end
		}
	}

	public function sendProgress(message:Dynamic = null):Void {
		if (!canceled) {
			#if (cpp || neko)
			__messageQueue.add(message);
			#else
			dispatchEvent(new ThreadEvent(ThreadEvent.PROGRESS, message));
			#end
		}
	}

	@:noCompletion private function __doWork():Void {
		// doWork.dispatch(__runMessage);

		if (doWork != null) {
			doWork(__runMessage);
		}
		// #if (cpp || neko)
		//
		// __messageQueue.add (MESSAGE_COMPLETE);
		//
		// #else
		//
		// if (!canceled) {
		//
		// canceled = true;
		// onComplete.dispatch (null);
		//
		// }
		//
		// #end
	}

	@:noCompletion private function __update(dt:Float):Void {
		var deltaTime:Int = Std.int(dt * 1000);
		#if (cpp || neko)
		var message = __messageQueue.pop(false);

		if (message != null) {
			if (message == MESSAGE_ERROR) {
				CrossByte.current().removeEventListener(TickEvent.TICK, __update);

				if (!canceled) {
					canceled = true;
					// onError.dispatch(__messageQueue.pop(false));
					dispatchEvent(new ThreadEvent(ThreadEvent.ERROR, __messageQueue.pop(false)));
				}
			} else if (message == MESSAGE_COMPLETE) {
				CrossByte.current().removeEventListener(TickEvent.TICK, __update);

				if (!canceled) {
					canceled = true;
					// onComplete.dispatch(__messageQueue.pop(false));
					dispatchEvent(new ThreadEvent(ThreadEvent.COMPLETE, __messageQueue.pop(false)));
				}
			} else {
				if (!canceled) {
					// onProgress.dispatch(message);
					dispatchEvent(new ThreadEvent(ThreadEvent.PROGRESS, message));
				}
			}
		}
		#end
	}
}
#end
