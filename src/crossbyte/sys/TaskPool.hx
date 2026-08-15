package crossbyte.sys;

import crossbyte.errors.IllegalOperationError;
#if (cpp || neko || hl)
import sys.thread.Deque;
import sys.thread.Lock;
import sys.thread.Mutex;
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
	@:noCompletion private var __retainedTasks:Array<Task<Dynamic>>;
	#if (cpp || neko || hl)
	@:noCompletion private var __queued:Int;
	@:noCompletion private var __running:Int;
	@:noCompletion private var __activeWorkers:Int;
	@:noCompletion private var __queue:Deque<QueuedTask>;
	// Guards the counters and the shutdown flag. Every critical section taken on
	// this mutex is short and never blocks, so a thread contending for it always
	// reaches a GC safepoint promptly.
	@:noCompletion private var __stateLock:Mutex;
	// Released once by the last worker to retire, so `shutdown(true)` can drain
	// without a condition variable.
	@:noCompletion private var __drained:Lock;
	#end

	public function new(workerCount:Int) {
		if (workerCount < 1) {
			throw new IllegalOperationError("workerCount must be greater than zero.");
		}

		__workerCount = workerCount;
		__isShutdown = false;
		__retainedTasks = [];

		#if (cpp || neko || hl)
		__queued = 0;
		__running = 0;
		__activeWorkers = workerCount;
		__queue = new Deque();
		__stateLock = new Mutex();
		__drained = new Lock();

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
		#if (cpp || neko || hl)
		__retainTask(cast task);
		task.__registerReleaseHook(() -> {
			__releaseTask(cast task);
		});
		#end
		var queuedTask:QueuedTask = {
			task: cast task,
			job: () -> job()
		};

		#if (cpp || neko || hl)
		// No cancel hook is registered: a task cancelled while queued is left in
		// place and discarded by whichever worker pops it, because `__start()`
		// refuses to start anything that is no longer PENDING.
		__stateLock.acquire();
		if (__isShutdown) {
			__stateLock.release();
			throw new IllegalOperationError("Cannot submit tasks after shutdown.");
		}
		__queued++;
		__stateLock.release();

		__queue.add(queuedTask);
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
		__stateLock.acquire();
		var alreadyShutdown:Bool = __isShutdown;
		__isShutdown = true;
		var workers:Int = __activeWorkers;
		__stateLock.release();

		if (!alreadyShutdown) {
			__wakeWorkersForShutdown(workers);
		}

		if (drain) {
			__awaitDrain();
		}
		#else
		__isShutdown = true;
		#end
	}

	public function shutdownNow():Void {
		#if (cpp || neko || hl)
		__stateLock.acquire();
		var alreadyShutdown:Bool = __isShutdown;
		__isShutdown = true;
		var workers:Int = __activeWorkers;
		__stateLock.release();

		var toCancel:Array<Task<Dynamic>> = __drainQueuedTasks();

		if (!alreadyShutdown) {
			__wakeWorkersForShutdown(workers);
		}

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
		__stateLock.acquire();
		var value = __queued;
		__stateLock.release();
		return value;
		#else
		return 0;
		#end
	}

	@:noCompletion private function get_activeCount():Int {
		#if (cpp || neko || hl)
		__stateLock.acquire();
		var value = __running;
		__stateLock.release();
		return value;
		#else
		return 0;
		#end
	}

	#if (cpp || neko || hl)
	@:noCompletion private function __retainTask(task:Task<Dynamic>):Void {
		__stateLock.acquire();
		__retainedTasks.push(task);
		__stateLock.release();
	}

	@:noCompletion private function __releaseTask(task:Task<Dynamic>):Void {
		__stateLock.acquire();
		__retainedTasks.remove(task);
		__stateLock.release();
	}

	@:noCompletion private function __workerLoop():Void {
		while (true) {
			// An idle worker parks here rather than on a condition variable.
			// hxcpp wraps `Deque`'s blocking pop in a GC-free zone but does not
			// wrap `Condition.wait()`, so a worker parked on a condition stays
			// off every GC safepoint and deadlocks the collector as soon as any
			// other thread allocates.
			var queuedTask:QueuedTask = __queue.pop(true);
			if (queuedTask == null || queuedTask.job == null) {
				__retireWorker();
				return;
			}

			__stateLock.acquire();
			__queued--;
			__stateLock.release();

			var task:Task<Dynamic> = queuedTask.task;
			if (!task.__start()) {
				continue;
			}

			__stateLock.acquire();
			__running++;
			__stateLock.release();

			try {
				task.__complete(queuedTask.job());
			} catch (error:Dynamic) {
				task.__fail(error);
			}

			__stateLock.acquire();
			__running--;
			__stateLock.release();
		}
	}

	@:noCompletion private function __retireWorker():Void {
		__stateLock.acquire();
		__activeWorkers--;
		var isLast:Bool = __activeWorkers == 0;
		__stateLock.release();

		if (isLast) {
			__drained.release();
		}
	}

	// One token per live worker: each token wakes exactly one parked worker and
	// tells it to retire.
	@:noCompletion private function __wakeWorkersForShutdown(workers:Int):Void {
		for (i in 0...workers) {
			__queue.add({task: null, job: null});
		}
	}

	@:noCompletion private function __awaitDrain():Void {
		__stateLock.acquire();
		var alreadyDrained:Bool = __activeWorkers == 0;
		__stateLock.release();

		if (alreadyDrained) {
			return;
		}

		// The last worker releases this exactly once; re-release so repeated or
		// concurrent drains also pass through.
		__drained.wait();
		__drained.release();
	}

	@:noCompletion private function __drainQueuedTasks():Array<Task<Dynamic>> {
		var drained:Array<Task<Dynamic>> = [];

		while (true) {
			var queuedTask:QueuedTask = __queue.pop(false);
			if (queuedTask == null) {
				break;
			}

			if (queuedTask.job == null) {
				// A retire token from an earlier shutdown. Put it back so the
				// worker it was meant for still wakes.
				__queue.add(queuedTask);
				break;
			}

			__stateLock.acquire();
			__queued--;
			__stateLock.release();
			drained.push(queuedTask.task);
		}

		return drained;
	}
	#end
}
