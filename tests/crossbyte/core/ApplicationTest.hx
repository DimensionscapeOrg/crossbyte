package crossbyte.core;

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
	#if !eval
	public function testAServerApplicationRunsOnTheTimersItWasGiven():Void {
		// It built its runtime naming POLL and nothing else, so a
		// ServerApplication asked for a timing wheel ran on the heap.
		var probe = new ProbeServer(TimerStrategy.WHEEL);
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
