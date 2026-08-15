package crossbyte.http;

import crossbyte.io.ByteArray;
import crossbyte.io.File;
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
