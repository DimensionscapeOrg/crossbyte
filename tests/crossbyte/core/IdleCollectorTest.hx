package crossbyte.core;

import crossbyte.core.CrossByte.IdleCollector;
import crossbyte.events.Event;
import crossbyte.events.TickEvent;
import utest.Assert;

/**
	`CrossByte.collectWhenIdle`: when the runtime collects in the gap before a
	tick. The decision is driven here by a heap and a clock of the test's own
	(a cycle of so much free space, spent so much a tick, and the collector
	running inside the tick that spends the last of it), and natively a real
	runtime runs with it on.
**/
@:access(crossbyte.core.CrossByte)
@:access(crossbyte.core.CrossByte.IdleCollector)
class IdleCollectorTest extends utest.Test {
	private static inline var INTERVAL:Float = 1 / 30;

	public function testNothingIsCollectedBeforeACycleHasBeenSeen():Void {
		// Two collections the collector makes itself: the first starts a
		// cycle to watch, the second ends it.
		var heap = new SimulatedHeap();
		__frames(heap, 59, 0.002, 1);
		Assert.equals(1, heap.natural);
		Assert.equals(0, heap.made, "it collected before it had seen a whole cycle");
	}

	public function testItCollectsInTheGapBeforeTheCycleItLearnedEnds():Void {
		// Thirty frames a cycle, and twenty cycles' worth of frames: two to
		// learn, then two made and one measured, four and one, eight and one.
		var heap = new SimulatedHeap();
		__frames(heap, 600, 0.002, 1);
		var collector = heap.collector();

		Assert.equals(2, heap.natural - collector.missed - collector.measured, "it took more than two cycles to learn");
		Assert.equals(0, collector.missed, "it missed a cycle of a steady load");
		Assert.equals(3, collector.measured);
		Assert.isTrue(heap.made >= 15, "most cycles were not ended in a gap: " + heap.made + " made, " + heap.natural + " by the collector");
		Assert.equals(0, collector.overruns);
		// Moved, not added: 600 frames are twenty cycles of thirty.
		Assert.isTrue(heap.made + heap.natural <= 22, "it collected " + (heap.made + heap.natural) + " times where the heap needed 20");
		// Each a little before the cycle would have ended, never long before.
		Assert.isTrue(heap.shortestCycle >= 27, "it collected " + heap.shortestCycle + " frames into a cycle of 30");
	}

	public function testAGapTooShortForACollectionIsLeftAlone():Void {
		// Ticks of 30 ms leave 3 ms before the next: less than half a tick,
		// which is what has to be left before a collection has been timed.
		var heap = new SimulatedHeap();
		__frames(heap, 600, 0.030, 1);
		Assert.equals(0, heap.made, "it collected in a gap too short for it");
		Assert.equals(20, heap.natural);
	}

	public function testACollectionThatOverranItsGapWantsALongerOneNext():Void {
		// Its collections take 30 ms, and a gap is 23 ms: the first overruns,
		// and the next cycle is left to the collector.
		var heap = new SimulatedHeap();
		heap.takes = 0.030;
		while (heap.made == 0 && heap.frames < 600) {
			__frames(heap, 1, 0.010, 1);
		}
		Assert.equals(1, heap.made);
		Assert.equals(1, heap.collector().overruns, "a collection past the next tick's start was not seen to overrun");
		Assert.floatEquals(0.030, heap.collector().pause);

		var natural = heap.natural;
		__frames(heap, 30, 0.010, 1);
		Assert.equals(1, heap.made, "it collected again in a gap shorter than the collection that overran");
		Assert.equals(natural + 1, heap.natural);
	}

	public function testACollectionThatNeverFitsIsTriedLessAndLessOften():Void {
		// Each takes 30 ms against gaps of 23: every one made overruns. Eased
		// back down, the estimate would let one be tried, and overrun, every five
		// cycles; so after an overrun the next cycles are left to the collector,
		// twice as many after each.
		var heap = new SimulatedHeap();
		heap.takes = 0.030;
		__frames(heap, 3000, 0.010, 1);
		Assert.equals(heap.made, heap.collector().overruns);
		Assert.isTrue(heap.made >= 3, "it stopped trying: " + heap.made + " made");
		Assert.isTrue(heap.made <= 8, "it overran " + heap.made + " times in about a hundred cycles");
	}

	public function testACycleCutShortMovesTheNextCollectionSooner():Void {
		var heap = new SimulatedHeap();
		__frames(heap, 120, 0.002, 1);
		var made = heap.made;
		Assert.equals(2, made, "it had not started collecting");

		// Twice the garbage a tick: cycles of fifteen frames. The first ends
		// before the collection learned from thirty; it follows them after.
		__frames(heap, 150, 0.002, 2);
		Assert.isTrue(heap.collector().missed >= 1, "a cycle that ended early was not seen");
		Assert.isTrue(heap.collector().missed <= 3, "it missed " + heap.collector().missed + " cycles of fifteen frames");
		Assert.isTrue(heap.made - made >= 5, "it did not follow the shorter cycles: " + (heap.made - made) + " made in ten");
		Assert.isTrue(heap.lastMadeCycle >= 13 && heap.lastMadeCycle <= 14, "it collected " + heap.lastMadeCycle + " frames into cycles of 15");
	}

	public function testALongerCycleIsFollowed():Void {
		// Half the garbage a tick: cycles of sixty frames. Collecting thirty
		// frames in would collect twice as often as the heap needs; the next
		// cycle it measures says so.
		var heap = new SimulatedHeap();
		__frames(heap, 120, 0.002, 1);
		__frames(heap, 1800, 0.002, 0.5);
		Assert.isTrue(heap.lastMadeCycle >= 55 && heap.lastMadeCycle < 60, "it collected " + heap.lastMadeCycle + " frames into cycles of 60");
		Assert.equals(0, heap.collector().overruns);
	}

	#if !js
	public function testARuntimeAsksNothingWithItOff():Void {
		var runtime = new CrossByte(false, DEFAULT, false);
		runtime.tps = 500;
		var heap = new SimulatedHeap();
		runtime.__idleCollector = heap.collector();
		try {
			for (_ in 0...5) {
				runtime.__defaultMainLoop();
			}
			Assert.equals(0, heap.asked, "a runtime with collectWhenIdle off asked when to collect");

			runtime.collectWhenIdle = true;
			for (_ in 0...5) {
				runtime.__defaultMainLoop();
			}
			#if cpp
			Assert.equals(5, heap.asked, "a runtime collecting when idle did not ask once a frame");
			#else
			Assert.equals(0, heap.asked, "collectWhenIdle did something off hxcpp");
			#end
		} catch (error:Dynamic) {
			runtime.exit();
			runtime.__finalizeExit();
			throw error;
		}
		runtime.exit();
		runtime.__finalizeExit();
	}
	#end

	#if cpp
	public function testARuntimeCollectingWhenIdleKeepsItsTicksAndTimers():Void {
		// Garbage enough a tick to run several cycles in five seconds.
		var ended = new sys.thread.Lock();
		var ticks:Int = 0;
		var fired:Int = 0;
		var started:Float = 0.0;
		var finished:Float = 0.0;
		var keep:Array<Junk> = [for (_ in 0...4096) null];
		var child:CrossByte = null;
		child = CrossByte.make(DEFAULT, HEAP, configured -> {
			configured.tps = 30;
			configured.collectWhenIdle = true;
			configured.addEventListener(Event.INIT, _ -> {
				started = haxe.Timer.stamp();
				crossbyte.Timer.setInterval(0.1, 0.1, () -> fired++);
			});
			configured.addEventListener(TickEvent.TICK, _ -> {
				ticks++;
				for (i in 0...100000) {
					keep[i & 4095] = new Junk(i);
				}
				if (ticks == 150) {
					finished = haxe.Timer.stamp();
					configured.exit();
				}
			});
			configured.addEventListener(Event.EXIT, _ -> ended.release());
		});

		var exited:Bool = ended.wait(30.0);
		if (!exited) {
			child.exit();
		}
		Assert.isTrue(exited, "a runtime collecting when idle did not run 150 ticks in 30 s");
		var seconds:Float = finished - started;
		Assert.isTrue(seconds >= 4.5 && seconds <= 9.0, "150 ticks at 30 a second took " + seconds + " s");
		Assert.isTrue(fired >= 40, "a 100 ms interval fired " + fired + " times in " + seconds + " s");
		var collector:IdleCollector = child.__idleCollector;
		Assert.notNull(collector, "the runtime never asked when to collect");
		if (collector != null) {
			Assert.isTrue(@:privateAccess collector.__seen, "no collection was seen in five seconds of garbage");
		}
	}
	#end

	// `count` frames at 30 a second: a tick of `work` seconds spending
	// `spend`, the collector's chance at the gap, and the gap waited out.
	private static function __frames(heap:SimulatedHeap, count:Int, work:Float, spend:Float):Void {
		for (_ in 0...count) {
			var start:Float = heap.now;
			heap.tick(work, spend);
			heap.collector().atGap(start + INTERVAL, INTERVAL);
			if (heap.now < start + INTERVAL) {
				heap.now = start + INTERVAL;
			}
			heap.frames++;
		}
	}
}

/**
	A heap whose cycle has 30 units of free space, spent by ticks; the
	collector runs inside the tick that spends the last of it. A collection
	made in a gap takes `takes` seconds and starts the cycle again.
**/
@:access(crossbyte.core.CrossByte.IdleCollector)
private class SimulatedHeap {
	public var now:Float = 100.0;
	public var free:Float = 30.0;
	public var takes:Float = 0.010;
	public var frames:Int = 0;
	public var natural:Int = 0;
	public var made:Int = 0;
	public var asked:Int = 0;
	public var shortestCycle:Int = 1000000;
	public var longestCycle:Int = 0;
	public var lastMadeCycle:Int = 0;

	private var __spent:Float = 0.0;
	private var __cycleFrames:Int = 0;
	private var __happened:Bool = false;
	private var __collector:HeapCollector;

	public function new() {
		__collector = new HeapCollector(this);
	}

	public inline function collector():IdleCollector {
		return __collector;
	}

	public function tick(seconds:Float, spend:Float):Void {
		now += seconds;
		__spent += spend;
		__cycleFrames++;
		if (__spent >= free) {
			natural++;
			__endCycle();
		}
	}

	public function collectNow():Void {
		made++;
		now += takes;
		lastMadeCycle = __cycleFrames;
		__endCycle();
	}

	public function happened():Bool {
		var was:Bool = __happened;
		__happened = false;
		return was;
	}

	private function __endCycle():Void {
		if (natural + made > 1) {
			if (__cycleFrames < shortestCycle) {
				shortestCycle = __cycleFrames;
			}
			if (__cycleFrames > longestCycle) {
				longestCycle = __cycleFrames;
			}
		}
		__spent = 0.0;
		__cycleFrames = 0;
		__happened = true;
	}
}

@:access(crossbyte.core.CrossByte.IdleCollector)
private class HeapCollector extends IdleCollector {
	private var __heap:SimulatedHeap;

	public function new(heap:SimulatedHeap) {
		super();
		__heap = heap;
	}

	override public function atGap(deadline:Float, interval:Float):Bool {
		__heap.asked++;
		return super.atGap(deadline, interval);
	}

	override private function clock():Float {
		return __heap.now;
	}

	override private function collect():Void {
		__heap.collectNow();
	}

	override private function collectedSince():Bool {
		return __heap.happened();
	}

	override private function freeSpace():Float {
		return __heap.free;
	}
}

#if cpp
private class Junk {
	public var a:Int;
	public var b:Float;
	public var c:Float;

	public function new(a:Int) {
		this.a = a;
		b = a * 0.5;
		c = a * 0.25;
	}
}
#end
