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
	#if cpp
	// Written by the allocating thread with a plain store and read in a loop
	// that must not itself reach a safepoint: a Lock, a Deque or a Mutex would
	// enter a GC-free zone and let the collection through, hiding the stall.
	static var __allocatorDone:Int = 0;

	/**
		A loop that only pumps does not stall another thread's collection.
		With no sleep and nothing allocated, pump() reached no GC safepoint, so
		a collection another thread started waited on this one for ever.
	**/
	public function testAPumpOnlyLoopDoesNotStallACollection():Void {
		var runtime = CrossByte.current();
		__allocatorDone = 0;

		Thread.create(() -> {
			// Enough to need collections, of which the last is forced.
			var keep:Array<haxe.io.Bytes> = [];
			for (i in 0...2000) {
				keep.push(haxe.io.Bytes.alloc(64 * 1024));
				if (keep.length > 32) {
					keep.shift();
				}
			}
			cpp.vm.Gc.run(true);
			__allocatorDone = 1;
		});

		var deadline:Float = haxe.Timer.stamp() + 10;
		while (__allocatorDone == 0 && haxe.Timer.stamp() < deadline) {
			runtime.pump(0.0, 0.0);
		}

		Assert.equals(1, __allocatorDone, "the other thread's collection was held up by a loop that only pumps");
	}
	#end

	#if (cpp && windows)
	/**
		The process keeps the priority it was started with unless asked to
		run high. Every native Windows build raised itself to
		HIGH_PRIORITY_CLASS as the runtime loaded, unasked and undocumented.
	**/
	public function testTheProcessIsRaisedToHighPriorityOnlyWhenAsked():Void {
		var high:Int = 0x80; // HIGH_PRIORITY_CLASS
		var before:Int = crossbyte.core._internal.NativeWindowsRuntime.getPriorityClass();
		Assert.isFalse(CrossByte.windowsHighPriority);
		Assert.notEquals(high, before, "the process ran at high priority unasked");

		CrossByte.windowsHighPriority = true;
		var raised:Int = crossbyte.core._internal.NativeWindowsRuntime.getPriorityClass();
		CrossByte.windowsHighPriority = false;
		var lowered:Int = crossbyte.core._internal.NativeWindowsRuntime.getPriorityClass();

		Assert.equals(high, raised);
		Assert.equals(before, lowered, "set back, the process did not return to its class");
	}
	#end

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
