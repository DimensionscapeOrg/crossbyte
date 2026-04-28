package crossbyte.sys;

import crossbyte.core.CrossByte;
import crossbyte.errors.IllegalOperationError;
import crossbyte.events.ThreadEvent;
import crossbyte.events.TickEvent;
import crossbyte.events.EventDispatcher;
#if (cpp || neko || hl)
import sys.thread.Deque;
import sys.thread.Thread;
#end

private enum WorkerMessage {
	Complete(message:Dynamic);
	Error(message:Dynamic);
	Progress(message:Dynamic);
}

/**
 * ...
 * @author Christopher Speciale
 */
class Worker extends EventDispatcher {
	public var canceled(default, null):Bool;
	public var completed(default, null):Bool;
	public var cancelRequested(default, null):Bool;
	public var doWork:Dynamic->Void;
	public var error(default, null):Dynamic;
	public var failed(get, never):Bool;
	public var result(default, null):Dynamic;
	public var running(get, never):Bool;
	public var state(default, null):WorkerState;

	@:noCompletion private var __runMessage:Dynamic;

	#if (cpp || neko || hl)
	@:noCompletion private var __messageQueue:Deque<WorkerMessage>;
	@:noCompletion private var __workerThread:Thread;
	#end

	public function new() {
		super();
		__resetState();
	}

	public function cancel(doClean:Bool = true):Void {
		cancelRequested = true;
		canceled = true;
		if (!completed && state != FAILED) {
			state = CANCELLED;
		}
		#if (cpp || neko || hl)
		__workerThread = null;
		CrossByte.current().removeEventListener(TickEvent.TICK, __update);
		#end
		if (doClean) {
			__cleanResources();
		}
	}

	public function clean():Void {
		#if (cpp || neko || hl)
		CrossByte.current().removeEventListener(TickEvent.TICK, __update);
		#end
		__cleanResources();
		__resetState();
	}

	public function run(message:Dynamic = null):Void {
		if (running) {
			throw new IllegalOperationError("Worker is already running.");
		}

		__resetState();
		state = RUNNING;
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
		if (cancelRequested || canceled) {
			return;
		}

		completed = true;
		result = message;
		error = null;

		#if (cpp || neko || hl)
		if (__messageQueue != null) {
			__messageQueue.add(Complete(message));
		}
		#else
		__finishCompleted(message);
		#end
	}

	public function sendError(message:Dynamic = null):Void {
		if (cancelRequested || canceled) {
			return;
		}

		error = message;

		#if (cpp || neko || hl)
		if (__messageQueue != null) {
			__messageQueue.add(Error(message));
		}
		#else
		__finishFailed(message);
		#end
	}

	public function sendProgress(message:Dynamic = null):Void {
		if (cancelRequested || canceled) {
			return;
		}

		#if (cpp || neko || hl)
		if (__messageQueue != null) {
			__messageQueue.add(Progress(message));
		}
		#else
		dispatchEvent(new ThreadEvent(ThreadEvent.PROGRESS, message));
		#end
	}

	@:noCompletion private inline function get_failed():Bool {
		return state == FAILED;
	}

	@:noCompletion private inline function get_running():Bool {
		return state == RUNNING;
	}

	@:noCompletion private function __cleanResources():Void {
		#if (cpp || neko || hl)
		__workerThread = null;
		__messageQueue = null;
		#end
		__runMessage = null;
		doWork = null;
	}

	@:noCompletion private function __resetState():Void {
		canceled = false;
		cancelRequested = false;
		completed = false;
		error = null;
		result = null;
		state = IDLE;
	}

	@:noCompletion private function __doWork():Void {
		try {
			if (doWork != null) {
				doWork(__runMessage);
			}
		} catch (e:Dynamic) {
			sendError(e);
		}
	}

	@:noCompletion private function __finishCompleted(message:Dynamic):Void {
		completed = true;
		result = message;
		state = COMPLETED;
		canceled = true;
		cancelRequested = false;
		dispatchEvent(new ThreadEvent(ThreadEvent.COMPLETE, message));
	}

	@:noCompletion private function __finishFailed(message:Dynamic):Void {
		error = message;
		state = FAILED;
		canceled = true;
		cancelRequested = false;
		dispatchEvent(new ThreadEvent(ThreadEvent.ERROR, message));
	}

	#if (cpp || neko || hl)
	@:noCompletion private function __update(dt:Float):Void {
		var msg = __messageQueue.pop(false);

		if (msg == null) {
			return;
		}

		switch (msg) {
			case Error(message):
				CrossByte.current().removeEventListener(TickEvent.TICK, __update);
				if (!canceled) {
					__finishFailed(message);
				}
			case Complete(message):
				CrossByte.current().removeEventListener(TickEvent.TICK, __update);
				if (!canceled) {
					__finishCompleted(message);
				}
			case Progress(message):
				if (!canceled) {
					dispatchEvent(new ThreadEvent(ThreadEvent.PROGRESS, message));
				}
		}
	}
	#end
}
