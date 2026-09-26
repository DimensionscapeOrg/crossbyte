package crossbyte.sys;

import crossbyte.core.CrossByte;
import crossbyte.errors.IllegalOperationError;
import crossbyte.events.ThreadEvent;
import crossbyte.events.EventDispatcher;
#if target.threaded
import sys.thread.Thread;
import sys.thread.Mutex;
#end

private enum WorkerMessage {
	Complete(message:Dynamic);
	Error(message:Dynamic);
	Progress(message:Dynamic);
}

/**
	Lightweight background worker that reports progress and completion on the
	owning runtime.

	What the work sends is delivered through the owning runtime's post queue,
	which wakes the runtime for it: one post per batch, when the first message
	of a batch arrives. A worker used to hold a tick listener for as long as it
	ran and poll its queue every tick, so a message waited for the next tick --
	up to a whole frame -- and every idle tick paid for every running worker.
**/
class Worker extends EventDispatcher {
	/**
		How many queued messages one worker delivers at a time.

		A worker used to deliver exactly one per tick, so a background job
		reporting progress drained at the runtime's tick rate — twelve a second
		under the default `tps`, however often the host pumped — and a job that
		reported faster than that fell further behind the longer it ran.

		Delivery is bounded rather than unbounded so that one talkative worker
		cannot hold the loop in one go: past the bound, the rest are delivered
		in the runtime's next turn at its queue, after whatever else it has to
		do in between. Set it to `0` or less to deliver everything at once.
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

	#if target.threaded
	// What the work has sent and the runtime has not yet delivered, in order.
	// Replaced by each run, so a drain can tell whether it still belongs to
	// the run that posted it.
	@:noCompletion private var __outbox:Array<WorkerMessage>;
	// Whether a drain is posted and has not yet emptied the outbox: the first
	// message after that posts the next one.
	@:noCompletion private var __drainPosted:Bool;
	@:noCompletion private var __workerThread:Thread;
	// Guards the outbox and the cross-thread lifecycle state (the canceled,
	// cancelRequested, completed, result and error flags) so the worker
	// thread's send* calls cannot race cancel()/clean() on the runtime thread.
	@:noCompletion private var __lock:Mutex;
	#end

	public function new() {
		super();
		#if target.threaded
		__lock = new Mutex();
		#end
		__resetState();
	}

	public function cancel(doClean:Bool = true):Void {
		#if target.threaded
		__lock.acquire();
		cancelRequested = true;
		canceled = true;
		if (!completed && state != FAILED) {
			state = CANCELLED;
		}
		__workerThread = null;
		__lock.release();
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

		#if target.threaded
		__runtime = CrossByte.current();
		__lock.acquire();
		__outbox = [];
		__drainPosted = false;
		__lock.release();
		__workerThread = Thread.create(__doWork);
		#else
		__doWork();
		#end
	}

	public function sendComplete(message:Dynamic = null):Void {
		#if target.threaded
		__lock.acquire();
		if (cancelRequested || canceled) {
			__lock.release();
			return;
		}
		completed = true;
		result = message;
		error = null;
		__send(Complete(message));
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
		#if target.threaded
		__lock.acquire();
		if (cancelRequested || canceled) {
			__lock.release();
			return;
		}
		error = message;
		__send(Error(message));
		#else
		if (cancelRequested || canceled) {
			return;
		}
		error = message;
		__finishFailed(message);
		#end
	}

	public function sendProgress(message:Dynamic = null):Void {
		#if target.threaded
		__lock.acquire();
		if (cancelRequested || canceled) {
			__lock.release();
			return;
		}
		__send(Progress(message));
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
		#if target.threaded
		__lock.acquire();
		__workerThread = null;
		__outbox = null;
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

	#if target.threaded
	// Queues `message` for the owning runtime and posts a drain when this is
	// the first of a batch. Called with __lock held; releases it.
	@:noCompletion private function __send(message:WorkerMessage):Void {
		var outbox:Array<WorkerMessage> = __outbox;
		var runtime:CrossByte = __runtime;
		if (outbox == null || runtime == null) {
			__lock.release();
			return;
		}

		outbox.push(message);
		var post:Bool = !__drainPosted;
		__drainPosted = true;
		__lock.release();

		if (post) {
			runtime.post(() -> __drain(outbox));
		}
	}

	// On the owning runtime's thread: delivers up to maxMessagesPerTick of
	// what the run that owns `outbox` sent, and posts itself again for the
	// rest.
	@:noCompletion private function __drain(outbox:Array<WorkerMessage>):Void {
		var limit:Int = maxMessagesPerTick;

		__lock.acquire();
		// A run since, or a clean(), has replaced the outbox this was posted
		// for: what it held belongs to a run that is over.
		if (__outbox != outbox || cancelRequested) {
			__lock.release();
			return;
		}
		var batch:Array<WorkerMessage>;
		var more:Bool;
		if (limit <= 0 || outbox.length <= limit) {
			batch = outbox.copy();
			outbox.resize(0);
			// Emptied, so the next message sent posts the next drain.
			__drainPosted = false;
			more = false;
		} else {
			batch = outbox.splice(0, limit);
			more = true;
		}
		__lock.release();

		for (message in batch) {
			// Checked again per message rather than trusted from above. A
			// handler dispatched below is free to cancel(), clean() or run()
			// the worker again, which replaces the outbox; delivering the rest
			// of this batch would hand a finished run's messages to its
			// successor.
			//
			// cancelRequested, not canceled. The two are not the same state:
			// canceled is set by __finishCompleted and __finishFailed as well
			// as by cancel(), so it means "no longer running" rather than "was
			// called off", and reading it here says the drain stops because
			// the producer finished -- which is exactly when the last messages
			// still need delivering. What arrives after the run has completed
			// or failed is not delivered, as it never was.
			if (cancelRequested || __outbox != outbox || state != RUNNING) {
				return;
			}

			switch (message) {
				case Error(value):
					if (!canceled) {
						__finishFailed(value);
					}
					return;
				case Complete(value):
					if (!canceled) {
						__finishCompleted(value);
					}
					return;
				case Progress(value):
					dispatchEvent(new ThreadEvent(ThreadEvent.PROGRESS, value));
			}
		}

		if (more) {
			var runtime:CrossByte = __runtime;
			if (runtime != null) {
				runtime.post(() -> __drain(outbox));
			}
		}
	}
	#end
}
