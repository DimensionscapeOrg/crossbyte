package crossbyte.core;

import crossbyte.events.Event;
import crossbyte.events.TickEvent;
import utest.Assert;

/**
 * Target-agnostic coverage for the runtime's stop flag, which is read and
 * written through the `__getRunning()`/`__setRunning()` accessors (an atomic
 * 0/1 int on cpp, a plain Bool elsewhere). These assertions check the
 * single-threaded, host-driven behaviour: a running runtime ticks, `exit()`
 * is observed by the next `pump()`, and the EXIT lifecycle fires exactly
 * once.
 *
 * Runs under every target (including eval/interp): host-driven runtimes are
 * driven synchronously via `pump()`, so there are no threads, sleeps, or
 * race-dependent assertions here.
 */
@:access(crossbyte.core.CrossByte)
class CrossByteRunningFlagTest extends utest.Test {
	public function testRunningRuntimePumpsTicks():Void {
		var runtime = new CrossByte(false, DEFAULT, true);
		var ticks = 0;
		runtime.addEventListener(TickEvent.TICK, _ -> ticks++);

		Assert.isTrue(runtime.__getRunning());
		runtime.pump(1 / 60, 0);
		runtime.pump(1 / 60, 0);
		Assert.equals(2, ticks);

		runtime.exit();
	}

	public function testExitIsObservedByNextPump():Void {
		var runtime = new CrossByte(false, DEFAULT, true);
		var ticks = 0;
		var exits = 0;
		runtime.addEventListener(TickEvent.TICK, _ -> ticks++);
		runtime.addEventListener(Event.EXIT, _ -> exits++);

		runtime.pump(1 / 60, 0);
		Assert.equals(1, ticks);

		runtime.exit();
		Assert.isFalse(runtime.__getRunning());
		Assert.equals(1, exits);

		// A pump after exit must not tick again and must not re-run finalize.
		runtime.pump(1 / 60, 0);
		Assert.equals(1, ticks);
		Assert.equals(1, exits);
	}

	public function testPumpingAnExitedRuntimeDoesNotClaimTheThread():Void {
		#if target.threaded
		var before = CrossByte.current();
		var runtime = new CrossByte(false, DEFAULT, true);

		runtime.pump(1 / 60, 0);
		runtime.exit();
		Assert.equals(before, CrossByte.current());

		// pump() on an exited runtime must not make it the thread's current
		// runtime. It reads the stop flag before it publishes `this`; otherwise a
		// runtime that can never tick again would stay CrossByte.current() for the
		// rest of the thread's life, and everything that later resolved the
		// current runtime would silently stop being serviced, with nothing thrown.
		runtime.pump(1 / 60, 0);
		Assert.equals(before, CrossByte.current());
		Assert.notEquals(runtime, CrossByte.current());
		Assert.isTrue(CrossByte.current().__getRunning());
		#else
		Assert.pass();
		#end
	}

	public function testTicksStillReachTheCurrentRuntimeAfterPumpingAnExitedOne():Void {
		#if target.threaded
		var stopped = new CrossByte(false, DEFAULT, true);
		stopped.pump(1 / 60, 0);
		stopped.exit();
		stopped.pump(1 / 60, 0);

		// Work handed to the current runtime after pumping an exited one is still
		// serviced.
		var runtime = CrossByte.current();
		var ticks = 0;
		var listener = function(_:TickEvent):Void {
			ticks++;
		};

		runtime.addEventListener(TickEvent.TICK, listener);
		runtime.pump(1 / 60, 0);
		runtime.removeEventListener(TickEvent.TICK, listener);

		Assert.equals(1, ticks);
		#else
		Assert.pass();
		#end
	}

	public function testSetRunningRoundTripsThroughAccessor():Void {
		var runtime = new CrossByte(false, DEFAULT, true);

		Assert.isTrue(runtime.__getRunning());
		runtime.__setRunning(false);
		Assert.isFalse(runtime.__getRunning());
		runtime.__setRunning(true);
		Assert.isTrue(runtime.__getRunning());

		runtime.exit();
	}
}
