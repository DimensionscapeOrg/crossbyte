package crossbyte.http;

import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.ProgressEvent;
import crossbyte.io.ByteArray;
import crossbyte.io.File;
import crossbyte.net.Socket;
import utest.Assert;

/**
 * Graceful shutdown of `HTTPServer`.
 */
class HTTPServerDrainTest extends utest.Test {
	public function testDrainWithNoTrafficCompletesImmediately():Void {
		var server = __makeServer();
		var port:Int = server.localPort;

		Assert.isFalse(server.draining);
		Assert.equals(0, server.activeConnections);
		Assert.isTrue(server.listening);

		var completed:Bool = false;
		server.drain(30.0, () -> completed = true);

		// With nothing in flight there is nothing to wait for, so shutdown
		// finishes synchronously rather than deferring to a later tick.
		Assert.isTrue(completed);
		Assert.isTrue(server.draining);
		Assert.isFalse(server.listening);
		Assert.equals(0, server.activeConnections);

		// The listener was genuinely released: the port can be rebound.
		var successor = new crossbyte.net.ServerSocket();
		successor.bind(port, "127.0.0.1");
		successor.listen();
		Assert.isTrue(successor.listening);
		successor.close();
	}

	public function testDrainIsIdempotent():Void {
		var server = __makeServer();

		var completions:Int = 0;
		server.drain(0, () -> completions++);
		// A second drain must not restart shutdown or fire the callback again.
		server.drain(0, () -> completions++);

		Assert.equals(1, completions);
		Assert.isTrue(server.draining);
	}

	public function testDrainWithoutCallbackIsSafe():Void {
		var server = __makeServer();
		server.drain(0);
		Assert.isTrue(server.draining);
		Assert.isFalse(server.listening);
	}

	public function testDrainClosesIdleKeepAliveConnectionImmediately():Void {
		var root = File.createTempDirectory();
		var indexFile = root.resolvePath("index.html");
		var fixture = new ByteArray();
		fixture.writeUTFBytes("drain fixture");
		indexFile.save(fixture);

		var config = new HTTPServerConfig("127.0.0.1", 0, root, null, ["index.html"]);
		var server = new HTTPServer(config);
		var client = new Socket();
		var raw = "";
		var closeSeen = false;

		client.addEventListener(Event.CONNECT, _ -> {
			client.writeUTFBytes("GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n");
			client.flush();
		});
		client.addEventListener(ProgressEvent.SOCKET_DATA, _ -> {
			if (client.bytesAvailable > 0) {
				raw += client.readUTFBytes(client.bytesAvailable);
			}
		});
		client.addEventListener(Event.CLOSE, _ -> closeSeen = true);

		try {
			client.connect("127.0.0.1", server.localPort);
			HTTPTestSupport.pumpUntil(() -> raw.indexOf("drain fixture") >= 0, 2.0);
			Assert.isTrue(raw.indexOf("drain fixture") >= 0);
			Assert.equals(1, server.activeConnections);

			// The connection is between requests: there is nothing in
			// flight to wait for, so drain closes it in the walk and
			// completes synchronously rather than sitting out any part of
			// the 30 s wall.
			var completed = false;
			server.drain(30.0, () -> completed = true);
			Assert.isTrue(completed);
			Assert.equals(0, server.activeConnections);

			HTTPTestSupport.pumpUntil(() -> closeSeen, 2.0);
			Assert.isTrue(closeSeen);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try {
			client.close();
		} catch (_:Dynamic) {}
		try {
			server.close();
		} catch (_:Dynamic) {}
		try {
			root.deleteDirectory(true);
		} catch (_:Dynamic) {}
	}

	public function testDrainLetsInFlightRequestFinish():Void {
		var root = File.createTempDirectory();
		var indexFile = root.resolvePath("index.html");
		var fixture = new ByteArray();
		fixture.writeUTFBytes("drain fixture");
		indexFile.save(fixture);

		// The middleware parks the request mid-dispatch so the drain is
		// observed while work is genuinely in flight.
		var release:?Dynamic->Void = null;
		var config = new HTTPServerConfig("127.0.0.1", 0, root, null, ["index.html"], null, null, null, [
			function(_:HTTPRequestHandler, next:?Dynamic->Void):Void {
				release = next;
			}
		]);
		var server = new HTTPServer(config);
		var client = new Socket();
		var raw = "";
		var closeSeen = false;

		client.addEventListener(Event.CONNECT, _ -> {
			client.writeUTFBytes("GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n");
			client.flush();
		});
		client.addEventListener(ProgressEvent.SOCKET_DATA, _ -> {
			if (client.bytesAvailable > 0) {
				raw += client.readUTFBytes(client.bytesAvailable);
			}
		});
		client.addEventListener(Event.CLOSE, _ -> closeSeen = true);

		try {
			client.connect("127.0.0.1", server.localPort);
			HTTPTestSupport.pumpUntil(() -> release != null, 2.0);
			Assert.notNull(release);

			var completed = false;
			server.drain(30.0, () -> completed = true);
			// In-flight work holds the drain open; severing it here is
			// exactly what drain() exists to avoid.
			Assert.isFalse(completed);
			Assert.equals(1, server.activeConnections);

			release();
			HTTPTestSupport.pumpUntil(() -> completed && closeSeen && raw.indexOf("drain fixture") >= 0, 3.0);

			Assert.isTrue(completed);
			// The response that finished during the drain warned the
			// client the connection is ending, keep-alive or not.
			Assert.isTrue(raw.toLowerCase().indexOf("connection: close") >= 0);
			Assert.isTrue(raw.indexOf("drain fixture") >= 0);
			Assert.isTrue(closeSeen);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try {
			client.close();
		} catch (_:Dynamic) {}
		try {
			server.close();
		} catch (_:Dynamic) {}
		try {
			root.deleteDirectory(true);
		} catch (_:Dynamic) {}
	}

	private function __makeServer():HTTPServer {
		var root = File.createTempDirectory();
		var indexFile = root.resolvePath("index.html");
		var fixture = new ByteArray();
		fixture.writeUTFBytes("drain fixture");
		indexFile.save(fixture);

		var config = new HTTPServerConfig("127.0.0.1", 0, root, null, ["index.html"]);
		return new HTTPServer(config);
	}

}
