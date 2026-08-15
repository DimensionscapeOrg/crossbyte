package crossbyte.net;

import utest.Assert;

/**
 * Graceful-shutdown primitives on `ServerSocket`.
 */
class ServerSocketDrainTest extends utest.Test {
	public function testStopAcceptingReleasesListenerAndIsIdempotent():Void {
		var server = new ServerSocket();
		server.bind(0, "127.0.0.1");
		server.listen();

		var port:Int = server.localPort;
		Assert.isTrue(server.listening);
		Assert.isTrue(port > 0);

		server.stopAccepting();
		Assert.isFalse(server.listening);
		Assert.isFalse(server.bound);

		// Repeat calls are harmless, and a later close() must not fail on the
		// already-released listener.
		server.stopAccepting();
		server.close();

		// The port is genuinely free again: a successor can bind it.
		var successor = new ServerSocket();
		successor.bind(port, "127.0.0.1");
		successor.listen();
		Assert.isTrue(successor.listening);
		successor.close();
	}

	public function testStopAcceptingOnUnboundServerIsNoOp():Void {
		var server = new ServerSocket();
		server.stopAccepting();
		Assert.isFalse(server.listening);

		// Still usable afterwards: nothing was torn down.
		server.bind(0, "127.0.0.1");
		server.listen();
		Assert.isTrue(server.listening);
		server.close();
	}
}
