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

		// As if 2^32 timers had come and gone since: the next id is the live
		// one's.
		@:privateAccess GlobalTimer.__lastTimerID = live - 1;
		var next = GlobalTimer.setTimeout(() -> {}, 100);
		Assert.notEquals(live, next, "a new timer took a live one's id");

		GlobalTimer.clearInterval(live);
		GlobalTimer.clearTimeout(next);
		CrossByte.current().pump(0.2, 0);
		Assert.equals(0, fired, "clearInterval could not reach the live timer");
	}

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
