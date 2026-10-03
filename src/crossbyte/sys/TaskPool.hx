package crossbyte.sys;

import crossbyte.errors.IllegalOperationError;
#if target.threaded
import sys.thread.Deque;
import sys.thread.Lock;
import sys.thread.Mutex;
import sys.thread.Thread;
#end

/**
	What a worker takes from the queue. A class rather than the anonymous
	`{task, job}` it was, whose two fields hxcpp read by name; the job is
	held as it was given rather than wrapped in another closure.
**/
@:access(crossbyte.sys.Task)
private class PoolEntry {
	public function new() {}

	/** The task this runs, or null for the token that retires a worker. **/
	public function task():Null<Task<Any>> {
		return null;
	}

	/** Moves the task to RUNNING; false when it was cancelled while queued. **/
	public function start():Bool {
		return false;
	}

	/** Runs the job and settles the task with what it returned or threw. **/
	public function run():Void {}
}

@:access(crossbyte.sys.Task)
private final class PoolJob<T> extends PoolEntry {
	@:noCompletion private final __task:Task<T>;
	@:noCompletion private final __job:Void->T;

	public function new(task:Task<T>, job:Void->T) {
		super();
		__task = task;
		__job = job;
	}

	override public function task():Null<Task<Any>> {
		return cast __task;
	}

	override public function start():Bool {
		return __task.__start();
	}

	override public function run():Void {
		try {
			__task.__complete(__job());
		} catch (error:Dynamic) {
			__task.__fail(error);
		}
	}
}

/**
	Small worker-pool scheduler for running `Task` jobs across background threads.

	On JavaScript, which has no threads, a job runs on the one thread there is,
	inside `submit`, holding it for as long as the job takes; the task's events
	still come in a later turn, as from a pool thread elsewhere, so a listener
	added right after `submit` hears them. `queuedCount` and `activeCount` are
	then always 0, and `shutdown` and `shutdownNow` only refuse what is submitted
	after them.
**/
class TaskPool {
	public var isShutdown(get, never):Bool;
	public var workerCount(get, never):Int;
	public var queuedCount(get, never):Int;
	public var activeCount(get, never):Int;

	@:noCompletion private var __workerCount:Int;
	@:noCompletion private var __isShutdown:Bool;
	// The tasks in flight, kept alive until each is done. Each task holds its
	// place here, so letting one go swaps the last into it: it was found with
	// Array.remove, a search and a shift of everything after it per task, so
	// a burst cost the square of its size, 200,000 tasks delivered in 1.5 s
	// where 0.1 s does.
	@:noCompletion private var __retained:Array<Task<Any>>;
	#if target.threaded
	@:noCompletion private var __queued:Int;
	@:noCompletion private var __running:Int;
	@:noCompletion private var __activeWorkers:Int;
	@:noCompletion private var __queue:Deque<PoolEntry>;
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
		__retained = [];

		#if target.threaded
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

	/**
		Runs `job` on a pool thread. The task completes with `null`; its type
		says so, and is `Any` rather than `Dynamic`, so reading anything from
		the result needs a cast that says what was meant.
	**/
	public function submit(job:Void->Void):Task<Any> {
		return submitResult(function():Any {
			job();
			return null;
		});
	}

	public function submitResult<T>(job:Void->T):Task<T> {
		if (__isShutdown) {
			throw new IllegalOperationError("Cannot submit tasks after shutdown.");
		}

		var task = new Task<T>();
		var entry:PoolJob<T> = new PoolJob(task, job);

		#if target.threaded
		// No cancel hook is registered: a task cancelled while queued is left in
		// place and discarded by whichever worker pops it, because `__start()`
		// refuses to start anything that is no longer PENDING.
		__stateLock.acquire();
		if (__isShutdown) {
			__stateLock.release();
			throw new IllegalOperationError("Cannot submit tasks after shutdown.");
		}
		__queued++;
		// Kept under the same lock, once the pool has taken the task: it was
		// kept first, and a submit refused by a shutdown kept it for good.
		@:privateAccess task.__poolSlot = __retained.length;
		__retained.push(cast task);
		task.__keptBy(this);
		__stateLock.release();

		__queue.add(entry);
		#else
		if (entry.start()) {
			entry.run();
		}
		#end

		return task;
	}

	public function shutdown(?drain:Bool = true):Void {
		#if target.threaded
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
		#if target.threaded
		__stateLock.acquire();
		var alreadyShutdown:Bool = __isShutdown;
		__isShutdown = true;
		var workers:Int = __activeWorkers;
		__stateLock.release();

		var toCancel:Array<Task<Any>> = __drainQueuedTasks();

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
		#if target.threaded
		__stateLock.acquire();
		var value = __queued;
		__stateLock.release();
		return value;
		#else
		return 0;
		#end
	}

	@:noCompletion private function get_activeCount():Int {
		#if target.threaded
		__stateLock.acquire();
		var value = __running;
		__stateLock.release();
		return value;
		#else
		return 0;
		#end
	}

	/** A task this pool kept is done: it lets go of it, from wherever it is in the list. **/
	@:allow(crossbyte.sys.Task)
	@:noCompletion private function __releaseTask<T>(task:Task<T>):Void {
		#if target.threaded
		__stateLock.acquire();
		var slot:Int = @:privateAccess task.__poolSlot;
		var last:Int = __retained.length - 1;
		if (slot >= 0 && slot <= last && __retained[slot] == cast task) {
			var moved:Task<Any> = __retained[last];
			__retained[slot] = moved;
			@:privateAccess moved.__poolSlot = slot;
			__retained.pop();
			@:privateAccess task.__poolSlot = -1;
		}
		__stateLock.release();
		#end
	}

	#if target.threaded

	@:noCompletion private function __workerLoop():Void {
		while (true) {
			// An idle worker parks here rather than on a condition variable.
			// hxcpp wraps `Deque`'s blocking pop in a GC-free zone but does not
			// wrap `Condition.wait()`, so a worker parked on a condition stays
			// off every GC safepoint and deadlocks the collector as soon as any
			// other thread allocates.
			var entry:PoolEntry = __queue.pop(true);
			if (entry == null || entry.task() == null) {
				__retireWorker();
				return;
			}

			// Started before it is counted, so one lock covers both counts.
			var started:Bool = entry.start();
			__stateLock.acquire();
			__queued--;
			if (started) {
				__running++;
			}
			__stateLock.release();

			if (!started) {
				continue;
			}

			entry.run();

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
			__queue.add(new PoolEntry());
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

	@:noCompletion private function __drainQueuedTasks():Array<Task<Any>> {
		var drained:Array<Task<Any>> = [];

		while (true) {
			var entry:PoolEntry = __queue.pop(false);
			if (entry == null) {
				break;
			}

			var task:Null<Task<Any>> = entry.task();
			if (task == null) {
				// A retire token from an earlier shutdown. Put it back so the
				// worker it was meant for still wakes.
				__queue.add(entry);
				break;
			}

			__stateLock.acquire();
			__queued--;
			__stateLock.release();
			drained.push(task);
		}

		return drained;
	}
	#end
}
