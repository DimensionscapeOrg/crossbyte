package crossbyte.net;

import crossbyte.core.CrossByte;
import crossbyte.errors.IOError;
import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ProgressEvent;
import crossbyte.events.ReliableDatagramSocketConnectEvent;
import crossbyte.io.ByteArray;
import utest.Assert;
import crossbyte.test.Require;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol.ReliableDatagramFrame;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol.ReliableDatagramFrameType;

@:access(crossbyte.net.ReliableDatagramServerSocket)
@:access(crossbyte.net.ReliableDatagramSocket)
class ReliableDatagramSocketTest extends utest.Test {
	public function testAServerLearnsWhereItIsReachable():Void {
		if (!requireDatagramSupport()) return;

		// A STUN server of our own, so this needs no network and no third
		// party. It answers the binding request with an address of its
		// choosing, which is what a real one does -- the point is that the
		// reply is picked out of ordinary inbound traffic on a socket already
		// carrying reliable sessions, and matched to the request that asked.
		var stun = new crossbyte.net.DatagramSocket();
		var sawRequest = false;

		stun.addEventListener(crossbyte.events.DatagramSocketDataEvent.DATA, function(e:crossbyte.events.DatagramSocketDataEvent):Void {
			var request = crossbyte.net._internal.stun.StunMessage.decode(e.data);

			if (request == null || request.type != crossbyte.net._internal.stun.StunMessage.BINDING_REQUEST) {
				return;
			}

			sawRequest = true;

			var reply = new crossbyte.net._internal.stun.StunMessage(crossbyte.net._internal.stun.StunMessage.BINDING_SUCCESS, request.transactionId,
				[crossbyte.net._internal.stun.StunMessage.xorMappedAddress("198.51.100.23", 61000)]);

			var payload = reply.encode();
			stun.send(payload, 0, payload.length, e.srcAddress, e.srcPort);
		});

		var server = new ReliableDatagramServerSocket();
		var discovered:Dynamic = null;
		var failure:String = null;

		try {
			stun.bind(0, "127.0.0.1");
			stun.receive();

			server.bind(0, "127.0.0.1");
			server.listen();

			server.discoverPublicAddress("127.0.0.1", stun.localPort, 3000)
				.then(function(address):Void {
					discovered = address;
				}, function(error:String):Void {
					failure = error;
				});

			pumpUntil(() -> discovered != null || failure != null, 4.0);

			Assert.isTrue(sawRequest, "the binding request never reached the server");
			Assert.isNull(failure, "discovery failed: " + failure);
			// Guarded, not just asserted. utest records a failed assertion and
			// carries on, so on a timeout `discovered` is still null when the
			// next line reads a field off it -- and a null field access on
			// hxcpp release is a SIGSEGV, not a catchable error, so the whole
			// process dies and takes the run's results with it.
			Assert.notNull(discovered, "no reflexive address was reported");

			if (discovered != null) {
				Assert.equals("198.51.100.23", discovered.address);
				Assert.equals(61000, discovered.port);
			}
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try server.close() catch (_:Dynamic) {}
		try stun.close() catch (_:Dynamic) {}
	}

	/**
		A lost binding request is asked again.

		The listening port's public address is what every peer is told to dial,
		and the question asking for it goes out over UDP like anything else. Sent
		once, a single dropped datagram loses the whole query and is reported as
		a server that is not there -- which sends whoever reads it looking at
		their configuration for a fault that is not in it.
	**/
	public function testADroppedBindingRequestIsAskedAgain():Void {
		if (!ReliableDatagramSocket.isSupported) {
			Assert.isFalse(ReliableDatagramSocket.isSupported);
			return;
		}

		var stun = new DatagramSocket();
		var requests = 0;

		stun.addEventListener(DatagramSocketDataEvent.DATA, function(e:DatagramSocketDataEvent):Void {
			var request = crossbyte.net._internal.stun.StunMessage.decode(e.data);

			if (request == null) {
				return;
			}

			requests++;

			// Two on the floor, so an answer can only come from a third request
			// that something chose to send.
			if (requests <= 2) {
				return;
			}

			var reply = new crossbyte.net._internal.stun.StunMessage(crossbyte.net._internal.stun.StunMessage.BINDING_SUCCESS,
				request.transactionId, [crossbyte.net._internal.stun.StunMessage.xorMappedAddress("198.51.100.77", 62000)]);

			var payload = reply.encode();
			stun.send(payload, 0, payload.length, e.srcAddress, e.srcPort);
		});

		var server = new ReliableDatagramServerSocket();
		var discovered:Dynamic = null;
		var failure:String = null;

		try {
			stun.bind(0, "127.0.0.1");
			stun.receive();

			server.bind(0, "127.0.0.1");
			server.listen();

			server.discoverPublicAddress("127.0.0.1", stun.localPort, 9000)
				.then(function(address):Void {
					discovered = address;
				}, function(error:String):Void {
					failure = error;
				});

			pumpUntil(() -> discovered != null || failure != null, 11.0);

			Assert.isNull(failure, "two dropped requests ended the query: " + failure);
			Assert.notNull(discovered, "nothing asked again after a dropped request");
			Assert.isTrue(requests >= 3, "expected the request to be repeated, saw " + requests);

			if (discovered != null) {
				Assert.equals("198.51.100.77", discovered.address);
			}
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try server.close() catch (_:Dynamic) {}
		try stun.close() catch (_:Dynamic) {}
	}

	public function testAForgedReplyIsIgnored():Void {
		if (!requireDatagramSupport()) return;

		// The reply carries somebody else's transaction. A datagram socket
		// accepts from anyone, so without the check this would be believed --
		// and a peer that believes it publishes an address of the sender's
		// choosing to every other peer in the mesh.
		var liar = new crossbyte.net.DatagramSocket();

		liar.addEventListener(crossbyte.events.DatagramSocketDataEvent.DATA, function(e:crossbyte.events.DatagramSocketDataEvent):Void {
			var wrong = new ByteArray();
			for (i in 0...12) {
				wrong.writeByte(0xE0 + i);
			}
			wrong.position = 0;

			var reply = new crossbyte.net._internal.stun.StunMessage(crossbyte.net._internal.stun.StunMessage.BINDING_SUCCESS, wrong,
				[crossbyte.net._internal.stun.StunMessage.xorMappedAddress("203.0.113.66", 1234)]);

			var payload = reply.encode();
			liar.send(payload, 0, payload.length, e.srcAddress, e.srcPort);
		});

		var server = new ReliableDatagramServerSocket();
		var discovered:Dynamic = null;
		var failure:String = null;

		try {
			liar.bind(0, "127.0.0.1");
			liar.receive();

			server.bind(0, "127.0.0.1");
			server.listen();

			server.discoverPublicAddress("127.0.0.1", liar.localPort, 1000)
				.then(function(address):Void {
					discovered = address;
				}, function(error:String):Void {
					failure = error;
				});

			pumpUntil(() -> discovered != null || failure != null, 3.0);

			Assert.isNull(discovered, "an address from a mismatched transaction was accepted");
			Assert.notNull(failure, "the query neither succeeded nor timed out");
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try server.close() catch (_:Dynamic) {}
		try liar.close() catch (_:Dynamic) {}
	}

	public function testDiscoveryRefusesWhatItCannotDo():Void {
		if (!requireDatagramSupport()) return;

		var server = new ReliableDatagramServerSocket();
		var beforeListening:String = null;

		// Unbound: there is no port to ask about.
		server.discoverPublicAddress("127.0.0.1", 3478, 500).catchError(message -> beforeListening = message);
		Assert.notNull(beforeListening, "discovery was attempted from an unbound server");

		try {
			server.bind(0, "127.0.0.1");
			server.listen();

			var second:String = null;
			server.discoverPublicAddress("127.0.0.1", 65530, 2000);
			// Two outstanding queries would race for one reply.
			server.discoverPublicAddress("127.0.0.1", 65530, 2000).catchError(message -> second = message);

			Assert.notNull(second, "a second concurrent query was accepted");
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try server.close() catch (_:Dynamic) {}
	}

	public function testTwoServersDiallingEachOtherBothConnect():Void {
		if (!requireDatagramSupport()) return;

		// Simultaneous open, which is what hole punching is made of. Each peer
		// dials the other's reflexive address from the port it listens on; the
		// outbound datagram opens that peer's own NAT mapping, so the other
		// side's arrives at something willing to receive it. Neither peer is
		// the server in the usual sense -- both dial, both are dialled.
		//
		// There is no NAT on loopback, so what this proves is the half that
		// lives in CrossByte: that two sessions opened toward each other over
		// one socket apiece complete rather than colliding. The retransmit in
		// __beginHandshake is what covers the skew between them, and a peer
		// that dialled first must accept the other's CONNECT arriving at a
		// session it has already created.
		var alice = new ReliableDatagramServerSocket();
		var bob = new ReliableDatagramServerSocket();
		var delivered:String = null;

		try {
			alice.socketMode = ReliableDatagramSocketMode.STREAM;
			bob.socketMode = ReliableDatagramSocketMode.STREAM;
			alice.bind(0, "127.0.0.1");
			alice.listen();
			bob.bind(0, "127.0.0.1");
			bob.listen();

			// Both, before either has heard anything. Dialling one after the
			// other completes would be an ordinary client and server and would
			// prove nothing about the case that matters.
			var toBob = alice.connect("127.0.0.1", bob.localPort);
			var toAlice = bob.connect("127.0.0.1", alice.localPort);

			pumpUntil(() -> toBob.connected && toAlice.connected, 5.0);

			Assert.isTrue(toBob.connected, "alice's session to bob never completed");
			Assert.isTrue(toAlice.connected, "bob's session to alice never completed");

			// Each still sees the other arriving from its listening port, which
			// is the property that makes the mapping reusable.
			Assert.equals(bob.localPort, toBob.remotePort);
			Assert.equals(alice.localPort, toAlice.remotePort);

			toAlice.addEventListener(ProgressEvent.SOCKET_DATA, _ -> {
				if (toAlice.bytesAvailable > 0) {
					delivered = toAlice.readUTFBytes(toAlice.bytesAvailable);
				}
			});

			var payload = new ByteArray();
			payload.writeUTFBytes("punched through");
			toBob.writeBytes(payload, 0, payload.length);
			toBob.flush();

			pumpUntil(() -> delivered != null, 3.0);
			Assert.equals("punched through", delivered, "the punched session could not carry data");
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try alice.close() catch (_:Dynamic) {}
		try bob.close() catch (_:Dynamic) {}
	}

	public function testTwoPeersThatDialEachOtherFallQuietOnceConnected():Void {
		if (!requireDatagramSupport()) return;

		// Both dial, so both answer. Every HANDSHAKE was answered with one, so
		// each answer drew the next: two connected peers with nothing to say
		// passed some forty thousand datagrams a second between them over
		// loopback, for as long as they stayed connected.
		var alice = new ReliableDatagramServerSocket();
		var bob = new ReliableDatagramServerSocket();
		var datagrams = 0;

		try {
			alice.bind(0, "127.0.0.1");
			alice.listen();
			bob.bind(0, "127.0.0.1");
			bob.listen();
			alice.__socket.addEventListener(DatagramSocketDataEvent.DATA, _ -> datagrams++);
			bob.__socket.addEventListener(DatagramSocketDataEvent.DATA, _ -> datagrams++);

			var toBob = alice.connect("127.0.0.1", bob.localPort);
			var toAlice = bob.connect("127.0.0.1", alice.localPort);
			pumpUntil(() -> toBob.connected && toAlice.connected, 5.0);
			Assert.isTrue(toBob.connected && toAlice.connected, "the peers never connected");

			// Whatever answers were already on their way arrive; then nothing.
			pumpUntil(() -> false, 0.2);
			var settled = datagrams;
			pumpUntil(() -> false, 0.5);
			Assert.equals(settled, datagrams, 'peers with nothing to say passed ${datagrams - settled} datagrams in half a second');
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		closeServerQuietly(alice);
		closeServerQuietly(bob);
	}

	public function testASessionWhoseAnswerToTheHandshakeWasLostStillConnects():Void {
		if (!requireDatagramSupport()) return;

		// The client's HANDSHAKE, answering the server's, is the last of the
		// three, and a server sends its own only when asked. Lost, it left
		// the client connected and sending and the server not, dropping all
		// of it, until the server's session timed out.
		var server = new ReliableDatagramServerSocket();
		var client = new AnswerLosingSocket();
		var accepted:ReliableDatagramSocket = null;
		var received:String = null;

		try {
			server.bind(0, "127.0.0.1");
			server.addEventListener(ReliableDatagramSocketConnectEvent.CONNECT, e -> {
				accepted = e.socket;
				accepted.addEventListener(DatagramSocketDataEvent.DATA, d -> received = textOf(d.data));
			});
			server.listen();
			client.addEventListener(Event.CONNECT, _ -> client.send(bytesOf("first words")));
			client.connect("127.0.0.1", server.localPort);

			pumpUntil(() -> received != null, 5.0);
			Assert.equals(1, client.lost, "nothing was lost, so nothing was tested");
			Assert.notNull(accepted, "the server never connected");
			Assert.equals("first words", received);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		closeQuietly(client);
		closeServerQuietly(server);
	}

	public function testASilentClientWhoseAnswerToTheHandshakeWasLostStillConnects():Void {
		if (!requireDatagramSupport()) return;

		// A client that waits for the server to speak first sends nothing
		// that would make the server ask again, so the client sends its
		// HANDSHAKE again itself, on the connection attempt interval, until
		// the server shows it arrived.
		var server = new ReliableDatagramServerSocket();
		var client = new AnswerLosingSocket();
		var accepted:ReliableDatagramSocket = null;

		try {
			server.bind(0, "127.0.0.1");
			server.addEventListener(ReliableDatagramSocketConnectEvent.CONNECT, e -> accepted = e.socket);
			server.listen();
			client.connect("127.0.0.1", server.localPort);

			pumpUntil(() -> accepted != null, ReliableDatagramSocket.CONNECTION_ATTEMPT_INTERVAL + 2.0);
			Assert.equals(1, client.lost, "nothing was lost, so nothing was tested");
			Assert.notNull(accepted, "the server never connected");
			pumpUntil(() -> client.__peerConfirmed, 1.0);
			Assert.isTrue(client.__peerConfirmed, "the client never heard that its HANDSHAKE arrived");
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		closeQuietly(client);
		closeServerQuietly(server);
	}

	public function testAServerGivesEachSessionThePolicyItsHookReturns():Void {
		if (!requireDatagramSupport()) return;

		var server = new ReliableDatagramServerSocket();
		var peer = new ReliableDatagramServerSocket();
		var client = new ReliableDatagramSocket();
		var accepted:ReliableDatagramSocket = null;
		var asked:Array<Int> = [];

		try {
			server.bind(0, "127.0.0.1");
			server.congestionControlFor = (address, port) -> {
				asked.push(port);
				return new LossTolerantCongestionControl();
			};
			server.addEventListener(ReliableDatagramSocketConnectEvent.CONNECT, e -> accepted = e.socket);
			server.listen();
			peer.bind(0, "127.0.0.1");
			peer.listen();

			// One session accepted, one dialled: both are the server's to make.
			client.connect("127.0.0.1", server.localPort);
			var dialled = server.connect("127.0.0.1", peer.localPort);
			pumpUntil(() -> accepted != null && dialled.connected, 5.0);

			Require.notNull(accepted, "the server never accepted the client");
			Assert.isTrue(Std.isOfType(accepted.congestionControl, LossTolerantCongestionControl), "an accepted session did not get the hook's policy");
			Assert.isTrue(Std.isOfType(dialled.congestionControl, LossTolerantCongestionControl), "a dialled session did not get the hook's policy");
			Assert.equals(2, asked.length, "the hook was not asked once a session");
			Assert.isTrue(asked.indexOf(peer.localPort) >= 0, "the hook was not told who a dialled session is to");

			// Nothing made the client but its own constructor: the default.
			Assert.equals(CongestionControl, Type.getClass(client.congestionControl));
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		closeQuietly(client);
		closeServerQuietly(server);
		closeServerQuietly(peer);
	}

	public function testAPolicyHookThatThrowsRefusesTheConnect():Void {
		if (!requireDatagramSupport()) return;

		var server = new ReliableDatagramServerSocket();
		var client = new ReliableDatagramSocket();

		try {
			server.bind(0, "127.0.0.1");
			server.congestionControlFor = (address, port) -> throw "no policy for this peer";
			server.listen();
			client.connect("127.0.0.1", server.localPort);

			pumpUntil(() -> false, 0.3);
			Assert.equals(0, __countConnections(server), "a session was opened for a peer the hook refused");
			Assert.isFalse(client.connected);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		closeQuietly(client);
		closeServerQuietly(server);
	}

	public function testAServerDialsOutFromItsOwnPort():Void {
		if (!requireDatagramSupport()) return;

		// The property this exists for, and the only one that matters: a
		// session opened with ReliableDatagramServerSocket.connect leaves from
		// the port the server is bound to, not from an arbitrary one. Hole
		// punching works only when the port a peer dials out from is the port
		// it is reachable on, because a NAT holds that mapping for one socket.
		//
		// Assembling this from outside the class is possible -- RTPMP does it
		// by writing eleven private fields -- but it cannot be checked from
		// outside, and it gets the routing wrong in a way that only shows up
		// under a second peer.
		var alice = new ReliableDatagramServerSocket();
		var bob = new ReliableDatagramServerSocket();
		var acceptedByBob:ReliableDatagramSocket = null;
		var delivered:String = null;

		try {
			// Stream mode on both, which is what a mesh uses: the dialled
			// session takes its server's socketMode exactly as an accepted one
			// does.
			alice.socketMode = ReliableDatagramSocketMode.STREAM;
			bob.socketMode = ReliableDatagramSocketMode.STREAM;
			alice.bind(0, "127.0.0.1");
			alice.listen();
			bob.bind(0, "127.0.0.1");
			bob.listen();

			bob.addEventListener(ReliableDatagramSocketConnectEvent.CONNECT, event -> {
				acceptedByBob = event.socket;
				acceptedByBob.addEventListener(ProgressEvent.SOCKET_DATA, _ -> {
					if (acceptedByBob.bytesAvailable > 0) {
						delivered = acceptedByBob.readUTFBytes(acceptedByBob.bytesAvailable);
					}
				});
			});

			var toBob = alice.connect("127.0.0.1", bob.localPort);
			pumpUntil(() -> toBob.connected && acceptedByBob != null && acceptedByBob.connected, 3.0);

			Assert.isTrue(toBob.connected, "the dialled session never completed its handshake");
			Assert.notNull(acceptedByBob, "the peer never saw the dialled session arrive");

			// The assertion. Bob sees the session arriving from Alice's
			// listening port, which is what makes Alice reachable there.
			//
			// Guarded: the wait above can time out under load, and a failed
			// `Assert.notNull` does not stop the test -- utest records it and
			// carries on. Reading a field off the null that follows is a
			// SIGSEGV on hxcpp release, not a catchable error, so it killed the
			// process and took the whole run's results with it.
			if (acceptedByBob != null) {
				Assert.equals(alice.localPort, acceptedByBob.remotePort,
					"dialled from port " + acceptedByBob.remotePort + " rather than the server's " + alice.localPort);
			}

			var payload = new ByteArray();
			payload.writeUTFBytes("punched");
			toBob.writeBytes(payload, 0, payload.length);
			toBob.flush();

			pumpUntil(() -> delivered != null, 3.0);
			Assert.equals("punched", delivered);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try alice.close() catch (_:Dynamic) {}
		try bob.close() catch (_:Dynamic) {}
	}

	public function testDiallingRefusesWhatItCannotHonour():Void {
		if (!requireDatagramSupport()) return;

		var server = new ReliableDatagramServerSocket();

		try {
			// Unbound: there is no port to dial from.
			Assert.raises(() -> server.connect("127.0.0.1", 9), IOError);

			server.bind(0, "127.0.0.1");

			// Bound but not listening. The server's pump is what routes replies
			// to a dialled session, so this would send a handshake and never
			// hear the answer -- a hang rather than an error, which is the
			// worse of the two.
			Assert.raises(() -> server.connect("127.0.0.1", 9), IOError);

			server.listen();

			var first = server.connect("127.0.0.1", 9);
			Assert.notNull(first);

			// A second session to one endpoint would take over the first's
			// routing entry and strand it, which is hard to see from outside.
			Assert.raises(() -> server.connect("127.0.0.1", 9), crossbyte.errors.ArgumentError);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try server.close() catch (_:Dynamic) {}
	}

	public function testDatagramModeHandshakeAndDeliveryOverLocalhost():Void {
		if (!requireDatagramSupport()) return;

		var server = new ReliableDatagramServerSocket();
		var client = new ReliableDatagramSocket();
		var accepted:ReliableDatagramSocket = null;
		var delivered:String = null;

		try {
			server.bind(0, "127.0.0.1");
			server.addEventListener(ReliableDatagramSocketConnectEvent.CONNECT, event -> {
				accepted = event.socket;
				accepted.addEventListener(DatagramSocketDataEvent.DATA, dataEvent -> {
					dataEvent.data.position = 0;
					delivered = dataEvent.data.readUTFBytes(dataEvent.data.length);
				});
			});
			server.listen();

			client.connect("127.0.0.1", server.localPort);
			pumpUntil(() -> client.connected && accepted != null && accepted.connected, 2.0);

			client.send(bytesOf("reliable"));
			pumpUntil(() -> delivered != null, 2.0);

			Assert.isTrue(client.connected);
			Require.notNull(accepted);
			Assert.isTrue(accepted.connected);
			Assert.equals("reliable", delivered);
		} catch (e:Dynamic) {
			closeQuietly(client);
			closeQuietly(accepted);
			closeServerQuietly(server);
			throw e;
		}

		closeQuietly(client);
		closeQuietly(accepted);
		closeServerQuietly(server);
	}

	public function testSessionsAskForAWindowOfSocketBuffer():Void {
		if (!requireDatagramSupport()) return;

		// What this system grants a socket that asks for a window's worth:
		// all of it on Windows and macOS, what net.core.rmem_max allows on
		// Linux. A session must end up with at least that much.
		var plain = new DatagramSocket();
		plain.receiveBufferSize = ReliableDatagramSocket.WINDOW_BUFFER_SIZE;
		plain.sendBufferSize = ReliableDatagramSocket.WINDOW_BUFFER_SIZE;
		var receiveGranted = plain.receiveBufferSize;
		var sendGranted = plain.sendBufferSize;
		plain.close();

		var client = new ReliableDatagramSocket();
		var server = new ReliableDatagramServerSocket();
		try {
			Assert.isTrue(client.receiveBufferSize >= receiveGranted, 'a session read back ${client.receiveBufferSize} where $receiveGranted is granted');
			Assert.isTrue(client.sendBufferSize >= sendGranted, 'a session read back ${client.sendBufferSize} where $sendGranted is granted');
			Assert.isTrue(server.receiveBufferSize >= receiveGranted, 'a server read back ${server.receiveBufferSize} where $receiveGranted is granted');
			Assert.isTrue(server.sendBufferSize >= sendGranted, 'a server read back ${server.sendBufferSize} where $sendGranted is granted');

			// Asked for, not imposed: a smaller size can still be chosen, and
			// reads back as asked, or doubled where Linux counts its own
			// bookkeeping.
			var smaller = 96 * 1024;
			client.receiveBufferSize = smaller;
			var read = client.receiveBufferSize;
			Assert.isTrue(read >= smaller && read <= smaller * 2, 'asked for $smaller, read back $read');
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}
		closeQuietly(client);
		closeServerQuietly(server);
	}

	public function testReservingAWindowNeverLowersABuffer():Void {
		if (!requireDatagramSupport()) return;

		var socket = new DatagramSocket();
		try {
			socket.receiveBufferSize = ReliableDatagramSocket.WINDOW_BUFFER_SIZE * 2;
			var before = socket.receiveBufferSize;
			ReliableDatagramSocket.__reserveWindow(socket);
			Assert.isTrue(socket.receiveBufferSize >= before, 'reserving a window took ${before} down to ${socket.receiveBufferSize}');
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}
		socket.close();
	}

	public function testARealSessionMeasuresItsRoundTrip():Void {
		if (!requireDatagramSupport()) return;

		var server = new ReliableDatagramServerSocket();
		var client = new ReliableDatagramSocket();
		var accepted:ReliableDatagramSocket = null;
		var echoed:Bool = false;

		try {
			server.bind(0, "127.0.0.1");
			server.addEventListener(ReliableDatagramSocketConnectEvent.CONNECT, event -> {
				accepted = event.socket;
				accepted.addEventListener(DatagramSocketDataEvent.DATA, dataEvent -> accepted.send(dataEvent.data));
			});
			server.listen();
			client.addEventListener(DatagramSocketDataEvent.DATA, _ -> echoed = true);

			client.connect("127.0.0.1", server.localPort);
			pumpUntil(() -> client.connected && accepted != null && accepted.connected, 2.0);
			Assert.equals(-1.0, client.roundTripTime, "a round trip before anything was acknowledged");

			client.send(bytesOf("there and back"));
			pumpUntil(() -> echoed && client.roundTripTime >= 0, 2.0);

			// Loopback, so well under a second however loaded the machine, and
			// the timeout drawn from it no lower than its floor.
			Assert.isTrue(echoed, "the echo never came back");
			Assert.isTrue(client.roundTripTime >= 0 && client.roundTripTime < 1, "the round trip read " + client.roundTripTime);
			Assert.isTrue(client.roundTripVariation >= 0);
			Assert.isTrue(client.retransmitTimeout >= 0.2 && client.retransmitTimeout <= 1, "the timeout read " + client.retransmitTimeout);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		closeQuietly(client);
		closeQuietly(accepted);
		closeServerQuietly(server);
	}

	public function testAMessageLargerThanOneFrameArrivesWhole():Void {
		if (!requireDatagramSupport()) return;

		var server = new ReliableDatagramServerSocket();
		var client = new ReliableDatagramSocket();
		var accepted:ReliableDatagramSocket = null;
		var arrived:Array<Int> = [];
		var messages:Array<ByteArray> = [];

		try {
			server.bind(0, "127.0.0.1");
			server.addEventListener(ReliableDatagramSocketConnectEvent.CONNECT, event -> {
				accepted = event.socket;
				accepted.addEventListener(DatagramSocketDataEvent.DATA, dataEvent -> {
					arrived.push(dataEvent.data.length);
					messages.push(dataEvent.data);
				});
			});
			server.listen();

			client.connect("127.0.0.1", server.localPort);
			pumpUntil(() -> client.connected && accepted != null && accepted.connected, 2.0);

			// Three frames' worth, then a small one: the boundaries a datagram
			// socket promises are the ones the sender drew, so this is two
			// messages, not four.
			var large = new ByteArray();
			for (i in 0...3000) {
				large.writeByte(i & 0xFF);
			}
			client.send(large);
			client.send(bytesOf("after"));
			pumpUntil(() -> arrived.length >= 2, 2.0);
			pumpUntil(() -> false, 0.2);

			Assert.same([3000, 5], arrived, "each send arrives as one message, not " + arrived.join(" + "));
			if (arrived.length == 2 && arrived[0] == 3000) {
				var whole:ByteArray = messages[0];
				whole.position = 0;
				var wrong:Int = -1;
				for (i in 0...3000) {
					if (whole.readUnsignedByte() != (i & 0xFF)) {
						wrong = i;
						break;
					}
				}
				Assert.equals(-1, wrong, "the first byte out of place");
				messages[1].position = 0;
				Assert.equals("after", messages[1].readUTFBytes(messages[1].length));
			}
		} catch (e:Dynamic) {
			closeQuietly(client);
			closeQuietly(accepted);
			closeServerQuietly(server);
			throw e;
		}

		closeQuietly(client);
		closeQuietly(accepted);
		closeServerQuietly(server);
	}

	public function testClosingFromTheDataHandlerReportsNoError():Void {
		if (!requireDatagramSupport()) return;

		var server = new ReliableDatagramServerSocket();
		var client = new ReliableDatagramSocket();
		var accepted:ReliableDatagramSocket = null;
		var errors:Array<String> = [];
		var heard = 0;

		try {
			server.bind(0, "127.0.0.1");
			server.addEventListener(ReliableDatagramSocketConnectEvent.CONNECT, event -> accepted = event.socket);
			server.listen();

			// The client owns its transport, so closing the session closes the
			// socket the acknowledgement for this very message would leave by.
			client.addEventListener(DatagramSocketDataEvent.DATA, _ -> {
				heard++;
				client.close();
			});
			client.addEventListener(IOErrorEvent.IO_ERROR, (e:IOErrorEvent) -> errors.push(e.text));

			client.connect("127.0.0.1", server.localPort);
			pumpUntil(() -> client.connected && accepted != null && accepted.connected, 2.0);
			Require.notNull(accepted);

			accepted.send(bytesOf("goodbye"));
			pumpUntil(() -> heard > 0, 2.0);
			pumpUntil(() -> false, 0.1);

			Assert.equals(1, heard);
			Assert.same([], errors, "a close the caller made itself was reported as a failure");
			Assert.isFalse(client.connected);
		} catch (e:Dynamic) {
			closeQuietly(client);
			closeQuietly(accepted);
			closeServerQuietly(server);
			throw e;
		}

		closeQuietly(accepted);
		closeServerQuietly(server);
	}

	public function testUnreliableAndSequencedMessagesCrossARealSession():Void {
		if (!requireDatagramSupport()) return;

		var server = new ReliableDatagramServerSocket();
		var client = new ReliableDatagramSocket();
		var accepted:ReliableDatagramSocket = null;
		var arrived:Array<String> = [];
		var back:Array<String> = [];

		try {
			server.bind(0, "127.0.0.1");
			server.addEventListener(ReliableDatagramSocketConnectEvent.CONNECT, event -> {
				accepted = event.socket;
				accepted.addEventListener(DatagramSocketDataEvent.DATA, dataEvent -> {
					arrived.push(dataEvent.data.toString());
				});
			});
			server.listen();
			client.addEventListener(DatagramSocketDataEvent.DATA, dataEvent -> back.push(dataEvent.data.toString()));

			client.connect("127.0.0.1", server.localPort);
			pumpUntil(() -> client.connected && accepted != null && accepted.connected, 2.0);

			// Through the server's routing to an accepted session, and back
			// the other way to a dialled one.
			client.send(bytesOf("unreliable"), 0, 0, DeliveryMode.UNRELIABLE);
			client.send(bytesOf("sequenced"), 0, 0, DeliveryMode.sequenced(4));
			client.send(bytesOf("reliable"));
			pumpUntil(() -> arrived.length >= 3, 2.0);
			Require.notNull(accepted);
			accepted.send(bytesOf("state"), 0, 0, DeliveryMode.sequenced(0));
			pumpUntil(() -> back.length >= 1, 2.0);

			arrived.sort(Reflect.compare);
			Assert.same(["reliable", "sequenced", "unreliable"], arrived);
			Assert.same(["state"], back);
		} catch (e:Dynamic) {
			closeQuietly(client);
			closeQuietly(accepted);
			closeServerQuietly(server);
			throw e;
		}

		closeQuietly(client);
		closeQuietly(accepted);
		closeServerQuietly(server);
	}

	public function testStreamModeHandshakeAndDeliveryOverLocalhost():Void {
		if (!requireDatagramSupport()) return;

		var server = new ReliableDatagramServerSocket();
		var client = new ReliableDatagramSocket();
		var accepted:ReliableDatagramSocket = null;
		var delivered:String = null;

		try {
			server.socketMode = STREAM;
			client.mode = STREAM;
			server.bind(0, "127.0.0.1");
			server.addEventListener(ReliableDatagramSocketConnectEvent.CONNECT, event -> {
				accepted = event.socket;
				accepted.addEventListener(ProgressEvent.SOCKET_DATA, _ -> {
					delivered = accepted.readUTFBytes(accepted.bytesAvailable);
				});
			});
			server.listen();

			client.connect("127.0.0.1", server.localPort);
			pumpUntil(() -> client.connected && accepted != null && accepted.connected, 2.0);

			client.writeUTFBytes("stream");
			client.flush();
			pumpUntil(() -> delivered != null, 2.0);

			Assert.equals("stream", delivered);
		} catch (e:Dynamic) {
			closeQuietly(client);
			closeQuietly(accepted);
			closeServerQuietly(server);
			throw e;
		}

		closeQuietly(client);
		closeQuietly(accepted);
		closeServerQuietly(server);
	}

	/**
		A frame that cannot go out reports why, and takes the connection down.

		`__sendRaw` is the single exit every frame leaves through -- data,
		acks and keep-alives alike -- and several of its callers run from
		timers and from the transport's own receive handler. A throw escaping
		here would unwind through those rather than fail this connection, so
		the failure has to leave as an ioError and a close.

		The reason has to travel with it. Reporting that a send failed without
		saying why is the fault that made an unrelated intermittent unreadable
		for weeks elsewhere in this package.
	**/
	public function testASendThatCannotGoOutReportsWhyAndCloses():Void {
		if (!requireDatagramSupport()) return;

		var server = new ReliableDatagramServerSocket();
		var client = new ReliableDatagramSocket();
		var accepted:ReliableDatagramSocket = null;
		var errors:Array<String> = [];
		var closes = 0;

		try {
			server.bind(0, "127.0.0.1");
			server.addEventListener(ReliableDatagramSocketConnectEvent.CONNECT, event -> accepted = event.socket);
			server.listen();

			client.connect("127.0.0.1", server.localPort);
			pumpUntil(() -> client.connected && accepted != null && accepted.connected, 2.0);
			Assert.isTrue(client.connected, "the pair never connected, so there was nothing to fail");

			client.addEventListener(IOErrorEvent.IO_ERROR, (e:IOErrorEvent) -> errors.push(e.text));
			client.addEventListener(Event.CLOSE, _ -> closes++);

			// The transport underneath is closed, so the next frame cannot
			// leave. This is what a socket dying under a live connection does.
			@:privateAccess client.__transport.close();
			client.send(bytesOf("frame"));

			// Gathered rather than sent, so it fails where the runtime's pass
			// ends -- which is the loop itself, and exactly where a throw must
			// not escape to.
			Assert.equals(0, errors.length, "the frame was sent from inside send()");
			pumpUntil(() -> errors.length > 0, 1.0);

			Assert.equals(1, errors.length, "a frame that could not be sent was not reported");
			if (errors.length > 0) {
				Assert.isTrue(errors[0].length > 0, "the ioError carried no reason for the failure");
			}
			Assert.equals(1, closes, "a send that failed left the connection open");
			Assert.isFalse(client.connected, "the connection still reported itself up after its transport had gone");
		} catch (e:Dynamic) {
			closeQuietly(client);
			closeQuietly(accepted);
			closeServerQuietly(server);
			throw e;
		}

		closeQuietly(client);
		closeQuietly(accepted);
		closeServerQuietly(server);
	}

	public function testConnectionTimeoutDispatchesIOErrorAndCloses():Void {
		if (!requireDatagramSupport()) return;

		var client = new ReliableDatagramSocket();
		var unused = new DatagramSocket();
		var errors = 0;
		var closes = 0;

		try {
			unused.bind(0, "127.0.0.1");
			var unusedPort = unused.localPort;
			unused.close();

			client.timeout = 10;
			client.addEventListener(IOErrorEvent.IO_ERROR, _ -> errors++);
			client.addEventListener(Event.CLOSE, _ -> closes++);
			client.connect("127.0.0.1", unusedPort);

			pumpUntil(() -> errors > 0, 1.0);

			Assert.equals(1, errors);
			Assert.equals(1, closes);
			Assert.isFalse(client.connected);
			Assert.isTrue(throwsIOError(() -> client.send(bytesOf("late"))));
		} catch (e:Dynamic) {
			closeQuietly(client);
			closeDatagramQuietly(unused);
			throw e;
		}

		closeQuietly(client);
		closeDatagramQuietly(unused);
	}

	public function testConnectsFromNewAddressesAreBoundedWhileUnanswered():Void {
		if (!requireDatagramSupport()) return;

		var server = new ReliableDatagramServerSocket();

		try {
			server.bind(0, "127.0.0.1");
			server.maxPendingConnections = 3;
			server.listen();

			// Fed to the handler directly, because the whole point is the source
			// address and one socket only ever sends from one. UDP lets a sender
			// write whatever it likes there, which is what makes a ceiling
			// necessary in the first place. Ports on loopback, so the handshakes
			// these provoke go nowhere off this machine.
			for (i in 0...12) {
				__injectConnect(server, 40000 + i);
			}

			Assert.equals(3, server.__pendingCount, "the ceiling did not hold");
			Assert.equals(3, __countConnections(server));
		} catch (e:Dynamic) {
			Assert.fail("flood test failed: " + Std.string(e));
		}

		server.close();
	}

	public function testAnAdmitHookDropsAConnectBeforeASessionExists():Void {
		if (!requireDatagramSupport()) return;

		var server = new ReliableDatagramServerSocket();
		var asked:Array<String> = [];

		try {
			server.bind(0, "127.0.0.1");
			server.admit = (address, port, _) -> {
				asked.push('$address:$port');
				return port != 40101;
			};
			server.listen();

			for (port in [40100, 40101, 40102]) {
				__injectConnect(server, port);
			}

			Assert.same(["127.0.0.1:40100", "127.0.0.1:40101", "127.0.0.1:40102"], asked);
			Assert.equals(2, __countConnections(server));
			Assert.equals(2, server.__pendingCount);
			Assert.isNull(server.__connections.get("127.0.0.1:40101"));
		} catch (e:Dynamic) {
			Assert.fail("admission test failed: " + Std.string(e));
		}

		server.close();
	}

	public function testAnAdmitHookThatThrowsDropsTheConnect():Void {
		if (!requireDatagramSupport()) return;

		var server = new ReliableDatagramServerSocket();

		try {
			server.bind(0, "127.0.0.1");
			server.admit = (_, _, _) -> throw "the hook's own bug";
			server.listen();

			__injectConnect(server, 40200);

			Assert.equals(0, __countConnections(server));
			Assert.equals(0, server.__pendingCount);
		} catch (e:Dynamic) {
			Assert.fail("admission test failed: " + Std.string(e));
		}

		server.close();
	}

	public function testAdmitSeesWhatTheClientSentWithItsConnect():Void {
		if (!requireDatagramSupport()) return;

		var server = new ReliableDatagramServerSocket();
		var client = new ReliableDatagramSocket();
		var accepted:ReliableDatagramSocket = null;
		var asked:Array<String> = [];

		try {
			server.bind(0, "127.0.0.1");
			server.admit = (_, _, payload) -> {
				// Read to the end, which the admitted session must not inherit.
				var token = payload.readUTFBytes(payload.bytesAvailable);
				asked.push(token);
				return token == "ticket-7";
			};
			server.addEventListener(ReliableDatagramSocketConnectEvent.CONNECT, event -> accepted = event.socket);
			server.listen();

			client.connect("127.0.0.1", server.localPort, bytesOf("ticket-7"));
			pumpUntil(() -> client.connected && accepted != null && accepted.connected, 3.0);

			Assert.same(["ticket-7"], asked);
			Assert.isTrue(client.connected, "the admitted client never connected");
			var kept = Require.notNull(Require.notNull(accepted, "the server never reported the session").connectPayload);
			Assert.equals(0, kept.position, "the session's payload starts where the hook left off");
			Assert.equals("ticket-7", textOf(kept));

			// A client of a server is never sent a CONNECT, so has none.
			Assert.isNull(client.connectPayload);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		closeQuietly(client);
		closeServerQuietly(server);
	}

	public function testAdmitCanRefuseOnThePayload():Void {
		if (!requireDatagramSupport()) return;

		var server = new ReliableDatagramServerSocket();

		try {
			server.bind(0, "127.0.0.1");
			server.admit = (_, _, payload) -> payload.readUTFBytes(payload.bytesAvailable) == "good";
			server.listen();

			__injectConnect(server, 40300, bytesOf("good"));
			__injectConnect(server, 40301, bytesOf("bad"));
			__injectConnect(server, 40302);

			Assert.equals(1, __countConnections(server));
			Assert.equals(1, server.__pendingCount);
			Assert.notNull(server.__connections.get("127.0.0.1:40300"));
		} catch (e:Dynamic) {
			Assert.fail("admission test failed: " + Std.string(e));
		}

		server.close();
	}

	public function testAConnectCarryingNothingShowsAdmitAnEmptyPayload():Void {
		if (!requireDatagramSupport()) return;

		var server = new ReliableDatagramServerSocket();
		var seen:Array<Int> = [];

		try {
			server.bind(0, "127.0.0.1");
			// Empty rather than null: a peer on an older build sends nothing,
			// and a hook written for tokens should not have to test for null
			// to refuse it.
			server.admit = (_, _, payload) -> {
				seen.push(payload == null ? -1 : payload.length);
				return true;
			};
			server.listen();

			__injectConnect(server, 40400);

			Assert.same([0], seen);
			var accepted = Require.notNull(server.__connections.get("127.0.0.1:40400"));
			Assert.equals(0, Require.notNull(accepted.connectPayload).length);
		} catch (e:Dynamic) {
			Assert.fail("admission test failed: " + Std.string(e));
		}

		server.close();
	}

	public function testAConnectCarryingMoreThanAFrameIsNeverAdmitted():Void {
		if (!requireDatagramSupport()) return;

		var server = new ReliableDatagramServerSocket();
		var asked:Int = 0;

		try {
			server.bind(0, "127.0.0.1");
			server.admit = (_, _, _) -> {
				asked++;
				return true;
			};
			server.listen();

			// No connect() can send the first, and each pending session keeps
			// what its CONNECT carried, so it is dropped before the hook is
			// asked. The second is the most one can carry.
			__injectConnect(server, 40500, zeros(ReliableDatagramProtocol.MAX_PAYLOAD_SIZE + 1));
			__injectConnect(server, 40501, zeros(ReliableDatagramProtocol.MAX_PAYLOAD_SIZE));

			Assert.equals(1, asked);
			Assert.equals(1, __countConnections(server));
			Assert.isNull(server.__connections.get("127.0.0.1:40500"));
			Assert.notNull(server.__connections.get("127.0.0.1:40501"));
		} catch (e:Dynamic) {
			Assert.fail("admission test failed: " + Std.string(e));
		}

		server.close();
	}

	public function testAConnectPayloadLargerThanAFrameIsRefusedBeforeAnythingStarts():Void {
		if (!requireDatagramSupport()) return;

		var client = new ReliableDatagramSocket();
		var server = new ReliableDatagramServerSocket();
		var tooBig = zeros(ReliableDatagramProtocol.MAX_PAYLOAD_SIZE + 1);

		try {
			Assert.raises(() -> client.connect("127.0.0.1", 9, tooBig), crossbyte.errors.RangeError);
			Assert.isFalse(client.bound, "the refused connect bound a port");
			Assert.equals(0, client.remotePort, "the refused connect took a peer");
			Assert.equals(-1, client.__connectionAttemptHandle, "the refused connect began a handshake");

			server.bind(0, "127.0.0.1");
			server.listen();
			Assert.raises(() -> server.connect("127.0.0.1", 9, 0, tooBig), crossbyte.errors.RangeError);
			Assert.equals(0, __countConnections(server), "the refused dial was registered");

			// A frame's worth exactly is not too big.
			Assert.notNull(server.connect("127.0.0.1", 9, 0, zeros(ReliableDatagramProtocol.MAX_PAYLOAD_SIZE)));
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		closeQuietly(client);
		closeServerQuietly(server);
	}

	public function testEveryConnectAttemptCarriesThePayload():Void {
		if (!requireDatagramSupport()) return;

		// A plain datagram socket where the server would be, so what arrives
		// is read as sent, with nothing answering it.
		var listener = new DatagramSocket();
		var client = new ReliableDatagramSocket();
		var frames:Array<ReliableDatagramFrame> = [];

		try {
			listener.bind(0, "127.0.0.1");
			listener.addEventListener(DatagramSocketDataEvent.DATA, e -> frames.push(ReliableDatagramProtocol.decode(e.data)));
			listener.receive();

			var passed = bytesOf("again");
			client.connect("127.0.0.1", listener.localPort, passed);
			pumpUntil(() -> frames.length >= 1, 3.0);

			// Rewritten between attempts. connect copied it, so the repeat
			// still says what the caller passed.
			passed.position = 0;
			passed.writeUTFBytes("other");

			// A lost CONNECT is recovered by the next attempt, which is only a
			// recovery if the next attempt says the same thing.
			client.__sendHandshakeAttempt();
			pumpUntil(() -> frames.length >= 2, 3.0);

			Assert.equals(2, frames.length);
			for (frame in frames) {
				if (frame == null) {
					Assert.fail("a CONNECT did not decode");
					continue;
				}
				Assert.equals(ReliableDatagramFrameType.CONNECT, frame.type);
				Assert.equals("again", textOf(frame.payload));
			}
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		closeQuietly(client);
		try listener.close() catch (_:Dynamic) {}
	}

	public function testPeersThatBothDialSeeEachOthersPayload():Void {
		if (!requireDatagramSupport()) return;

		// Two peers opening a path through NAT both dial, so neither side's
		// admit is asked -- each CONNECT arrives at a session already dialled.
		// The payload is still what the other side said, and it is kept.
		var alice = new ReliableDatagramServerSocket();
		var bob = new ReliableDatagramServerSocket();

		try {
			alice.bind(0, "127.0.0.1");
			alice.listen();
			bob.bind(0, "127.0.0.1");
			bob.listen();

			var toBob = alice.connect("127.0.0.1", bob.localPort, 0, bytesOf("from alice"));
			var toAlice = bob.connect("127.0.0.1", alice.localPort, 0, bytesOf("from bob"));

			pumpUntil(() -> toBob.connected && toAlice.connected, 5.0);

			Assert.isTrue(toBob.connected && toAlice.connected, "the dialled sessions never completed");
			Assert.equals("from bob", textOf(toBob.connectPayload));
			Assert.equals("from alice", textOf(toAlice.connectPayload));
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		closeServerQuietly(alice);
		closeServerQuietly(bob);
	}

	public function testADialledSessionKeepsNoConnectLargerThanAFrame():Void {
		if (!requireDatagramSupport()) return;

		var server = new ReliableDatagramServerSocket();

		try {
			server.bind(0, "127.0.0.1");
			server.listen();

			// A dialled session takes the CONNECT of a peer that dialled too,
			// and holds it no larger than the server would.
			var dialled = server.connect("127.0.0.1", 40600);
			__injectConnect(server, 40600, zeros(ReliableDatagramProtocol.MAX_PAYLOAD_SIZE + 1));
			Assert.isNull(dialled.connectPayload, "an oversized CONNECT payload was kept");

			__injectConnect(server, 40600, bytesOf("fits"));
			Assert.equals("fits", textOf(dialled.connectPayload));
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		closeServerQuietly(server);
	}

	public function testAnAcceptedSessionAnswersOnceRatherThanRepeating():Void {
		if (!requireDatagramSupport()) return;

		var server = new ReliableDatagramServerSocket();

		try {
			server.bind(0, "127.0.0.1");
			server.listen();
			__injectConnect(server, 41000);

			var accepted = server.__connections.get("127.0.0.1:41000");
			Require.notNull(accepted);
			Assert.isFalse(accepted.connected);

			// The address is still only a claim, so the answer is sent once and
			// not repeated. A dialling session arms this handle; an accepted one
			// must not, or one spoofed datagram becomes a run of them aimed at
			// whoever the address really belongs to.
			Assert.equals(-1, accepted.__connectionAttemptHandle, "an accepted session armed a retransmit timer");

			// The reaper still runs, so a session nobody answers for is not kept.
			Assert.notEquals(-1, accepted.__connectionTimeoutHandle);
		} catch (e:Dynamic) {
			Assert.fail("accepted-session test failed: " + Std.string(e));
		}

		server.close();
	}

	private static function __injectConnect(server:ReliableDatagramServerSocket, srcPort:Int, ?payload:ByteArray):Void {
		var encoded:ByteArray = ReliableDatagramProtocol.encode(ReliableDatagramFrameType.CONNECT, 1, payload);
		var packet:ByteArray = new ByteArray();
		packet.writeBytes(encoded, 0, encoded.length);
		packet.position = 0;

		server.__onData(new DatagramSocketDataEvent(DatagramSocketDataEvent.DATA, "127.0.0.1", srcPort, "127.0.0.1", server.localPort, packet));
	}

	private static function __countConnections(server:ReliableDatagramServerSocket):Int {
		var count:Int = 0;
		for (_ in server.__connections) {
			count++;
		}
		return count;
	}

	private static function requireDatagramSupport():Bool {
		if (!ReliableDatagramSocket.isSupported) {
			Assert.isFalse(ReliableDatagramSocket.isSupported);
			return false;
		}
		return true;
	}

	// The whole of `bytes` as text, leaving its position where it was.
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

	private static function zeros(length:Int):ByteArray {
		var bytes = new ByteArray();
		bytes.length = length;
		return bytes;
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

	private static function closeDatagramQuietly(socket:DatagramSocket):Void {
		try {
			if (socket != null) {
				socket.close();
			}
		} catch (_:Dynamic) {}
	}

	private static function throwsIOError(fn:Void->Void):Bool {
		try {
			fn();
			return false;
		} catch (_:IOError) {
			return true;
		} catch (_:Dynamic) {
			return false;
		}
	}
}

/** A client that loses the first datagram it sends once connected. **/
@:access(crossbyte.net.ReliableDatagramSocket)
private class AnswerLosingSocket extends ReliableDatagramSocket {
	public var lost:Int = 0;

	public function new() {
		super();
	}

	override private function __sendDatagram(offset:Int, length:Int):Bool {
		if (__connected && lost == 0) {
			lost++;
			return true;
		}
		return super.__sendDatagram(offset, length);
	}
}
