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
	A `Worker` whose messages have types: `In` is what `run` hands `doWork`,
	`Out` what `sendComplete` reports and `result` holds, `Progress` what
	`sendProgress` reports.

	```haxe
	var hasher = new TypedWorker<String, Int, Float>();
	hasher.doWork = path -> {
		hasher.sendProgress(0.5);
		hasher.sendComplete(path.length);
	};
	hasher.onProgress(fraction -> trace(fraction));
	hasher.onComplete(size -> trace(size));
	hasher.run("data.bin");
	```

	The events are the same `ThreadEvent`s a `Worker` dispatches, whose
	`message` is untyped; `onProgress` and `onComplete` hand the message to a
	typed handler. The types are the compiler's only: at run time this is a
	`Worker`, and costs nothing more.
**/
class TypedWorker<In, Out, Progress> extends EventDispatcher {
	public var canceled(default, null):Bool;
	public var completed(default, null):Bool;
	public var cancelRequested(default, null):Bool;
	public var doWork:In->Void;
	public var error(default, null):Dynamic;
	public var failed(get, never):Bool;
	public var result(default, null):Null<Out>;
	public var running(get, never):Bool;
	public var state(default, null):WorkerState;

	@:noCompletion private var __runMessage:Null<In>;
	@:noCompletion private var __runtime:CrossByte;

	#if (target.threaded || js)
	// What the work has sent and the runtime has not yet taken, in order.
	// Made by each run and dropped by clean(); null between them.
	@:noCompletion private var __outbox:Array<WorkerMessage>;
	// Whether a drain is posted and has not yet emptied the outbox: the first
	// message after that posts the next one.
	@:noCompletion private var __drainPosted:Bool;
	// Which run this is, so a drain posted for an earlier one does nothing.
	@:noCompletion private var __runCount:Int = 0;
	// The runtime's side, touched only on its thread: what a drain took from
	// the outbox, and how far delivery has come through it. A drain takes
	// the whole outbox at once, swapping in an empty array, and delivers up
	// to maxMessagesPerTick of it a turn. It used to splice each turn's share
	// off the front of the outbox, moving everything behind it: a backlog of
	// a million messages cost hundreds of billions of moves to deliver.
	@:noCompletion private var __taken:Array<WorkerMessage> = null;
	@:noCompletion private var __takenAt:Int = 0;
	#end
	#if target.threaded
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
		// Made here, before any thread can write this object. A neko object
		// gains a field when it is first set, which can move its field table,
		// and run() first set this one just after starting the thread: work
		// that cancelled itself at once wrote CANCELLED into the table being
		// left, and the worker read RUNNING for good (35 runs in 20,000).
		__workerThread = null;
		#end
		__resetState();
	}

	public function cancel(doClean:Bool = true):Void {
		__acquire();
		cancelRequested = true;
		canceled = true;
		// By the state, not by `completed`: sendComplete sets that as the work
		// sends, and a completion not yet delivered is discarded by the drain
		// once this is called, which then set nothing -- the worker read
		// RUNNING for good, and run() refused it.
		if (state != COMPLETED && state != FAILED) {
			state = CANCELLED;
		}
		#if target.threaded
		__workerThread = null;
		#end
		__release();
		if (doClean) {
			__cleanResources();
		}
	}

	public function clean():Void {
		__cleanResources();
		__resetState();
	}

	public function run(?message:In):Void {
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
		__runCount++;
		__lock.release();
		__taken = null;
		__takenAt = 0;
		__workerThread = Thread.create(__doWork);
		#elseif js
		// Here and now, on the one thread there is. What it sends goes to the
		// outbox and is delivered in a later turn, as from a thread: it was
		// dispatched inside run(), before a listener added after it could hear.
		__outbox = [];
		__drainPosted = false;
		__runCount++;
		__taken = null;
		__takenAt = 0;
		__doWork();
		#else
		__doWork();
		#end
	}

	public function sendComplete(?message:Out):Void {
		#if (target.threaded || js)
		__acquire();
		if (cancelRequested || canceled) {
			__release();
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
		#if (target.threaded || js)
		__acquire();
		if (cancelRequested || canceled) {
			__release();
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

	public function sendProgress(?message:Progress):Void {
		#if (target.threaded || js)
		__acquire();
		if (cancelRequested || canceled) {
			__release();
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

	/**
		Calls `handler` with each progress message, as `ThreadEvent.PROGRESS`
		is dispatched. Returns this worker, so calls chain.
	**/
	public function onProgress(handler:Progress->Void):TypedWorker<In, Out, Progress> {
		addEventListener(ThreadEvent.PROGRESS, (event:ThreadEvent) -> handler(event.message));
		return this;
	}

	/**
		Calls `handler` with the completion message, as `ThreadEvent.COMPLETE`
		is dispatched. Returns this worker, so calls chain.
	**/
	public function onComplete(handler:Out->Void):TypedWorker<In, Out, Progress> {
		addEventListener(ThreadEvent.COMPLETE, (event:ThreadEvent) -> handler(event.message));
		return this;
	}

	@:noCompletion private inline function get_failed():Bool {
		return state == FAILED;
	}

	@:noCompletion private inline function get_running():Bool {
		return state == RUNNING;
	}

	@:noCompletion private function __cleanResources():Void {
		__acquire();
		#if target.threaded
		__workerThread = null;
		#end
		#if (target.threaded || js)
		__outbox = null;
		#end
		__release();
		__runtime = null;
		__runMessage = null;
		doWork = null;
	}

	// The lock where there are threads to need it, and nothing where there
	// are not.
	@:noCompletion private inline function __acquire():Void {
		#if target.threaded
		__lock.acquire();
		#end
	}

	@:noCompletion private inline function __release():Void {
		#if target.threaded
		__lock.release();
		#end
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

	@:noCompletion private function __finishCompleted(message:Null<Out>):Void {
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

	#if (target.threaded || js)
	// Queues `message` for the owning runtime and posts a drain when this is
	// the first of a batch -- on JavaScript, for a later turn. Called with the
	// lock held; releases it.
	@:noCompletion private function __send(message:WorkerMessage):Void {
		var outbox:Array<WorkerMessage> = __outbox;
		#if target.threaded
		var runtime:CrossByte = __runtime;
		if (outbox == null || runtime == null) {
			__release();
			return;
		}
		#else
		if (outbox == null) {
			__release();
			return;
		}
		#end

		outbox.push(message);
		var post:Bool = !__drainPosted;
		__drainPosted = true;
		var run:Int = __runCount;
		__release();

		if (post) {
			#if js
			CrossByte.__nextTurn(() -> __drain(run));
			#else
			runtime.post(() -> __drain(run));
			#end
		}
	}

	// On the owning runtime's thread: delivers up to maxMessagesPerTick of
	// what the run numbered `run` sent, and posts itself again for the rest.
	@:noCompletion private function __drain(run:Int):Void {
		var limit:Int = Worker.maxMessagesPerTick;

		__acquire();
		// A run since, or a clean(), has replaced the outbox this was posted
		// for: what it held belongs to a run that is over.
		if (__runCount != run || __outbox == null || cancelRequested) {
			__release();
			return;
		}
		var taken:Array<WorkerMessage> = __taken;
		if (taken == null || __takenAt >= taken.length) {
			// Everything sent so far, taken at once; the emptied array goes
			// back as the outbox, so the two are reused rather than made.
			var spare:Array<WorkerMessage> = taken;
			taken = __outbox;
			if (spare == null) {
				spare = [];
			} else {
				spare.resize(0);
			}
			__outbox = spare;
			__taken = taken;
			__takenAt = 0;
		}
		var end:Int = (limit <= 0 || taken.length - __takenAt <= limit) ? taken.length : __takenAt + limit;
		var more:Bool = end < taken.length || __outbox.length > 0;
		if (!more) {
			// Emptied, so the next message sent posts the next drain.
			__drainPosted = false;
		}
		__release();

		while (__takenAt < end) {
			var message:WorkerMessage = taken[__takenAt];
			taken[__takenAt] = null;
			__takenAt++;

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
			if (cancelRequested || __runCount != run || __outbox == null || state != RUNNING) {
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
			#if js
			CrossByte.__nextTurn(() -> __drain(run));
			#else
			var runtime:CrossByte = __runtime;
			if (runtime != null) {
				runtime.post(() -> __drain(run));
			}
			#end
		}
	}
	#end
}
