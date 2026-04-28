package crossbyte.sys;

import crossbyte.errors.IllegalOperationError;
#if (cpp || neko || hl)
import sys.thread.Condition;
import sys.thread.Deque;
import sys.thread.Thread;
#end

private typedef QueuedTask = {
	task:Task<Dynamic>,
	job:Void->Dynamic
}

/** Small worker-pool scheduler for running `Task` jobs across background threads. */
class TaskPool {
	public var isShutdown(get, never):Bool;
	public var workerCount(get, never):Int;
	public var queuedCount(get, never):Int;
	public var activeCount(get, never):Int;

	@:noCompletion private var __workerCount:Int;
	@:noCompletion private var __isShutdown:Bool;
	#if (cpp || neko || hl)
	@:noCompletion private var __queued:Int;
	@:noCompletion private var __running:Int;
	@:noCompletion private var __activeWorkers:Int;
	@:noCompletion private var __queue:Deque<QueuedTask>;
	@:noCompletion private var __queueLock:Condition;
	#end

	public function new(workerCount:Int) {
		if (workerCount < 1) {
			throw new IllegalOperationError("workerCount must be greater than zero.");
		}

		__workerCount = workerCount;
		__isShutdown = false;

		#if (cpp || neko || hl)
		__queued = 0;
		__running = 0;
		__activeWorkers = workerCount;
		__queue = new Deque();
		__queueLock = new Condition();

		for (i in 0...workerCount) {
			Thread.create(__workerLoop);
		}
		#end
	}

	public function submit(job:Void->Void):Task<Dynamic> {
		return submitResult(() -> {
			job();
			return null;
		});
	}

	public function submitResult<T>(job:Void->T):Task<T> {
		if (__isShutdown) {
			throw new IllegalOperationError("Cannot submit tasks after shutdown.");
		}

		var task = new Task<T>();
		var queuedTask:QueuedTask = {
			task: cast task,
			job: () -> job()
		};

		#if (cpp || neko || hl)
		task.__registerCancelHook(() -> {
			__cancelQueuedTask(cast task);
		});

		__queueLock.acquire();
		if (__isShutdown) {
			__queueLock.release();
			throw new IllegalOperationError("Cannot submit tasks after shutdown.");
		}
		__queue.add(queuedTask);
		__queued++;
		__queueLock.signal();
		__queueLock.release();
		#else
		if (task.__start()) {
			try {
				task.__complete(queuedTask.job());
			} catch (error:Dynamic) {
				task.__fail(error);
			}
		}
		#end

		return task;
	}

	public function shutdown(?drain:Bool = true):Void {
		#if (cpp || neko || hl)
		__queueLock.acquire();
		if (!__isShutdown) {
			__isShutdown = true;
		}
		__queueLock.broadcast();

		if (drain) {
			while (__activeWorkers > 0) {
				__queueLock.wait();
			}
		}
		__queueLock.release();
		#else
		__isShutdown = true;
		#end
	}

	public function shutdownNow():Void {
		#if (cpp || neko || hl)
		var toCancel = new Array<Task<Dynamic>>();

		__queueLock.acquire();
		if (!__isShutdown) {
			__isShutdown = true;
		}
		while (__queued > 0) {
			var queuedTask = __queue.pop(false);
			if (queuedTask == null) {
				break;
			}
			__queued--;
			toCancel.push(queuedTask.task);
		}
		__queueLock.broadcast();
		__queueLock.release();

		for (task in toCancel) {
			task.cancel();
		}
		#else
		__isShutdown = true;
		#end
	}

	public function get_isShutdown():Bool {
		return __isShutdown;
	}

	@:noCompletion private function get_workerCount():Int {
		return __workerCount;
	}

	@:noCompletion private function get_queuedCount():Int {
		#if (cpp || neko || hl)
		__queueLock.acquire();
		var value = __queued;
		__queueLock.release();
		return value;
		#else
		return 0;
		#end
	}

	@:noCompletion private function get_activeCount():Int {
		#if (cpp || neko || hl)
		__queueLock.acquire();
		var value = __running;
		__queueLock.release();
		return value;
		#else
		return 0;
		#end
	}

	#if (cpp || neko || hl)
	@:noCompletion private function __workerLoop():Void {
		var queuedTask:QueuedTask = null;
		while (true) {
			var shouldRun:Bool = false;
			queuedTask = null;

			__queueLock.acquire();
			while (__queued == 0 && !__isShutdown) {
				__queueLock.wait();
			}

			if (__queued == 0 && __isShutdown) {
				__activeWorkers--;
				if (__activeWorkers == 0) {
					__queueLock.broadcast();
				}
				__queueLock.release();
				break;
			}

			queuedTask = __queue.pop(false);
			if (queuedTask != null) {
				__queued--;
				if (queuedTask.task.__start()) {
					__running++;
					shouldRun = true;
				}
			}
			__queueLock.release();

			if (!shouldRun || queuedTask == null) {
				continue;
			}

			var task = queuedTask.task;
			try {
				task.__complete(queuedTask.job());
			} catch (error:Dynamic) {
				task.__fail(error);
			}

			__queueLock.acquire();
			__running--;
			if (__isShutdown && __running == 0 && __queued == 0 && __activeWorkers == 0) {
				__queueLock.broadcast();
			}
			__queueLock.release();
		}
	}

	@:noCompletion private function __cancelQueuedTask(target:Task<Dynamic>):Void {
		var removed = false;
		var requeue = new Array<QueuedTask>();

		__queueLock.acquire();
		while (__queued > 0) {
			var queuedTask = __queue.pop(false);
			if (queuedTask == null) {
				break;
			}
			__queued--;
			if (!removed && queuedTask.task == target) {
				removed = true;
			} else {
				requeue.push(queuedTask);
			}
		}
		while (requeue.length > 0) {
			var queuedTask = requeue.shift();
			__queue.add(queuedTask);
			__queued++;
		}
		__queueLock.release();
	}

	#end
}
