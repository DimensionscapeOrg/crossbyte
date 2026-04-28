package crossbyte.sys;

import crossbyte.events.EventDispatcher;
import crossbyte.events.TaskEvent;

#if (cpp || neko || hl)
import sys.thread.Lock;
import sys.thread.Mutex;
#end

/**
 * ...
 */
class Task<T> extends EventDispatcher {
	public var state(default, null):TaskState;
	public var result(default, null):Null<T>;
	public var error(default, null):Dynamic;

	public var isDone(get, never):Bool;
	public var isCancelled(get, never):Bool;
	public var isFailed(get, never):Bool;

	@:noCompletion private var __cancelHook:Void->Void;

	#if (cpp || neko || hl)
	@:noCompletion private var __lock:Mutex;
	@:noCompletion private var __completion:Lock;
	@:noCompletion private var __awaiters:Int;
	#end

	public function new() {
		super();

		state = PENDING;
		result = null;
		error = null;

		#if (cpp || neko || hl)
		__lock = new Mutex();
		__completion = new Lock();
		__awaiters = 0;
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
			dispatchEvent(new TaskEvent(TaskEvent.CANCEL, this));
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
			dispatchEvent(new TaskEvent(TaskEvent.COMPLETE, this, value));
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
			dispatchEvent(new TaskEvent(TaskEvent.ERROR, this, null, finalError));
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
}
