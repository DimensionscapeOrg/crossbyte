package crossbyte.sys;

import crossbyte.core.CrossByte;
import crossbyte.sys.TaskState;
import utest.Assert;
#if target.threaded
import sys.thread.Mutex;
#end

@:access(crossbyte.core.CrossByte)
class TaskPoolTest extends utest.Test {
	// Pools created through `makePool` are shut down after every test. Without
	// this, each case leaked its worker threads for the rest of the run.
	private var __pools:Array<TaskPool> = [];

	public function teardown():Void {
		for (pool in __pools) {
			try {
				pool.shutdownNow();
				pool.shutdown(true);
			} catch (_:Dynamic) {}
		}
		__pools = [];
	}

	private function makePool(workerCount:Int):TaskPool {
		var pool = new TaskPool(workerCount);
		__pools.push(pool);
		return pool;
	}

	public function testJobsRunOffTheSubmittingThread():Void {
		// On the jvm and the interpreter a pool ran every job inline, on the
		// thread that submitted it: four 200ms jobs held the caller for 800ms,
		// so AsyncDatabase, URLLoader and File's async calls stalled the very
		// loop they exist to spare.
		#if target.threaded
		var pool = makePool(4);
		var caller = new sys.thread.Tls<Bool>();
		caller.value = true;
		var onCaller = 0;
		var guard = new Mutex();

		var start = haxe.Timer.stamp();
		var tasks = [
			for (_ in 0...4)
				pool.submit(() -> {
					if (caller.value == true) {
						guard.acquire();
						onCaller++;
						guard.release();
					}
					crossbyte.sys.System.sleep(0.2);
				})
		];
		var submitted = haxe.Timer.stamp() - start;
		for (task in tasks) {
			task.await();
		}
		var finished = haxe.Timer.stamp() - start;

		Assert.equals(0, onCaller, "jobs ran on the thread that submitted them");
		Assert.isTrue(submitted < 0.15, "submitting four jobs held the caller for " + submitted + "s");
		Assert.isTrue(finished < 0.7, "four 200ms jobs on four workers took " + finished + "s");
		#else
		Assert.pass();
		#end
	}

	public function testPendingTasksHoldNoTickListeners():Void {
		// Each pending task held a tick listener of its own, and adding or
		// removing one copied the runtime's whole list: 8000 tasks took 2.3s
		// to submit, and every idle tick polled all of them.
		#if target.threaded
		var runtime = CrossByte.current();
		var before = __tickListeners(runtime);
		var gate = new sys.thread.Lock();
		var pool = makePool(2);
		var tasks = [for (_ in 0...1000) pool.submit(() -> gate.wait())];

		Assert.equals(before, __tickListeners(runtime), "pending tasks attached tick listeners");

		for (_ in 0...1000) {
			gate.release();
		}
		for (task in tasks) {
			task.await();
		}
		pumpUntil(() -> __tickListeners(runtime) == before);
		Assert.equals(before, __tickListeners(runtime));
		#else
		Assert.pass();
		#end
	}

	private static function __tickListeners(runtime:CrossByte):Int {
		var list:Array<Dynamic> = @:privateAccess runtime.__eventMap == null ? null : cast @:privateAccess runtime.__eventMap.get(crossbyte.events.TickEvent.TICK);
		return list == null ? 0 : list.length;
	}

	public function testAPoolCanBeSizedByTheProcessorCount():Void {
		// processorCount was 0 everywhere but native, and a pool of 0 throws.
		Assert.isTrue(System.processorCount >= 1, "processorCount is " + System.processorCount);
		var pool = makePool(System.processorCount);
		Assert.equals(System.processorCount, pool.workerCount);
	}

	public function testTasksRunAndComplete():Void {
		var pool = makePool(1);
		var value = 0;
		var task = pool.submit(() -> value = 5);
		task.await();

		Assert.equals(5, value);
		Assert.isTrue(task.isDone);
		Assert.equals(TaskState.COMPLETED, task.state);
		Assert.isNull(task.result);
	}

	public function testSubmitResultStoresAndReturnsResult():Void {
		var pool = makePool(2);
		var task = pool.submitResult(() -> 7);

		Assert.equals(7, task.await());
		Assert.equals(7, task.result);
		Assert.equals(TaskState.COMPLETED, task.state);
		Assert.isTrue(task.isDone);
	}

	public function testErrorsCaptureAndDispatchError():Void {
		var pool = makePool(2);
		var caught:Dynamic = null;
		var task = pool.submitResult(() -> {
			throw "bad";
		});
		task.onError(value -> caught = value);

		Assert.equals(2, pool.workerCount);
		Assert.isTrue(throws(() -> task.await()));
		pumpUntil(() -> caught != null);
		Assert.equals("bad", caught);
		Assert.equals("bad", task.error);
		Assert.equals(TaskState.FAILED, task.state);
		Assert.isTrue(task.isFailed);
		Assert.isTrue(task.isDone);
	}

	public function testCompletionDispatchesOnOwningRuntimeTick():Void {
		#if target.threaded
		var primordial = CrossByte.current();
		var child = new CrossByte(false, DEFAULT, true);
		var pool = makePool(1);
		var callbackRuntime:CrossByte = null;
		var callbackCount = 0;
		// Held until the handler is attached. A job that finished first made
		// onComplete call the handler at once, on this thread, which is a
		// different contract from the one this case is about, and on the
		// jvm, where a pool thread picks a job up within microseconds, it
		// finished first every time.
		var gate = new sys.thread.Lock();
		var task = pool.submitResult(() -> {
			gate.wait();
			return 42;
		});
		task.onComplete(_ -> {
			callbackCount++;
			callbackRuntime = CrossByte.current();
		});
		gate.release();

		Assert.equals(42, task.await());
		Assert.equals(0, callbackCount);

		primordial.pump(1 / 60, 0);
		Assert.equals(0, callbackCount);

		pumpRuntimeUntil(child, () -> callbackCount == 1);

		Assert.equals(1, callbackCount);
		Assert.equals(child, callbackRuntime);

		pool.shutdown();
		child.exit();
		#else
		Assert.pass();
		#end
	}

	/**
		A task made on a thread no runtime belongs to finishes on the pool
		thread, and `onComplete` and `onError` looked at its state and added
		their listener in two steps: a task finishing between them was never
		heard, and whatever waited on the handler waited for good. Thousands
		of tasks, each given its handler as soon as it is submitted; the jvm
		lost about one in two thousand.
	**/
	@:timeout(60000)
	public function testHandlersGivenOffAnyRuntimeAreAlwaysCalled():Void {
		#if target.threaded
		var pool = makePool(4);
		var count:Int = 20000;
		var heard = new Tally();
		var submitted = new sys.thread.Lock();
		sys.thread.Thread.create(() -> {
			for (i in 0...count) {
				if (i % 2 == 0) {
					pool.submitResult(() -> i).onComplete(value -> heard.add(value));
				} else {
					pool.submitResult(() -> {
						throw i;
						return 0;
					}).onError(error -> heard.add(error));
				}
			}
			submitted.release();
		});
		submitted.wait();
		heard.waitFor(count, 20);

		Assert.equals(count, heard.count, '${count - heard.count} of $count handlers were never called');
		if (heard.count == count) {
			Assert.equals((count - 1.0) * count / 2, heard.sum, "a handler was given another task's outcome");
		}
		#else
		Assert.pass();
		#end
	}

	/**
		`onCancel` read the state without the lock and added its listener
		after, so a task cancelled on another thread between the two was
		never heard. A thread cancels each task as soon as it is made, while
		the thread that made it gives it its handler.
	**/
	@:timeout(60000)
	public function testCancelHandlersGivenOffAnyRuntimeAreAlwaysCalled():Void {
		#if target.threaded
		var pool = makePool(1);
		var gate = new sys.thread.Lock();
		// Holds the one worker, so every task after it stays queued until
		// it is cancelled.
		var blocker = pool.submit(() -> gate.wait());
		var count:Int = 20000;
		var made = new sys.thread.Deque<Task<Dynamic>>();
		var heard = new Tally();
		var refused = new Tally();
		sys.thread.Thread.create(() -> {
			for (_ in 0...count) {
				if (!made.pop(true).cancel()) {
					refused.add(1);
				}
			}
		});
		sys.thread.Thread.create(() -> {
			for (_ in 0...count) {
				var task = pool.submit(() -> {});
				made.add(task);
				task.onCancel(() -> heard.add(1));
			}
		});

		heard.waitFor(count, 20);
		gate.release();
		blocker.await();

		Assert.equals(0, refused.sum, "a queued task refused to be cancelled");
		Assert.equals(count, heard.count, '${count - heard.count} of $count cancel handlers were never called');
		#else
		Assert.pass();
		#end
	}

	public function testFifoExecutionWithSingleWorker():Void {
		var pool = makePool(1);
		var output:Array<Int> = [];

		var tasks = [
			pool.submit(() -> output.push(1)),
			pool.submit(() -> output.push(2)),
			pool.submit(() -> output.push(3))
		];

		for (task in tasks) {
			task.await();
		}

		Assert.equals(3, output.length);
		Assert.equals(1, output[0]);
		Assert.equals(2, output[1]);
		Assert.equals(3, output[2]);
	}

	public function testMultipleWorkersCanRunMultipleTasks():Void {
		#if target.threaded
		var pool = makePool(4);
		var lock = new Mutex();
		var running:Int = 0;
		var maxRunning:Int = 0;

		var tasks = [for (i in 0...8) pool.submitResult(() -> {
			lock.acquire();
			running++;
			if (running > maxRunning) {
				maxRunning = running;
			}
			lock.release();
			crossbyte.sys.System.sleep(0.05);
			lock.acquire();
			running--;
			lock.release();
			return i;
		})];

		for (task in tasks) {
			task.await();
		}

		Assert.isTrue(maxRunning > 1);
		Assert.equals(8, tasks.length);
		#else
		Assert.pass();
		#end
	}

	public function testCancelBeforeStartDispatchesCancel():Void {
		#if target.threaded
		var pool = makePool(1);
		var cancelled = false;
		pool.submit(() -> {
			crossbyte.sys.System.sleep(0.2);
		});
		var task = pool.submit(() -> {
			crossbyte.sys.System.sleep(0.2);
		});

		crossbyte.sys.System.sleep(0.01);
		task.onCancel(() -> cancelled = true);
		Assert.isTrue(task.cancel());
		Assert.isTrue(cancelled);
		Assert.equals(TaskState.CANCELLED, task.state);
		Assert.isTrue(task.isCancelled);

		pool.shutdownNow();
		#else
		Assert.pass();
		#end
	}

	public function testCancelAfterStartFails():Void {
		#if target.threaded
		var pool = makePool(1);
		var started = false;
		var task = pool.submit(() -> {
			started = true;
			crossbyte.sys.System.sleep(0.1);
		});

		while (!started) {
			crossbyte.sys.System.sleep(0.005);
		}

		Assert.isFalse(task.cancel());
		Assert.notEquals(TaskState.CANCELLED, task.state);
		Assert.isFalse(task.isCancelled);

		pool.shutdownNow();
		#else
		var pool = makePool(1);
		var task = pool.submit(() -> {});
		Assert.isFalse(task.cancel());
		Assert.notEquals(TaskState.CANCELLED, task.state);
		pool.shutdown();
		#end
	}

	public function testAwaitReturnsResult():Void {
		var pool = makePool(2);
		var task = pool.submitResult(() -> 99);
		Assert.equals(99, task.await());
	}

	public function testAwaitRethrowsErrorFromTask():Void {
		var pool = makePool(2);
		var task = pool.submitResult(() -> {
			throw "boom";
		});

		Assert.isTrue(throws(() -> task.await()));
		Assert.equals("boom", task.error);
	}

	public function testIdleWorkersDoNotStallGarbageCollection():Void {
		#if target.threaded
		// Idle workers must park inside a GC-free zone. hxcpp does not wrap
		// `Condition.wait()` in one, so a pool that parks there keeps its workers
		// off every GC safepoint and the next collection triggered by this thread
		// deadlocks the process instead of failing.
		var pool = makePool(4);
		pool.submit(() -> {}).await();

		var sink:Array<Dynamic> = [];
		for (i in 0...120000) {
			sink.push({index: i, label: Std.string(i)});
			if (i % 40000 == 0) {
				sink = [];
			}
		}

		Assert.equals(4, pool.workerCount);
		#else
		Assert.pass();
		#end
	}

	public function testShutdownRejectsNewSubmits():Void {
		var pool = makePool(1);
		pool.submit(() -> crossbyte.sys.System.sleep(0.02));
		pool.shutdown();

		Assert.isTrue(throws(() -> pool.submit(() -> 1)));
	}

	public function testShutdownNowCancelsQueuedTasks():Void {
		#if target.threaded
		var pool = makePool(1);
		var running = false;

		var first = pool.submit(() -> {
			running = true;
			crossbyte.sys.System.sleep(0.1);
			running = false;
		});
		var second = pool.submit(() -> {});
		var third = pool.submit(() -> {});

		while (!running) {
			crossbyte.sys.System.sleep(0.005);
		}

		pool.shutdownNow();

		Assert.isTrue(second.isCancelled);
		Assert.isTrue(third.isCancelled);

		var secondCanceled = false;
		second.onCancel(() -> secondCanceled = true);
		Assert.isTrue(secondCanceled);

		first.await();
		#else
		Assert.pass();
		#end
	}

	@:noCompletion private static function throws(fn:Void->Void):Bool {
		try {
			fn();
			return false;
		} catch (_:Dynamic) {
			return true;
		}
	}

	@:noCompletion private static function pumpUntil(done:Void->Bool, timeoutSeconds:Float = 2.0):Void {
		#if target.threaded
		pumpRuntimeUntil(CrossByte.current(), done, timeoutSeconds);
		#end
	}

	@:noCompletion private static function pumpRuntimeUntil(runtime:CrossByte, done:Void->Bool, timeoutSeconds:Float = 2.0):Void {
		#if target.threaded
		var deadline = haxe.Timer.stamp() + timeoutSeconds;
		while (!done() && haxe.Timer.stamp() < deadline) {
			runtime.pump(1 / 60, 0);
			crossbyte.sys.System.sleep(0.001);
		}
		#end
	}
}

#if target.threaded
/**
	A count and a sum that any thread adds to. Not a `Deque<Int>`: on the jvm
	its `pop(false)` answers 0, not null, once it is empty.
**/
private class Tally {
	public var count(get, never):Int;
	public var sum(get, never):Float;

	private var __count:Int = 0;
	private var __sum:Float = 0.0;
	private final __lock:sys.thread.Mutex = new sys.thread.Mutex();

	public function new() {}

	public function add(value:Int):Void {
		__lock.acquire();
		__count++;
		__sum += value;
		__lock.release();
	}

	/** Until `expected` have been added, or for `seconds`. **/
	public function waitFor(expected:Int, seconds:Float):Void {
		var deadline:Float = haxe.Timer.stamp() + seconds;
		while (count < expected && haxe.Timer.stamp() < deadline) {
			crossbyte.sys.System.sleep(0.001);
		}
	}

	private function get_count():Int {
		__lock.acquire();
		var value:Int = __count;
		__lock.release();
		return value;
	}

	private function get_sum():Float {
		__lock.acquire();
		var value:Float = __sum;
		__lock.release();
		return value;
	}
}
#end
