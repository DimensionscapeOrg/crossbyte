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

	public function testANaNObservationIsCountedInNoFiniteBucket():Void {
		// Not below any bound, so it belongs only to +Inf, which is where the
		// count comes from, so the two cannot disagree about it.
		var latency = metrics.histogram("nan_seconds", [1.0]);
		latency.observe(0.5);
		latency.observe(Math.NaN);

		Assert.equals(2.0, latency.count());
		Assert.equals(1.0, latency.bucketCounts()[0]);
		Assert.isTrue(Math.isNaN(latency.sum()));
	}

	#if target.threaded
	public function testUpdatesFromSeveralThreadsAreAllCounted():Void {
		// Workers record metrics as well as the runtime's thread. On hxcpp an
		// update is a compare-and-swap rather than a lock, and one that lost a
		// race and was not retried would simply vanish from these totals.
		var requests = metrics.counter("threaded_total");
		var depth = metrics.gauge("threaded_depth");
		var latency = metrics.histogram("threaded_seconds", [1.0]);
		var threads:Int = 4;
		var each:Int = 50000;
		var finished = new sys.thread.Lock();

		for (_ in 0...threads) {
			sys.thread.Thread.create(function():Void {
				for (i in 0...each) {
					requests.inc();
					depth.inc(2);
					depth.dec();
					// Halves and twos, whose sums are exact in binary floating
					// point in any order, so the expected sum is exact too.
					latency.observe((i & 1) == 0 ? 0.5 : 2.0);
					__letTheCollectorIn(i);
				}
				finished.release();
			});
		}

		for (_ in 0...threads) {
			Assert.isTrue(finished.wait(60.0), "a thread never finished");
		}

		var total:Float = threads * each;
		Assert.equals(total, requests.value());
		Assert.equals(total, depth.value());
		Assert.equals(total, latency.count());
		Assert.equals(total / 2, latency.bucketCounts()[0]);
		Assert.equals(total / 2 * 0.5 + total / 2 * 2.0, latency.sum());
	}

	public function testAScrapeTakenWhileObservationsArriveAgreesWithItself():Void {
		// The +Inf bucket and _count are one number, written twice. They were
		// read separately, each under an acquisition of its own, so an
		// observation landing between the two reads made a scrape contradict
		// itself, and a collector computing a quantile from buckets that
		// are not monotonic, or do not add up to the count, gets nonsense.
		var latency = metrics.histogram("scraped_seconds", [0.1, 1.0]);
		var writers:Int = 3;
		var stop = new sys.thread.Deque<Bool>();
		var finished = new sys.thread.Deque<Bool>();

		for (_ in 0...writers) {
			sys.thread.Thread.create(function():Void {
				var i:Int = 0;
				while (true) {
					// One in each bucket and one past the last.
					latency.observe(i % 3 == 0 ? 0.05 : (i % 3 == 1 ? 0.5 : 5.0));
					__letTheCollectorIn(++i);
					if ((i & 1023) == 0 && stop.pop(false) != null) {
						break;
					}
				}
				finished.add(true);
			});
		}

		var contradictions:Array<String> = [];

		for (_ in 0...300) {
			var text:String = metrics.toPrometheus();
			var below:Float = __sample(text, 'scraped_seconds_bucket{le="0.1"}');
			var within:Float = __sample(text, 'scraped_seconds_bucket{le="1"}');
			var all:Float = __sample(text, 'scraped_seconds_bucket{le="+Inf"}');
			var count:Float = __sample(text, "scraped_seconds_count");

			if (!(below <= within && within <= all && all == count) && contradictions.length < 3) {
				contradictions.push('le=0.1 $below, le=1 $within, +Inf $all, _count $count');
			}
		}

		for (_ in 0...writers) {
			stop.add(true);
		}
		for (_ in 0...writers) {
			finished.pop(true);
		}

		Assert.equals(0, contradictions.length, "a scrape contradicted itself: " + contradictions.join("; "));
		// And at rest, everything agrees exactly.
		var counts = latency.bucketCounts();
		Assert.isTrue(counts[0] <= counts[1] && counts[1] <= latency.count());
		Assert.equals(latency.count(), __sample(metrics.toPrometheus(), "scraped_seconds_count"));
	}

	/** The value on the exposition line that starts with `series`, or NaN. **/
	private static function __sample(text:String, series:String):Float {
		for (line in text.split("\n")) {
			if (StringTools.startsWith(line, series + " ")) {
				return Std.parseFloat(line.substr(series.length + 1));
			}
		}
		return Math.NaN;
	}

	/**
		A place for the collector to stop this thread now and then. The loops
		above allocate nothing, and on hxcpp a thread that never allocates
		never reaches a point where a collection another thread started can
		stop it, so the thread scraping would wait on them for good.
	**/
	private static inline function __letTheCollectorIn(i:Int):Void {
		#if cpp
		if ((i & 1023) == 0) {
			cpp.vm.Gc.safePoint();
		}
		#end
	}
	#end
}
