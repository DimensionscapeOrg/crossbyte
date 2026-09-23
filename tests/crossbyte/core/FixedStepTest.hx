package crossbyte.core;

import utest.Assert;

class FixedStepTest extends utest.Test {
	public function testElapsedTimeBecomesWholeStepsAndAFraction():Void {
		var sim = new FixedStep(0.1);

		Assert.equals(2, sim.advance(0.25));
		Assert.floatEquals(0.5, sim.alpha, 1e-9);

		Assert.isTrue(sim.step());
		Assert.isTrue(sim.step());
		Assert.isFalse(sim.step());
		Assert.equals(2, sim.tick);

		// The half step left over counts toward the next one.
		Assert.equals(1, sim.advance(0.05));
		Assert.floatEquals(0, sim.alpha, 1e-9);
		Assert.isTrue(sim.step());
		Assert.equals(3, sim.tick);
	}

	public function testEachStepIsNumberedAsItIsTaken():Void {
		var sim = new FixedStep(1 / 60);
		sim.advance(4 / 60);

		var numbered:Array<Int> = [];
		while (sim.step()) {
			numbered.push(sim.tick);
		}
		Assert.same([1, 2, 3, 4], numbered);
		Assert.equals(0, sim.pending);
	}

	public function testAnEvenRateStepsOnSchedule():Void {
		// A runtime ticking at 144 Hz under a 60 Hz simulation: each tick is
		// exactly five twelfths of a step, so the steps fall on a fixed
		// pattern. A 144th of a second does not add up to a 60th exactly in
		// binary, and floored without care the tick that completes a step
		// sometimes falls a hair short and the next one steps twice -- a
		// stutter at a perfectly even rate, on 500 ticks of these 6000.
		var sim = new FixedStep(1 / 60);
		var twelfths:Int = 0;
		var expected:Int = 0;
		var offSchedule:Int = 0;

		for (_ in 0...6000) {
			// The same schedule in integers, where nothing rounds.
			twelfths += 5;
			while (twelfths >= 12) {
				twelfths -= 12;
				expected++;
			}

			sim.advance(1 / 144);
			while (sim.step()) {}
			if (sim.tick != expected) {
				offSchedule++;
			}
		}

		Assert.equals(0, offSchedule);
		Assert.equals(2500, sim.tick);
	}

	public function testAStallIsDroppedRatherThanOwed():Void {
		// Ten seconds at a tenth of a second a step is 100 steps; five run,
		// and the other 95 are what running behind would have owed forever.
		var sim = new FixedStep(0.1, 5);

		Assert.equals(5, sim.advance(10.0));
		Assert.floatEquals(9.5, sim.dropped, 1e-6);

		var taken:Int = 0;
		while (sim.step()) {
			taken++;
		}
		Assert.equals(5, taken);
		Assert.equals(5, sim.tick);
	}

	public function testStepsLeftUntakenCountAgainstTheCap():Void {
		var sim = new FixedStep(0.1, 5);
		sim.advance(0.35);
		Assert.equals(3, sim.pending);

		// Three still owed, so only two more fit; the third is dropped.
		Assert.equals(5, sim.advance(0.3));
		Assert.floatEquals(0.1, sim.dropped, 1e-9);
	}

	public function testNoTimeIsLostOrInventedOverALongRun():Void {
		// Uneven deltas, the way a loaded runtime reports them, summed
		// against the steps taken. Stepping by the nominal interval would
		// drift; a fraction rounded away on each tick would too.
		var interval:Float = 1 / 60;
		var sim = new FixedStep(interval, 1000);
		var seed:Int = 12345;
		var total:Float = 0;
		var steps:Int = 0;

		for (_ in 0...200000) {
			seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
			var delta:Float = 0.005 + (seed % 20000) / 1000000.0;
			total += delta;
			sim.advance(delta);
			while (sim.step()) {
				steps++;
			}
		}

		Assert.equals(0.0, sim.dropped);
		var accounted:Float = steps * interval + sim.alpha * interval;
		Assert.floatEquals(total, accounted, 1e-6, 'accounted ${accounted}s of ${total}s');
		Assert.isTrue(sim.alpha >= 0 && sim.alpha < 1);
	}

	public function testZeroAndNegativeTimeAddNothing():Void {
		var sim = new FixedStep(0.1);
		sim.advance(0.05);

		Assert.equals(0, sim.advance(0));
		Assert.equals(0, sim.advance(-5.0));
		Assert.equals(0, sim.advance(Math.NEGATIVE_INFINITY));
		Assert.floatEquals(0.5, sim.alpha, 1e-9);
		Assert.equals(0.0, sim.dropped);
	}

	public function testTimeThatIsNotANumberIsRefused():Void {
		var sim = new FixedStep(0.1);
		Assert.raises(() -> sim.advance(Math.NaN));
		Assert.raises(() -> sim.advance(Math.POSITIVE_INFINITY));
		Assert.equals(0, sim.pending);
	}

	public function testAnAbsurdElapsedTimeLeavesAUsableAlpha():Void {
		var sim = new FixedStep(0.1, 3);
		Assert.equals(3, sim.advance(1e300));
		Assert.isTrue(sim.alpha >= 0 && sim.alpha < 1, 'alpha ${sim.alpha}');
	}

	public function testResetForgetsWhatIsOwedButKeepsTheCount():Void {
		var sim = new FixedStep(0.1);
		sim.advance(0.25);
		sim.step();

		sim.reset();
		Assert.equals(0, sim.pending);
		Assert.equals(0.0, sim.alpha);
		Assert.equals(1, sim.tick);
		Assert.equals(0.0, sim.dropped);
		Assert.isFalse(sim.step());
	}

	public function testTheTickWrapsOnEveryTarget():Void {
		// On JavaScript an Int is a double; without the wrap this would read
		// 2147483648 there and -2147483648 everywhere else.
		var sim = new FixedStep(0.1);
		@:privateAccess sim.tick = 2147483647;
		sim.advance(0.1);
		Assert.isTrue(sim.step());
		Assert.equals(-2147483647 - 1, sim.tick);
	}

	public function testConfigurationThatCannotWorkIsRefused():Void {
		Assert.raises(() -> new FixedStep(0));
		Assert.raises(() -> new FixedStep(-0.1));
		Assert.raises(() -> new FixedStep(Math.NaN));
		Assert.raises(() -> new FixedStep(Math.POSITIVE_INFINITY));
		Assert.raises(() -> new FixedStep(0.1, 0));
	}
}
