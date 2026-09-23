package crossbyte.core;

import crossbyte.errors.ArgumentError;

/**
 * Turns a runtime's uneven ticks into the equal steps a simulation wants.
 *
 * `TickEvent.delta` is what actually elapsed, and that moves with load. A
 * simulation stepped by it directly behaves differently at every frame
 * rate, and one stepped by the nominal interval instead drifts behind real
 * time. This keeps the difference: give it each tick's delta, and it hands
 * back steps of exactly `interval`, as many as that time has paid for.
 *
 * ```haxe
 * var sim = new FixedStep(1 / 30);
 *
 * runtime.addEventListener(TickEvent.TICK, event -> {
 * 	sim.advance(event.delta);
 * 	while (sim.step()) {
 * 		world.update(sim.interval, sim.tick);
 * 	}
 * 	world.blend(sim.alpha);
 * });
 * ```
 *
 * **Falling behind.** When more time arrives than `maxSteps` steps can use
 * -- a stall, a breakpoint, a machine resuming from sleep, or steps that
 * take longer to run than they simulate -- the excess is dropped rather
 * than owed, and added to `dropped`. Owing it is the spiral this exists to
 * prevent: a simulation that falls behind runs extra steps to catch up,
 * falls further behind doing so, and never recovers. Dropping it lets
 * simulated time run slow through the overload instead, and `dropped` is
 * how that stays visible rather than silent.
 *
 * **Tick numbers.** `tick` numbers the steps taken, which is what snapshots
 * and inputs are stamped with. It wraps past `2^31 - 1` -- over a year at
 * 60 steps a second -- so compare two ticks by the sign of their
 * difference, as sequence numbers are compared, not with `<`.
 *
 * **Threading.** None. Drive it from the tick that owns the simulation.
 */
final class FixedStep {
	/**
	 * Seconds each step simulates.
	 */
	public var interval(default, null):Float;

	/**
	 * Most steps that may be owed at once. Time beyond what they cover is
	 * dropped, not deferred.
	 */
	public var maxSteps(default, null):Int;

	/**
	 * Number of the step most recently taken; zero before the first. Wraps
	 * past `2^31 - 1`.
	 */
	public var tick(default, null):Int = 0;

	/**
	 * Steps paid for and not yet taken.
	 */
	public var pending(default, null):Int = 0;

	/**
	 * How far the time left over reaches into the next step, from 0 up to
	 * but not including 1: where between the last state and the next the
	 * present actually is.
	 */
	public var alpha(get, never):Float;

	/**
	 * Seconds of elapsed time thrown away because more arrived than
	 * `maxSteps` steps could use. Simulated time is behind real time by
	 * exactly this much.
	 */
	public var dropped(default, null):Float = 0;

	// Elapsed time not yet worth a whole step: below `interval`, and at most a
	// rounding error below zero.
	private var __remainder:Float = 0;

	/**
	 * @param interval Seconds each step simulates.
	 * @param maxSteps Most steps that may be owed at once; the rest of a
	 *        long stall is dropped.
	 */
	public function new(interval:Float, maxSteps:Int = 5) {
		if (!(interval > 0) || !Math.isFinite(interval)) {
			throw new ArgumentError("A step needs a finite interval above zero.");
		}
		if (maxSteps < 1) {
			throw new ArgumentError("maxSteps must be at least 1.");
		}
		this.interval = interval;
		this.maxSteps = maxSteps;
	}

	/**
	 * Adds elapsed time, converting it into steps owed.
	 *
	 * Zero and negative time add nothing, so a clock that stepped backwards
	 * costs no steps rather than taking some away.
	 *
	 * @param elapsed Seconds since the last call -- a tick's `delta`.
	 * @return Steps now owed, the same as `pending`.
	 */
	public function advance(elapsed:Float):Int {
		if (Math.isNaN(elapsed) || elapsed == Math.POSITIVE_INFINITY) {
			throw new ArgumentError("Elapsed time must be a finite number of seconds.");
		}
		if (elapsed <= 0) {
			return pending;
		}

		var time:Float = __remainder + elapsed;

		// A quotient a hair short of a whole number is that number. With a
		// tenth-of-a-second step, 0.25 leaves a remainder that 0.05 more
		// divides out to 0.9999999999999999, and flooring that takes the step
		// a tick late -- every time, for a runtime pumped with exact deltas.
		// The remainder then sits a hair below zero, and is carried rather
		// than rounded away, so time only ever moves between steps: none is
		// gained or lost.
		var whole:Float = Math.ffloor(time / interval + 1e-9);
		__remainder = time - whole * interval;

		if (__remainder >= interval) {
			__remainder -= interval;
			whole += 1;
		}

		// Past either bound only when elapsed is so large that a fraction of
		// a step is below the precision it is held in. The fraction means
		// nothing there, and carrying it would make the next step wrong.
		if (__remainder >= interval || __remainder < -interval) {
			__remainder = 0;
		}

		var room:Int = maxSteps - pending;
		if (whole > room) {
			dropped += (whole - room) * interval;
			whole = room;
		}

		pending += Std.int(whole);
		return pending;
	}

	/**
	 * Takes one step, if one is owed.
	 *
	 * @return `true` when a step was taken -- `tick` has moved on to number
	 *         it -- and `false` when the time is used up.
	 */
	public function step():Bool {
		if (pending == 0) {
			return false;
		}
		pending--;

		// `| 0` because on JavaScript an Int is a double, and it would count
		// on past 2^31 where every other target wraps.
		tick = (tick + 1) | 0;
		return true;
	}

	/**
	 * Forgets every step owed and the time left over, for a simulation that
	 * was paused on purpose and should resume without catching up. `tick` is
	 * kept, since the steps it numbers still happened; `dropped` is not
	 * touched, since nothing was lost that was not meant to be.
	 */
	public function reset():Void {
		pending = 0;
		__remainder = 0;
	}

	private inline function get_alpha():Float {
		return __remainder > 0 ? __remainder / interval : 0;
	}
}
