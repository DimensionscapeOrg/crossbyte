package crossbyte.net;

import crossbyte.errors.ArgumentError;
import crossbyte.events.ServerSocketConnectEvent;
import haxe.io.Bytes;
import utest.Assert;
import utest.Async;

/**
	What a `ServerWebSocket` does with a session between accepting it and
	opening it -- while its peer is still upgrading -- when the server stops,
	drains or closes, and what it counts.

	The deadline on those sessions is reaped from the tick `stopAccepting()`,
	`drain()` and `close()` take away, and none of them touched the sessions
	themselves: a peer caught mid-upgrade was held with no deadline at all,
	and one that finished afterwards opened on a server that had stopped.
	`pendingHandshakeCount()` and `handshakeFailures`, inherited from
	`ServerSocket`, never moved.

	Peers are `WirePeer`s, so each says exactly as much as a case needs, on
	every target, Node included.
**/
class ServerWebSocketUpgradeLifecycleTest extends utest.Test {
	@:timeout(15000)
	public function testStopAcceptingDropsSessionsStillUpgrading(async:Async):Void {
		__waitingPeer(function(server, peer, done) {
			server.stopAccepting();

			NetPump.until(() -> __ended(peer), 5.0, function(_) {
				Assert.isTrue(peer.ended, "a session still upgrading outlived stopAccepting()");
				Assert.equals(0, __pending(server), "the server still waited on a session it had let go of");
				Assert.equals(0, server.handshakeFailures, "a session let go of was counted as a failed handshake");
				done();
			});
		}, async);
	}

	@:timeout(15000)
	public function testCloseDropsSessionsStillUpgrading(async:Async):Void {
		__waitingPeer(function(server, peer, done) {
			server.close();

			NetPump.until(() -> __ended(peer), 5.0, function(_) {
				Assert.isTrue(peer.ended, "a session still upgrading outlived close()");
				Assert.equals(0, __pending(server), "the server still waited on a session it had let go of");
				done();
			});
		}, async);
	}

	/**
		A peer that asks to upgrade once the server is draining gets nothing:
		no session opens, and no `connect` is dispatched on a server shutting
		down.
	**/
	@:timeout(15000)
	public function testDrainRefusesALateUpgrade(async:Async):Void {
		__waitingPeer(function(server, peer, done) {
			var connects:Int = 0;
			server.addEventListener(ServerSocketConnectEvent.CONNECT, function(_) connects++);

			server.drain(5.0);

			NetPump.until(() -> __ended(peer), 3.0, function(_) {
				Assert.isTrue(peer.ended, "the late peer's connection was left open");

				// Asked once the server has let go, or, where it has not, as late
				// as a peer might. Read only while the connection is up: eval
				// raises the reset that follows a send into a closed one as an
				// error nothing can catch.
				peer.upgrade("/");
				NetPump.until(() -> {
					if (!peer.ended) {
						peer.poll();
					}
					return false;
				}, 0.5, function(_) {
					Assert.isNull(peer.head(), "a server that was draining answered an upgrade: " + peer.head());
					Assert.equals(0, connects, "a session opened on a server that was draining");
					done();
				});
			});
		}, async);
	}

	/**
		A close code that may not be sent is refused before anything is
		stopped. Each session's `closeWith` refused it, and the refusals were
		swallowed, so no session heard why it was dropped.
	**/
	public function testDrainWithACodeThatMayNotBeSentIsRefused():Void {
		var server = new ServerWebSocket();
		server.bind(0, "127.0.0.1");
		server.listen();

		Assert.raises(() -> server.drain(0, null, 1006), ArgumentError);
		Assert.isTrue(server.listening, "a refused drain stopped the server");
		Assert.isFalse(server.draining, "a refused drain left the server draining");

		var completed:Bool = false;
		server.drain(0, () -> completed = true, 4000);
		Assert.isTrue(completed, "a code from the application range was refused");
	}

	/**
		A session given up on at `handshakeTimeout` is counted in
		`handshakeFailures`, as a handshake given up on is by `ServerSocket`.
	**/
	@:timeout(15000)
	public function testASessionGivenUpOnIsCountedAsAFailedHandshake(async:Async):Void {
		__waitingPeer(function(server, peer, done) {
			NetPump.until(() -> __ended(peer), 5.0, function(_) {
				Assert.isTrue(peer.ended, "a session that never upgraded was not given up on");
				Assert.equals(1, server.handshakeFailures, "a session given up on was not counted");
				done();
			});
		}, async, 0.3);
	}

	/**
		An upgrade request the server cannot read is a failed handshake; one
		`upgrade` turned down is a decision, and is not counted.
	**/
	@:timeout(15000)
	public function testABadUpgradeIsCountedAndARefusalIsNot(async:Async):Void {
		var server = new ServerWebSocket();
		server.upgrade = request -> request.path != "/refused";
		server.bind(0, "127.0.0.1");
		server.listen();

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var refused = new WirePeer(server.localPort);
			var garbled = new WirePeer(server.localPort);
			refused.upgrade("/refused");
			// No Upgrade header: answered 400.
			garbled.send(Bytes.ofString("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"));

			NetPump.until(() -> __ended(refused) && __ended(garbled), 5.0, function(_) {
				Assert.isTrue(refused.ended && garbled.ended, "the server left a connection it had answered open");
				Assert.isTrue(StringTools.startsWith(refused.text(), "HTTP/1.1 403"), "the refusal was not answered 403: " + refused.text());
				Assert.isTrue(StringTools.startsWith(garbled.text(), "HTTP/1.1 400"), "the bad request was not answered 400: " + garbled.text());
				Assert.equals(1, server.handshakeFailures, "the bad upgrade should be counted and the refusal not");
				refused.close();
				garbled.close();
				try server.close() catch (_:Dynamic) {}
				async.done();
			});
		});
	}

	/**
		`pendingHandshakeCount()` is the sessions still upgrading -- what
		`maxPendingHandshakes` bounds -- where it read 0 on every
		`ServerWebSocket`.
	**/
	@:timeout(15000)
	public function testPendingHandshakeCountIsTheSessionsStillUpgrading(async:Async):Void {
		var server = new ServerWebSocket();
		server.bind(0, "127.0.0.1");
		server.listen();

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var first = new WirePeer(server.localPort);
			var second = new WirePeer(server.localPort);

			NetPump.until(() -> __pending(server) == 2, 5.0, function(_) {
				Assert.equals(2, server.pendingHandshakeCount(), "the sessions still upgrading were not counted");
				first.close();
				second.close();
				try server.close() catch (_:Dynamic) {}
				async.done();
			});
		});
	}

	/**
		A plain server with one peer connected and saying nothing; `body`
		runs once the server is waiting on it, and closes everything with
		`done`.
	**/
	private function __waitingPeer(body:(ServerWebSocket, WirePeer, Void->Void)->Void, async:Async, handshakeTimeout:Float = 30.0):Void {
		var server = new ServerWebSocket();
		// Long by default, so the deadline is not what ends a session.
		server.handshakeTimeout = handshakeTimeout;
		server.bind(0, "127.0.0.1");
		server.listen();

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var peer = new WirePeer(server.localPort);

			NetPump.until(() -> __pending(server) > 0, 5.0, function(arrived) {
				Assert.isTrue(arrived, "the peer was never taken on");
				body(server, peer, function() {
					peer.close();
					try server.close() catch (_:Dynamic) {}
					NetPump.wait(0.1, () -> async.done());
				});
			});
		});
	}

	/** Whether `peer` has been hung up on, reading what has arrived. **/
	private static function __ended(peer:WirePeer):Bool {
		peer.poll();
		return peer.ended;
	}

	private static function __pending(server:ServerWebSocket):Int {
		return @:privateAccess server.__pendingUpgrades.length;
	}
}
