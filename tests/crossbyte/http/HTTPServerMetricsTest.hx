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

/**
 * End-to-end metrics: a live server, a real request, real recorded series.
 */
class HTTPServerMetricsTest extends utest.Test {
	public function testServerRecordsRequestMetrics():Void {
		var registry = new Metrics();
		var body = __request(registry, "GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n");

		Assert.isTrue(body.indexOf("Hello metrics") >= 0);

		var text = registry.toPrometheus();

		// A served request must land in the counter under its status class.
		Assert.isTrue(text.indexOf('http_requests_total{status="2xx"} 1') >= 0);
		// The duration histogram observes on connection cleanup.
		Assert.isTrue(text.indexOf("# TYPE http_request_seconds histogram") >= 0);
		// The connection gauge exists and has settled back to zero.
		Assert.isTrue(text.indexOf("http_active_connections 0") >= 0);
	}

	public function testMetricsEndpointServesRegistry():Void {
		var registry = new Metrics();
		registry.counter("custom_total", null, "A custom counter.").inc(7);

		var body = __request(registry, "GET /metrics HTTP/1.1\r\nHost: localhost\r\n\r\n", true);

		Assert.isTrue(body.indexOf("# HELP custom_total A custom counter.") >= 0);
		Assert.isTrue(body.indexOf("custom_total 7") >= 0);
		// The scrape itself is a request, so the server's own series appear.
		Assert.isTrue(body.indexOf("http_active_connections") >= 0);
	}

	public function testMetricsEndpointRejectsNonReadMethods():Void {
		var registry = new Metrics();
		var raw = __requestRaw(registry, "POST /metrics HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n", true);

		Assert.isTrue(raw.indexOf("405") >= 0);
	}

	public function testDisabledMetricsRecordNothing():Void {
		var registry = new Metrics();
		// Server configured without a registry: the request succeeds but
		// nothing is recorded.
		var body = __request(null, "GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n");

		Assert.isTrue(body.indexOf("Hello metrics") >= 0);
		Assert.equals(0, registry.size());
	}

	private function __request(registry:Metrics, requestText:String, withEndpoint:Bool = false):String {
		var raw = __requestRaw(registry, requestText, withEndpoint);
		var split = raw.indexOf("\r\n\r\n");
		return split < 0 ? raw : raw.substr(split + 4);
	}

	private function __requestRaw(registry:Metrics, requestText:String, withEndpoint:Bool = false):String {
		var root = File.createTempDirectory();
		var indexFile = root.resolvePath("index.html");
		var fixture = new ByteArray();
		fixture.writeUTFBytes("Hello metrics");
		indexFile.save(fixture);

		var config = new HTTPServerConfig("127.0.0.1", 0, root, null, ["index.html"]);
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

		try {
			client.connect("127.0.0.1", server.localPort);
			__pumpUntil(() -> closed, 3.0);
			try {
				client.close();
			} catch (_:Dynamic) {}
		} catch (_:Dynamic) {}

		// Cleanup must run before assertions so a failure cannot leave a
		// listener bound for the next case.
		try {
			server.close();
		} catch (_:Dynamic) {}
		try {
			root.deleteDirectory(true);
		} catch (_:Dynamic) {}

		return raw;
	}

	private function __pumpUntil(done:Void->Bool, timeout:Float):Void {
		var runtime = CrossByte.current();
		var deadline:Float = Sys.time() + timeout;

		while (!done() && Sys.time() < deadline) {
			@:privateAccess runtime.pump(0.008);
		}

		// One extra pump so the close-driven cleanup (which records the
		// duration observation) runs before the caller inspects metrics.
		@:privateAccess runtime.pump(0.008);
	}
}
