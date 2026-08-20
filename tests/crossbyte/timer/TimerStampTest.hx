package crossbyte.timer;

import haxe.Timer as HxTimer;
import utest.Assert;

/**
 * `haxe.Timer.stamp()` on its own, with no runtime around it.
 *
 * CrossByte vendors `haxe.Timer`, so this is the framework's clock and not the
 * standard library's, and a good deal of the runtime measures intervals with
 * it: the frame cost behind `cpuLoad`, the base both timer schedulers start
 * from, and the default seed `Random` falls back to when it is not given one.
 *
 * It reached Node returning a constant, and not one of those reported a
 * problem -- an interval measured against a constant is just zero, and a seed
 * taken from one is just a fixed number. That is the reason this case exists
 * separately from `HaxeTimerTest`: it needs no runtime, so it can run on every
 * target including the JavaScript ones, which is where the clock was wrong.
 */
class TimerStampTest extends utest.Test {
	public function testStampIsNotAConstantZero():Void {
		Assert.isTrue(HxTimer.stamp() > 0, "haxe.Timer.stamp() returned " + HxTimer.stamp() + "; a clock that is not running reads as no time passing");
	}

	public function testStampNeverGoesBackwards():Void {
		var first = HxTimer.stamp();
		var second = HxTimer.stamp();
		Assert.isTrue(second >= first, "stamp went backwards: " + first + " then " + second);
	}

	public function testStampAdvancesWhileWorkIsDone():Void {
		var start = HxTimer.stamp();
		var end = start;
		var spins = 0;
		var burn = 0.0;

		// Busy rather than sleeping, because this has to hold on a target with
		// no sleep to call. The arithmetic is here so the loop cannot be folded
		// away and so that enough wall time passes for a coarse clock -- on a
		// fine one the first read already differs and the cap is never neared.
		while (end == start && spins < 2000000) {
			spins++;
			burn += spins * 0.5;
			end = HxTimer.stamp();
		}

		Assert.isTrue(end > start, "stamp did not move across " + spins + " reads (burn " + burn + ")");
	}
}
