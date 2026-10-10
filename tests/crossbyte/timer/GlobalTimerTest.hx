package crossbyte.timer;

import crossbyte.core.CrossByte;
import crossbyte.utils.GlobalTimer;
import utest.Assert;

class GlobalTimerTest extends utest.Test {
	public function testSetTimeoutInvokesClosureWithEmptyArgs():Void {
		var fired = 0;
		GlobalTimer.setTimeout(() -> fired++, 100, []);

		CrossByte.current().pump(0.1, 0);
		Assert.equals(1, fired);
	}

	public function testClearTimeoutCancelsPendingCallback():Void {
		var fired = 0;
		var id = GlobalTimer.setTimeout(() -> fired++, 100);

		GlobalTimer.clearTimeout(id);
		CrossByte.current().pump(0.1, 0);
		Assert.equals(0, fired);
	}

	public function testAWrappedIdDoesNotTakeOverALiveTimer():Void {
		var fired = 0;
		var live = GlobalTimer.setInterval(() -> fired++, 100);

		// As if 2^32 timers had come and gone since: the counter has wrapped,
		// and the next id is the live one's.
		@:privateAccess GlobalTimer.__wrapped = true;
		@:privateAccess GlobalTimer.__lastTimerID = live - 1;
		var next = GlobalTimer.setTimeout(() -> {}, 100);
		// Every id from here on is past any issued before the rewind.
		@:privateAccess GlobalTimer.__wrapped = false;
		Assert.notEquals(live, next, "a new timer took a live one's id");

		GlobalTimer.clearInterval(live);
		GlobalTimer.clearTimeout(next);
		CrossByte.current().pump(0.2, 0);
		Assert.equals(0, fired, "clearInterval could not reach the live timer");
	}

	#if target.threaded
	/**
		A timer runs on the runtime of the thread that set it. One still
		waiting as that runtime exits never runs, and its id went on holding
		it, and whatever its function held, for as long as the process ran.
	**/
	@:timeout(20000)
	public function testATimerWhoseRuntimeExitsIsLetGo(async:utest.Async):Void {
		var timeout:UInt = 0;
		var interval:UInt = 0;
		var child:CrossByte = CrossByte.make(DEFAULT, HEAP, configured -> {
			configured.addEventListener(crossbyte.events.Event.INIT, _ -> {
				timeout = GlobalTimer.setTimeout(() -> {}, 60000);
				interval = GlobalTimer.setInterval(() -> {}, 60000);
				configured.exit();
			});
		});
		var held = () -> @:privateAccess (GlobalTimer.__timers.exists(timeout) || GlobalTimer.__timers.exists(interval));
		crossbyte.net.NetPump.until(() -> @:privateAccess child.__didExit && timeout != 0 && !held(), 10.0, function(_) {
			Assert.isTrue(timeout != 0 && interval != 0, "the child set no timers");
			Assert.isFalse(held(), "a timer on a runtime that exited was kept");
			async.done();
		});
	}

	/**
		From a thread with no runtime, a timer goes to the primordial runtime
		with its function already given: `delay` and `GlobalTimer` set it
		before the timer is handed over, where they set it after, and a
		runtime quick enough could run the timer once with none.
	**/
	public function testATimerSetFromAThreadWithNoRuntimeRunsItsFunctionOnce():Void {
		var runtime = CrossByte.current();
		var delayed = 0;
		var timedOut = 0;
		var ticks = 0;
		var interval:UInt = 0;
		var done = new sys.thread.Lock();
		sys.thread.Thread.create(() -> {
			haxe.Timer.delay(() -> delayed++, 0);
			GlobalTimer.setTimeout(() -> timedOut++, 0);
			interval = GlobalTimer.setInterval(() -> ticks++, 0);
			done.release();
		});
		Assert.isTrue(done.wait(5.0), "the thread did not finish");
		runtime.pump(0, 0);
		runtime.pump(0, 0);
		GlobalTimer.clearInterval(interval);
		Assert.equals(1, delayed);
		Assert.equals(1, timedOut);
		Assert.isTrue(ticks >= 1, "the interval never ran");
	}

	/**
		Timers set and cleared from several threads at once keep distinct ids,
		and clearing them all leaves nothing behind.

		The map and the id counter are locked on every threaded target, not
		only on hxcpp: unlocked, four threads doing this on the jvm would be
		issued ids twice and leave entries in the map, and a clearTimeout could
		stop another thread's timer.
	**/
	public function testTimersFromManyThreadsKeepDistinctIds():Void {
		var threads:Int = 4;
		var perThread:Int = 4000;
		var done = new sys.thread.Lock();
		var issued:Array<Array<Int>> = [for (_ in 0...threads) []];
		var failures:Array<String> = [];
		var failuresLock = new sys.thread.Mutex();
		var before:Int = __held();

		for (t in 0...threads) {
			var mine:Array<Int> = issued[t];
			sys.thread.Thread.create(() -> {
				try {
					for (_ in 0...perThread) {
						mine.push(GlobalTimer.setTimeout(() -> {}, 3600000));
					}
					for (id in mine) {
						GlobalTimer.clearTimeout(id);
					}
				} catch (e:haxe.Exception) {
					failuresLock.acquire();
					failures.push(e.message);
					failuresLock.release();
				}
				done.release();
			});
		}
		for (_ in 0...threads) {
			done.wait();
		}
		// The timers were made on threads with no runtime, so they were
		// armed and stopped through the primordial runtime's post queue.
		CrossByte.current().pump(0.01, 0);

		Assert.equals(0, failures.length, failures.join("; "));
		var seen = new Map<Int, Bool>();
		var twice:Int = 0;
		for (ids in issued) {
			for (id in ids) {
				if (seen.exists(id)) {
					twice++;
				}
				seen.set(id, true);
			}
		}
		Assert.equals(0, twice, twice + " ids were issued twice");
		Assert.equals(before, __held(), "clearing every timer left " + (__held() - before) + " in the map");
	}

	private static function __held():Int {
		var count:Int = 0;
		var timers:Map<UInt, haxe.Timer> = @:privateAccess GlobalTimer.__timers;
		for (_ in timers.keys()) {
			count++;
		}
		return count;
	}
	#end

	public function testClearIntervalStopsRepeatingCallback():Void {
		var fired = 0;
		var id = GlobalTimer.setInterval(() -> fired++, 100);

		CrossByte.current().pump(0.1, 0);
		Assert.equals(1, fired);

		GlobalTimer.clearInterval(id);
		CrossByte.current().pump(0.2, 0);
		Assert.equals(1, fired);
	}
}
