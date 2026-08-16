package crossbyte.metrics;

import crossbyte.errors.ArgumentError;
import utest.Assert;

class MetricsEndpointTest extends utest.Test {
	public function testConstantsAndPathValidation():Void {
		Assert.equals("/metrics", MetricsEndpoint.DEFAULT_PATH);
		Assert.isTrue(MetricsEndpoint.CONTENT_TYPE.indexOf("text/plain") == 0);
		Assert.isTrue(MetricsEndpoint.CONTENT_TYPE.indexOf("version=0.0.4") > 0);

		// A path that cannot match any request is a silent misconfiguration.
		Assert.raises(() -> MetricsEndpoint.middleware(null, "metrics"), ArgumentError);
		Assert.notNull(MetricsEndpoint.middleware(null, "/custom"));
		Assert.notNull(MetricsEndpoint.middleware(new Metrics()));
	}

	public function testRegistryRendersServerStyleSeries():Void {
		// The shape HTTPServer publishes, asserted without needing a live
		// server: counter by status class, duration histogram, bound gauge.
		var registry = new Metrics();
		var connections:Int = 2;

		registry.counter("http_requests_total", ["status" => "2xx"], "Responses sent.").inc(3);
		registry.counter("http_requests_total", ["status" => "5xx"]).inc();
		registry.histogram("http_request_seconds").observe(0.02);
		registry.gaugeFn("http_active_connections", () -> connections);

		var text = registry.toPrometheus();

		Assert.isTrue(text.indexOf("# TYPE http_requests_total counter") >= 0);
		Assert.isTrue(text.indexOf('http_requests_total{status="2xx"} 3') >= 0);
		Assert.isTrue(text.indexOf('http_requests_total{status="5xx"} 1') >= 0);
		Assert.isTrue(text.indexOf("# TYPE http_request_seconds histogram") >= 0);
		Assert.isTrue(text.indexOf("http_request_seconds_count 1") >= 0);
		Assert.isTrue(text.indexOf("http_active_connections 2") >= 0);

		// The gauge tracks its source rather than a copy taken at
		// registration time.
		connections = 5;
		Assert.isTrue(registry.toPrometheus().indexOf("http_active_connections 5") >= 0);
	}

	public function testStatusClassKeepsCardinalityBounded():Void {
		var registry = new Metrics();

		// Many distinct codes must collapse into a handful of series.
		for (code in [200, 201, 204, 301, 404, 410, 500, 503]) {
			registry.counter("http_requests_total", ["status" => Std.int(code / 100) + "xx"]).inc();
		}

		Assert.equals(4, registry.size());
		var text = registry.toPrometheus();
		Assert.isTrue(text.indexOf('http_requests_total{status="2xx"} 3') >= 0);
		Assert.isTrue(text.indexOf('http_requests_total{status="3xx"} 1') >= 0);
		Assert.isTrue(text.indexOf('http_requests_total{status="4xx"} 2') >= 0);
		Assert.isTrue(text.indexOf('http_requests_total{status="5xx"} 2') >= 0);
	}
}
