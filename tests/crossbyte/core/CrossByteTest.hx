package crossbyte.core;

import crossbyte.errors.IllegalOperationError;
import crossbyte.utils.ThreadUtil;
import utest.Assert;
#if target.threaded
import sys.thread.Deque;
import sys.thread.Lock;
import sys.thread.Thread;
#end

@:access(crossbyte.core.CrossByte)
class CrossByteTest extends utest.Test {
	public function testMakeRequiresPrimordialRuntime():Void {
		var primordial = CrossByte.__primordial;
		CrossByte.__primordial = null;

		var threw = throwsIllegalOperationError(() -> CrossByte.make());
		CrossByte.__primordial = primordial;

		Assert.isTrue(threw);
	}

	public function testCurrentRestoresPrimordialAfterHostDrivenChildExit():Void {
		#if target.threaded
		var primordial = CrossByte.current();
		var child = new CrossByte(false, DEFAULT, true);

		Assert.equals(child, CrossByte.current());

		child.exit();
		Assert.equals(primordial, CrossByte.current());
		Assert.isTrue(ThreadUtil.isPrimordial);
		#else
		Assert.pass();
		#end
	}

	public function testCurrentThrowsOnForeignThreadWithoutRuntime():Void {
		// Every threaded target, not only native. Elsewhere current() handed
		// back the primordial runtime on any thread, so whatever a worker
		// thread registered there was touched from two threads, and
		// ThreadUtil.isPrimordial was true on every thread.
		#if target.threaded
		var queue:Deque<String> = new Deque();
		Thread.create(() -> {
			try {
				CrossByte.current();
				queue.add("no-throw");
			} catch (_:IllegalOperationError) {
				queue.add("illegal-operation");
			} catch (_:Dynamic) {
				queue.add("wrong-error");
			}
			queue.add(ThreadUtil.isPrimordial ? "primordial" : "not-primordial");
		});

		Assert.equals("illegal-operation", queue.pop(true));
		Assert.equals("not-primordial", queue.pop(true));
		Assert.isTrue(ThreadUtil.isPrimordial);
		#else
		Assert.pass();
		#end
	}

	public function testAChildRuntimeIsCurrentOnItsOwnThread():Void {
		#if target.threaded
		var primordial = CrossByte.current();
		var arrived = new Lock();
		var seen:Array<String> = [];
		var child = CrossByte.make();
		// make() rebinds this thread's timers to the child; pumping the
		// primordial takes them back for the cases that follow.
		primordial.pump(0, 0);

		child.__post(() -> {
			seen.push(CrossByte.current() == child ? "child" : "other");
			seen.push(ThreadUtil.isPrimordial ? "primordial" : "not-primordial");
			arrived.release();
		});
		var ran = arrived.wait(5.0);
		child.exit();

		Assert.isTrue(ran, "the child never ran what was posted to it");
		Assert.same(["child", "not-primordial"], seen);
		Assert.equals(primordial, CrossByte.current());
		#else
		Assert.pass();
		#end
	}

	public function testThreadUtilRecognizesPrimordialThread():Void {
		Assert.isTrue(ThreadUtil.isPrimordial);
	}

	public function testTickEventIsReusedAcrossPumps():Void {
		#if target.threaded
		var runtime = new CrossByte(false, DEFAULT, true);
		var first = null;
		var second = null;
		var count = 0;

		runtime.addEventListener(crossbyte.events.TickEvent.TICK, event -> {
			count++;
			if (count == 1) {
				first = event;
			} else if (count == 2) {
				second = event;
			}
		});

		runtime.pump(1 / 60, 0);
		runtime.pump(1 / 60, 0);
		runtime.exit();

		Assert.notNull(first);
		Assert.equals(first, second);
		#else
		Assert.pass();
		#end
	}

	public function testTpsIsClampedToAtLeastOne():Void {
		#if target.threaded
		var runtime = new CrossByte(false, DEFAULT, true);

		// tps == 0 would make __tickInterval +Infinity and hang the wait loop.
		runtime.tps = 0;
		Assert.isTrue(runtime.tps == 1);
		Assert.isTrue(Math.isFinite(runtime.__tickInterval));

		runtime.tps = 60;
		Assert.isTrue(runtime.tps == 60);

		runtime.exit();
		#else
		Assert.pass();
		#end
	}

	public function testLoopReportsRealElapsedTimeAfterALongFrame():Void {
		#if target.threaded
		// A frame that ran long is reported as it ran. The runtime used to cap
		// this at a quarter second, which cost more than it bought: the capped
		// figure was also what haxe.Timer and the HTTP connection sweep
		// subtracted from their own deadlines, so a stall silently made every
		// one of them run slow, and a listener handed the capped delta had no
		// way back to the real one. Bounding the step is the consumer's call,
		// made where the right bound is actually known.
		var runtime = new CrossByte(false, DEFAULT, true);
		var reported:Float = -1;

		runtime.addEventListener(crossbyte.events.TickEvent.TICK, event -> {
			reported = event.delta;
		});

		runtime.__dt = 0.8;
		runtime.__defaultMainLoop();
		runtime.exit();

		Assert.floatEquals(0.8, reported);
		#else
		Assert.pass();
		#end
	}

	@:noCompletion private static function throwsIllegalOperationError(fn:Void->Void):Bool {
		try {
			fn();
			return false;
		} catch (_:IllegalOperationError) {
			return true;
		} catch (_:Dynamic) {
			return false;
		}
	}
}
