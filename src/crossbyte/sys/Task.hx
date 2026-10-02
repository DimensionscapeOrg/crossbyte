package crossbyte.sys;

import crossbyte.core.CrossByte;
import crossbyte.events.EventDispatcher;
import crossbyte.events.TaskEvent;
import crossbyte.events.UncaughtErrorEvent;
import crossbyte.utils.Logger;

#if target.threaded
import sys.thread.Lock;
import sys.thread.Mutex;
#end

/** Promise-like unit of work scheduled and completed through `TaskPool`. */
private enum TaskDispatch<T> {
	Complete(result:Null<T>);
	Fail(error:Dynamic);
	Cancel;
}

/**
	Promise-like unit of work scheduled and completed through `TaskPool`.

	Its events -- `TaskEvent.COMPLETE`, `ERROR`, `CANCEL` -- are dispatched on
	the runtime of the thread that made it. A task finished on a pool thread
	hands them to that runtime's post queue, which wakes the runtime for them;
	each pending task used to hold a tick listener of its own instead, polled
	every tick, and adding and removing one copied the runtime's whole list of
	them, so submitting a burst of tasks took time in proportion to the square
	of its size and every idle tick paid for every task still waiting.

	A task made on a thread no runtime belongs to has no runtime to hand its
	events to: they are dispatched on the pool thread that finishes it, or on
	the thread that cancels it. Give such a task its handlers through
	`onComplete`, `onError` and `onCancel`, which never miss the outcome: one
	given before the task finishes is called there, with the events, and one
	given after is called at once, on the thread that gives it. A listener
	added with `addEventListener` while the task finishes on another thread
	can miss the event.

	A listener or handler that throws is reported as a callback the runtime
	runs is -- logged with `Logger.error`, and dispatched as
	`UncaughtErrorEvent.UNCAUGHT_ERROR` (source `POSTED`, origin the task) on
	the runtime delivering it; only logged on a pool thread -- and the other
	listeners and handlers still hear the outcome. `cancel()` does not throw
	what a `CANCEL` listener threw.

	On JavaScript, which has no threads, the job runs on the one thread there
	is, inside `TaskPool.submit`, and the task's `state` is final when
	`submit` returns. Its events still come in a later turn, as they do from
	a pool thread, so a listener added right after `submit` hears them.
**/
class Task<T> extends EventDispatcher {
	public var state(default, null):TaskState;
	public var result(default, null):Null<T>;
	public var error(default, null):Dynamic;

	public var isDone(get, never):Bool;
	public var isCancelled(get, never):Bool;
	public var isFailed(get, never):Bool;

	// Null from the start: a neko object gains a field when it is first set,
	// which can move its field table, and the pool thread set this one
	// first as the submitting thread added its listener -- which was lost,
	// and its caller waited for good.
	@:noCompletion private var __cancelHook:Void->Void = null;
	@:noCompletion private var __releaseHook:Void->Void;
	@:noCompletion private var __released:Bool;
	// What onComplete, onError and onCancel were given before the task was
	// done, each told the outcome. Taken under the lock by the step that
	// makes the task done, so a handler is either here then or finds the
	// task done and is called at once. They were event listeners, added
	// after the state was read, and a task made off any runtime finished on
	// the pool thread in between: the handler was never called. Null from
	// the start, for the reason __cancelHook is.
	@:noCompletion private var __waiting:Array<TaskDispatch<T>->Void> = null;

	#if target.threaded
	@:noCompletion private var __lock:Mutex;
	@:noCompletion private var __completion:Lock;
	@:noCompletion private var __awaiters:Int;
	#end
	@:noCompletion private var __runtime:CrossByte;

	public function new() {
		super();

		state = PENDING;
		result = null;
		error = null;
		__releaseHook = null;
		__released = false;

		#if target.threaded
		__lock = new Mutex();
		__completion = new Lock();
		__awaiters = 0;
		#end
		// Where its events go. A task made off any runtime's thread has
		// nowhere to send them, and dispatches wherever it finishes.
		__runtime = CrossByte.__currentOrNull();
	}

	public function cancel():Bool {
		var didCancel = false;
		var cancelHook:Void->Void = null;
		var waiting:Array<TaskDispatch<T>->Void> = null;

		#if target.threaded
		__lock.acquire();
		#end

		if (state == PENDING) {
			result = null;
			error = null;
			state = CANCELLED;
			cancelHook = __cancelHook;
			__cancelHook = null;
			waiting = __waiting;
			__waiting = null;
			didCancel = true;
			#if target.threaded
			__notifyWaiters();
			#end
		}

		#if target.threaded
		__lock.release();
		#end

		if (didCancel) {
			if (cancelHook != null) {
				cancelHook();
			}
			__dispatchTerminalEvent(Cancel, waiting);
		}

		return didCancel;
	}

	public function await():T {
		#if target.threaded
		__lock.acquire();
		while (!isDone) {
			__awaiters++;
			__lock.release();
			__completion.wait();
			__lock.acquire();
		}

		var taskState = state;
		var value = result;
		var taskError = error;
		__lock.release();
		#else
		var taskState = state;
		var value = result;
		var taskError = error;
		#end

		if (taskState == FAILED) {
			throw taskError;
		}

		return value;
	}

	/**
		Calls `handler` with the result once the task completes, or at once if
		it already has. Whichever thread the task completes on, a handler given
		before then is called and one given after is called at once: never
		neither. The state and the result are read together, under the task's
		lock: read apart, a task completing on another thread could be seen as
		complete with its result not yet there, and the handler given null.

		A task belonging to a runtime calls a handler given before it
		completes on that runtime, after its `TaskEvent.COMPLETE` listeners;
		one with no runtime, on the pool thread that completed it.
	**/
	public function onComplete(handler:T->Void):Task<T> {
		__whenDone(outcome -> switch (outcome) {
			case Complete(value):
				handler(value);
			default:
		});
		return this;
	}

	/**
		Calls `handler` with the error once the task fails, or at once if it
		already has; called where and when `onComplete`'s handler would be.
	**/
	public function onError(handler:Dynamic->Void):Task<T> {
		__whenDone(outcome -> switch (outcome) {
			case Fail(failure):
				handler(failure);
			default:
		});
		return this;
	}

	/**
		Calls `handler` once the task is cancelled, or at once if it already
		has been; called where and when `onComplete`'s handler would be, the
		thread that cancelled it standing in for the pool thread.
	**/
	public function onCancel(handler:Void->Void):Task<T> {
		__whenDone(outcome -> switch (outcome) {
			case Cancel:
				handler();
			default:
		});
		return this;
	}

	/**
		Keeps `waiter` for the step that makes the task done, or calls it now
		with the outcome if that step has been. Checked and kept under the
		lock that step takes, so the two cannot pass each other.
	**/
	@:noCompletion private function __whenDone(waiter:TaskDispatch<T>->Void):Void {
		#if target.threaded
		__lock.acquire();
		#end
		var outcome:TaskDispatch<T> = switch (state) {
			case COMPLETED: Complete(result);
			case FAILED: Fail(error);
			case CANCELLED: Cancel;
			case PENDING, RUNNING: null;
		}
		if (outcome == null) {
			if (__waiting == null) {
				__waiting = [];
			}
			__waiting.push(waiter);
		}
		#if target.threaded
		__lock.release();
		#end

		if (outcome != null) {
			waiter(outcome);
		}
	}

	@:noCompletion private function get_isDone():Bool {
		return switch (state) {
			case COMPLETED, FAILED, CANCELLED: true;
			case PENDING, RUNNING: false;
		}
	}

	@:noCompletion private function get_isCancelled():Bool {
		return state == CANCELLED;
	}

	@:noCompletion private function get_isFailed():Bool {
		return state == FAILED;
	}

	@:allow(crossbyte.sys.TaskPool)
	@:noCompletion private function __registerCancelHook(handler:Void->Void):Void {
		__cancelHook = handler;
	}

	@:allow(crossbyte.sys.TaskPool)
	@:noCompletion private function __registerReleaseHook(handler:Void->Void):Void {
		__releaseHook = handler;
	}

	@:allow(crossbyte.sys.TaskPool)
	@:noCompletion private function __start():Bool {
		var didStart = false;

		#if target.threaded
		__lock.acquire();
		#end
		if (state == PENDING) {
			state = RUNNING;
			__cancelHook = null;
			didStart = true;
		}
		#if target.threaded
		__lock.release();
		#end

		return didStart;
	}

	@:allow(crossbyte.sys.TaskPool)
	@:noCompletion private function __complete(value:Null<T>):Void {
		var shouldDispatch = false;
		var waiting:Array<TaskDispatch<T>->Void> = null;

		#if target.threaded
		__lock.acquire();
		#end
		if (state == RUNNING) {
			// The result before the state, so that nothing reading the state
			// as complete can find the result still missing.
			result = value;
			error = null;
			state = COMPLETED;
			__cancelHook = null;
			waiting = __waiting;
			__waiting = null;
			shouldDispatch = true;
			#if target.threaded
			__notifyWaiters();
			#end
		}
		#if target.threaded
		__lock.release();
		#end

		if (shouldDispatch) {
			__dispatchTerminalEvent(Complete(value), waiting);
		}
	}

	@:allow(crossbyte.sys.TaskPool)
	@:noCompletion private function __fail(errorValue:Dynamic):Void {
		var shouldDispatch = false;
		var finalError:Dynamic = errorValue;
		var waiting:Array<TaskDispatch<T>->Void> = null;

		#if target.threaded
		__lock.acquire();
		#end
		if (state == RUNNING) {
			error = finalError;
			result = null;
			state = FAILED;
			__cancelHook = null;
			waiting = __waiting;
			__waiting = null;
			shouldDispatch = true;
			#if target.threaded
			__notifyWaiters();
			#end
		}
		#if target.threaded
		__lock.release();
		#end

		if (shouldDispatch) {
			__dispatchTerminalEvent(Fail(finalError), waiting);
		}
	}

	@:allow(crossbyte.sys.TaskPool)
	@:noCompletion private function __notifyWaiters():Void {
	#if target.threaded
		while (__awaiters > 0) {
			__completion.release();
			__awaiters--;
		}
	#end
	}

	/** The outcome, to the listeners and then to the handlers that were `waiting` for it. **/
	@:noCompletion private function __dispatchTerminalEvent(event:TaskDispatch<T>, waiting:Array<TaskDispatch<T>->Void>):Void {
		#if js
		// In a later turn, as a pool thread's completion arrives elsewhere.
		// With no thread the job runs inside submit(), and this was delivered
		// there too: before submit() had returned the task, so no listener
		// could be on it yet, and none ever heard it.
		CrossByte.__nextTurn(() -> __deliver(event, waiting));
		#else
		#if target.threaded
		var runtime:CrossByte = __runtime;
		if (runtime != null && !runtime.__isOwnThread()) {
			// Finished on another thread: delivered on the task's own runtime,
			// which is woken for it. Refused only by a runtime that has exited,
			// whose thread will never touch these listeners again.
			if (runtime.post(() -> __deliver(event, waiting))) {
				return;
			}
		}
		#end
		__deliver(event, waiting);
		#end
	}

	/**
		What a listener or a handler throws is reported, and the rest still
		run and the task is still let go of by its pool. A throw used to end
		the delivery where it was: the runtime reported it, but nothing after
		it ran and the pool held the task for good; and on a pool thread,
		with no runtime, the pool took it for the job's failure, which a
		finished task ignores, so it went without a word.
	**/
	@:noCompletion private function __deliver(event:TaskDispatch<T>, waiting:Array<TaskDispatch<T>->Void>):Void {
		// Each listener's failure to __listenerThrew, below.
		switch (event) {
			case Complete(value):
				__dispatchContained(new TaskEvent(TaskEvent.COMPLETE, this, value));
			case Fail(errorValue):
				__dispatchContained(new TaskEvent(TaskEvent.ERROR, this, null, errorValue));
			case Cancel:
				__dispatchContained(new TaskEvent(TaskEvent.CANCEL, this));
		}
		if (waiting != null) {
			for (waiter in waiting) {
				try {
					waiter(event);
				} catch (error:Dynamic) {
					__handlerThrew(error);
				}
			}
		}
		__maybeRelease();
	}

	/**
		As a posted callback's failure is reported -- logged, and dispatched
		as `UncaughtErrorEvent.UNCAUGHT_ERROR` -- on the runtime of the thread
		delivering, which is the task's own when it has one; logged alone on a
		pool thread.
	**/
	@:noCompletion override private function __listenerThrew(error:Dynamic, event:crossbyte.events.Event):Void {
		__handlerThrew(error);
	}

	@:noCompletion private function __handlerThrew(error:Dynamic):Void {
		var runtime:Null<CrossByte> = CrossByte.__currentOrNull();
		if (runtime != null) {
			runtime.__uncaught(error, UncaughtErrorEvent.POSTED, this);
			return;
		}
		try {
			Logger.error("A Task listener or handler threw: " + Std.string(error));
		} catch (_:Dynamic) {}
	}

	@:noCompletion private inline function __maybeRelease():Void {
		if (__released || !isDone) {
			return;
		}

		__released = true;
		if (__releaseHook != null) {
			var hook = __releaseHook;
			__releaseHook = null;
			hook();
		}
	}
}
