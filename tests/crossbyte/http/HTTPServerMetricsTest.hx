package crossbyte.http;

import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.ProgressEvent;
import crossbyte.io.ByteArray;
import crossbyte.io.File;
import crossbyte.metrics.Metrics;
import crossbyte.metrics.MetricsEndpoint;
import crossbyte.net.Socket;
import utest.Assert;
import utest.Async;

/**
 * End-to-end metrics: a live server, a real request, real recorded series.
 */
@:timeout(20000)
class HTTPServerMetricsTest extends utest.Test {
	public function testServerRecordsRequestMetrics(async:Async):Void {
		var registry = new Metrics();

		__request(registry, "GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n", function(body):Void {
			Assert.isTrue(body.indexOf("Hello metrics") >= 0);

			var text = registry.toPrometheus();

			// A served request must land in the counter under its status class.
			Assert.isTrue(text.indexOf('http_requests_total{status="2xx"} 1') >= 0);
			// The duration histogram observes once per response, at response time.
			Assert.isTrue(text.indexOf("# TYPE http_request_seconds histogram") >= 0);
			// The connection gauge exists and has settled back to zero.
			Assert.isTrue(text.indexOf("http_active_connections 0") >= 0);

			// Buffer pressure is published as aggregates across connections,
			// and reads zero once everything has drained.
			Assert.isTrue(text.indexOf("http_output_buffer_bytes_max 0") >= 0);
			Assert.isTrue(text.indexOf("http_output_buffer_bytes_total 0") >= 0);

			// The constraint that keeps this safe on a busy server: no series
			// may carry a per-connection label. A peer address or socket id
			// here would outlive the connection that produced it and grow
			// without bound.
			for (line in text.split("\n")) {
				if (line.indexOf("http_") != 0) {
					continue;
				}
				var brace:Int = line.indexOf("{");
				if (brace < 0) {
					continue;
				}
				var labels:String = line.substring(brace, line.indexOf("}") + 1);
				Assert.isTrue(labels.indexOf("peer") < 0 && labels.indexOf("addr") < 0 && labels.indexOf("socket") < 0
					&& labels.indexOf("connection") < 0, 'per-connection label found in $line');
			}

			async.done();
		});
	}

	public function testMetricsEndpointServesRegistry(async:Async):Void {
		var registry = new Metrics();
		registry.counter("custom_total", null, "A custom counter.").inc(7);

		__request(registry, "GET /metrics HTTP/1.1\r\nHost: localhost\r\n\r\n", function(body):Void {
			Assert.isTrue(body.indexOf("# HELP custom_total A custom counter.") >= 0);
			Assert.isTrue(body.indexOf("custom_total 7") >= 0);
			// The scrape itself is a request, so the server's own series appear.
			Assert.isTrue(body.indexOf("http_active_connections") >= 0);
			async.done();
		}, true);
	}

	public function testMetricsEndpointRejectsNonReadMethods(async:Async):Void {
		var registry = new Metrics();

		__requestRaw(registry, "POST /metrics HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n", function(raw):Void {
			Assert.isTrue(raw.indexOf("405") >= 0);
			async.done();
		}, true);
	}

	public function testDisabledMetricsRecordNothing(async:Async):Void {
		var registry = new Metrics();

		// Server configured without a registry: the request succeeds but
		// nothing is recorded.
		__request(null, "GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n", function(body):Void {
			Assert.isTrue(body.indexOf("Hello metrics") >= 0);
			Assert.equals(0, registry.size());
			async.done();
		});
	}

	private function __request(registry:Metrics, requestText:String, done:String->Void, withEndpoint:Bool = false):Void {
		__requestRaw(registry, requestText, function(raw):Void {
			var split = raw.indexOf("\r\n\r\n");
			done(split < 0 ? raw : raw.substr(split + 4));
		}, withEndpoint);
	}

	private function __requestRaw(registry:Metrics, requestText:String, done:String->Void, withEndpoint:Bool = false):Void {
		var root = File.createTempDirectory();
		var indexFile = root.resolvePath("index.html");
		var fixture = new ByteArray();
		fixture.writeUTFBytes("Hello metrics");
		indexFile.save(fixture);

		var config = new HTTPServerConfig("127.0.0.1", 0, root, null, ["index.html"]);
		// This harness pumps until the server closes the connection, so
		// keep-alive would burn the whole timeout and leave the gauge
		// assertions racing a connection that is deliberately still open.
		config.keepAlive = false;
		config.metrics = registry;
		if (withEndpoint) {
			config.middleware.push(MetricsEndpoint.middleware(registry));
		}

		var server = new HTTPServer(config);
		var client = new Socket();
		var raw = "";
		var closed = false;

		client.addEventListener(Event.CONNECT, _ -> {
			client.writeUTFBytes(requestText);
			client.flush();
		});
		client.addEventListener(ProgressEvent.SOCKET_DATA, _ -> {
			if (client.bytesAvailable > 0) {
				raw += client.readUTFBytes(client.bytesAvailable);
			}
		});
		client.addEventListener(Event.CLOSE, _ -> closed = true);

		HTTPTestSupport.connectThen(client, server, function():Void {
			__pumpUntil(() -> closed, 3.0, function():Void {
				try {
					client.close();
				} catch (_:Dynamic) {}

				// Cleanup runs before the assertions so a failing case cannot
				// leave a listener bound for the next one.
				try {
					server.close();
				} catch (_:Dynamic) {}
				try {
					root.deleteDirectory(true);
				} catch (_:Dynamic) {}

				done(raw);
			});
		});
	}

	private function __pumpUntil(ready:Void->Bool, timeout:Float, then:Void->Void):Void {
		// A shorter step than the shared default: this suite reads gauges
		// rather than a socket, so it wants the runtime stepped as tightly as
		// possible.
		HTTPTestSupport.pumpUntilAsync(ready, timeout, function(_):Void {
			// One extra pump so the close-driven cleanup (which settles the
			// connection gauge) runs before the caller inspects metrics.
			HTTPTestSupport.pumpMoreAsync(1, then, 0.008);
		}, 0.008);
	}
}
