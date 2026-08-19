package crossbyte.core;

/** Selects how a `CrossByte` instance advances its main loop. */
enum MainLoopType {
	/**
	 * Fixed-cadence application loop: advance timers, dispatch a tick, service
	 * sockets once, then wait out the frame.
	 *
	 * The shape a renderer or a simulation wants, and what `Application` and
	 * `HostApplication` use. Sockets are polled once per frame without
	 * blocking, so the tick rate is also the latency floor for anything
	 * arriving on one — at the default rate, an arrival waits up to a frame to
	 * be seen. That is the right trade when the loop's job is to keep a steady
	 * cadence for something else; it is the wrong one for a server, which
	 * should use `POLL`.
	 */
	DEFAULT;

	/**
	 * Server loop: the frame's remaining time is spent inside poll, so a
	 * socket that becomes ready wakes the loop immediately instead of waiting
	 * for the next tick.
	 *
	 * What `ServerApplication` uses. Tick cadence is unchanged — an idle frame
	 * still ends on the interval — but arrivals are no longer quantised to it.
	 */
	POLL;

	/**
	 * Caller-provided loop body, invoked in place of either built-in.
	 *
	 * The callback owns the whole frame: dispatching the tick, advancing
	 * timers, servicing the socket registry, and whatever pacing it wants.
	 * Nothing above supplies any of that for it.
	 */
	CUSTOM(loop:Void->Void);
}
