package crossbyte.net;

import crossbyte.http.HTTPTestSupport;
import utest.Assert;
import utest.Async;

/**
 * A peer that completes the TCP connection and then says nothing must not
 * keep a descriptor for as long as it likes.
 *
 * `ServerWebSocketDrainTest` covers this on the targets that accept through
 * their own loop. Node accepts on a callback, so it needs its own proof
 * that an accepted session is recorded as pending and that the reaper runs.
 * `handshakeTimeout` defaults to ten seconds, so this protection is on by
 * default everywhere, and Node is the target most likely to be serving a
 * browser, which is the entire audience for a WebSocket.
 *
 * Asynchronous so that Node can run it at all. The synchronous pump-and-sleep
 * the drain test uses blocks the event loop that the accept callback needs, so
 * on Node it would spend its whole timeout having accepted nothing. On every
 * other target `pumpUntilAsync` delegates inline and this stays as fast and as
 * debuggable as the synchronous version.
 */
class ServerWebSocketUpgradeReapTest extends utest.Test {
	@:timeout(20000)
	public function testAStalledUpgradeIsReclaimed(async:Async):Void {
		if (!ServerSocket.isSupported) {
			Assert.isFalse(ServerSocket.isSupported);
			async.done();
			return;
		}

		var server = new ServerWebSocket();
		server.handshakeTimeout = 0.4;
		server.bind(0, "127.0.0.1");
		server.listen();

		// Node has no bind separate from listen and claims the port a turn
		// later, so reading it before this resolves gives 0.
		HTTPTestSupport.pumpUntilAsync(() -> server.localPort != 0, 2.0, function(_):Void {
			var client = new Socket();
			client.connect("127.0.0.1", server.localPort);

			// Accepted and recorded, well short of the deadline.
			HTTPTestSupport.pumpUntilAsync(() -> pending(server) > 0, 2.0, function(recorded:Bool):Void {
				Assert.isTrue(recorded, "the accepted session was never recorded as waiting to upgrade");

				// Held on to, so that the closing below can be asserted rather
				// than inferred from the list emptying. That distinction is the
				// whole point: a session dropped from tracking with its descriptor
				// still open would empty the list just the same, so an assertion on
				// the list alone passes either way.
				var session = @:privateAccess server.__pendingUpgrades[0].session;
				Assert.notNull(session);
				Assert.isFalse(session.registryClosed, "the session was closed before its deadline");

				// Nothing is ever sent, so the upgrade cannot complete and the
				// only thing that can end this session is the clock.
				HTTPTestSupport.pumpUntilAsync(() -> pending(server) == 0, 3.0, function(reaped:Bool):Void {
					Assert.isTrue(reaped, "a session that never upgraded was still being waited on");
					Assert.isTrue(session.registryClosed, "a session that never upgraded was forgotten rather than closed");
					Assert.equals(0, server.clientCount, "a session that never upgraded was counted as established");

					try client.close() catch (_:Dynamic) {}
					try server.close() catch (_:Dynamic) {}
					async.done();
				});
			});
		});
	}

	private static function pending(server:ServerWebSocket):Int {
		return @:privateAccess server.__pendingUpgrades.length;
	}
}
