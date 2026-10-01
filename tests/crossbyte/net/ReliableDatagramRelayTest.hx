package crossbyte.net;

import crossbyte.core.CrossByte;
import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ReliableDatagramSocketConnectEvent;
import crossbyte.io.ByteArray;
import crossbyte.net.ice.IceAgent;
import crossbyte.net.ice.IceCandidate;
import crossbyte.test.Require;
import utest.Assert;

/**
	Reliable datagram sessions between two servers that can reach each other
	only through a TURN relay.

	The README offers hole punching on these sockets, and for the peers it
	cannot help -- a symmetric NAT or a carrier's CGNAT at either end -- there
	was no relay to fall back to. The auditor's attempt to wire one in needed
	two private accesses and had two steps that could not be written at all:
	the relay's answers went to the reliable decoder, and a session could only
	send straight at its peer.

	As in `PeerConnectionRelayTest`, loopback always has a path, so three
	things keep these honest. The servers bind 127.0.0.2 and 127.0.0.3, so a
	datagram one sent itself and one the relay forwarded do not share a
	source. Each is told only the other's relayed address. And the relay --
	`FakeTurnRelay` on real sockets -- forwards nothing from an address no
	permission covers, as RFC 8656 requires.
**/
@:access(crossbyte.net.ReliableDatagramServerSocket)
@:access(crossbyte.net.ReliableDatagramSocket)
class ReliableDatagramRelayTest extends utest.Test {
	private function unsupported():Bool {
		if (!ReliableDatagramServerSocket.isSupported || !TurnClient.isSupported) {
			Assert.isTrue(!ReliableDatagramServerSocket.isSupported || !TurnClient.isSupported);
			return true;
		}

		return false;
	}

	/** A session opened, and a message each way, with the relay the only path. **/
	public function testTwoServersReachEachOtherOnlyThroughARelay():Void {
		if (unsupported()) return;
		__throughTheRelay(false);
	}

	/** The same over channels: four bytes a datagram where an indication costs thirty-six. **/
	public function testTheSameOverChannels():Void {
		if (unsupported()) return;
		__throughTheRelay(true);
	}

	@:noCompletion private function __throughTheRelay(useChannels:Bool):Void {
		var relay = new FakeTurnRelaySocket();
		var alice = new ReliableDatagramServerSocket();
		var bob = new ReliableDatagramServerSocket();

		try {
			relay.start();
			alice.bind(0, "127.0.0.2");
			alice.listen();
			bob.bind(0, "127.0.0.3");
			bob.listen();

			if (!__allocate([alice, bob], relay, useChannels)) {
				Assert.fail("the relay never lent both addresses");
				__closeAll(relay, [alice, bob]);
				return;
			}

			var aliceRelayed = Require.notNull(alice.relayedCandidate);
			var bobRelayed = Require.notNull(bob.relayedCandidate);

			// Bob is dialled first, so the relay has to be told to expect Alice.
			bob.permitRelayedPeer(aliceRelayed.address);

			var accepted:ReliableDatagramSocket = null;
			var bobHeard:String = null;
			bob.addEventListener(ReliableDatagramSocketConnectEvent.CONNECT, function(e:ReliableDatagramSocketConnectEvent):Void {
				accepted = e.socket;
				accepted.addEventListener(DatagramSocketDataEvent.DATA, d -> bobHeard = textOf(d.data));
			});

			var session = alice.connectRelayed(bobRelayed.address, bobRelayed.port);
			var aliceHeard:String = null;
			session.addEventListener(DatagramSocketDataEvent.DATA, d -> aliceHeard = textOf(d.data));
			pumpUntil(() -> session.connected && accepted != null && accepted.connected, 8.0);

			Assert.isTrue(session.connected, "the session through the relay never connected");
			Require.notNull(accepted, "Bob never accepted a session through the relay");

			// Bob sees Alice as the relay does: at her relayed address.
			Assert.equals(aliceRelayed.address, accepted.remoteAddress);
			Assert.equals(aliceRelayed.port, accepted.remotePort);

			session.send(bytesOf("from Alice, twice relayed"));
			pumpUntil(() -> bobHeard != null, 5.0);
			Assert.equals("from Alice, twice relayed", bobHeard);

			accepted.send(bytesOf("and back"));
			pumpUntil(() -> aliceHeard != null, 5.0);
			Assert.equals("and back", aliceHeard);

			// It went the long way round, and the short way was never used.
			var forwarded:Int = relay.relay.count("send-relayed") + relay.relay.count("channeldata-relayed");
			Assert.isTrue(forwarded > 0, "the relay forwarded nothing");

			if (useChannels) {
				Assert.isTrue(relay.relay.count("channeldata-relayed") > 0, "a channel was asked for and never used");
			}
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		__closeAll(relay, [alice, bob]);
	}

	/**
		One side reaching the relay over TLS, as a network that lets out only
		what looks like HTTPS needs. TurnStream refused a TLS relay while a
		client Socket could not start TLS; the relay's certificate is checked
		like any other, here against the fixture's own authority.
	**/
	public function testOneSideReachesTheRelayOverTls():Void {
		if (unsupported()) return;

		var fixture = TLSTestFixture.trusted();
		if (fixture == null) {
			Assert.warn("no certificate toolchain on this machine; the TURN over TLS case did not run");
			return;
		}

		var relay = new FakeTurnRelaySocket();
		var alice = new ReliableDatagramServerSocket();
		var bob = new ReliableDatagramServerSocket();

		try {
			relay.start();
			relay.startTcp(fixture.certificate, fixture.key);
			alice.bind(0, "127.0.0.2");
			alice.listen();
			bob.bind(0, "127.0.0.3");
			bob.listen();

			var granted:Int = 0;
			var failure:String = null;
			alice.relayCertAuthority = fixture.certificate;
			alice.allocateRelay("127.0.0.1", relay.tcpPort, "user", "secret", false, TLS).then(_ -> granted++, e -> failure = Std.string(e));
			bob.allocateRelay("127.0.0.1", relay.port, "user", "secret").then(_ -> granted++, _ -> {});
			pumpUntil(() -> granted == 2 || failure != null, 8.0);

			if (granted != 2) {
				Assert.fail("the relay never lent both addresses: " + failure);
				__closeAll(relay, [alice, bob]);
				return;
			}

			bob.permitRelayedPeer(alice.relayedCandidate.address);

			var accepted:ReliableDatagramSocket = null;
			var heard:String = null;
			bob.addEventListener(ReliableDatagramSocketConnectEvent.CONNECT, function(e:ReliableDatagramSocketConnectEvent):Void {
				accepted = e.socket;
				accepted.addEventListener(DatagramSocketDataEvent.DATA, d -> heard = textOf(d.data));
			});

			var session = alice.connectRelayed(bob.relayedCandidate.address, bob.relayedCandidate.port);
			pumpUntil(() -> session.connected && accepted != null, 8.0);
			Assert.isTrue(session.connected, "the session from the side on TLS never connected");

			session.send(bytesOf("down a TLS connection and out as UDP"));
			pumpUntil(() -> heard != null, 5.0);
			Assert.equals("down a TLS connection and out as UDP", heard);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		__closeAll(relay, [alice, bob]);
	}

	/** A relay whose certificate chains to nothing trusted is refused, not used. **/
	public function testARelayOverTlsIsRefusedAnUntrustedCertificate():Void {
		if (unsupported()) return;

		var fixture = TLSTestFixture.trusted();
		if (fixture == null) {
			Assert.warn("no certificate toolchain on this machine; the TURN over TLS case did not run");
			return;
		}

		var relay = new FakeTurnRelaySocket();
		var alice = new ReliableDatagramServerSocket();

		try {
			relay.start();
			relay.startTcp(fixture.certificate, fixture.key);
			alice.bind(0, "127.0.0.2");
			alice.listen();

			var granted:Bool = false;
			var failure:String = null;
			alice.allocateRelay("127.0.0.1", relay.tcpPort, "user", "secret", false, TLS).then(_ -> granted = true, e -> failure = Std.string(e));
			pumpUntil(() -> granted || failure != null, 8.0);

			Assert.isFalse(granted, "a relay presenting an untrusted certificate lent an address");
			Assert.notNull(failure, "the allocation neither succeeded nor failed");
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		__closeAll(relay, [alice]);
	}

	/**
		The same relay is used once the server is told not to check its
		certificate, as a test against a throwaway one needs. The server let
		an authority through to its relay client and not `verifyCert`, so a
		relay like this could be reached only by naming its authority.
	**/
	public function testARelayOverTlsCanBeReachedWithItsCertificateUnchecked():Void {
		if (unsupported()) return;

		var fixture = TLSTestFixture.trusted();
		if (fixture == null) {
			Assert.warn("no certificate toolchain on this machine; the TURN over TLS case did not run");
			return;
		}

		var relay = new FakeTurnRelaySocket();
		var alice = new ReliableDatagramServerSocket();

		try {
			relay.start();
			relay.startTcp(fixture.certificate, fixture.key);
			alice.bind(0, "127.0.0.2");
			alice.listen();

			var granted:Bool = false;
			var failure:String = null;
			Assert.isTrue(alice.relayVerifyCert, "a relay's certificate was not checked by default");
			alice.relayVerifyCert = false;
			alice.allocateRelay("127.0.0.1", relay.tcpPort, "user", "secret", false, TLS).then(_ -> granted = true, e -> failure = Std.string(e));
			pumpUntil(() -> granted || failure != null, 8.0);

			Assert.isTrue(granted, "a relay whose certificate was not to be checked was refused: " + failure);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		__closeAll(relay, [alice]);
	}

	/**
		The same with one server reaching the relay over TCP, as one behind a
		network that lets nothing else out would: what the relay relays is UDP
		either way, and the session does not know the difference.
	**/
	public function testOneSideReachesTheRelayOverTcp():Void {
		if (unsupported()) return;

		var relay = new FakeTurnRelaySocket();
		var alice = new ReliableDatagramServerSocket();
		var bob = new ReliableDatagramServerSocket();

		try {
			relay.start();
			relay.startTcp();
			alice.bind(0, "127.0.0.2");
			alice.listen();
			bob.bind(0, "127.0.0.3");
			bob.listen();

			var granted:Int = 0;
			alice.allocateRelay("127.0.0.1", relay.tcpPort, "user", "secret", false, TCP).then(_ -> granted++, _ -> {});
			bob.allocateRelay("127.0.0.1", relay.port, "user", "secret").then(_ -> granted++, _ -> {});
			pumpUntil(() -> granted == 2, 8.0);

			if (granted != 2) {
				Assert.fail("the relay never lent both addresses");
				__closeAll(relay, [alice, bob]);
				return;
			}

			bob.permitRelayedPeer(alice.relayedCandidate.address);

			var accepted:ReliableDatagramSocket = null;
			var heard:String = null;
			bob.addEventListener(ReliableDatagramSocketConnectEvent.CONNECT, function(e:ReliableDatagramSocketConnectEvent):Void {
				accepted = e.socket;
				accepted.addEventListener(DatagramSocketDataEvent.DATA, d -> heard = textOf(d.data));
			});

			var session = alice.connectRelayed(bob.relayedCandidate.address, bob.relayedCandidate.port);
			pumpUntil(() -> session.connected && accepted != null, 8.0);
			Assert.isTrue(session.connected, "the session from the side on TCP never connected");

			session.send(bytesOf("down a TCP connection and out as UDP"));
			pumpUntil(() -> heard != null, 5.0);
			Assert.equals("down a TCP connection and out as UDP", heard);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		__closeAll(relay, [alice, bob]);
	}

	/**
		A relay that loses the allocation ends the sessions that ran through
		it, each saying why, rather than leaving them sending into nothing
		until their timeout.
	**/
	public function testLosingTheRelayEndsTheSessionsThroughIt():Void {
		if (unsupported()) return;

		var relay = new FakeTurnRelaySocket();
		var alice = new ReliableDatagramServerSocket();
		var bob = new ReliableDatagramServerSocket();

		try {
			relay.start();
			alice.bind(0, "127.0.0.2");
			alice.listen();
			bob.bind(0, "127.0.0.3");
			bob.listen();

			if (!__allocate([alice, bob], relay, false)) {
				Assert.fail("the relay never lent both addresses");
				__closeAll(relay, [alice, bob]);
				return;
			}

			bob.permitRelayedPeer(alice.relayedCandidate.address);

			var session = alice.connectRelayed(bob.relayedCandidate.address, bob.relayedCandidate.port);
			pumpUntil(() -> session.connected, 8.0);

			if (!session.connected) {
				Assert.fail("the session through the relay never connected");
				__closeAll(relay, [alice, bob]);
				return;
			}

			var errors:Array<String> = [];
			var closed:Bool = false;
			session.addEventListener(IOErrorEvent.IO_ERROR, e -> errors.push(e.text));
			session.addEventListener(Event.CLOSE, _ -> closed = true);

			// The relay restarts and forgets every allocation; Alice's next
			// refresh finds out, brought forward to now.
			relay.relay.forgetEverything();
			alice.relay.refresh(haxe.Timer.stamp());
			pumpUntil(() -> closed, 5.0);

			Assert.isTrue(closed, "a session whose relay went away stayed open");
			Assert.isNull(alice.relay, "the lost relay is still attached");
			Assert.equals(1, errors.length);

			if (errors.length > 0) {
				Assert.isTrue(errors[0].indexOf("relay") >= 0, "the error should say the relay went: " + errors[0]);
			}
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		__closeAll(relay, [alice, bob]);
	}

	/**
		An attached agent does not take the relay's answers, and checks from
		the relayed candidate the relay lends.

		The agent took every STUN message on the socket, a relay's answers
		included, so on a server with one attached no allocation could complete.
	**/
	public function testAnAttachedAgentLeavesTheRelayItsAnswers():Void {
		if (unsupported()) return;

		var relay = new FakeTurnRelaySocket();
		var server = new ReliableDatagramServerSocket();
		var agent = new IceAgent(true);

		try {
			relay.start();
			server.bind(0, "127.0.0.2");
			server.listen();
			server.attachIceAgent(agent);

			if (!__allocate([server], relay, false)) {
				Assert.fail("an attached agent kept the relay from ever allocating");
				__closeAll(relay, [server]);
				return;
			}

			var relayed = Require.notNull(server.relayedCandidate);
			var locals:Array<IceCandidate> = @:privateAccess agent.__locals;
			var checksFromIt:Bool = false;

			for (local in locals) {
				if (local.sameAs(relayed)) {
					checksFromIt = true;
				}
			}

			Assert.isTrue(checksFromIt, "the agent was not given the relayed candidate");
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		agent.close();
		__closeAll(relay, [server]);
	}

	/**
		A datagram the application routes itself goes no further, and can be
		answered from the same port.
	**/
	public function testTheApplicationCanTakeItsOwnDatagrams():Void {
		if (unsupported()) return;

		var server = new ReliableDatagramServerSocket();
		var probe = new DatagramSocket();
		var answer:String = null;
		var sessions:Int = 0;

		try {
			server.bind(0, "127.0.0.1");
			server.listen();
			server.addEventListener(ReliableDatagramSocketConnectEvent.CONNECT, _ -> sessions++);

			server.onDatagram = function(data:ByteArray, address:String, port:Int):Bool {
				if (textOf(data) != "PING") {
					return false;
				}

				var pong = bytesOf("PONG");
				server.sendDatagram(pong, 0, pong.length, address, port);
				return true;
			};

			probe.bind(0, "127.0.0.1");
			probe.addEventListener(DatagramSocketDataEvent.DATA, e -> answer = textOf(e.data));
			probe.receive();

			var ping = bytesOf("PING");
			probe.send(ping, 0, ping.length, "127.0.0.1", server.localPort);
			pumpUntil(() -> answer != null, 3.0);

			Assert.equals("PONG", answer, "the hook never saw the datagram, or could not answer it");

			// And what it passes on still reaches the sessions.
			var client = new ReliableDatagramSocket();
			client.connect("127.0.0.1", server.localPort);
			pumpUntil(() -> sessions > 0, 5.0);
			Assert.equals(1, sessions, "a datagram the hook passed on never reached the sessions");
			client.close();
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try {
			probe.close();
		} catch (_:Dynamic) {}

		try {
			server.close();
		} catch (_:Dynamic) {}
	}

	/**
		A reliable datagram `NetHost` reaches peers through a relay too, and a
		stream host says it cannot.
	**/
	public function testANetHostDialsThroughARelay():Void {
		if (unsupported()) return;

		var relay = new FakeTurnRelaySocket();
		var alice = new ReliableDatagramServerSocket();
		var bob = new ReliableDatagramServerSocket();

		try {
			relay.start();
			alice.bind(0, "127.0.0.2");
			alice.listen();
			bob.bind(0, "127.0.0.3");
			bob.listen();

			var aliceHost:NetHost = NetHost.fromReliableDatagramServerSocket(alice);
			var bobHost:NetHost = NetHost.fromReliableDatagramServerSocket(bob);
			var accepted:INetConnection = null;
			bobHost.onAccept = connection -> accepted = connection;
			bobHost.listen();

			var granted:Int = 0;
			aliceHost.allocateRelay("127.0.0.1", relay.port, "user", "secret").then(_ -> granted++, _ -> {});
			bobHost.allocateRelay("127.0.0.1", relay.port, "user", "secret").then(_ -> granted++, _ -> {});
			pumpUntil(() -> granted == 2, 8.0);
			Assert.equals(2, granted, "the relay never lent both addresses");

			if (granted == 2) {
				bobHost.permitRelayedPeer(alice.relayedCandidate.address);
				aliceHost.dialRelayed(bob.relayedCandidate.address, bob.relayedCandidate.port);
				pumpUntil(() -> accepted != null, 8.0);
				Assert.notNull(accepted, "the session dialled through the relay never arrived");
			}
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		// A stream host says it through the Future, as every NetHost method
		// that returns one does, and does not throw.
		var tcp:NetHost = NetHost.fromServerSocket(new ServerSocket());
		var refused = tcp.allocateRelay("127.0.0.1", relay.port, "user", "secret");
		Assert.isTrue(refused.completed && !refused.succeeded, "a stream host's relay allocation did not fail at once");
		Assert.isTrue(Std.isOfType(refused.cause, crossbyte.errors.IllegalOperationError), "the failure was not an IllegalOperationError: "
			+ Std.string(refused.cause));

		__closeAll(relay, [alice, bob]);
	}

	// ------------------------------------------------------------------

	/** Asks the relay for an address for each server, and waits for them all. **/
	@:noCompletion private static function __allocate(servers:Array<ReliableDatagramServerSocket>, relay:FakeTurnRelaySocket, useChannels:Bool):Bool {
		var granted:Int = 0;

		for (server in servers) {
			server.allocateRelay("127.0.0.1", relay.port, "user", "secret", useChannels).then(_ -> granted++, _ -> {});
		}

		pumpUntil(() -> granted == servers.length, 8.0);
		return granted == servers.length;
	}

	@:noCompletion private static function __closeAll(relay:FakeTurnRelaySocket, servers:Array<ReliableDatagramServerSocket>):Void {
		for (server in servers) {
			try {
				server.close();
			} catch (_:Dynamic) {}
		}

		// A turn for the goodbyes to leave before the relay stops listening.
		pumpUntil(() -> false, 0.1);
		relay.close();
	}

	private static function textOf(bytes:ByteArray):String {
		if (bytes == null) {
			return null;
		}

		var at:Int = bytes.position;
		bytes.position = 0;
		var text:String = bytes.readUTFBytes(bytes.length);
		bytes.position = at;
		return text;
	}

	private static function bytesOf(value:String):ByteArray {
		var bytes = new ByteArray();
		bytes.writeUTFBytes(value);
		bytes.position = 0;
		return bytes;
	}

	private static function pumpUntil(done:Void->Bool, timeout:Float):Void {
		var runtime = CrossByte.current();
		var deadline = Sys.time() + timeout;

		while (!done() && Sys.time() < deadline) {
			runtime.pump(1 / 60, 0);
			crossbyte.sys.System.sleep(0.001);
		}
	}
}
