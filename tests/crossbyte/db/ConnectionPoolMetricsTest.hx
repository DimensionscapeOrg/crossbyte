package crossbyte.db;

import crossbyte.metrics.Metrics;
import utest.Assert;

/** Stand-in connection, so the pool is measured without a database. */
private class FakeConnection {
	public var id(default, null):Int;
	public var closed:Bool = false;

	public function new(id:Int) {
		this.id = id;
	}
}

/**
 * Metrics published by `ConnectionPool`.
 *
 * The gauges matter less than the shape of the series: a pool that
 * published one series per connection would be correct on a dashboard and
 * ruinous in production, so the cardinality case below is the one that
 * would fail loudest if this were wired up carelessly.
 */
class ConnectionPoolMetricsTest extends utest.Test {
	private var registry:Metrics;
	private var nextId:Int;
	private var closedIds:Array<Int>;

	public function setup():Void {
		registry = new Metrics();
		nextId = 0;
		closedIds = [];
	}

	private function makePool(maxSize:Int = 2, ?validate:FakeConnection->Bool, ?acquireTimeout:Float, withMetrics:Bool = true):ConnectionPool<FakeConnection> {
		return new ConnectionPool({
			factory: function() {
				return new FakeConnection(nextId++);
			},
			close: function(connection:FakeConnection) {
				connection.closed = true;
				closedIds.push(connection.id);
			},
			validate: validate,
			maxSize: maxSize,
			acquireTimeout: acquireTimeout == null ? 0.05 : acquireTimeout,
			metrics: withMetrics ? registry : null,
			metricsPrefix: "testpool"
		});
	}

	private function value(name:String):Null<Float> {
		// Read through the exposition text rather than the registry's
		// internals, so this asserts what a collector would actually see.
		for (line in registry.toPrometheus().split("\n")) {
			var trimmed:String = StringTools.trim(line);
			if (trimmed == "" || trimmed.charAt(0) == "#") {
				continue;
			}
			var space:Int = trimmed.lastIndexOf(" ");
			if (space < 0) {
				continue;
			}
			if (trimmed.substr(0, space) == name) {
				return Std.parseFloat(trimmed.substr(space + 1));
			}
		}
		return null;
	}

	public function testNoRegistryPublishesNothingAndPoolStillWorks():Void {
		var pool = makePool(2, null, null, false);
		var connection = pool.acquire();
		Assert.notNull(connection);
		pool.release(connection);
		pool.close();

		Assert.equals(0, registry.size(), "a pool without a registry must publish nothing");
	}

	/**
	 * Series exist before the first acquire, so an idle pool reads as zero
	 * rather than as an absent series — which a collector cannot tell apart
	 * from a pool that is not running.
	 */
	public function testSeriesExistBeforeFirstUse():Void {
		makePool();

		Assert.equals(0.0, value("testpool_connections_open"));
		Assert.equals(0.0, value("testpool_connections_in_use"));
		Assert.equals(0.0, value("testpool_connections_idle"));
		Assert.equals(2.0, value("testpool_connections_max"));
		Assert.equals(0.0, value("testpool_acquired_total"));
	}

	public function testGaugesTrackCheckoutAndReturn():Void {
		var pool = makePool(4);

		var first = pool.acquire();
		var second = pool.acquire();

		Assert.equals(2.0, value("testpool_connections_open"));
		Assert.equals(2.0, value("testpool_connections_in_use"));
		Assert.equals(0.0, value("testpool_connections_idle"));

		pool.release(first);
		pool.release(second);

		Assert.equals(2.0, value("testpool_connections_open"), "releasing must not close connections");
		Assert.equals(0.0, value("testpool_connections_in_use"));
		Assert.equals(2.0, value("testpool_connections_idle"));
	}

	/**
	 * Reuse is the pool's whole purpose, so acquisitions and openings have
	 * to be separate counters: a pool that opened a connection per acquire
	 * would look identical on `acquired_total` alone.
	 */
	public function testReuseCountsAcquisitionsWithoutCountingOpens():Void {
		var pool = makePool(2);

		for (_ in 0...5) {
			pool.release(pool.acquire());
		}

		Assert.equals(5.0, value("testpool_acquired_total"));
		Assert.equals(1.0, value("testpool_opened_total"), "reusing an idle connection must not count as opening one");
	}

	public function testTimeoutIsCounted():Void {
		var pool = makePool(1);
		var held = pool.acquire();

		try {
			pool.acquire(0.01);
			Assert.fail("a saturated pool must time out");
		} catch (_:Dynamic) {}

		Assert.equals(1.0, value("testpool_acquire_timeouts_total"));
		Assert.equals(1.0, value("testpool_acquired_total"), "a timed-out acquisition is not an acquisition");
		pool.release(held);
	}

	/**
	 * Retirement reasons are labelled because they mean different things
	 * operationally: connections dying under `failed_validation` say the
	 * database is dropping them, which is not the same problem as an
	 * application calling `discard()`.
	 */
	public function testRetirementsAreLabelledByReason():Void {
		var pool = makePool(2);
		pool.discard(pool.acquire());
		Assert.equals(1.0, value('testpool_retired_total{reason="discarded"}'));

		var unhealthy:Bool = false;
		var validating = makePool(2, function(_) return unhealthy);
		var first = validating.acquire();
		validating.release(first);
		// The connection is now idle; failing validation retires it on the
		// next acquire rather than handing it out.
		validating.release(validating.acquire());
		Assert.equals(1.0, value('testpool_retired_total{reason="failed_validation"}'));

		var closing = makePool(2);
		closing.release(closing.acquire());
		closing.close();
		Assert.equals(1.0, value('testpool_retired_total{reason="pool_closed"}'));
	}

	/**
	 * The constraint that makes this safe to run in production: the series
	 * count is fixed by the pool, not by how much traffic flows through it.
	 *
	 * A per-connection label would pass every other case here and then
	 * grow without bound on a real server, where the collector keeps each
	 * series long after the connection it named is gone.
	 */
	public function testSeriesCountDoesNotGrowWithTraffic():Void {
		var pool = makePool(4);

		pool.release(pool.acquire());
		var afterFirst:Int = registry.size();

		for (_ in 0...500) {
			var held = pool.acquire();
			pool.release(held);
		}
		pool.discard(pool.acquire());

		// The discard adds exactly one series: the labelled retirement
		// reason, which is drawn from a fixed set of four.
		Assert.isTrue(registry.size() <= afterFirst + 1,
			'series grew from $afterFirst to ${registry.size()} under 500 acquisitions; a per-connection label would do this');
	}
}
