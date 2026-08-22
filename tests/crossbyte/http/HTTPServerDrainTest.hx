package crossbyte.http;

import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.ProgressEvent;
import crossbyte.io.ByteArray;
import crossbyte.io.File;
import crossbyte.net.Socket;
import utest.Assert;
import utest.Async;

/**
 * Graceful shutdown of `HTTPServer`.
 *
 * The three cases that touch no socket stay synchronous, because they mean the
 * same thing on every target without help. The two that do -- and the one that
 * needs the assigned port, which Node hands over a turn later -- go through the
 * asynchronous pump.
 */
@:timeout(20000)
class HTTPServerDrainTest extends utest.Test {
	public function testDrainWithNoTrafficCompletesImmediately(async:Async):Void {
		var server = __makeServer();

		// Asynchronous only for the port. Node has no bind separate from
		// listen and claims the port on a later turn, so reading it here gives
		// 0 -- and rebinding port 0 below would bind a fresh random port and
		// assert nothing about the one just released.
		HTTPTestSupport.pumpUntilAsync(() -> server.localPort != 0, 2.0, function(_):Void {
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
			async.done();
		});
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

	public function testDrainClosesIdleKeepAliveConnectionImmediately(async:Async):Void {
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

		function cleanUp():Void {
			try {
				client.close();
			} catch (_:Dynamic) {}
			try {
				server.close();
			} catch (_:Dynamic) {}
			try {
				root.deleteDirectory(true);
			} catch (_:Dynamic) {}

			async.done();
		}

		HTTPTestSupport.connectThen(client, server, function():Void {
			HTTPTestSupport.pumpUntilAsync(() -> raw.indexOf("drain fixture") >= 0, 2.0, function(_):Void {
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

				HTTPTestSupport.pumpUntilAsync(() -> closeSeen, 2.0, function(_):Void {
					Assert.isTrue(closeSeen);
					cleanUp();
				});
			});
		});
	}

	public function testDrainLetsInFlightRequestFinish(async:Async):Void {
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

		function cleanUp():Void {
			try {
				client.close();
			} catch (_:Dynamic) {}
			try {
				server.close();
			} catch (_:Dynamic) {}
			try {
				root.deleteDirectory(true);
			} catch (_:Dynamic) {}

			async.done();
		}

		HTTPTestSupport.connectThen(client, server, function():Void {
			HTTPTestSupport.pumpUntilAsync(() -> release != null, 2.0, function(_):Void {
				Assert.notNull(release);

				var completed = false;
				server.drain(30.0, () -> completed = true);
				// In-flight work holds the drain open; severing it here is
				// exactly what drain() exists to avoid.
				Assert.isFalse(completed);
				Assert.equals(1, server.activeConnections);

				release();

				HTTPTestSupport.pumpUntilAsync(() -> completed && closeSeen && raw.indexOf("drain fixture") >= 0, 3.0, function(_):Void {
					Assert.isTrue(completed);
					// The response that finished during the drain warned the
					// client the connection is ending, keep-alive or not.
					Assert.isTrue(raw.toLowerCase().indexOf("connection: close") >= 0);
					Assert.isTrue(raw.indexOf("drain fixture") >= 0);
					Assert.isTrue(closeSeen);
					cleanUp();
				});
			});
		});
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
