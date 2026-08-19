package crossbyte.events;

import crossbyte.events.Event;

/** Event dispatched once per runtime tick with the elapsed delta time. */
class TickEvent extends Event {
	public static inline var TICK:String = "tick";

	/**
	 * Seconds elapsed since the previous tick.
	 *
	 * The measurement, not a policy applied to it. A collection pause, a
	 * blocking disk read, a breakpoint or a machine resuming from sleep each
	 * produce one enormous frame, and this reports it. The runtime does not
	 * cap it, because a cap cannot be undone by the listener that receives
	 * one and the right value for it is a property of that listener rather
	 * than of the loop.
	 *
	 * Anything integrating against this — a renderer, a physics step, an
	 * interpolation — should bound its own step, since one step of that size
	 * passes through whatever it should have collided with:
	 *
	 * ```haxe
	 * var dt:Float = Math.min(event.delta, 1 / 30);
	 * ```
	 *
	 * Note that a bound discards the excess rather than deferring it, so
	 * anything measuring elapsed time — a timeout, a rate, a timer — should
	 * accumulate this as it arrives and not bound it at all, or it runs slow
	 * through a stall instead of catching up after one.
	 *
	 * Do not assume it equals `1 / tps`. The runtime holds that rate closely
	 * and corrects for a frame that overruns, but a loaded process still
	 * reports what actually elapsed, and stepping by the nominal interval
	 * instead would drift behind real time without saying so.
	 *
	 * A runtime driven by `pump()` reports the delta its caller passed.
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
