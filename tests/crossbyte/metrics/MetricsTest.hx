package crossbyte.metrics;

import crossbyte.errors.ArgumentError;
import utest.Assert;

class MetricsTest extends utest.Test {
	private var metrics:Metrics;

	public function setup():Void {
		metrics = new Metrics();
	}

	public function testCounterAccumulatesAndRejectsDecrease():Void {
		var requests = metrics.counter("http_requests_total");

		Assert.equals(0.0, requests.value());
		requests.inc();
		requests.inc(4);
		Assert.equals(5.0, requests.value());

		// Zero is a no-op rather than an error.
		requests.inc(0);
		Assert.equals(5.0, requests.value());

		// A counter that can go down would corrupt every rate derived from
		// it, so this is rejected rather than silently allowed.
		Assert.raises(() -> requests.inc(-1), ArgumentError);
		Assert.equals(5.0, requests.value());

		requests.reset();
		Assert.equals(0.0, requests.value());
	}

	public function testGaugeRisesAndFalls():Void {
		var connections = metrics.gauge("active_connections");

		connections.set(10);
		connections.inc();
		connections.dec(3);
		Assert.equals(8.0, connections.value());
		Assert.isFalse(connections.bound);

		connections.set(-2);
		Assert.equals(-2.0, connections.value());
	}

	public function testBoundGaugeSamplesProviderAndIgnoresWrites():Void {
		var backing:Int = 3;
		var poolSize = metrics.gaugeFn("db_pool_in_use", () -> backing);

		Assert.isTrue(poolSize.bound);
		Assert.equals(3.0, poolSize.value());

		backing = 7;
		Assert.equals(7.0, poolSize.value());

		// Writes to a bound gauge must not shadow the real source.
		poolSize.set(999);
		poolSize.inc(5);
		Assert.equals(7.0, poolSize.value());
	}

	public function testBoundGaugeSurvivesFailingProvider():Void {
		var failing = metrics.gaugeFn("flaky", function():Float {
			throw "provider exploded";
		});

		// Scraping metrics must never be able to fail a request path.
		Assert.equals(0.0, failing.value());
	}

	public function testHistogramBucketsAreCumulative():Void {
		var latency = metrics.histogram("request_seconds", [0.1, 0.5, 1.0]);

		latency.observe(0.05);
		latency.observe(0.3);
		latency.observe(0.75);
		latency.observe(5.0);

		Assert.equals(4.0, latency.count());
		Assert.equals(6.1, Math.round(latency.sum() * 100) / 100);

		var counts = latency.bucketCounts();
		Assert.equals(1.0, counts[0]); // <= 0.1
		Assert.equals(2.0, counts[1]); // <= 0.5
		Assert.equals(3.0, counts[2]); // <= 1.0
	}

	public function testHistogramSortsBoundsAndRejectsDuplicates():Void {
		var sorted = metrics.histogram("sorted", [1.0, 0.1, 0.5]);
		Assert.same([0.1, 0.5, 1.0], sorted.bounds);

		Assert.raises(() -> metrics.histogram("dupes", [0.5, 0.5]), ArgumentError);
	}

	public function testHistogramTimeRecordsEvenWhenBodyThrows():Void {
		var latency = metrics.histogram("timed", [10.0]);

		var value = latency.time(() -> 42);
		Assert.equals(42, value);
		Assert.equals(1.0, latency.count());

		var threw = false;
		try {
			latency.time(function():Int {
				throw "failed work";
			});
		} catch (_:Dynamic) {
			threw = true;
		}

		Assert.isTrue(threw);
		// A failing path still contributes to the latency picture.
		Assert.equals(2.0, latency.count());
	}

	public function testLookupsReturnTheSameInstance():Void {
		var a = metrics.counter("shared_total");
		var b = metrics.counter("shared_total");
		a.inc(3);

		Assert.equals(3.0, b.value());
		Assert.equals(1, metrics.size());
	}

	public function testLabelsCreateDistinctSeries():Void {
		var get = metrics.counter("requests_total", ["method" => "GET"]);
		var post = metrics.counter("requests_total", ["method" => "POST"]);

		get.inc(2);
		post.inc(5);

		Assert.equals(2.0, get.value());
		Assert.equals(5.0, post.value());
		Assert.equals(2, metrics.size());
	}

	public function testSeriesKeysCannotCollideAcrossNameAndLabelBoundaries():Void {
		// Naive key concatenation would fold these into one series.
		var first = metrics.counter("ab", ["c" => "d"]);
		var second = metrics.counter("a", ["bc" => "d"]);
		var third = metrics.counter("a", ["b" => "cd"]);

		first.inc(1);
		second.inc(2);
		third.inc(3);

		Assert.equals(1.0, first.value());
		Assert.equals(2.0, second.value());
		Assert.equals(3.0, third.value());
		Assert.equals(3, metrics.size());
	}

	public function testInvalidNamesAndLabelsAreRejected():Void {
		Assert.raises(() -> metrics.counter("has spaces"), ArgumentError);
		Assert.raises(() -> metrics.counter("1_leading_digit"), ArgumentError);
		Assert.raises(() -> metrics.counter("has-dash"), ArgumentError);
		Assert.raises(() -> metrics.counter(null), ArgumentError);
		Assert.raises(() -> metrics.counter("valid", ["bad label" => "x"]), ArgumentError);
		Assert.raises(() -> metrics.gaugeFn("valid", null), ArgumentError);

		// Colons are legal in metric names.
		Assert.notNull(metrics.counter("service:requests_total"));
	}

	public function testPrometheusExportShape():Void {
		metrics.counter("requests_total", ["method" => "GET"], "Total requests.").inc(3);
		metrics.gauge("queue_depth").set(2);

		var text = metrics.toPrometheus();

		Assert.isTrue(text.indexOf("# HELP requests_total Total requests.") >= 0);
		Assert.isTrue(text.indexOf("# TYPE requests_total counter") >= 0);
		Assert.isTrue(text.indexOf('requests_total{method="GET"} 3') >= 0);
		Assert.isTrue(text.indexOf("# TYPE queue_depth gauge") >= 0);
		Assert.isTrue(text.indexOf("queue_depth 2") >= 0);
	}

	public function testPrometheusHistogramExportIncludesBucketsSumAndCount():Void {
		var latency = metrics.histogram("request_seconds", [0.1, 1.0]);
		latency.observe(0.05);
		latency.observe(2.0);

		var text = metrics.toPrometheus();

		Assert.isTrue(text.indexOf("# TYPE request_seconds histogram") >= 0);
		Assert.isTrue(text.indexOf('request_seconds_bucket{le="0.1"} 1') >= 0);
		Assert.isTrue(text.indexOf('request_seconds_bucket{le="1"} 1') >= 0);
		// The implicit +Inf bucket always equals the total count.
		Assert.isTrue(text.indexOf('request_seconds_bucket{le="+Inf"} 2') >= 0);
		Assert.isTrue(text.indexOf("request_seconds_count 2") >= 0);
		Assert.isTrue(text.indexOf("request_seconds_sum 2.05") >= 0);
	}

	public function testPrometheusEscapesLabelValuesAndEmitsOneHeaderPerName():Void {
		metrics.counter("escaped", ["note" => 'say "hi"\\there'], "help").inc();
		metrics.counter("multi", ["a" => "1"], "shared help").inc();
		metrics.counter("multi", ["a" => "2"]).inc();

		var text = metrics.toPrometheus();

		Assert.isTrue(text.indexOf('note="say \\"hi\\"\\\\there"') >= 0);

		// A metric name gets exactly one TYPE line even with several series.
		var typeCount = 0;
		for (line in text.split("\n")) {
			if (line == "# TYPE multi counter") {
				typeCount++;
			}
		}
		Assert.equals(1, typeCount);
	}

	public function testLabelOrderDoesNotAffectIdentityOrOutput():Void {
		var first = metrics.counter("ordered", ["b" => "2", "a" => "1"]);
		var second = metrics.counter("ordered", ["a" => "1", "b" => "2"]);
		first.inc();

		// Same series regardless of insertion order.
		Assert.equals(1.0, second.value());
		Assert.equals(1, metrics.size());

		// Rendered deterministically so scrapes and diffs stay stable.
		Assert.isTrue(metrics.toPrometheus().indexOf('ordered{a="1",b="2"} 1') >= 0);
	}

	public function testClearEmptiesTheRegistry():Void {
		metrics.counter("a").inc();
		metrics.gauge("b").set(1);
		Assert.equals(2, metrics.size());

		metrics.clear();
		Assert.equals(0, metrics.size());
		Assert.equals("", metrics.toPrometheus());
	}

	public function testSharedRegistryIsStable():Void {
		Assert.equals(Metrics.shared, Metrics.shared);
	}
}
