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
