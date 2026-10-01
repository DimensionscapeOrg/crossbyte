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
	 * arriving on one, at the default rate, an arrival waits up to a frame to
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
	 * What `ServerApplication` uses. Tick cadence is unchanged, an idle frame
	 * still ends on the interval, but arrivals are no longer quantised to it.
	 */
	POLL;

	/**
	 * Caller-provided loop body, invoked in place of either built-in.
	 *
	 * The runtime calls `loop` over and over on its own thread for as long
	 * as it runs, having dispatched `INIT` first, and dispatches `EXIT` once
	 * `exit()` has been called and `loop` has returned. The body does a
	 * frame's work by calling the runtime's `pump(delta, socketTimeout)`:
	 * what other threads posted, the timers, the tick, the sockets and what
	 * they send. When it calls that, and what else it does around it, is the
	 * body's to decide, a simulation stepping at its own rate, a loop that
	 * waits on readiness alone.
	 *
	 * So is the pacing. `pump` waits up to `socketTimeout` for a socket to be
	 * ready or for something to be posted, and no longer; a body that does
	 * not wait there or sleep spins a core. On JavaScript, which cannot block,
	 * the body is called once a frame, at the runtime's `tps`.
	 *
	 * ```haxe
	 * var last:Float = haxe.Timer.stamp();
	 * CrossByte.make(CUSTOM(() -> {
	 *     var now:Float = haxe.Timer.stamp();
	 *     CrossByte.current().pump(now - last, 0.005);
	 *     last = now;
	 * }));
	 * ```
	 */
	CUSTOM(loop:Void->Void);
}
