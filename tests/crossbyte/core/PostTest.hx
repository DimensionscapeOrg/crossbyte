package crossbyte.core;

import crossbyte.events.Event;
import crossbyte.events.TickEvent;
import utest.Assert;
#if target.threaded
import sys.thread.Lock;
#end

/**
	Handing a runtime work from another thread with `post`.

	A runtime waiting out the rest of its frame used to sleep through it: a
	callback posted mid-frame waited for the next tick, 38ms on average at the
	default rate and up to a whole frame. These run a child runtime's real
	loop at two ticks a second and post just after a tick, the worst moment,
	where the old wait was half a second.
**/
@:access(crossbyte.core.CrossByte)
class PostTest extends utest.Test {
	#if target.threaded
	public function testAPostWakesTheDefaultLoop():Void {
		var latency = __postAfterATick(DEFAULT);
		Assert.isTrue(latency >= 0, "the posted callback never ran");
		Assert.isTrue(latency < 0.15, "a post waited " + latency + "s for a loop at 2 ticks a second");
	}

	public function testAPostWakesThePollLoop():Void {
		var latency = __postAfterATick(POLL);
		Assert.isTrue(latency >= 0, "the posted callback never ran");
		Assert.isTrue(latency < 0.15, "a post waited " + latency + "s for a loop at 2 ticks a second");
	}

	public function testExitFromAnotherThreadStopsTheLoopPromptly():Void {
		// exit() from another thread used to be noticed only once the loop
		// had slept out its frame.
		var ticked = new Lock();
		var exited = new Lock();
		var child = CrossByte.make(DEFAULT, HEAP, configured -> {
			configured.tps = 1;
			configured.addEventListener(TickEvent.TICK, _ -> ticked.release());
			configured.addEventListener(Event.EXIT, _ -> exited.release());
		});

		var sawTick = ticked.wait(5.0);
		var start = haxe.Timer.stamp();
		child.exit();
		var sawExit = exited.wait(5.0);
		var took = haxe.Timer.stamp() - start;

		Assert.isTrue(sawTick);
		Assert.isTrue(sawExit, "the child never exited");
		Assert.isTrue(took < 0.3, "a loop at one tick a second took " + took + "s to stop");
	}

	// Posts from this thread just after the child ticks, and answers how long
	// the callback waited to run, or -1 if it never did.
	private static function __postAfterATick(loop:MainLoopType):Float {
		var ticked = new Lock();
		var ran = new Lock();
		var waited = -1.0;
		var child = CrossByte.make(loop, HEAP, configured -> {
			configured.tps = 2;
			configured.addEventListener(TickEvent.TICK, _ -> ticked.release());
		});

		// The second tick, so the loop is settled into its cadence.
		ticked.wait(5.0);
		ticked.wait(5.0);
		var postedAt = haxe.Timer.stamp();
		child.post(() -> {
			waited = haxe.Timer.stamp() - postedAt;
			ran.release();
		});
		ran.wait(5.0);
		child.exit();
		return waited;
	}
	#end

	public function testAPostToAnExitedRuntimeIsRefused():Void {
		var runtime = new CrossByte(false, DEFAULT, true);
		runtime.exit();

		var ran = false;
		Assert.isFalse(runtime.post(() -> ran = true), "a post that can never run was accepted");
		Assert.isFalse(ran);
	}

	public function testWhatWasPostedBeforeTheExitStillRuns():Void {
		var runtime = new CrossByte(false, DEFAULT, true);
		var order:Array<String> = [];
		runtime.addEventListener(Event.EXIT, _ -> {
			order.push("exit");
			runtime.post(() -> order.push("posted by exit"));
		});

		Assert.isTrue(runtime.post(() -> order.push("posted before")));
		runtime.exit();

		Assert.same(["posted before", "exit", "posted by exit"], order);
	}

	public function testPostedCallbacksRunInOrderOnTheNextPump():Void {
		var runtime = new CrossByte(false, DEFAULT, true);
		var order:Array<Int> = [];
		for (i in 0...5) {
			var n:Int = i;
			runtime.post(() -> order.push(n));
		}
		Assert.same([], order);
		runtime.pump(1 / 60, 0);
		runtime.exit();
		Assert.same([0, 1, 2, 3, 4], order);
	}
}
