package crossbyte.sys;

import crossbyte.core.CrossByte;
import crossbyte.errors.IllegalOperationError;
import crossbyte.events.ThreadEvent;
import utest.Assert;

@:access(crossbyte.core.CrossByte)
class WorkerTest extends utest.Test {
	public function testCompleteCapturesResultAndState():Void {
		var worker = new Worker();
		var completeMessage:Dynamic = null;
		worker.addEventListener(ThreadEvent.COMPLETE, (event:ThreadEvent) -> completeMessage = event.message);
		worker.doWork = message -> worker.sendComplete("done:" + message);

		worker.run("job");
		pumpUntil(() -> worker.state != WorkerState.RUNNING);

		Assert.equals("done:job", completeMessage);
		Assert.equals("done:job", worker.result);
		Assert.equals(WorkerState.COMPLETED, worker.state);
		Assert.isTrue(worker.completed);
		Assert.isTrue(worker.canceled);
		Assert.isFalse(worker.cancelRequested);
	}

	public function testRunReturnsWhileTheWorkIsStillGoing():Void {
		// On the jvm and the interpreter run() did the work itself, on the
		// runtime's thread, and dispatched COMPLETE before returning.
		#if target.threaded
		var worker = new Worker();
		var caller = new sys.thread.Tls<Bool>();
		caller.value = true;
		var onCaller:Null<Bool> = null;
		var completed = false;
		worker.addEventListener(ThreadEvent.COMPLETE, (_:ThreadEvent) -> completed = true);
		worker.doWork = _ -> {
			onCaller = caller.value == true;
			crossbyte.sys.System.sleep(0.3);
			worker.sendComplete("done");
		};

		var start = haxe.Timer.stamp();
		worker.run();
		var held = haxe.Timer.stamp() - start;
		var completedDuringRun = completed;
		pumpUntil(() -> completed, 5.0);

		Assert.isTrue(held < 0.15, "run() held the caller for " + held + "s");
		Assert.isFalse(completedDuringRun, "COMPLETE was dispatched inside run()");
		Assert.isTrue(completed);
		Assert.equals(false, onCaller, "the work ran on the thread that called run()");
		#else
		Assert.pass();
		#end
	}

	public function testProgressIsDispatchedBeforeComplete():Void {
		var worker = new Worker();
		var events:Array<String> = [];
		worker.addEventListener(ThreadEvent.PROGRESS, (event:ThreadEvent) -> events.push("progress:" + event.message));
		worker.addEventListener(ThreadEvent.COMPLETE, (event:ThreadEvent) -> events.push("complete:" + event.message));
		worker.doWork = _ -> {
			worker.sendProgress("one");
			worker.sendProgress("two");
			worker.sendComplete("done");
		};

		worker.run();
		pumpUntil(() -> events.length >= 3 || worker.state != WorkerState.RUNNING);

		Assert.equals("progress:one", events[0]);
		Assert.equals("progress:two", events[1]);
		Assert.equals("complete:done", events[2]);
		Assert.equals(3, events.length);
	}

	public function testSendErrorCapturesErrorAndState():Void {
		var worker = new Worker();
		var errorMessage:Dynamic = null;
		worker.addEventListener(ThreadEvent.ERROR, (event:ThreadEvent) -> errorMessage = event.message);
		worker.doWork = _ -> worker.sendError("bad");

		worker.run();
		pumpUntil(() -> worker.state != WorkerState.RUNNING);

		Assert.equals("bad", errorMessage);
		Assert.equals("bad", worker.error);
		Assert.equals(WorkerState.FAILED, worker.state);
		Assert.isTrue(worker.failed);
		Assert.isTrue(worker.canceled);
	}

	public function testThrownExceptionIsCapturedAsError():Void {
		var worker = new Worker();
		var errorMessage:Dynamic = null;
		worker.addEventListener(ThreadEvent.ERROR, (event:ThreadEvent) -> errorMessage = event.message);
		worker.doWork = _ -> throw "boom";

		worker.run();
		pumpUntil(() -> worker.state != WorkerState.RUNNING);

		Assert.equals("boom", errorMessage);
		Assert.equals("boom", worker.error);
		Assert.equals(WorkerState.FAILED, worker.state);
	}

	public function testCancelSuppressesLaterMessages():Void {
		var worker = new Worker();
		var completeCount:Int = 0;
		var progressCount:Int = 0;
		worker.addEventListener(ThreadEvent.COMPLETE, (_:ThreadEvent) -> completeCount++);
		worker.addEventListener(ThreadEvent.PROGRESS, (_:ThreadEvent) -> progressCount++);
		worker.doWork = _ -> {
			worker.cancel(false);
			worker.sendProgress("late");
			worker.sendComplete("late");
		};

		worker.run();
		pumpUntil(() -> worker.state == WorkerState.CANCELLED);

		Assert.equals(0, completeCount);
		Assert.equals(0, progressCount);
		Assert.equals(WorkerState.CANCELLED, worker.state);
		Assert.isTrue(worker.canceled);
		Assert.isTrue(worker.cancelRequested);
	}

	public function testRunWhileRunningThrows():Void {
		var worker = new Worker();
		var threw:Bool = false;
		worker.doWork = _ -> {
			try {
				worker.run("again");
			} catch (e:IllegalOperationError) {
				threw = true;
			}
			worker.sendComplete();
		};

		worker.run();
		pumpUntil(() -> worker.state != WorkerState.RUNNING);

		Assert.isTrue(threw);
		Assert.equals(WorkerState.COMPLETED, worker.state);
	}

	public function testCleanResetsReusableWorker():Void {
		var worker = new Worker();
		worker.doWork = _ -> worker.sendComplete("first");
		worker.run();
		pumpUntil(() -> worker.state != WorkerState.RUNNING);
		worker.clean();

		var completeMessage:Dynamic = null;
		worker.addEventListener(ThreadEvent.COMPLETE, (event:ThreadEvent) -> completeMessage = event.message);
		worker.doWork = _ -> worker.sendComplete("second");
		worker.run();
		pumpUntil(() -> worker.state != WorkerState.RUNNING);

		Assert.equals("second", completeMessage);
		Assert.equals(WorkerState.COMPLETED, worker.state);
		Assert.equals("second", worker.result);
	}

	public function testAWorkerDeliversToTheRuntimeItRanOnAndHoldsNoTickListener():Void {
		// A running worker held a tick listener on its runtime and polled its
		// queue every tick. It posts to the runtime instead, which wakes it.
		#if target.threaded
		var primordial = CrossByte.current();
		var child = new CrossByte(false, DEFAULT, true);
		var worker = new Worker();
		var completed = false;
		var sent = false;
		worker.addEventListener(ThreadEvent.COMPLETE, (_:ThreadEvent) -> completed = true);
		worker.doWork = _ -> {
			worker.sendComplete("done");
			sent = true;
		};

		worker.run();
		Assert.isFalse(child.hasEventListener(crossbyte.events.TickEvent.TICK), "a running worker holds a tick listener");
		waitFor(() -> sent);

		primordial.pump(0, 0);
		Assert.isFalse(completed, "delivered to a runtime other than the one it ran on");
		child.pump(0, 0);
		Assert.isTrue(completed);
		child.exit();
		#else
		Assert.pass();
		#end
	}

	public function testACancelledWorkerDeliversNothingMore():Void {
		#if target.threaded
		var child = new CrossByte(false, DEFAULT, true);
		var worker = new Worker();
		var progress = 0;
		var sent = false;
		worker.addEventListener(ThreadEvent.PROGRESS, (_:ThreadEvent) -> progress++);
		worker.doWork = _ -> {
			worker.sendProgress(1);
			sent = true;
		};

		worker.run();
		waitFor(() -> sent);
		worker.cancel(false);
		child.pump(0, 0);
		child.exit();

		Assert.equals(0, progress);
		#else
		Assert.pass();
		#end
	}

	public function testEverythingQueuedIsDeliveredOnOneTick():Void {
		#if target.threaded
		var worker = new Worker();
		var progress:Int = 0;
		var completed:Bool = false;
		var sent:Bool = false;

		worker.addEventListener(ThreadEvent.PROGRESS, (_:ThreadEvent) -> progress++);
		worker.addEventListener(ThreadEvent.COMPLETE, (_:ThreadEvent) -> completed = true);
		worker.doWork = _ -> {
			for (i in 0...64) {
				worker.sendProgress(i);
			}
			worker.sendComplete("done");
			sent = true;
		};

		worker.run();
		// Waited on without pumping, so every message the worker sends is already
		// queued before the runtime gets its first tick.
		waitFor(() -> sent);
		Assert.isTrue(sent);

		CrossByte.current().pump(1 / 60, 0);

		// A tick used to deliver exactly one message, so this took 65 of them --
		// paced by the runtime's tick rate rather than by how often the host pumps.
		Assert.equals(64, progress);
		Assert.isTrue(completed);
		#else
		Assert.pass();
		#end
	}

	public function testDeliveryPerTickIsBounded():Void {
		#if target.threaded
		var previous:Int = Worker.maxMessagesPerTick;
		Worker.maxMessagesPerTick = 4;

		var worker = new Worker();
		var progress:Int = 0;
		var sent:Bool = false;

		worker.addEventListener(ThreadEvent.PROGRESS, (_:ThreadEvent) -> progress++);
		worker.doWork = _ -> {
			for (i in 0...10) {
				worker.sendProgress(i);
			}
			sent = true;
		};

		worker.run();
		waitFor(() -> sent);

		var runtime = CrossByte.current();
		runtime.pump(1 / 60, 0);
		var afterFirstTick:Int = progress;
		runtime.pump(1 / 60, 0);
		var afterSecondTick:Int = progress;

		// Restored before asserting so a failure here cannot leak the bound into
		// whatever utest runs next.
		Worker.maxMessagesPerTick = previous;
		worker.cancel();

		// The bound is what keeps a producer faster than the loop from holding the
		// tick indefinitely, and with it the socket poll that runs after it.
		Assert.equals(4, afterFirstTick);
		Assert.equals(8, afterSecondTick);
		#else
		Assert.pass();
		#end
	}

	private static function waitFor(done:Void->Bool, timeoutSeconds:Float = 2.0):Void {
		#if target.threaded
		var deadline = haxe.Timer.stamp() + timeoutSeconds;
		while (!done() && haxe.Timer.stamp() < deadline) {
			crossbyte.sys.System.sleep(0.001);
		}
		#end
	}

	private static function pumpUntil(done:Void->Bool, timeoutSeconds:Float = 2.0):Void {
		#if target.threaded
		var runtime = CrossByte.current();
		var deadline = haxe.Timer.stamp() + timeoutSeconds;
		while (!done() && haxe.Timer.stamp() < deadline) {
			runtime.pump(1 / 60, 0);
			crossbyte.sys.System.sleep(0.001);
		}
		#end
	}
}
