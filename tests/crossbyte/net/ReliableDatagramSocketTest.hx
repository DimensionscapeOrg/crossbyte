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
			@:privateAccess client.__sendRaw(bytesOf("frame"));

			Assert.equals(1, errors.length, "a frame that could not be sent was not reported");
			Assert.isTrue(errors[0].length > 0, "the ioError carried no reason for the failure");
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

	private static function requireDatagramSupport():Bool {
		if (!ReliableDatagramSocket.isSupported) {
			Assert.isFalse(ReliableDatagramSocket.isSupported);
			return false;
		}
		return true;
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
