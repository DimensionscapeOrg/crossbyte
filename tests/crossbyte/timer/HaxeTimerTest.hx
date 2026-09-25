package crossbyte.timer;

import crossbyte.core.CrossByte;
import haxe.Timer as HxTimer;
import utest.Assert;

@:access(crossbyte.core.CrossByte)
@:access(haxe.Timer)
class HaxeTimerTest extends utest.Test {
	// Made while the program's statics are initialized. Natively that is
	// before main, so before any runtime exists -- where a library's static
	// initializer makes its timers, as hxcpp's debug server does in every
	// debug build that includes it when no debugger is listening. On the jvm
	// statics wait for first use, when the harness's runtime is already up,
	// and this is an ordinary timer.
	static var early:EarlyTimer = new EarlyTimer();

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

	public function testATimerMadeBeforeMainFiresOnceTheRuntimeRuns():Void {
		#if !(java || jvm)
		// Where statics are set up before main, this has to be the case it
		// claims to be, or it proves nothing.
		Assert.isTrue(early.madeBeforeRuntime, "the timer was made after the runtime, not before main");
		#end
		Assert.isNull(early.error, "making a timer before main threw: " + early.error);

		var runtime = CrossByte.current();
		var deadline = HxTimer.stamp() + 3;
		while (early.fired == 0 && HxTimer.stamp() < deadline) {
			runtime.pump(0.1, 0);
		}
		Assert.isTrue(early.fired > 0, "the timer never fired (made before the runtime: " + early.madeBeforeRuntime + ")");
		early.stop();
	}

	public function testATimerMadeWithNoRuntimeWaitsForOne():Void {
		var runtime = CrossByte.current();
		var fired = 0;
		var timer:HxTimer = null;

		// The state before any runtime exists: no primordial, and the tick
		// listener on nothing.
		__withNoRuntime(() -> {
			try {
				timer = new HxTimer(100);
				timer.run = () -> fired++;
			} catch (e:Dynamic) {
				Assert.fail("making a timer with no runtime threw: " + e);
			}
			Assert.isNull(HxTimer.__listening, "the timer found a runtime to listen to where there was none");
		});
		if (timer == null) {
			return;
		}

		// Nothing counts it down until a runtime is set up and takes it.
		HxTimer.__primordialReady(runtime);
		Assert.equals(runtime, HxTimer.__listening);
		runtime.pump(0.1, 0);
		Assert.equals(1, fired);
		timer.stop();
	}

	public function testStoppingATimerAfterItsRuntimeHasGoneDoesNotThrow():Void {
		var timer = new HxTimer(100);
		var runtime = CrossByte.current();

		__withNoRuntime(() -> {
			try {
				timer.stop();
				Assert.pass();
			} catch (e:Dynamic) {
				Assert.fail("stopping a timer threw once its runtime had gone: " + e);
			}
		});

		// Whatever it was listening on, it was taken off -- or other timers
		// still running keep it listening, and there it is still attached.
		Assert.isTrue(HxTimer.__listening == null || HxTimer.timerCount > 0);
		HxTimer.__primordialReady(runtime);
	}

	// Runs `body` as if no runtime existed, restoring the one there is after.
	// Timers still running from other cases are put back on it.
	private static function __withNoRuntime(body:Void->Void):Void {
		var primordial = CrossByte.__primordial;
		var listening = HxTimer.__listening;
		if (listening != null) {
			listening.removeEventListener(crossbyte.events.TickEvent.TICK, HxTimer.onTick);
			HxTimer.__listening = null;
		}
		CrossByte.__primordial = null;
		try {
			body();
		} catch (e:Dynamic) {
			CrossByte.__primordial = primordial;
			HxTimer.__primordialReady(primordial);
			throw e;
		}
		CrossByte.__primordial = primordial;
		HxTimer.__primordialReady(primordial);
	}
}

@:access(crossbyte.core.CrossByte)
private class EarlyTimer {
	public var fired:Int = 0;
	public var error:Dynamic = null;
	public var madeBeforeRuntime:Bool;

	private var __timer:HxTimer;

	public function new() {
		madeBeforeRuntime = CrossByte.__primordial == null;
		try {
			__timer = new HxTimer(100);
			__timer.run = () -> fired++;
		} catch (e:Dynamic) {
			error = e;
		}
	}

	public function stop():Void {
		if (__timer != null) {
			__timer.stop();
		}
	}
}
