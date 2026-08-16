package crossbyte.net;

import utest.Assert;

/**
 * Graceful shutdown of `ServerWebSocket`.
 */
class ServerWebSocketDrainTest extends utest.Test {
	public function testStopAcceptingReleasesListenerAndIsIdempotent():Void {
		var server = new ServerWebSocket();
		server.bind(0, "127.0.0.1");
		server.listen();

		Assert.isTrue(server.listening);
		Assert.equals(0, server.clientCount);

		server.stopAccepting();
		Assert.isFalse(server.listening);
		Assert.isFalse(server.bound);

		// Repeat calls are harmless, and a later close() must not fail on
		// the already-released listener.
		server.stopAccepting();
		server.close();
	}

	public function testDrainWithNoClientsCompletesImmediately():Void {
		var server = new ServerWebSocket();
		server.bind(0, "127.0.0.1");
		server.listen();

		var port:Int = server.localPort;
		Assert.isFalse(server.draining);

		var completed:Bool = false;
		server.drain(30.0, () -> completed = true);

		// Nothing to tell to go away, so shutdown finishes synchronously
		// rather than waiting out the timeout.
		Assert.isTrue(completed);
		Assert.isTrue(server.draining);
		Assert.isFalse(server.listening);
		Assert.equals(0, server.clientCount);

		// The listener was genuinely released: the port can be rebound.
		var successor = new ServerSocket();
		successor.bind(port, "127.0.0.1");
		successor.listen();
		Assert.isTrue(successor.listening);
		successor.close();
	}

	public function testDrainIsIdempotent():Void {
		var server = new ServerWebSocket();
		server.bind(0, "127.0.0.1");
		server.listen();

		var completions:Int = 0;
		server.drain(0, () -> completions++);
		// A second drain must not restart teardown or re-fire the callback.
		server.drain(0, () -> completions++);

		Assert.equals(1, completions);
		Assert.isTrue(server.draining);
	}

	public function testDrainWithoutCallbackAndOnUnboundServerIsSafe():Void {
		var server = new ServerWebSocket();
		server.bind(0, "127.0.0.1");
		server.listen();
		server.drain(0);
		Assert.isTrue(server.draining);
		Assert.isFalse(server.listening);

		// stopAccepting() on a server that never listened is a no-op, and
		// leaves it usable.
		var fresh = new ServerWebSocket();
		fresh.stopAccepting();
		Assert.isFalse(fresh.listening);
		fresh.bind(0, "127.0.0.1");
		fresh.listen();
		Assert.isTrue(fresh.listening);
		fresh.close();
	}
}
