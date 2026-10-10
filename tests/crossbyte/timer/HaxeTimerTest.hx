package crossbyte.timer;

import crossbyte.core.CrossByte;
import crossbyte.utils.GlobalTimer;
import haxe.Timer as HxTimer;
import utest.Assert;

@:access(crossbyte.core.CrossByte)
@:access(haxe.Timer)
class HaxeTimerTest extends utest.Test {
	// Made while the program's statics are initialized. Natively that is
	// before main, so before any runtime exists, which is where a library's
	// static initializer makes its timers, as hxcpp's debug server does in
	// every debug build that includes it when no debugger is listening. On
	// the jvm statics wait for first use, when the harness's runtime is
	// already up, and this is an ordinary timer.
	static var early:EarlyTimer = new EarlyTimer();

	public function testConstructorStartsTimerImmediately():Void {
		var runtime = CrossByte.current();
		var fired = 0;
		var timer = new HxTimer(100);
		timer.run = function() fired++;

		runtime.pump(0.05, 0);
		Assert.equals(0, fired);

		runtime.pump(0.05, 0);
		Assert.equals(1, fired);

		timer.stop();
	}

	public function testAnIntervalRunsAtTheRateItAskedFor():Void {
		// The overshoot carries into the next period. Counting tick deltas down
		// and resetting to the full interval after each run would round a period
		// up to whole ticks: 100ms at 12 ticks a second would run every 167ms, 12
		// times in two seconds rather than 20.
		var runtime = CrossByte.current();
		var fired = 0;
		var timer = new HxTimer(100);
		timer.run = () -> fired++;
		var global = 0;
		var id = GlobalTimer.setInterval(() -> global++, 100);

		for (_ in 0...24) {
			runtime.pump(1 / 12, 0);
		}
		timer.stop();
		GlobalTimer.clearInterval(id);

		Assert.isTrue(fired >= 19 && fired <= 20, "a 100ms haxe.Timer ran " + fired + " times in 2s");
		Assert.isTrue(global >= 19 && global <= 20, "a 100ms GlobalTimer.setInterval ran " + global + " times in 2s");
	}

	public function testTimeoutsArmedTogetherRunInTheOrderTheyWereArmed():Void {
		// haxe.Timer.delay and GlobalTimer.setTimeout, as a library ported
		// from JavaScript arms them: f before g whenever both are due.
		var runtime = CrossByte.current();
		var order:Array<String> = [];
		for (i in 0...3) {
			HxTimer.delay(() -> order.push("delay" + i), 0);
			GlobalTimer.setTimeout(() -> order.push("global" + i), 0);
		}
		runtime.pump(0, 0);
		Assert.equals("delay0,global0,delay1,global1,delay2,global2", order.join(","));
	}

	public function testATimerBehindRunsOnceAFrameRatherThanInABurst():Void {
		var runtime = CrossByte.current();
		var fired = 0;
		var timer = new HxTimer(10);
		timer.run = () -> fired++;

		runtime.pump(0.5, 0);
		Assert.equals(1, fired, "a stall made a burst");
		runtime.pump(0, 0);
		Assert.equals(2, fired);
		timer.stop();
	}

	public function testATimerFasterThanTheFramesOwesAtMostOneRun():Void {
		// Run once a frame, a 10ms timer falls most of a frame further behind
		// each frame. Owed all of it, it ran at every pass once the passes
		// came faster (a host pumping faster, a higher tick rate): ten times
		// its rate here, for as long as the debt lasted.
		var runtime = CrossByte.current();
		var fired = 0;
		var timer = new HxTimer(10);
		timer.run = () -> fired++;
		var global = 0;
		var id = GlobalTimer.setInterval(() -> global++, 10);
		for (_ in 0...24) {
			runtime.pump(1 / 12, 0);
		}

		var timerBehind = fired;
		var globalBehind = global;
		for (_ in 0...100) {
			runtime.pump(0.001, 0);
		}
		timer.stop();
		GlobalTimer.clearInterval(id);

		var fast = fired - timerBehind;
		Assert.isTrue(fast >= 9 && fast <= 12, 'a 10ms haxe.Timer ran $fast times in 100ms of 1ms passes');
		fast = global - globalBehind;
		Assert.isTrue(fast >= 9 && fast <= 12, 'a 10ms GlobalTimer.setInterval ran $fast times in 100ms of 1ms passes');
	}

	public function testStoppingOneTimerLeavesTheOthersRunning():Void {
		// Timers are not kept in one map by an id that wraps, where a new timer
		// could take a live one's id and evict it.
		var runtime = CrossByte.current();
		var a = 0;
		var b = 0;
		var first = new HxTimer(50);
		first.run = () -> a++;
		var second = new HxTimer(50);
		second.run = () -> b++;

		first.stop();
		runtime.pump(0.05, 0);
		second.stop();

		Assert.equals(0, a);
		Assert.equals(1, b);
	}

	public function testStopIsIdempotent():Void {
		var runtime = CrossByte.current();
		var before = runtime.__timer.size;
		var timer = new HxTimer(100);
		Assert.equals(before + 1, runtime.__timer.size);

		timer.stop();
		Assert.equals(before, runtime.__timer.size);

		timer.stop();
		Assert.equals(before, runtime.__timer.size);
	}

	public function testARunThatThrowsKeepsTheTimerRunning():Void {
		var runtime = CrossByte.current();
		var fired = 0;
		crossbyte.utils.Logger.sink = _ -> {};
		var timer = new HxTimer(100);
		timer.run = () -> {
			fired++;
			throw "run bug";
		};

		for (_ in 0...3) {
			runtime.pump(0.1, 0);
		}
		crossbyte.utils.Logger.sink = null;
		timer.stop();

		Assert.equals(3, fired);
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

		// The state before any runtime exists: no primordial to arm on.
		__withNoRuntime(() -> {
			try {
				timer = new HxTimer(100);
				timer.run = () -> fired++;
			} catch (e:Dynamic) {
				Assert.fail("making a timer with no runtime threw: " + e);
			}
			Assert.isTrue(HxTimer.__waiting.indexOf(timer) >= 0, "the timer found a runtime where there was none");
		});
		if (timer == null) {
			return;
		}

		// __withNoRuntime put the runtime back and armed what was waiting.
		Assert.equals(-1, HxTimer.__waiting.indexOf(timer));
		runtime.pump(0.1, 0);
		Assert.equals(1, fired);
		timer.stop();
	}

	public function testStoppingATimerStillWaitingForARuntimeDoesNotThrow():Void {
		__withNoRuntime(() -> {
			var timer = new HxTimer(100);
			try {
				timer.stop();
				Assert.pass();
			} catch (e:Dynamic) {
				Assert.fail("stopping a waiting timer threw: " + e);
			}
			Assert.equals(-1, HxTimer.__waiting.indexOf(timer), "a stopped timer stayed waiting");
		});
	}

	// Runs `body` as if no runtime existed, restoring the one there is after
	// and arming, on it, whatever was made to wait meanwhile.
	private static function __withNoRuntime(body:Void->Void):Void {
		var primordial = CrossByte.__primordial;
		CrossByte.__primordial = null;
		#if target.threaded
		var local = CrossByte.__threadLocalStorage.value;
		CrossByte.__threadLocalStorage.value = null;
		#end
		var failure:Dynamic = null;
		try {
			body();
		} catch (e:Dynamic) {
			failure = e;
		}
		CrossByte.__primordial = primordial;
		#if target.threaded
		CrossByte.__threadLocalStorage.value = local;
		#end
		HxTimer.__primordialReady(primordial);
		if (failure != null) {
			throw failure;
		}
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
