package crossbyte.core;

import utest.Assert;

/**
	The runtime fires every timer that is due, however many there are, and
	bounds a frame's timers by time rather than by count.

	It used to fire at most 256 a frame. At the default twelve ticks a second
	that is about three thousand a second, which a few hundred sessions each
	keeping a 50ms retransmit clock exceed, and past the cap every timer
	ran late by more each frame, so a 30 second idle timeout beside 400 busy
	sessions fired at 78 seconds.
**/
@:access(crossbyte.core.CrossByte)
class RuntimeTimersTest extends utest.Test {
	public function testEveryTimerDueInAFrameFires():Void {
		var runtime = new CrossByte(false, DEFAULT, true);
		var fired = 0;
		for (_ in 0...1000) {
			runtime.__timer.setTimeout(0.05, () -> fired++);
		}

		runtime.pump(0.1, 0);
		Assert.equals(1000, fired);
		Assert.equals(0, runtime.timerBacklog);
		Assert.equals(0, runtime.timerOverruns);
		runtime.exit();
	}

	public function testALongTimeoutIsNotDelayedByBusySessions():Void {
		// 400 sessions each re-arming every 50ms: 8000 fires a second at the
		// default rate, against a cap that allowed 3072.
		var runtime = new CrossByte(false, DEFAULT, true);
		var frame:Float = 1 / 12;
		for (_ in 0...400) {
			runtime.__timer.setInterval(0.05, 0.05, () -> {});
		}
		var start = runtime.uptime;
		var firedAt = -1.0;
		runtime.__timer.setTimeout(10.0, () -> firedAt = runtime.uptime - start);

		var frames = 0;
		while (firedAt < 0 && frames < 12 * 40) {
			runtime.pump(frame, 0);
			frames++;
		}
		runtime.exit();

		Assert.isTrue(firedAt >= 10.0 && firedAt <= 10.0 + frame + 1e-9, "a 10 second timeout fired at " + firedAt + "s");
	}

	public function testABurstBeyondTheBudgetIsCountedAndCaughtUp():Void {
		// A frame's timers get one tick interval of wall time; what that
		// leaves is backlog, fired on the frames after.
		var runtime = new CrossByte(false, DEFAULT, true);
		runtime.tps = 500;
		var fired = 0;
		for (_ in 0...100) {
			runtime.__timer.setTimeout(0.05, () -> {
				fired++;
				var end = haxe.Timer.stamp() + 0.0005;
				while (haxe.Timer.stamp() < end) {}
			});
		}

		runtime.pump(0.1, 0);
		Assert.isTrue(fired < 100, "the budget did not bound the frame: " + fired);
		Assert.equals(1, runtime.timerOverruns);
		Assert.equals(100 - fired, runtime.timerBacklog);
		Assert.isTrue(runtime.timerLag > 0, "the backlog was not reported as late");

		var frames = 0;
		while (fired < 100 && frames++ < 100) {
			runtime.pump(0, 0);
		}
		Assert.equals(100, fired);
		Assert.equals(0, runtime.timerBacklog);
		Assert.equals(0.0, runtime.timerLag);
		runtime.exit();
	}
}
