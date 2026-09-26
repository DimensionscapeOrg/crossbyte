import crossbyte.metrics.Counter;
import crossbyte.metrics.Histogram;
import crossbyte.metrics.Metrics;

/**
	What recording a metric costs, on the paths that record one per unit of
	work: the HTTP server counts every response and times it into a
	histogram, and a connection pool does the same for every checkout.

	The latencies observed cycle through a spread from well inside the first
	bucket to past the last, since which bucket a value lands in is part of
	what an observation costs.
**/
class BenchMetrics {
	public static function run():Void {
		Bench.section("Metrics");

		var metrics = new Metrics();
		var counter:Counter = metrics.counter("bench_requests_total");
		var gauge = metrics.gauge("bench_queue_depth");
		var histogram:Histogram = metrics.histogram("bench_request_seconds");
		var latencies:Array<Float> = [0.002, 0.004, 0.02, 0.07, 0.3, 0.9, 3.0, 12.0];
		var next:Int = 0;

		Bench.run("Counter.inc", function():Void {
			counter.inc();
		});

		Bench.run("Gauge.inc", function():Void {
			gauge.inc();
		});

		Bench.run("Gauge.set", function():Void {
			gauge.set(3);
		});

		Bench.run("Histogram.observe (11 buckets)", function():Void {
			histogram.observe(latencies[next++ & 7]);
		});

		// What HTTPServer records for each response it sends.
		Bench.run("one response: inc + observe", function():Void {
			counter.inc();
			histogram.observe(latencies[next++ & 7]);
		});

		// The read side, which a scrape pays once per series.
		Bench.run("Histogram read: count + sum + buckets", function():Void {
			histogram.count();
			histogram.sum();
			histogram.bucketCounts();
		});

		// Printed so no target can decide the updates do nothing.
		Sys.println("  (" + counter.value() + " counted, " + histogram.count() + " observed)");
	}
}
