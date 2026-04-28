package crossbyte.timer;

import crossbyte.core.CrossByte;
import haxe.Timer as HxTimer;
import utest.Assert;

@:access(crossbyte.core.CrossByte)
@:access(haxe.Timer)
class HaxeTimerTest extends utest.Test {
	public function testConstructorStartsTimerImmediately():Void {
		var fired = 0;
		var timer = new HxTimer(100);
		timer.run = function() fired++;

		@:privateAccess timer.__update(0.05);
		Assert.equals(0, fired);

		@:privateAccess timer.__update(0.05);
		Assert.equals(1, fired);

		timer.stop();
	}

	public function testStopIsIdempotent():Void {
		var baseCount = @:privateAccess HxTimer.timerCount;
		var timer = new HxTimer(100);

		Assert.equals(baseCount + 1, @:privateAccess HxTimer.timerCount);

		timer.stop();
		Assert.equals(baseCount, @:privateAccess HxTimer.timerCount);

		timer.stop();
		Assert.equals(baseCount, @:privateAccess HxTimer.timerCount);
	}

	public function testTimerCreatedOnChildRuntimeStillFiresOnPrimordialRuntime():Void {
		var primordial = CrossByte.current();
		var child = new CrossByte(false, DEFAULT, true);
		var fired = 0;
		var timer = new HxTimer(100);
		timer.run = function() fired++;

		child.pump(0.1, 0);
		Assert.equals(0, fired);

		primordial.pump(0.1, 0);
		Assert.equals(1, fired);

		timer.stop();
		child.exit();
	}
}
