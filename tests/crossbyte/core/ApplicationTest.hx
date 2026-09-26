package crossbyte.core;

import crossbyte.events.TickEvent;
import crossbyte.events.UncaughtErrorEvent;
import utest.Assert;

/**
	What the application base classes build their runtime from.

	The runtime each builds is intercepted rather than made: a real one would
	be a second primordial runtime, with its own loop queued to run after
	`main`, in a process whose primordial runtime is the test harness's.
**/
@:access(crossbyte.core.Application)
@:access(crossbyte.core.CrossByte)
class ApplicationTest extends utest.Test {
	public function testAServerApplicationRunsOnTheTimersItWasGiven():Void {
		// It built its runtime naming POLL and nothing else, so a
		// ServerApplication asked for a timing wheel ran on the heap. On the
		// interpreter it could not be built at all: its main-thread check
		// read true on the main thread itself.
		var probe:ProbeServer = null;
		try {
			probe = new ProbeServer(TimerStrategy.WHEEL);
		} catch (e:Dynamic) {
			Application.__application = null;
			Assert.fail("a ServerApplication could not be made: " + Std.string(e));
			return;
		}
		try {
			Assert.equals(TimerStrategy.WHEEL, probe.timers);
			Assert.equals(MainLoopType.POLL, probe.loop);
			Assert.isFalse(probe.hostDriven);
		} catch (e:Dynamic) {
			__release(probe);
			throw e;
		}
		__release(probe);
	}

	#if js
	/**
		A POLL runtime on JavaScript runs the DEFAULT loop, since there is no
		socket set to poll there. It threw at its first frame, which took down
		every ServerApplication on Node.
	**/
	@:timeout(5000)
	public function testAPollRuntimeRunsOnJavaScript(async:utest.Async):Void {
		var runtime = new CrossByte(false, POLL, true);
		runtime.tps = 100;
		var ticks = 0;
		var failures = 0;
		runtime.addEventListener(TickEvent.TICK, _ -> ticks++);
		runtime.addEventListener(UncaughtErrorEvent.UNCAUGHT_ERROR, _ -> failures++);
		crossbyte.utils.Logger.sink = _ -> {};
		runtime.__runEventLoop();

		js.Syntax.code("setTimeout({0}, 200)", () -> {
			runtime.exit();
			crossbyte.utils.Logger.sink = null;
			Assert.equals(0, failures, "the POLL loop failed its frames");
			Assert.isTrue(ticks > 3, "the POLL loop ticked " + ticks + " times in 200ms");
			async.done();
		});
	}
	#end

	private static function __release(app:Application):Void {
		if (app.crossByte != null) {
			app.crossByte.exit();
		}
		Application.__application = null;
	}
}

@:access(crossbyte.core.Application)
@:access(crossbyte.core.CrossByte)
private class ProbeServer extends ServerApplication {
	public var loop:MainLoopType;
	public var timers:TimerStrategy;
	public var hostDriven:Bool;

	public function new(timers:TimerStrategy) {
		super(timers);
	}

	override private function __createRuntime():CrossByte {
		loop = __crossByteLoopType;
		timers = __crossByteTimers;
		hostDriven = __crossByteHostDriven;
		// A runtime of its own, standing in for the primordial one.
		return new CrossByte(false, MainLoopType.DEFAULT, true);
	}
}
