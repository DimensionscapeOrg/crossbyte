package crossbyte._internal.http;

import sys.thread.Lock;
import sys.thread.Mutex;
import utest.Assert;

/**
 * The threads URLLoader's loads run on. Shared by the whole process, so these
 * cases restore whatever they change, and allow for threads earlier cases
 * left waiting.
 */
class LoadPoolTest extends utest.Test {
	public function testAThrowingLoadLeavesThePoolWorking():Void {
		// What a load throws is caught on its thread, which then takes the
		// next load: one failure must not cost every later load its thread.
		var done = new Lock();
		LoadPool.run(() -> throw "a load that fails");
		LoadPool.run(() -> done.release());
		Assert.isTrue(done.wait(5.0), "a load queued after a failing one never ran");
	}

	public function testThreadsAreKeptBetweenLoads():Void {
		var before:Int = LoadPool.threadsStarted();
		for (i in 0...10) {
			var done = new Lock();
			LoadPool.run(() -> done.release());
			Assert.isTrue(done.wait(5.0));
		}
		// One, or two when a load is queued in the moment before the thread
		// that ran the last is waiting again -- not ten.
		var started:Int = LoadPool.threadsStarted() - before;
		Assert.isTrue(started <= 2, 'ten loads one after another started $started threads');
	}

	public function testNoMoreThanMaxThreadsRunAtOnce():Void {
		var saved:Int = LoadPool.maxThreads;
		LoadPool.maxThreads = 2;

		var lock = new Mutex();
		var running:Int = 0;
		var most:Int = 0;
		var gate = new Lock();
		var finished = new Lock();
		for (i in 0...5) {
			LoadPool.run(() -> {
				lock.acquire();
				running++;
				if (running > most) {
					most = running;
				}
				lock.release();
				gate.wait(5.0);
				lock.acquire();
				running--;
				lock.release();
				finished.release();
			});
		}

		// Until two are running, then a little longer for a third that should
		// not start.
		var until:Float = haxe.Timer.stamp() + 3.0;
		while (haxe.Timer.stamp() < until) {
			lock.acquire();
			var reached:Bool = most >= 2;
			lock.release();
			if (reached) {
				break;
			}
			Sys.sleep(0.01);
		}
		Sys.sleep(0.2);
		lock.acquire();
		var atOnce:Int = most;
		lock.release();
		for (i in 0...5) {
			gate.release();
		}
		var all:Bool = true;
		for (i in 0...5) {
			all = finished.wait(5.0) && all;
		}
		LoadPool.maxThreads = saved;

		Assert.isTrue(all, "a queued load never ran");
		// Threads earlier cases left waiting count too: lowering the limit
		// retires those past it rather than letting them add to the loads.
		Assert.equals(2, atOnce);
	}

	public function testAThreadWithNothingToDoEnds():Void {
		var saved:Float = LoadPool.idleSeconds;
		LoadPool.idleSeconds = 0.1;

		var done = new Lock();
		LoadPool.run(() -> done.release());
		Assert.isTrue(done.wait(5.0));
		var busy:Int = LoadPool.threadCount();
		// The thread that ran it now waits a tenth of a second, then ends.
		// Others earlier cases left are on the wait they began with.
		var until:Float = haxe.Timer.stamp() + 3.0;
		while (LoadPool.threadCount() >= busy && haxe.Timer.stamp() < until) {
			Sys.sleep(0.02);
		}
		var after:Int = LoadPool.threadCount();
		LoadPool.idleSeconds = saved;

		Assert.isTrue(after < busy, 'the idle thread was kept: $after threads, $busy before');
	}
}
