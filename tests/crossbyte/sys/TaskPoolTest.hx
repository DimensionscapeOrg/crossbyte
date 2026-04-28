package crossbyte.sys;

import crossbyte.sys.TaskState;
import utest.Assert;
#if (cpp || neko || hl)
import sys.thread.Mutex;
#end

class TaskPoolTest extends utest.Test {
	public function testTasksRunAndComplete():Void {
		var pool = new TaskPool(1);
		var value = 0;
		var task = pool.submit(() -> value = 5);
		task.await();

		Assert.equals(5, value);
		Assert.isTrue(task.isDone);
		Assert.equals(TaskState.COMPLETED, task.state);
		Assert.isNull(task.result);
	}

	public function testSubmitResultStoresAndReturnsResult():Void {
		var pool = new TaskPool(2);
		var task = pool.submitResult(() -> 7);

		Assert.equals(7, task.await());
		Assert.equals(7, task.result);
		Assert.equals(TaskState.COMPLETED, task.state);
		Assert.isTrue(task.isDone);
	}

	public function testErrorsCaptureAndDispatchError():Void {
		var pool = new TaskPool(2);
		var caught:Dynamic = null;
		var task = pool.submitResult(() -> {
			throw "bad";
		});
		task.onError(value -> caught = value);

		Assert.equals(2, pool.workerCount);
		Assert.isTrue(throws(() -> task.await()));
		Assert.equals("bad", caught);
		Assert.equals("bad", task.error);
		Assert.equals(TaskState.FAILED, task.state);
		Assert.isTrue(task.isFailed);
		Assert.isTrue(task.isDone);
	}

	public function testFifoExecutionWithSingleWorker():Void {
		var pool = new TaskPool(1);
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
		#if (cpp || neko || hl)
		var pool = new TaskPool(4);
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
			Sys.sleep(0.05);
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
		#if (cpp || neko || hl)
		var pool = new TaskPool(1);
		var cancelled = false;
		pool.submit(() -> {
			Sys.sleep(0.2);
		});
		var task = pool.submit(() -> {
			Sys.sleep(0.2);
		});

		Sys.sleep(0.01);
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
		#if (cpp || neko || hl)
		var pool = new TaskPool(1);
		var started = false;
		var task = pool.submit(() -> {
			started = true;
			Sys.sleep(0.1);
		});

		while (!started) {
			Sys.sleep(0.005);
		}

		Assert.isFalse(task.cancel());
		Assert.notEquals(TaskState.CANCELLED, task.state);
		Assert.isFalse(task.isCancelled);

		pool.shutdownNow();
		#else
		var pool = new TaskPool(1);
		var task = pool.submit(() -> {});
		Assert.isFalse(task.cancel());
		Assert.notEquals(TaskState.CANCELLED, task.state);
		pool.shutdown();
		#end
	}

	public function testAwaitReturnsResult():Void {
		var pool = new TaskPool(2);
		var task = pool.submitResult(() -> 99);
		Assert.equals(99, task.await());
	}

	public function testAwaitRethrowsErrorFromTask():Void {
		var pool = new TaskPool(2);
		var task = pool.submitResult(() -> {
			throw "boom";
		});

		Assert.isTrue(throws(() -> task.await()));
		Assert.equals("boom", task.error);
	}

	public function testShutdownRejectsNewSubmits():Void {
		var pool = new TaskPool(1);
		pool.submit(() -> Sys.sleep(0.02));
		pool.shutdown();

		Assert.isTrue(throws(() -> pool.submit(() -> 1)));
	}

	public function testShutdownNowCancelsQueuedTasks():Void {
		#if (cpp || neko || hl)
		var pool = new TaskPool(1);
		var running = false;

		var first = pool.submit(() -> {
			running = true;
			Sys.sleep(0.1);
			running = false;
		});
		var second = pool.submit(() -> {});
		var third = pool.submit(() -> {});

		while (!running) {
			Sys.sleep(0.005);
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
}
