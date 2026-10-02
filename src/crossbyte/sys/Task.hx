package crossbyte.sys;

import crossbyte.core.CrossByte;
import crossbyte.events.EventDispatcher;
import crossbyte.events.TaskEvent;

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

		#if target.threaded
		__lock.acquire();
		#end

		if (state == PENDING) {
			result = null;
			error = null;
			state = CANCELLED;
			cancelHook = __cancelHook;
			__cancelHook = null;
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
			__dispatchTerminalEvent(Cancel);
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
		it already has. The state and the result are read together, under the
		task's lock: read apart, a task completing on another thread could be
		seen as complete with its result not yet there, and the handler given
		null.
	**/
	public function onComplete(handler:T->Void):Task<T> {
		#if target.threaded
		__lock.acquire();
		#end
		var done:Bool = state == COMPLETED;
		var value:Null<T> = result;
		#if target.threaded
		__lock.release();
		#end

		if (done) {
			handler(value);
			return this;
		}

		addEventListener(TaskEvent.COMPLETE, (event:TaskEvent<T>) -> handler(event.result));
		return this;
	}

	public function onError(handler:Dynamic->Void):Task<T> {
		#if target.threaded
		__lock.acquire();
		#end
		var failed:Bool = state == FAILED;
		var failure:Dynamic = error;
		#if target.threaded
		__lock.release();
		#end

		if (failed) {
			handler(failure);
			return this;
		}

		addEventListener(TaskEvent.ERROR, (event:TaskEvent<T>) -> handler(event.error));
		return this;
	}

	public function onCancel(handler:Void->Void):Task<T> {
		if (state == CANCELLED) {
			handler();
			return this;
		}

		addEventListener(TaskEvent.CANCEL, (_:TaskEvent<T>) -> handler());
		return this;
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
			shouldDispatch = true;
			#if target.threaded
			__notifyWaiters();
			#end
		}
		#if target.threaded
		__lock.release();
		#end

		if (shouldDispatch) {
			__dispatchTerminalEvent(Complete(value));
		}
	}

	@:allow(crossbyte.sys.TaskPool)
	@:noCompletion private function __fail(errorValue:Dynamic):Void {
		var shouldDispatch = false;
		var finalError:Dynamic = errorValue;

		#if target.threaded
		__lock.acquire();
		#end
		if (state == RUNNING) {
			error = finalError;
			result = null;
			state = FAILED;
			__cancelHook = null;
			shouldDispatch = true;
			#if target.threaded
			__notifyWaiters();
			#end
		}
		#if target.threaded
		__lock.release();
		#end

		if (shouldDispatch) {
			__dispatchTerminalEvent(Fail(finalError));
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

	@:noCompletion private function __dispatchTerminalEvent(event:TaskDispatch<T>):Void {
		#if js
		// In a later turn, as a pool thread's completion arrives elsewhere.
		// With no thread the job runs inside submit(), and this was delivered
		// there too: before submit() had returned the task, so no listener
		// could be on it yet, and none ever heard it.
		CrossByte.__nextTurn(() -> __deliver(event));
		#else
		#if target.threaded
		var runtime:CrossByte = __runtime;
		if (runtime != null && !runtime.__isOwnThread()) {
			// Finished on another thread: delivered on the task's own runtime,
			// which is woken for it. Refused only by a runtime that has exited,
			// whose thread will never touch these listeners again.
			if (runtime.post(() -> __deliver(event))) {
				return;
			}
		}
		#end
		__deliver(event);
		#end
	}

	@:noCompletion private function __deliver(event:TaskDispatch<T>):Void {
		switch (event) {
			case Complete(value):
				dispatchEvent(new TaskEvent(TaskEvent.COMPLETE, this, value));
			case Fail(errorValue):
				dispatchEvent(new TaskEvent(TaskEvent.ERROR, this, null, errorValue));
			case Cancel:
				dispatchEvent(new TaskEvent(TaskEvent.CANCEL, this));
		}
		__maybeRelease();
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
