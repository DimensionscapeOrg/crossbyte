package crossbyte.sys;

import crossbyte.core.CrossByte;
import crossbyte.errors.IllegalOperationError;
import crossbyte.events.EventDispatcher;
import crossbyte.events.TaskEvent;
import crossbyte.events.TickEvent;

#if (cpp || neko || hl)
import sys.thread.Deque;
import sys.thread.Lock;
import sys.thread.Mutex;
#end

/** Promise-like unit of work scheduled and completed through `TaskPool`. */
private enum TaskDispatch<T> {
	Complete(result:Null<T>);
	Fail(error:Dynamic);
	Cancel;
}

/** Promise-like unit of work scheduled and completed through `TaskPool`. */
class Task<T> extends EventDispatcher {
	public var state(default, null):TaskState;
	public var result(default, null):Null<T>;
	public var error(default, null):Dynamic;

	public var isDone(get, never):Bool;
	public var isCancelled(get, never):Bool;
	public var isFailed(get, never):Bool;

	@:noCompletion private var __cancelHook:Void->Void;
	@:noCompletion private var __releaseHook:Void->Void;
	@:noCompletion private var __released:Bool;

	#if (cpp || neko || hl)
	@:noCompletion private var __lock:Mutex;
	@:noCompletion private var __completion:Lock;
	@:noCompletion private var __awaiters:Int;
	@:noCompletion private var __dispatchQueue:Deque<TaskDispatch<T>>;
	@:noCompletion private var __dispatchListener:TickEvent->Void;
	@:noCompletion private var __dispatchAttached:Bool;
	@:noCompletion private var __dispatchPending:Bool;
	#end
	@:noCompletion private var __runtime:CrossByte;

	public function new() {
		super();

		state = PENDING;
		result = null;
		error = null;
		__releaseHook = null;
		__released = false;

		#if (cpp || neko || hl)
		__lock = new Mutex();
		__completion = new Lock();
		__awaiters = 0;
		__dispatchQueue = new Deque();
		__dispatchListener = function(event:TickEvent):Void {
			__flushDispatchQueue(event);
		};
		__dispatchAttached = false;
		__dispatchPending = false;
		#end
		try {
			__runtime = CrossByte.current();
		} catch (_:IllegalOperationError) {
			__runtime = null;
		} catch (_:Dynamic) {
			__runtime = null;
		}
		#if (cpp || neko || hl)
		if (__runtime != null) {
			__dispatchAttached = true;
			__runtime.addEventListener(TickEvent.TICK, __dispatchListener);
		}
		#end
	}

	public function cancel():Bool {
		var didCancel = false;
		var cancelHook:Void->Void = null;

		#if (cpp || neko || hl)
		__lock.acquire();
		#end

		if (state == PENDING) {
			state = CANCELLED;
			result = null;
			error = null;
			cancelHook = __cancelHook;
			__cancelHook = null;
			didCancel = true;
			#if (cpp || neko || hl)
			__notifyWaiters();
			#end
		}

		#if (cpp || neko || hl)
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
		#if (cpp || neko || hl)
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

	public function onComplete(handler:T->Void):Task<T> {
		if (state == COMPLETED) {
			handler(result);
			return this;
		}

		addEventListener(TaskEvent.COMPLETE, (event:TaskEvent<T>) -> handler(event.result));
		return this;
	}

	public function onError(handler:Dynamic->Void):Task<T> {
		if (state == FAILED) {
			handler(error);
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

		#if (cpp || neko || hl)
		__lock.acquire();
		#end
		if (state == PENDING) {
			state = RUNNING;
			__cancelHook = null;
			didStart = true;
		}
		#if (cpp || neko || hl)
		__lock.release();
		#end

		return didStart;
	}

	@:allow(crossbyte.sys.TaskPool)
	@:noCompletion private function __complete(value:Null<T>):Void {
		var shouldDispatch = false;

		#if (cpp || neko || hl)
		__lock.acquire();
		#end
		if (state == RUNNING) {
			state = COMPLETED;
			result = value;
			error = null;
			__cancelHook = null;
			shouldDispatch = true;
			#if (cpp || neko || hl)
			__notifyWaiters();
			#end
		}
		#if (cpp || neko || hl)
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

		#if (cpp || neko || hl)
		__lock.acquire();
		#end
		if (state == RUNNING) {
			state = FAILED;
			error = finalError;
			result = null;
			__cancelHook = null;
			shouldDispatch = true;
			#if (cpp || neko || hl)
			__notifyWaiters();
			#end
		}
		#if (cpp || neko || hl)
		__lock.release();
		#end

		if (shouldDispatch) {
			__dispatchTerminalEvent(Fail(finalError));
		}
	}

	@:allow(crossbyte.sys.TaskPool)
	@:noCompletion private function __notifyWaiters():Void {
	#if (cpp || neko || hl)
		while (__awaiters > 0) {
			__completion.release();
			__awaiters--;
		}
	#end
	}

	@:noCompletion private inline function __dispatchTerminalEvent(event:TaskDispatch<T>):Void {
		#if (cpp || neko || hl)
		if (!__canDispatchInline()) {
			__lock.acquire();
			__dispatchPending = true;
			__lock.release();
			__dispatchQueue.add(event);
			return;
		}
		#end
		__dispatchNow(event);
		__finalizeDispatchLifecycle();
	}

	#if (cpp || neko || hl)
	@:noCompletion private inline function __canDispatchInline():Bool {
		if (__runtime == null) {
			return true;
		}

		try {
			return CrossByte.current() == __runtime;
		} catch (_:Dynamic) {
			return false;
		}
	}

	@:noCompletion private function __flushDispatchQueue(event:TickEvent):Void {
		var dispatched = false;
		while (true) {
			var pending = __dispatchQueue.pop(false);
			if (pending == null) {
				break;
			}
			dispatched = true;
			__dispatchNow(pending);
		}

		if (dispatched) {
			__lock.acquire();
			__dispatchPending = false;
			__lock.release();
		}
		__finalizeDispatchLifecycle();
	}
	#end

	@:noCompletion private inline function __dispatchNow(event:TaskDispatch<T>):Void {
		switch (event) {
			case Complete(value):
				dispatchEvent(new TaskEvent(TaskEvent.COMPLETE, this, value));
			case Fail(errorValue):
				dispatchEvent(new TaskEvent(TaskEvent.ERROR, this, null, errorValue));
			case Cancel:
				dispatchEvent(new TaskEvent(TaskEvent.CANCEL, this));
		}
	}

	@:noCompletion private inline function __finalizeDispatchLifecycle():Void {
		#if (cpp || neko || hl)
		__lock.acquire();
		var shouldDetach = __dispatchAttached && __runtime != null && isDone && !__dispatchPending;
		__lock.release();
		if (shouldDetach) {
			__dispatchAttached = false;
			__runtime.removeEventListener(TickEvent.TICK, __dispatchListener);
		}
		#end
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
