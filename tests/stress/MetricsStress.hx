package stress;

import crossbyte.metrics.Metrics;
import crossbyte.sys.TaskPool;

/**
 * Hammers the metrics registry from many threads.
 *
 * Invariants: no update is lost, and concurrent get-or-create converges on
 * one instance per name rather than racing into duplicate series.
 *
 * This case caught a real bug: metric-name validation used shared static
 * `EReg` instances, and because `EReg` carries mutable match state,
 * concurrent matches corrupted each other and spuriously rejected valid
 * names — silently dropping 1850 of 50000 updates.
 */
class MetricsStress implements StressCase {
	private static inline final WORKERS:Int = 16;
	private static inline final JOBS:Int = 2000;
	private static inline final UPDATES_PER_JOB:Int = 25;

	public function new() {}

	public function run():StressResult {
		var metrics = new Metrics();
		var workers = new TaskPool(WORKERS);
		var expected:Float = JOBS * UPDATES_PER_JOB;

		for (i in 0...JOBS) {
			workers.submit(function() {
				// Resolved inside the worker on purpose: this is the
				// get-or-create path that must not race.
				var counter = metrics.counter("stress_total");
				var histogram = metrics.histogram("stress_seconds", [0.5, 1.0]);
				var gauge = metrics.gauge("stress_gauge");

				for (n in 0...UPDATES_PER_JOB) {
					counter.inc();
					histogram.observe(0.25);
					gauge.inc();
				}
			});
		}

		workers.shutdown(true);

		var counter = metrics.counter("stress_total");
		var histogram = metrics.histogram("stress_seconds");
		var gauge = metrics.gauge("stress_gauge");
		var buckets = histogram.bucketCounts();

		var passed:Bool = counter.value() == expected
			&& histogram.count() == expected
			&& buckets[0] == expected
			&& gauge.value() == expected
			&& metrics.size() == 3;

		return {
			name: "Metrics registry contention",
			passed: passed,
			details: [
				'jobs=$JOBS workers=$WORKERS updates=$expected',
				"counter=" + counter.value(),
				"histogram count=" + histogram.count() + " bucket[0]=" + buckets[0],
				"gauge=" + gauge.value(),
				"series=" + metrics.size() + " (expected 3)"
			]
		};
	}
}
