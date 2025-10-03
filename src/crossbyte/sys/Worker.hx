package crossbyte.sys;

import crossbyte.core.CrossByte;
import crossbyte.events.ThreadEvent;
import crossbyte.events.TickEvent;
import crossbyte.events.EventDispatcher;
#if (cpp || neko || hl)
import sys.thread.Deque;
import sys.thread.Thread;
#end

/**
 * ...
 * @author Christopher Speciale
 */
class Worker extends EventDispatcher {
	@:noCompletion private static inline var MESSAGE_COMPLETE:String = "__COMPLETE__";
	@:noCompletion private static inline var MESSAGE_ERROR:String = "__ERROR__";

	public var canceled(default, null):Bool;
	public var completed(default, null):Bool;
	public var doWork:Dynamic->Void;

	@:noCompletion private var __runMessage:Dynamic;

	#if (cpp || neko || hl)
	@:noCompletion private var __messageQueue:Deque<Dynamic>;	
	@:noCompletion private var __workerThread:Thread;
	#end

	public function new() {
		super();
	}

	public function cancel(doClean:Bool = true):Void {
		canceled = true;
		#if (cpp || neko || hl)
		__workerThread = null;
		CrossByte.current().removeEventListener(TickEvent.TICK, __update);
		#end
		if (doClean) {
			clean();
		}
	}

	public function clean():Void {
		#if (cpp || neko || hl)
		__workerThread = null;
		__messageQueue = null;
		#end
		canceled = false;
		completed = false;
		__runMessage = null;
		doWork = null;
	}

	public function run(message:Dynamic = null):Void {
		canceled = false;
		completed = false;
		__runMessage = message;

		#if (cpp || neko || hl)
		__messageQueue = new Deque();
		__workerThread = Thread.create(__doWork);
		CrossByte.current().addEventListener(TickEvent.TICK, __update);
		#else
		__doWork();
		#end
	}

	public function sendComplete(message:Dynamic = null):Void {
		completed = true;
		if (canceled) {
			return;
		}

		#if (cpp || neko || hl)
		__messageQueue.add(MESSAGE_COMPLETE);
		__messageQueue.add(message);
		#else
		canceled = true;
		dispatchEvent(new ThreadEvent(ThreadEvent.COMPLETE, message));
		#end
	}

	public function sendError(message:Dynamic = null):Void {
		if (canceled) {
			return;
		}

		#if (cpp || neko || hl)
		__messageQueue.add(MESSAGE_ERROR);
		__messageQueue.add(message);
		#else
		canceled = true;
		dispatchEvent(new ThreadEvent(ThreadEvent.ERROR, message));
		#end
	}

	public function sendProgress(message:Dynamic = null):Void {
		if (canceled) {
			return;
		}

		#if (cpp || neko || hl)
		__messageQueue.add(message);
		#else
		dispatchEvent(new ThreadEvent(ThreadEvent.PROGRESS, message));
		#end
	}

	@:noCompletion private function __doWork():Void {
		if (doWork != null) {
			doWork(__runMessage);
		}
	}

	#if (cpp || neko || hl)
	@:noCompletion private function __update(dt:Float):Void {
		var msg = __messageQueue.pop(false);

		if (msg == null) {
			return;
		}

		if (msg == MESSAGE_ERROR) {
			CrossByte.current().removeEventListener(TickEvent.TICK, __update);
			
			if (!canceled) {
				canceled = true;
				dispatchEvent(new ThreadEvent(ThreadEvent.ERROR, __messageQueue.pop(false)));
			}
		} else if (msg == MESSAGE_COMPLETE) {
			CrossByte.current().removeEventListener(TickEvent.TICK, __update);
			
			if (!canceled) {
				canceled = true;
				dispatchEvent(new ThreadEvent(ThreadEvent.COMPLETE, __messageQueue.pop(false)));
			}
		} else if (!canceled) {
			dispatchEvent(new ThreadEvent(ThreadEvent.PROGRESS, msg));
		}
	}
	#end
}
