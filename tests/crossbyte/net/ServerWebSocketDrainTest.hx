package crossbyte.net;

import crossbyte.core.CrossByte;
import utest.Assert;

/**
 * Graceful shutdown of `ServerWebSocket`.
 */
class ServerWebSocketDrainTest extends utest.Test {
	public function testAStalledUpgradeIsReclaimed():Void {
		if (!ServerSocket.isSupported) {
			Assert.isFalse(ServerSocket.isSupported);
			return;
		}

		// A peer that completes the TCP connection and then says nothing. That
		// is indistinguishable from a slow client until a clock runs out, and
		// until this existed there was no clock: `ServerSocket` defers its TLS
		// handshake and sweeps deadlines from the tick, but `ServerWebSocket`
		// overrides the tick and accepts through its own path, so it inherited
		// the setting and not the sweep. The socket was held until the
		// operating system ran out of them.
		var server = new ServerWebSocket();
		server.handshakeTimeout = 0.4;

		var client = new crossbyte.net.Socket();

		try {
			server.bind(0, "127.0.0.1");
			server.listen();

			client.connect("127.0.0.1", server.localPort);

			// Long enough for the accept to land and be recorded as pending,
			// well short of the deadline.
			pumpUntil(() -> @:privateAccess server.__pendingUpgrades.length > 0, 2.0);
			Assert.equals(1, @:privateAccess server.__pendingUpgrades.length, "the accepted session was not being waited on");

			// Nothing is ever sent, so the upgrade cannot complete.
			pumpUntil(() -> @:privateAccess server.__pendingUpgrades.length == 0, 3.0);

			Assert.equals(0, @:privateAccess server.__pendingUpgrades.length, "a session that never upgraded was still being waited on");
			Assert.equals(0, server.clientCount, "a session that never upgraded was counted as established");
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try client.close() catch (_:Dynamic) {}
		try server.close() catch (_:Dynamic) {}
	}

	public function testAHandshakeTimeoutOfZeroWaitsForever():Void {
		if (!ServerSocket.isSupported) {
			Assert.isFalse(ServerSocket.isSupported);
			return;
		}

		// Zero means no deadline, matching every other timeout in this
		// codebase. A deployment with a legitimately slow client should be
		// able to say so rather than being told what its network is like.
		var server = new ServerWebSocket();
		server.handshakeTimeout = 0;

		var client = new crossbyte.net.Socket();

		try {
			server.bind(0, "127.0.0.1");
			server.listen();
			client.connect("127.0.0.1", server.localPort);

			pumpUntil(() -> false, 0.8);
			Assert.equals(0, @:privateAccess server.__pendingUpgrades.length, "a deadline was recorded when none was asked for");
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try client.close() catch (_:Dynamic) {}
		try server.close() catch (_:Dynamic) {}
	}

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
		// Binding to 0 must report the port the OS actually assigned;
		// otherwise the rebind check below proves nothing, since binding
		// to 0 again would simply pick another free port.
		Assert.isTrue(port > 0);
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

	/** Pumps the runtime until `done`, or until `timeout` seconds pass. **/
	private function pumpUntil(done:Void->Bool, timeout:Float):Void {
		var runtime = CrossByte.current();
		var deadline = Sys.time() + timeout;

		while (!done() && Sys.time() < deadline) {
			runtime.pump(1 / 120, 0);
			Sys.sleep(0.002);
		}
	}
}
