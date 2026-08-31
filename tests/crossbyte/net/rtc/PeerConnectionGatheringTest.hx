package crossbyte.net.rtc;

import crossbyte.core.CrossByte;
import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.io.ByteArray;
import crossbyte.net.DatagramSocket;
import crossbyte.net._internal.stun.StunMessage;
import crossbyte.net.ice.IceCandidate;
import utest.Assert;

/**
	Asking a STUN server what address this connection appears from.

	Against a server bound in the test rather than one on the internet, which
	is not a compromise: the property under test is that the question goes out
	of *this connection's* socket, that the answer comes back in through a
	demultiplexer already carrying ICE and DTLS, and that what the server said
	becomes a candidate. A real server would answer the same question no
	differently and would make the suite depend on the network.

	What a fake server cannot show is a NAT translating anything -- on loopback
	the address reported is the address asked from. So the server here reports
	an address deliberately unlike the one it sees, which is what a NAT would
	do and what makes the difference between reporting the answer and reporting
	the question visible.
**/
class PeerConnectionGatheringTest extends utest.Test {
	/** Somewhere the test machine certainly is not, so it can only have come from the reply. **/
	public static inline var REPORTED_ADDRESS:String = "203.0.113.7";

	public static inline var REPORTED_PORT:Int = 54321;

	private function unsupported():Bool {
		if (!PeerConnection.isSupported) {
			Assert.isFalse(PeerConnection.isSupported);
			return true;
		}

		return false;
	}

	/**
		The address the server reports becomes a candidate, and one the peer
		will be told about.
	**/
	public function testTheAddressAServerReportsBecomesACandidate():Void {
		if (unsupported()) return;

		var server = new FakeStunServer();
		var connection = new PeerConnection(true);

		try {
			server.start();
			connection.bind(0, "127.0.0.1");

			var gathered:IceCandidate = null;
			var failure:String = null;

			connection.gatherReflexive("127.0.0.1", server.port, 4000).then(c -> gathered = c, e -> failure = e);
			pumpUntil(() -> gathered != null || failure != null, 6.0);

			Assert.isNull(failure, failure);
			Assert.notNull(gathered, "the server answered but no candidate came back");

			if (gathered == null) {
				return;
			}

			Assert.equals(REPORTED_ADDRESS, gathered.address);
			Assert.equals(REPORTED_PORT, gathered.port);
			Assert.equals("srflx", (gathered.type : String));

			// And it is in what the peer would be sent, which is the only place
			// a candidate does any good.
			var described = connection.description().candidates;
			var carried = false;

			for (candidate in described) {
				if (candidate.address == REPORTED_ADDRESS && candidate.port == REPORTED_PORT) {
					carried = true;
				}
			}

			Assert.isTrue(carried, "the reflexive address never reached the description");

			// And it knows the address it was discovered through. Nothing sends
			// from a reflexive address -- the datagram leaves the socket that
			// asked, and the translation happens on the way -- so ICE pairs it
			// as its base, and a candidate that did not record one would be
			// checked as a place of its own and send every check twice.
			Assert.notNull(gathered.base, "the reflexive candidate recorded no base");

			if (gathered.base == null) {
				return;
			}

			Assert.equals("127.0.0.1", gathered.base.address);
			Assert.equals(connection.localPort, gathered.base.port);
			Assert.equals("host", (gathered.base.type : String));
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		connection.close();
		server.close();
	}

	/**
		A lost request is asked again.

		The one datagram carrying the only question this connection asks about
		its own address is a thing to lose, and losing it means advertising
		nothing beyond the local network. A deadline alone would report that as
		a server which is not there.
	**/
	public function testAskingAgainWhenTheFirstRequestsAreLost():Void {
		if (unsupported()) return;

		var server = new FakeStunServer();
		var connection = new PeerConnection(true);

		try {
			// Two dropped on the floor, so an answer can only come from a third
			// request that something chose to send.
			server.ignoreFirst = 2;
			server.start();
			connection.bind(0, "127.0.0.1");

			var gathered:IceCandidate = null;
			var failure:String = null;

			connection.gatherReflexive("127.0.0.1", server.port, 8000).then(c -> gathered = c, e -> failure = e);
			pumpUntil(() -> gathered != null || failure != null, 10.0);

			Assert.isNull(failure, failure);
			Assert.notNull(gathered, "two dropped requests ended the gathering, so nothing asked again");
			Assert.isTrue(server.received >= 3, "expected the request to be repeated, saw " + server.received);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		connection.close();
		server.close();
	}

	/**
		Silence ends, and says what it means.

		UDP reports nothing when a datagram is dropped, so a server that never
		answers and one that was never reached are the same event from here.
	**/
	public function testGivingUpWhenNothingAnswers():Void {
		if (unsupported()) return;

		var server = new FakeStunServer();
		var connection = new PeerConnection(true);

		try {
			server.ignoreEverything = true;
			server.start();
			connection.bind(0, "127.0.0.1");

			var gathered:IceCandidate = null;
			var failure:String = null;

			connection.gatherReflexive("127.0.0.1", server.port, 700).then(c -> gathered = c, e -> failure = e);
			pumpUntil(() -> gathered != null || failure != null, 6.0);

			Assert.isNull(gathered, "a server that said nothing produced a candidate");
			Assert.notNull(failure, "a query that will never be answered never ended");

			if (failure == null) {
				return;
			}

			Assert.isTrue(failure.indexOf("STUN") >= 0, "the failure should name what did not answer: " + failure);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		connection.close();
		server.close();
	}

	/** A server that refuses says why, rather than the connection timing out. **/
	public function testAServerThatRefusesIsReported():Void {
		if (unsupported()) return;

		var server = new FakeStunServer();
		var connection = new PeerConnection(true);

		try {
			server.refuse = true;
			server.start();
			connection.bind(0, "127.0.0.1");

			var gathered:IceCandidate = null;
			var failure:String = null;

			connection.gatherReflexive("127.0.0.1", server.port, 4000).then(c -> gathered = c, e -> failure = e);
			pumpUntil(() -> gathered != null || failure != null, 6.0);

			Assert.isNull(gathered);
			Assert.notNull(failure, "a refusal left the query outstanding");

			if (failure == null) {
				return;
			}

			Assert.isTrue(failure.indexOf("refused") >= 0, "the failure should say it was refused: " + failure);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		connection.close();
		server.close();
	}

	/**
		Somebody else's STUN traffic is not this connection's answer.

		The socket carries ICE as well, in the same byte range and the same
		message format, and the reflexive query is offered every datagram first.
		What separates them is the transaction, and a query that settled on a
		peer's connectivity check would report the peer's address as this
		connection's own -- an address on the wrong side of the NAT, advertised
		with confidence.
	**/
	public function testAnotherPeersCheckDoesNotAnswerTheQuery():Void {
		if (unsupported()) return;

		var server = new FakeStunServer();
		var connection = new PeerConnection(true);
		var stranger = new DatagramSocket();

		try {
			server.ignoreEverything = true;
			server.start();
			connection.bind(0, "127.0.0.1");

			var gathered:IceCandidate = null;
			var failure:String = null;

			connection.gatherReflexive("127.0.0.1", server.port, 3000).then(c -> gathered = c, e -> failure = e);

			// A binding request of somebody else's, and a success carrying a
			// mapped address, both with transactions this connection never
			// chose. Either one settling the query is the bug.
			stranger.bind(0, "127.0.0.1");

			var foreignRequest = StunMessage.bindingRequest();
			var foreign = new StunMessage(StunMessage.BINDING_SUCCESS, StunMessage.bindingRequest().transactionId,
				[StunMessage.xorMappedAddress("198.51.100.9", 9999)]);

			for (payload in [foreignRequest.encode(), foreign.encode()]) {
				stranger.send(payload, 0, payload.length, "127.0.0.1", connection.localPort);
			}

			pumpUntil(() -> gathered != null || failure != null, 1.5);

			Assert.isNull(gathered, "a stranger's STUN message was taken for this connection's own address");
			Assert.isNull(failure, "the query ended early");
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		stranger.close();
		connection.close();
		server.close();
	}

	/** One at a time, so a second cannot displace one in flight. **/
	public function testASecondQueryWhileOneIsOutstandingIsRefused():Void {
		if (unsupported()) return;

		var server = new FakeStunServer();
		var connection = new PeerConnection(true);

		try {
			server.ignoreEverything = true;
			server.start();
			connection.bind(0, "127.0.0.1");

			var firstFailure:String = null;
			var secondFailure:String = null;

			connection.gatherReflexive("127.0.0.1", server.port, 3000).then(_ -> {}, e -> firstFailure = e);
			connection.gatherReflexive("127.0.0.1", server.port, 3000).then(_ -> {}, e -> secondFailure = e);

			pumpUntil(() -> secondFailure != null, 2.0);

			Assert.notNull(secondFailure, "a second query neither ran nor was refused");
			Assert.isNull(firstFailure, "the second query ended the first");
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		connection.close();
		server.close();
	}

	/** There is no socket to ask through before `bind`. **/
	public function testGatheringBeforeBindingIsRefused():Void {
		if (unsupported()) return;

		var connection = new PeerConnection(true);
		var failure:String = null;

		connection.gatherReflexive("127.0.0.1", 3478, 1000).then(_ -> {}, e -> failure = e);

		Assert.notNull(failure, "gathering without a socket did not say so");

		if (failure != null) {
			Assert.isTrue(failure.indexOf("bind") >= 0, "the failure should name what is missing: " + failure);
		}

		connection.close();
	}

	/** Closing settles what was outstanding, rather than leaving it pending forever. **/
	public function testClosingEndsAnOutstandingQuery():Void {
		if (unsupported()) return;

		var server = new FakeStunServer();
		var connection = new PeerConnection(true);

		try {
			server.ignoreEverything = true;
			server.start();
			connection.bind(0, "127.0.0.1");

			var settled = false;
			connection.gatherReflexive("127.0.0.1", server.port, 30000).then(_ -> settled = true, _ -> settled = true);

			Assert.isFalse(settled, "the query ended before anything happened");
			connection.close();

			Assert.isTrue(settled, "closing left a future nobody will ever complete");
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		server.close();
	}

	// ------------------------------------------------------------------

	private static function pumpUntil(done:Void->Bool, timeout:Float):Void {
		var runtime = CrossByte.current();
		var deadline = Sys.time() + timeout;

		while (!done() && Sys.time() < deadline) {
			runtime.pump(1 / 60, 0);
			Sys.sleep(0.001);
		}
	}
}

/**
	A STUN server that answers on loopback, and can be told to misbehave.

	It reports an address nothing like the one it sees, because on loopback
	those would otherwise be the same and a connection that advertised the
	address it asked from would pass.
**/
private class FakeStunServer {
	public var port(default, null):Int = 0;

	/** How many requests to drop before answering any. **/
	public var ignoreFirst:Int = 0;

	public var ignoreEverything:Bool = false;

	/** Answer with an error rather than an address. **/
	public var refuse:Bool = false;

	/** How many requests arrived, dropped ones included. **/
	public var received(default, null):Int = 0;

	private var __socket:DatagramSocket;

	public function new() {}

	public function start():Void {
		__socket = new DatagramSocket();
		__socket.bind(0, "127.0.0.1");
		port = __socket.localPort;

		__socket.addEventListener(DatagramSocketDataEvent.DATA, __onDatagram);
		__socket.receive();
	}

	public function close():Void {
		if (__socket != null) {
			try {
				__socket.close();
			} catch (_:Dynamic) {}

			__socket = null;
		}
	}

	private function __onDatagram(e:DatagramSocketDataEvent):Void {
		var request = StunMessage.decode(e.data);

		if (request == null || request.type != StunMessage.BINDING_REQUEST) {
			return;
		}

		received++;

		if (ignoreEverything || received <= ignoreFirst) {
			return;
		}

		var reply = refuse ? new StunMessage(StunMessage.BINDING_ERROR, request.transactionId,
			[StunMessage.errorCode(400, "Bad Request")]) : new StunMessage(StunMessage.BINDING_SUCCESS, request.transactionId,
			[StunMessage.xorMappedAddress(PeerConnectionGatheringTest.REPORTED_ADDRESS, PeerConnectionGatheringTest.REPORTED_PORT)]);

		var payload = reply.encode();
		__socket.send(payload, 0, payload.length, e.srcAddress, e.srcPort);
	}
}
