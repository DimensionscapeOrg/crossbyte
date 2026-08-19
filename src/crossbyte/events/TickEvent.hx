package crossbyte.events;

import crossbyte.events.Event;

/** Event dispatched once per runtime tick with the elapsed delta time. */
class TickEvent extends Event {
	public static inline var TICK:String = "tick";

	/**
	 * Seconds elapsed since the previous tick.
	 *
	 * Bounded by `CrossByte.maxDelta`, and the bound is the part worth
	 * knowing: past it the excess is **discarded, not deferred**. A frame that
	 * stalls for a second reports the cap and the rest is simply gone, so
	 * anything accumulating this to track elapsed time runs slow through a
	 * stall rather than catching up afterwards. That is deliberate — a
	 * simulation given the true figure takes one enormous step and passes
	 * through whatever it should have hit — but it means this is not a
	 * reliable clock. Read `Sys.time()` for wall time.
	 *
	 * Do not assume it equals `1 / tps`. The runtime holds that rate closely
	 * and corrects for a frame that overruns, but a loaded process still
	 * reports what actually elapsed, and stepping a simulation by the nominal
	 * interval instead would drift behind real time without saying so.
	 *
	 * A runtime driven by `pump()` reports the delta its caller passed,
	 * unbounded: the host supplies the figure rather than the loop measuring
	 * it, so the cap does not apply.
	 *
	 * The first tick of a runtime reports zero.
	 */
	public var delta:Float;

	public function new(type:String, delta:Float) {
		super(type);

		this.delta = delta;
	}

	override public function clone():Event {
		var event = new TickEvent(type, delta);
		event.target = target;
		event.currentTarget = currentTarget;
		return event;
	}
}
