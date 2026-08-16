package stress;

/**
 * A concurrency stress case.
 *
 * These exist because the utest suites cannot see this class of bug: the
 * interpreter is single-threaded, so a data race in shared state passes
 * every unit test and only appears under real thread contention. Each case
 * here corresponds to a race that actually shipped and was caught this
 * way.
 *
 * Cases must be deterministic in their assertions even though their
 * scheduling is not: assert on invariants that must hold under any
 * interleaving (no lost updates, no duplicate ids, no exceeded ceiling),
 * never on timing or ordering.
 */
interface StressCase {
	/**
	 * Runs the case to completion and reports what happened.
	 */
	function run():StressResult;
}
