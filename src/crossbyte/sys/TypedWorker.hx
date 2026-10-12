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
	/**
		Whether the work has called `sendComplete`. Set as the work sends it,
		so it can be `true` a moment before `ThreadEvent.COMPLETE` is
		dispatched and `state` becomes `COMPLETED`.
	**/
	public var completed(default, null):Bool;

	/** Whether `cancel()` has been called since the last `run()` or `clean()`. **/
	public var cancelRequested(default, null):Bool;

	/**
		The work `run()` starts, handed the message `run()` was given. It
		reports through `sendProgress`, `sendComplete` and `sendError`; what
		it throws is reported as `sendError` reports it.
	**/
	public var doWork:In->Void;

	/** What the work sent with `sendError`, or threw. **/
	public var error(default, null):Dynamic;

	/** Whether the last run failed: `state` is `FAILED`. **/
	public var failed(get, never):Bool;

	/** What the work sent with `sendComplete`. **/
	public var result(default, null):Null<Out>;

	/** Whether a run is under way: `state` is `RUNNING`. `run()` refuses a worker that is. **/
	public var running(get, never):Bool;

	/**
		Where the worker is: `IDLE` until `run()`, `RUNNING` while the work
		goes on, then `COMPLETED`, `FAILED` or `CANCELLED` as its run ends:
		the first two as the run's last message is delivered, the third by
		`cancel()`.
	**/
	public var state(default, null):WorkerState;

	// Whether the run is over, however it ended: set by cancel(), and as the
	// run completes or fails. What the work sends after that is dropped.
	@:noCompletion private var __over:Bool;
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
	// to maxMessagesPerTick of it a turn, rather than splicing each turn's
	// share off the front of the outbox and moving everything behind it.
	@:noCompletion private var __taken:Array<WorkerMessage> = null;
	@:noCompletion private var __takenAt:Int = 0;
	#end
	#if target.threaded
	@:noCompletion private var __workerThread:Thread;
	// Guards the outbox and the cross-thread lifecycle state (the __over,
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

	/**
		Calls the run off. The work's thread is not stopped: what it sends
		from here on is dropped, and nothing more is dispatched for the run.
		`state` becomes `CANCELLED`, unless the run had already completed or
		failed. With `doClean`, what the run had sent and was not yet
		delivered is let go of as well.
	**/
	public function cancel(doClean:Bool = true):Void {
		__acquire();
		cancelRequested = true;
		__over = true;
		// By the state, not by `completed`: sendComplete sets that as the work
		// sends, and a completion not yet delivered is discarded by the drain
		// once this is called, which would then set nothing, leaving the
		// worker RUNNING for good and run() refusing it.
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

	/**
		Lets go of what the last run left (its undelivered messages, `result`
		and `error`) and makes the worker `IDLE` again, every flag `false`.
	**/
	public function clean():Void {
		__cleanResources();
		__resetState();
	}

	/**
		Runs `doWork` with `message`: on a thread of its own where there are
		threads, and here, holding this thread, on JavaScript.

		A message of bytes (a `ByteArray` or `haxe.io.Bytes`) is copied
		before this returns, from 0 to its `length`, and `doWork` is handed
		the copy: the thread reads it later, and the caller's bytes are the
		caller's again at once, as a payload a listener was handed for its
		call alone is. Anything else is handed over as it is, to be read on
		the other thread: a structure holding such a payload holds a copy
		of it, or the thread reads what it has become (see
		`crossbyte.events.Event`).
	**/
	public function run(?message:In):Void {
		if (running) {
			throw new IllegalOperationError("Worker is already running.");
		}

		__resetState();
		state = RUNNING;
		__runMessage = __handedOver(message);

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
		// outbox and is delivered in a later turn, as from a thread, so a
		// listener added after run() hears it.
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

	/**
		`message` as `run` hands it to the work: bytes copied (a `ByteArray`
		at the same position, in the same byte order and object encoding),
		and anything else as it is.
	**/
	@:noCompletion private static function __handedOver<T>(message:Null<T>):Null<T> {
		if (message == null) {
			return message;
		}
		if (Std.isOfType(message, crossbyte.io.ByteArray.ByteArrayData)) {
			return cast crossbyte.events._internal.Arrivals.copyOf(cast message);
		}
		if (Std.isOfType(message, haxe.io.Bytes)) {
			var bytes:haxe.io.Bytes = cast message;
			return cast bytes.sub(0, bytes.length);
		}
		return message;
	}

	/**
		For the work: ends the run with `message`, which listeners hear as
		`ThreadEvent.COMPLETE` on the runtime that called `run()`. Dropped
		once the run is over.
	**/
	public function sendComplete(?message:Out):Void {
		#if (target.threaded || js)
		__acquire();
		if (cancelRequested || __over) {
			__release();
			return;
		}
		completed = true;
		result = message;
		error = null;
		__send(Complete(message));
		#else
		if (cancelRequested || __over) {
			return;
		}
		completed = true;
		result = message;
		error = null;
		__finishCompleted(message);
		#end
	}

	/**
		For the work: ends the run as failed, with `message`, which listeners
		hear as `ThreadEvent.ERROR`. Dropped once the run is over.
	**/
	public function sendError(message:Dynamic = null):Void {
		#if (target.threaded || js)
		__acquire();
		if (cancelRequested || __over) {
			__release();
			return;
		}
		error = message;
		__send(Error(message));
		#else
		if (cancelRequested || __over) {
			return;
		}
		error = message;
		__finishFailed(message);
		#end
	}

	/**
		For the work: reports `message`, which listeners hear as
		`ThreadEvent.PROGRESS`, in the order sent. Dropped once the run is
		over.
	**/
	public function sendProgress(?message:Progress):Void {
		#if (target.threaded || js)
		__acquire();
		if (cancelRequested || __over) {
			__release();
			return;
		}
		__send(Progress(message));
		#else
		if (cancelRequested || __over) {
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
		__over = false;
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
		__over = true;
		cancelRequested = false;
		dispatchEvent(new ThreadEvent(ThreadEvent.COMPLETE, message));
	}

	@:noCompletion private function __finishFailed(message:Dynamic):Void {
		error = message;
		state = FAILED;
		__over = true;
		cancelRequested = false;
		dispatchEvent(new ThreadEvent(ThreadEvent.ERROR, message));
	}

	#if (target.threaded || js)
	// Queues `message` for the owning runtime and posts a drain when this is
	// the first of a batch (on JavaScript, for a later turn). Called with the
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
			// cancelRequested, not __over. The two are not the same state:
			// __over is set by __finishCompleted and __finishFailed as well
			// as by cancel(), so it means "no longer running" rather than "was
			// called off", and reading it here says the drain stops because
			// the producer finished, which is exactly when the last messages
			// still need delivering. What arrives after the run has completed
			// or failed is not delivered.
			if (cancelRequested || __runCount != run || __outbox == null || state != RUNNING) {
				return;
			}

			switch (message) {
				case Error(value):
					if (!__over) {
						__finishFailed(value);
					}
					return;
				case Complete(value):
					if (!__over) {
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
