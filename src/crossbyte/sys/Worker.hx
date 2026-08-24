package crossbyte.sys;

import crossbyte.core.CrossByte;
import crossbyte.errors.IllegalOperationError;
import crossbyte.events.ThreadEvent;
import crossbyte.events.TickEvent;
import crossbyte.events.EventDispatcher;
#if (cpp || neko || hl)
import sys.thread.Deque;
import sys.thread.Thread;
import sys.thread.Mutex;
#end

private enum WorkerMessage {
	Complete(message:Dynamic);
	Error(message:Dynamic);
	Progress(message:Dynamic);
}

/** Lightweight background worker that reports progress and completion on the owning runtime. */
class Worker extends EventDispatcher {
	/**
		How many queued messages one worker delivers per tick of its owning runtime.

		A worker used to deliver exactly one, so a background job reporting progress
		drained at the runtime's tick rate — twelve a second under the default `tps`,
		however often the host pumped — and a job that reported faster than that fell
		further behind the longer it ran, with the backlog held in the queue.

		Draining is bounded rather than unbounded so that one talkative worker cannot
		hold the tick and starve the socket poll that follows it. The default is far
		above what any single producer emits between two ticks; set it to `0` or less
		to drain until the queue is empty.
	**/
	public static var maxMessagesPerTick:Int = 256;

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
	@:noCompletion private var __runtime:CrossByte;
	#if (cpp || neko || hl)
	@:noCompletion private var __tickListener:TickEvent->Void;
	#end

	#if (cpp || neko || hl)
	@:noCompletion private var __messageQueue:Deque<WorkerMessage>;
	@:noCompletion private var __workerThread:Thread;
	// Guards the cross-thread lifecycle state (__messageQueue reference plus the
	// canceled/cancelRequested/completed/result/error flags) so the worker
	// thread's send* calls cannot race cancel()/clean() on the runtime thread.
	@:noCompletion private var __lock:Mutex;
	#end

	public function new() {
		super();
		#if (cpp || neko || hl)
		__lock = new Mutex();
		__tickListener = __update;
		#end
		__resetState();
	}

	public function cancel(doClean:Bool = true):Void {
		#if (cpp || neko || hl)
		__lock.acquire();
		cancelRequested = true;
		canceled = true;
		if (!completed && state != FAILED) {
			state = CANCELLED;
		}
		__workerThread = null;
		__lock.release();
		__detachRuntimeListener();
		#else
		cancelRequested = true;
		canceled = true;
		if (!completed && state != FAILED) {
			state = CANCELLED;
		}
		#end
		if (doClean) {
			__cleanResources();
		}
	}

	public function clean():Void {
		#if (cpp || neko || hl)
		__detachRuntimeListener();
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
		__runtime = CrossByte.current();
		__messageQueue = new Deque();
		__workerThread = Thread.create(__doWork);
		__runtime.addEventListener(TickEvent.TICK, __tickListener);
		#else
		__doWork();
		#end
	}

	public function sendComplete(message:Dynamic = null):Void {
		#if (cpp || neko || hl)
		__lock.acquire();
		if (cancelRequested || canceled) {
			__lock.release();
			return;
		}
		completed = true;
		result = message;
		error = null;
		if (__messageQueue != null) {
			__messageQueue.add(Complete(message));
		}
		__lock.release();
		#else
		if (cancelRequested || canceled) {
			return;
		}
		completed = true;
		result = message;
		error = null;
		__finishCompleted(message);
		#end
	}

	public function sendError(message:Dynamic = null):Void {
		#if (cpp || neko || hl)
		__lock.acquire();
		if (cancelRequested || canceled) {
			__lock.release();
			return;
		}
		error = message;
		if (__messageQueue != null) {
			__messageQueue.add(Error(message));
		}
		__lock.release();
		#else
		if (cancelRequested || canceled) {
			return;
		}
		error = message;
		__finishFailed(message);
		#end
	}

	public function sendProgress(message:Dynamic = null):Void {
		#if (cpp || neko || hl)
		__lock.acquire();
		if (cancelRequested || canceled) {
			__lock.release();
			return;
		}
		if (__messageQueue != null) {
			__messageQueue.add(Progress(message));
		}
		__lock.release();
		#else
		if (cancelRequested || canceled) {
			return;
		}
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
		__lock.acquire();
		__workerThread = null;
		__messageQueue = null;
		__lock.release();
		#end
		__runtime = null;
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
	@:noCompletion private inline function __detachRuntimeListener():Void {
		if (__runtime != null) {
			__runtime.removeEventListener(TickEvent.TICK, __tickListener);
		}
	}

	@:noCompletion private function __update(event:TickEvent):Void {
		// A detached tick listener can still fire once under snapshot dispatch,
		// after cancel()/clean() has nulled the queue — guard against that.
		var queue:Deque<WorkerMessage> = __messageQueue;
		if (queue == null) {
			return;
		}

		var limit:Int = maxMessagesPerTick;
		var drained:Int = 0;

		while (limit <= 0 || drained < limit) {
			// Re-read on every pass rather than trusting the reference this tick
			// started with. A handler dispatched below is free to cancel(), clean()
			// or run() the worker again, which nulls this queue or swaps a new one
			// in; draining a queue that is no longer the worker's would deliver a
			// finished run's backlog into its successor.
			// cancelRequested, not canceled. The two are not the same state:
			// canceled is set by __finishCompleted and __finishFailed as well
			// as by cancel(), so it means "no longer running" rather than "was
			// called off", and reading it here says the drain stops because
			// the producer finished -- which is exactly when the last messages
			// still need delivering.
			//
			// No test distinguishes the two, and that is stated rather than
			// implied: cancel() detaches the listener and frees the queue, so
			// the checks above catch that path first, and the completion paths
			// run inside this loop and return immediately after. The change is
			// so the code means what it says. It cost a debugging session to
			// work that out from the old spelling, during a hunt for a lost-
			// message bug that turned out to be in SQLiteConnection.close().
			if (cancelRequested || __messageQueue != queue) {
				return;
			}

			var msg = queue.pop(false);

			if (msg == null) {
				return;
			}

			drained++;

			switch (msg) {
				case Error(message):
					__detachRuntimeListener();
					if (!canceled) {
						__finishFailed(message);
					}
					return;
				case Complete(message):
					__detachRuntimeListener();
					if (!canceled) {
						__finishCompleted(message);
					}
					return;
				case Progress(message):
					dispatchEvent(new ThreadEvent(ThreadEvent.PROGRESS, message));
			}
		}
	}
	#end
}
