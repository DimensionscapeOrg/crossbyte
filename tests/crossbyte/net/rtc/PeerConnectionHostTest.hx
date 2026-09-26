package crossbyte.net.rtc;

import crossbyte.core.CrossByte;
import crossbyte.errors.ArgumentError;
import crossbyte.net.ice.IceCredentials;
import utest.Assert;

/**
	Several connections on one host's socket, each reaching its own peer.

	What a shared socket can get wrong is the routing: a datagram handed to
	the wrong connection is lost to the right one, and nothing below says why.
	So the peers here are ordinary connections with sockets of their own, as a
	browser would be, and each case checks that every message reaches the
	connection it was for and no other.

	Real sockets on loopback, so native only, like `PeerConnectionTest`.
**/
class PeerConnectionHostTest extends utest.Test {
	private function unsupported():Bool {
		if (!PeerConnection.isSupported) {
			Assert.isFalse(PeerConnection.isSupported);
			return true;
		}

		return false;
	}

	/**
		Two connections on one port, each talking to its own peer, and one
		closing leaves the other working.

		Checks are routed by the ufrag they name, the answers to this side's
		checks by their transaction, and DTLS by the address a path was proved
		to, all three are needed before a message crosses, so a message each
		way on each connection covers them.
	**/
	public function testConnectionsOnOneHostEachReachTheirOwnPeer():Void {
		if (unsupported()) return;

		var host = new PeerConnectionHost();
		var peers:Array<PeerConnection> = [];
		var hosted:Array<PeerConnection> = [];

		try {
			host.bind(0, "127.0.0.1");

			for (i in 0...2) {
				var peer = new PeerConnection(true);
				peer.bind(0, "127.0.0.1");

				var connection = host.createConnection(false);
				connection.connect(peer.description());
				peer.connect(connection.description());

				peers.push(peer);
				hosted.push(connection);
			}

			Assert.equals(2, host.connectionCount);
			Assert.equals(host.localPort, hosted[0].localPort, "a hosted connection has a port of its own");
			Assert.equals(host.localPort, hosted[1].localPort, "a hosted connection has a port of its own");
			Assert.equals(host.localPort, hosted[0].description().candidates[0].port, "a hosted connection offers a port of its own");

			pumpUntil(() -> [for (c in peers.concat(hosted)) if (!c.connected) c].length == 0, 20.0);

			for (connection in peers.concat(hosted)) {
				Assert.isTrue(connection.connected, "a connection never came up");
			}

			if ([for (c in peers.concat(hosted)) if (!c.connected) c].length > 0) {
				return;
			}

			var heard:Array<Array<String>> = [[], []];
			var answered:Array<Array<String>> = [[], []];
			var channels:Array<DataChannel> = [];

			for (i in 0...2) {
				var index = i;

				hosted[i].onChannel = function(channel:DataChannel):Void {
					channel.onMessage = function(text:String):Void {
						heard[index].push(text);
						channel.send("back from hosted " + index);
					};
				};

				var channel = peers[i].createDataChannel("chat");
				channel.onMessage = text -> answered[index].push(text);
				channels.push(channel);
			}

			pumpUntil(() -> channels[0].open && channels[1].open, 5.0);

			for (i in 0...2) {
				channels[i].send("to hosted " + i);
			}

			pumpUntil(() -> answered[0].length > 0 && answered[1].length > 0, 5.0);

			for (i in 0...2) {
				Assert.equals("to hosted " + i, heard[i].join(","), "hosted " + i + " heard the wrong peer, or nothing");
				Assert.equals("back from hosted " + i, answered[i].join(","), "peer " + i + " heard the wrong connection, or nothing");
			}

			// The first peer leaves; the second connection carries on.
			var reason:String = null;
			hosted[0].onClose = r -> reason = r;
			peers[0].close();
			pumpUntil(() -> reason != null, 5.0);

			Assert.notNull(reason, "the hosted connection whose peer left was not told");
			Assert.equals(1, host.connectionCount, "a closed connection is still on the host");
			Assert.isTrue(hosted[1].connected, "one peer leaving took another's connection down");

			// And everything routed to the one that closed is forgotten.
			var routed = 0;

			for (connection in (@:privateAccess host.__byTransaction)) {
				if (connection == hosted[0]) routed++;
			}

			for (connection in (@:privateAccess host.__byAddress)) {
				if (connection == hosted[0]) routed++;
			}

			Assert.equals(0, routed, "the host still routes to a connection that closed");

			channels[1].send("still here");
			pumpUntil(() -> answered[1].length > 1, 5.0);
			Assert.equals("to hosted 1,still here", heard[1].join(","), "the remaining connection stopped hearing its peer");
		} catch (e:Dynamic) {
			Assert.fail("unexpected: " + Std.string(e));
		}

		var closes = 0;

		for (connection in hosted) {
			connection.onClose = _ -> closes++;
		}

		host.close();
		Assert.equals(0, host.connectionCount, "closing the host left connections on it");
		Assert.equals(1, closes, "closing the host closed " + closes + " connections, where one was open");

		if (hosted.length > 1) {
			Assert.isFalse(hosted[1].connected, "closing the host left a connection up");
		}

		for (peer in peers) {
			peer.close();
		}
	}

	/**
		A connection whose peer names another peer's address does not take
		that peer's traffic.

		A peer's candidates are its own to write. If sending a check to an
		address were enough to be routed what arrives from it, one peer could
		list another's address as a candidate of its own and have that peer's
		records handed to it, the victim's connection would go quiet with
		nothing to say why. Only a proved path claims an address, and a path to
		somebody else's address cannot be proved.
	**/
	public function testAPeerNamingAnotherPeersAddressDoesNotTakeItsTraffic():Void {
		if (unsupported()) return;

		var host = new PeerConnectionHost();
		var victim = new PeerConnection(true);
		var hostedVictim:PeerConnection = null;
		var hostedThief:PeerConnection = null;

		try {
			host.bind(0, "127.0.0.1");
			victim.bind(0, "127.0.0.1");

			hostedVictim = host.createConnection(false);
			hostedVictim.connect(victim.description());
			victim.connect(hostedVictim.description());

			var accepted:DataChannel = null;
			var heard:Array<String> = [];

			hostedVictim.onChannel = function(channel:DataChannel):Void {
				accepted = channel;
				channel.onMessage = text -> heard.push(text);
			};

			pumpUntil(() -> victim.connected && hostedVictim.connected, 15.0);

			if (!victim.connected || !hostedVictim.connected) {
				Assert.fail("the victim's connection never came up, so there is nothing to protect");
				return;
			}

			var chat = victim.createDataChannel("chat");
			pumpUntil(() -> chat.open && accepted != null, 5.0);

			// A second connection on the host, whose peer names the victim's
			// address as its own. Its checks go there, and keep going, being
			// unanswered.
			var thief = new PeerConnection(true);
			var stolen = thief.description();
			stolen.candidates = [{address: "127.0.0.1", port: victim.localPort, type: "host", priority: 2130706431}];

			hostedThief = host.createConnection(false);
			hostedThief.connect(stolen);
			thief.close();

			pumpUntil(() -> false, 2.0);

			chat.send("still mine");
			pumpUntil(() -> heard.length > 0, 5.0);

			Assert.equals("still mine", heard.join(","), "the victim's records went to the connection that named its address");
			Assert.isTrue(hostedVictim.connected, "the victim's connection went down");
		} catch (e:Dynamic) {
			Assert.fail("unexpected: " + Std.string(e));
		}

		victim.close();
		host.close();
	}

	/**
		What a shared socket refuses: a socket of the connection's own, and the
		addresses only a socket of its own could discover.
	**/
	public function testAHostedConnectionHasNoSocketOfItsOwn():Void {
		if (unsupported()) return;

		var host = new PeerConnectionHost();

		try {
			Assert.raises(() -> host.createConnection(true), ArgumentError, "a connection was made on a host with no socket");

			host.bind(0, "127.0.0.1");
			var connection = host.createConnection(true);

			Assert.raises(() -> connection.bind(0, "127.0.0.1"), ArgumentError, "a hosted connection bound a socket of its own");

			var reflexive:String = null;
			var relayed:String = null;
			connection.gatherReflexive("127.0.0.1", 3478).then(_ -> reflexive = "resolved", e -> reflexive = e);
			connection.gatherRelayed("127.0.0.1", "user", "secret").then(_ -> relayed = "resolved", e -> relayed = e);

			pumpUntil(() -> reflexive != null && relayed != null, 2.0);

			Assert.isTrue(reflexive != null && reflexive.indexOf("host") >= 0, "a hosted connection asked a STUN server: " + reflexive);
			Assert.isTrue(relayed != null && relayed.indexOf("host") >= 0, "a hosted connection asked a relay: " + relayed);

			// Checks are routed by the ufrag, so two connections cannot share one.
			var credentials = IceCredentials.generate();
			host.createConnection(true, null, credentials);
			Assert.raises(() -> host.createConnection(true, null, credentials), ArgumentError, "two connections were given one ufrag");
		} catch (e:Dynamic) {
			Assert.fail("unexpected: " + Std.string(e));
		}

		host.close();
		Assert.raises(() -> host.createConnection(true), ArgumentError, "a connection was made on a closed host");
	}

	private static function pumpUntil(done:Void->Bool, timeout:Float):Void {
		var runtime = CrossByte.current();
		var deadline = haxe.Timer.stamp() + timeout;

		while (!done() && haxe.Timer.stamp() < deadline) {
			runtime.pump(1 / 60, 0);
			Sys.sleep(0.001);
		}
	}
}
