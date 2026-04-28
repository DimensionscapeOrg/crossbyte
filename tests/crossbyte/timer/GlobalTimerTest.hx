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
