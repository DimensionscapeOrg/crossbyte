package crossbyte.core;

/** Selects the structure a `CrossByte` instance schedules its timers with. */
enum TimerStrategy {
	/**
	 * Min-heap ordered by due time. The default, and the right choice for
	 * almost everything.
	 *
	 * Orders timers exactly, and a delay of a microsecond costs what a delay
	 * of six hours costs — there is no range beyond which it degrades and no
	 * granularity below which it rounds. Arming, cancelling and rescheduling
	 * are O(log n) with the position kept on the timer itself, which at thirty
	 * thousand recurring timers is well under a millisecond per frame at sixty
	 * ticks a second.
	 */
	HEAP;

	/**
	 * Timing wheel: fixed-resolution buckets in a ring.
	 *
	 * Arming a timer inside the ring is an index calculation and a list link,
	 * with nothing that grows as more timers are held. Worth choosing for a
	 * runtime holding thousands of *short* timers it re-arms constantly — a
	 * deadline per connection, a cooldown per entity — where measurement shows
	 * the scheduler itself in the profile. Around five to six times the heap
	 * on that workload.
	 *
	 * It is the wrong choice otherwise, and not only slower:
	 *
	 * - Timers past the ring wait in an unordered overflow list reconsidered
	 *   once per revolution, so a runtime whose timers are mostly long pays
	 *   for a scan the heap never performs.
	 * - Timers due in the same tick fire in bucket order, not by exact time.
	 * - A timer may be late by up to one tick. Never early.
	 *
	 * Chosen per runtime rather than per process, so a simulation thread
	 * carrying a timer per entity and a network thread carrying a handful can
	 * each have what suits them.
	 */
	WHEEL;
}
