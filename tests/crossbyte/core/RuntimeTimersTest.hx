package crossbyte.core;

import utest.Assert;

/**
	The runtime fires every timer that is due, however many there are, and
	bounds a frame's timers by time rather than by count.

	A cap of 256 a frame would be about three thousand a second at the
	default twelve ticks a second, which a few hundred sessions each keeping
	a 50ms retransmit clock exceed. Past such a cap every timer runs later
	each frame, so a 30 second idle timeout beside 400 busy sessions would
	fire at 78 seconds.
**/
@:access(crossbyte.core.CrossByte)
class RuntimeTimersTest extends utest.Test {
	/**
		Wall time and scheduler time convert at the present: the scheduler's
		time now is the clock's now, and other times follow by the difference.
		Counting the scheduler's time on top of its start instead would put
		every wall time an hour out on a runtime that has run for an hour.
	**/
	public function testWallClockConversionsMeetAtThePresent():Void {
		var runtime = new CrossByte(false, DEFAULT, true);
		// A runtime that has been running a while, at the clock's pace, as
		// one with a loop of its own does.
		var started:Float = haxe.Timer.stamp();
		crossbyte.sys.System.sleep(0.3);
		runtime.pump(haxe.Timer.stamp() - started, 0);

		var virtualNow:Float = crossbyte.Timer.getTime();
		var wallNow:Float = crossbyte.Timer.now();
		Assert.isTrue(virtualNow >= 0.25, "the runtime had not run: " + virtualNow);

		Assert.floatEquals(virtualNow, crossbyte.Timer.fromWallClock(wallNow), 0.05);
		Assert.floatEquals(wallNow, crossbyte.Timer.toWallClock(virtualNow), 0.05);
		// A deadline ten seconds off is ten seconds of the scheduler's time off.
		Assert.floatEquals(virtualNow + 10, crossbyte.Timer.fromWallClock(wallNow + 10), 0.05);
		Assert.floatEquals(wallNow + 10, crossbyte.Timer.toWallClock(virtualNow + 10), 0.05);
		// And each undoes the other.
		Assert.floatEquals(wallNow - 2, crossbyte.Timer.toWallClock(crossbyte.Timer.fromWallClock(wallNow - 2)), 0.05);
		runtime.exit();
	}

	/**
		`Timer.stamp()` with no application is an IllegalOperationError that
		says so, as `CrossByte.make()` is, not a null access to the primordial
		runtime's uptime (natively, in a release build, a crash).
	**/
	public function testStampWithNoApplicationSaysSo():Void {
		var primordial:CrossByte = CrossByte.__primordial;
		CrossByte.__primordial = null;
		var thrown:Dynamic = null;
		try {
			crossbyte.Timer.stamp();
		} catch (e:Dynamic) {
			thrown = e;
		}
		CrossByte.__primordial = primordial;

		Assert.isTrue(Std.isOfType(thrown, crossbyte.errors.IllegalOperationError), "stamp() threw " + thrown);
	}

	#if target.threaded
	/**
		A thread no runtime runs on has no timers, and asking for them is an
		IllegalOperationError, as `CrossByte.current()` is there, not a bare
		String.
	**/
	public function testATimerOnAThreadWithNoRuntimeIsRefused():Void {
		var result = new sys.thread.Deque<Dynamic>();
		sys.thread.Thread.create(() -> {
			try {
				crossbyte.Timer.setTimeout(1.0, () -> {});
				result.add("no throw");
			} catch (e:Dynamic) {
				result.add(e);
			}
		});
		var thrown:Dynamic = result.pop(true);
		Assert.isTrue(Std.isOfType(thrown, crossbyte.errors.IllegalOperationError), "setTimeout threw " + thrown);
	}
	#end

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
		// default rate, well past the 3072 a cap of 256 a frame would allow.
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
