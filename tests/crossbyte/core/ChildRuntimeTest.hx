package crossbyte.core;

import crossbyte.events.Event;
import utest.Assert;
#if target.threaded
import sys.thread.Lock;
import sys.thread.Tls;
#end

/**
	Child runtimes made with `CrossByte.make()`: they leave the calling
	thread's timers alone, can be configured before their thread starts, and
	exit with the runtime that made them.
**/
@:access(crossbyte.core.CrossByte)
@:access(crossbyte.Timer)
class ChildRuntimeTest extends utest.Test {
	#if target.threaded
	public function testMakeLeavesTheCallersTimersAlone():Void {
		var before = crossbyte.Timer.currentOrNull();
		var child = CrossByte.make();
		var after = crossbyte.Timer.currentOrNull();
		child.exit();

		Assert.notNull(before);
		Assert.isTrue(before == after, "make() took over the calling thread's timers");
	}

	public function testATimerArmedAfterMakeRunsOnTheThreadThatArmedIt():Void {
		// The auditor's case: a heartbeat armed on the main thread after a
		// simulation thread was started ran on the simulation's thread.
		var runtime = CrossByte.current();
		var here = new Tls<Bool>();
		here.value = true;
		var ranHere:Null<Bool> = null;
		var child = CrossByte.make();

		crossbyte.Timer.setTimeout(0.01, () -> ranHere = here.value == true);
		var deadline = haxe.Timer.stamp() + 3;
		while (ranHere == null && haxe.Timer.stamp() < deadline) {
			runtime.pump(1 / 60, 0);
			Sys.sleep(0.005);
		}
		child.exit();

		Assert.equals(true, ranHere, "the timer ran on another thread, or never");
	}

	public function testAChildIsConfiguredBeforeItsThreadStarts():Void {
		var ran = new Lock();
		var inits = 0;
		var tpsAtInit:Int = 0;
		var child:CrossByte = null;
		child = CrossByte.make(DEFAULT, HEAP, configured -> {
			configured.tps = 50;
			configured.addEventListener(Event.INIT, _ -> {
				inits++;
				tpsAtInit = configured.tps;
				ran.release();
			});
		});

		var initArrived = ran.wait(5.0);
		child.exit();

		Assert.isTrue(initArrived, "INIT never reached a listener added while configuring");
		Assert.equals(1, inits);
		Assert.equals(50, tpsAtInit);
	}

	public function testChildrenExitWithTheRuntimeThatMadeThem():Void {
		// On the primordial runtime this is what ends the process: a child
		// used to keep running, and the process waiting on its thread, after
		// the primordial runtime had exited.
		var parent = new CrossByte(false, DEFAULT, true);
		var exited = new Lock();
		var child = CrossByte.make(DEFAULT, HEAP, configured -> configured.addEventListener(Event.EXIT, _ -> exited.release()));

		parent.exit();
		var childExited = exited.wait(5.0);
		if (!childExited) {
			child.exit();
		}

		Assert.isTrue(childExited, "the child outlived the runtime that made it");
		Assert.isFalse(child.__getRunning());
		Assert.equals(CrossByte.__primordial, CrossByte.current(), "the thread was not handed back");
	}

	public function testAChildExitedWhileConfiguringNeverStarts():Void {
		var inits = 0;
		var exits = 0;
		var child = CrossByte.make(DEFAULT, HEAP, configured -> {
			configured.addEventListener(Event.INIT, _ -> inits++);
			configured.addEventListener(Event.EXIT, _ -> exits++);
			configured.exit();
		});

		Assert.isFalse(child.__getRunning());
		Assert.equals(0, inits);
		Assert.equals(1, exits);
	}
	#end
}
