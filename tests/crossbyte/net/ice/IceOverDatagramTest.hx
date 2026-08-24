package crossbyte.net.ice;

import crossbyte.core.CrossByte;
import crossbyte.errors.ArgumentError;
import crossbyte.errors.IOError;
import crossbyte.events.ProgressEvent;
import crossbyte.io.ByteArray;
import crossbyte.net.ReliableDatagramServerSocket;
import crossbyte.net.ReliableDatagramSocket;
import crossbyte.net.ReliableDatagramSocketMode;
import utest.Assert;

/**
	ICE over real sockets, and then a session over what it found.

	`IceAgentTest` proves the exchange with no network in the way, which is the
	right place to test the protocol. This tests the join: that checks actually
	leave the socket the server listens on, arrive, get routed to the agent
	rather than dropped as noise, and -- the part most likely to break -- that
	the reliable session afterwards still works on the same socket, because the
	agent did not swallow frames that were never its business.

	Loopback has no NAT, so nothing here is punched through anything. That is
	deliberate: what is under test is the plumbing, and the protocol has already
	been tested where a fake network could be made to misbehave on demand.
**/
class IceOverDatagramTest extends utest.Test {
	private static function credentials(name:String):IceCredentials {
		return new IceCredentials(name + "frag", name + "-password-padded-to-length");
	}

	private function unavailable():Bool {
		if (!ReliableDatagramSocket.isSupported || !IceAgent.isSupported) {
			Assert.isTrue(true);
			return true;
		}

		return false;
	}

	/**
		The whole path, end to end.

		Two servers, each listening on its own port with an agent attached to
		the socket it listens on. They exchange candidates the way an
		application would, run the checks, agree on a pair -- and then a
		reliable session is dialled over that pair and carries a message.
	**/
	public function testTwoServersNegotiateAPathAndThenUseIt():Void {
		if (unavailable()) return;

		var alice = new ReliableDatagramServerSocket();
		var bob = new ReliableDatagramServerSocket();
		var session:ReliableDatagramSocket = null;
		var delivered:String = null;

		try {
			alice.socketMode = ReliableDatagramSocketMode.STREAM;
			bob.socketMode = ReliableDatagramSocketMode.STREAM;
			alice.bind(0, "127.0.0.1");
			alice.listen();
			bob.bind(0, "127.0.0.1");
			bob.listen();

			// Registered before anything is dialled: an accept that lands before
			// the listener exists is an accept nobody sees.
			bob.addEventListener(crossbyte.events.ReliableDatagramSocketConnectEvent.CONNECT, function(e):Void {
				var accepted:ReliableDatagramSocket = e.socket;
				accepted.addEventListener(ProgressEvent.SOCKET_DATA, function(_):Void {
					if (accepted.bytesAvailable > 0) {
						delivered = accepted.readUTFBytes(accepted.bytesAvailable);
					}
				});
			});

			var aliceAgent = new IceAgent(true, credentials("alice"));
			var bobAgent = new IceAgent(false, credentials("bob"));

			alice.attachIceAgent(aliceAgent);
			bob.attachIceAgent(bobAgent);

			// What an application would exchange over whatever channel already
			// brought the two peers together. Here both are on loopback, so the
			// host candidate is the whole list.
			aliceAgent.addLocalCandidate(IceCandidate.host("127.0.0.1", alice.localPort));
			bobAgent.addLocalCandidate(IceCandidate.host("127.0.0.1", bob.localPort));
			aliceAgent.addRemoteCandidate(IceCandidate.host("127.0.0.1", bob.localPort));
			bobAgent.addRemoteCandidate(IceCandidate.host("127.0.0.1", alice.localPort));

			aliceAgent.start(bobAgent.localCredentials, Sys.time());
			bobAgent.start(aliceAgent.localCredentials, Sys.time());

			pumpUntil(() -> aliceAgent.state == IceAgentState.CONNECTED && bobAgent.state == IceAgentState.CONNECTED, 8.0);

			Assert.equals(IceAgentState.CONNECTED, aliceAgent.state, "the controlling agent never connected over real sockets");
			Assert.equals(IceAgentState.CONNECTED, bobAgent.state, "the controlled agent never connected over real sockets");

			if (aliceAgent.selectedPair == null) {
				Assert.fail("connected without a selected pair");
				return;
			}

			Assert.equals(bob.localPort, aliceAgent.selectedPair.remote.port, "the path found does not lead to the other server");

			// And now the point of all of it: a session over the pair ICE
			// chose, dialled from the port the checks were sent from, which is
			// the mapping that was just proved to work.
			session = alice.connect(aliceAgent.selectedPair.remote.address, aliceAgent.selectedPair.remote.port);

			pumpUntil(() -> session.connected, 5.0);
			Assert.isTrue(session.connected, "the negotiated path would not carry a session");

			var payload = new ByteArray();
			payload.writeUTFBytes("over the path ICE found");
			session.writeBytes(payload, 0, payload.length);
			session.flush();

			pumpUntil(() -> delivered != null, 5.0);
			Assert.equals("over the path ICE found", delivered, "the session ICE negotiated could not carry data");
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		closeQuietly(session);
		closeServerQuietly(alice);
		closeServerQuietly(bob);
	}

	/**
		Traffic that is not a check still reaches the session.

		The agent sits in front of the reliable decode, so an agent that
		consumed everything would break the connection it had just finished
		establishing. This drives an ordinary session with an agent attached and
		never started -- so the agent is in the path and has nothing to do.
	**/
	public function testAnAttachedAgentDoesNotSwallowOrdinaryTraffic():Void {
		if (unavailable()) return;

		var server = new ReliableDatagramServerSocket();
		var client = new ReliableDatagramSocket();
		var delivered:String = null;

		try {
			server.socketMode = ReliableDatagramSocketMode.STREAM;
			server.bind(0, "127.0.0.1");
			server.listen();
			server.attachIceAgent(new IceAgent(true, credentials("alice")));

			server.addEventListener(crossbyte.events.ReliableDatagramSocketConnectEvent.CONNECT, function(e):Void {
				var accepted:ReliableDatagramSocket = e.socket;
				accepted.addEventListener(ProgressEvent.SOCKET_DATA, function(_):Void {
					if (accepted.bytesAvailable > 0) {
						delivered = accepted.readUTFBytes(accepted.bytesAvailable);
					}
				});
			});

			client.mode = ReliableDatagramSocketMode.STREAM;
			client.connect("127.0.0.1", server.localPort);
			pumpUntil(() -> client.connected, 5.0);
			Assert.isTrue(client.connected);

			var payload = new ByteArray();
			payload.writeUTFBytes("not a binding request");
			client.writeBytes(payload, 0, payload.length);
			client.flush();

			pumpUntil(() -> delivered != null, 5.0);
			Assert.equals("not a binding request", delivered, "an attached agent swallowed traffic that was not its own");
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		closeQuietly(client);
		closeServerQuietly(server);
	}

	/**
		Two agents on one socket would answer each other's checks.

		Refused rather than allowed to produce a session that appears to work
		and is being negotiated by something the caller has forgotten about.
	**/
	public function testASecondAgentIsRefused():Void {
		if (unavailable()) return;

		var server = new ReliableDatagramServerSocket();

		try {
			server.bind(0, "127.0.0.1");
			server.listen();
			server.attachIceAgent(new IceAgent(true, credentials("alice")));

			var refused = false;

			try {
				server.attachIceAgent(new IceAgent(false, credentials("bob")));
			} catch (_:ArgumentError) {
				refused = true;
			}

			Assert.isTrue(refused, "a second agent was attached to a socket that already had one");

			// And detaching makes room again, so this is a rule about how many
			// rather than a socket that can only ever have one.
			server.detachIceAgent();
			server.attachIceAgent(new IceAgent(false, credentials("bob")));
			Assert.isTrue(true);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		closeServerQuietly(server);
	}

	/**
		Nothing to send from, nothing to attach to.

		A socket that is not listening has no port a peer could be told about,
		so an agent on it would be checking paths to an endpoint that does not
		exist yet.
	**/
	public function testAnAgentNeedsAListeningSocket():Void {
		if (unavailable()) return;

		var server = new ReliableDatagramServerSocket();
		var refused = false;

		try {
			// Bound but never listening.
			server.bind(0, "127.0.0.1");
			server.attachIceAgent(new IceAgent(true, credentials("alice")));
		} catch (_:IOError) {
			refused = true;
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		Assert.isTrue(refused, "an agent was attached to a socket that was not listening");
		closeServerQuietly(server);
	}

	private static function pumpUntil(done:Void->Bool, timeout:Float):Void {
		var runtime = CrossByte.current();
		var deadline = Sys.time() + timeout;

		while (!done() && Sys.time() < deadline) {
			runtime.pump(1 / 60, 0);
			Sys.sleep(0.001);
		}
	}

	private static function closeQuietly(socket:ReliableDatagramSocket):Void {
		try {
			if (socket != null) {
				socket.close();
			}
		} catch (_:Dynamic) {}
	}

	private static function closeServerQuietly(server:ReliableDatagramServerSocket):Void {
		try {
			if (server != null) {
				server.close();
			}
		} catch (_:Dynamic) {}
	}
}
