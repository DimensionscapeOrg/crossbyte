package crossbyte.net;

import crossbyte.core.CrossByte;
import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.io.ByteArray;
import crossbyte.net._internal.stun.StunMessage;
import utest.Assert;

/**
	Asking a STUN server what address the world sees this host as.

	`StunMessage` is pinned to RFC 5769's published vectors and `TurnClient` has
	cases of its own, but the class a caller reaches for first had neither --
	nothing in this repository named `StunClient` until now. What it does is
	short, and every part of it is a thing that can be quietly wrong: a reply
	meant for somebody else settling the question, a refusal reported as
	silence, a success carrying no address at all.

	Against a server bound in the test rather than one on the internet. The
	property is that the right question goes out and the right answer is
	believed, which a real server would demonstrate no better while making the
	suite depend on the network -- and most of these a real server could not
	demonstrate at all, since a refusal and a dropped request are not things one
	can be asked for.

	The server reports an address deliberately unlike the one it sees, because
	on loopback those are otherwise identical and a client that echoed back the
	address it asked from would pass.
**/
class StunClientTest extends utest.Test {
	/** Somewhere this machine certainly is not, so it can only have been reported. **/
	public static inline var REPORTED_ADDRESS:String = "198.51.100.42";

	public static inline var REPORTED_PORT:Int = 51234;

	/** The whole point: the address comes back, and it is the server's answer. **/
	public function testTheAddressAServerReportsIsReturned():Void {
		if (unsupported()) return;

		var server = new FakeStunServer();
		var answer = new Outcome();

		try {
			server.start();
			StunClient.discover("127.0.0.1", server.port, 4000).then(answer.succeed, answer.fail);
			pumpUntil(answer.settled, 6.0);

			Assert.isNull(answer.error, answer.error);
			Assert.notNull(answer.address, "a server that answered produced no address");

			if (answer.address == null) {
				return;
			}

			Assert.equals(REPORTED_ADDRESS, answer.address.address);
			Assert.equals(REPORTED_PORT, answer.address.port);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		server.close();
	}

	/**
		A lost request is asked again.

		One datagram carries the only question this asks, and UDP loses
		datagrams. Sending once and waiting out a deadline reports a dropped
		packet as a server that is not there -- which sends whoever reads it
		looking at their configuration for a fault that is not in it.
	**/
	public function testAskingAgainWhenTheFirstRequestsAreLost():Void {
		if (unsupported()) return;

		var server = new FakeStunServer();
		var answer = new Outcome();

		try {
			// Two on the floor, so an answer can only come from a third request
			// that something chose to send.
			server.ignoreFirst = 2;
			server.start();

			StunClient.discover("127.0.0.1", server.port, 9000).then(answer.succeed, answer.fail);
			pumpUntil(answer.settled, 11.0);

			Assert.isNull(answer.error, answer.error);
			Assert.notNull(answer.address, "two dropped requests ended the query, so nothing asked again");
			Assert.isTrue(server.received >= 3, "expected the request to be repeated, saw " + server.received);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		server.close();
	}

	/**
		Silence ends, and the failure says what silence means.

		A dropped datagram and a server that was never there are the same event
		from here, and the message has to admit that rather than pick one.
	**/
	public function testGivingUpWhenNothingAnswers():Void {
		if (unsupported()) return;

		var server = new FakeStunServer();
		var answer = new Outcome();

		try {
			server.ignoreEverything = true;
			server.start();

			StunClient.discover("127.0.0.1", server.port, 900).then(answer.succeed, answer.fail);
			pumpUntil(answer.settled, 6.0);

			Assert.isNull(answer.address, "a server that said nothing produced an address");
			Assert.notNull(answer.error, "a query that will never be answered never ended");

			if (answer.error == null) {
				return;
			}

			Assert.isTrue(answer.error.indexOf("STUN") >= 0, "the failure should name what did not answer: " + answer.error);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		server.close();
	}

	/** A refusal is reported as one, rather than waiting out the deadline. **/
	public function testAServerThatRefusesIsReported():Void {
		if (unsupported()) return;

		var server = new FakeStunServer();
		var answer = new Outcome();

		try {
			server.refuse = true;
			server.start();

			StunClient.discover("127.0.0.1", server.port, 6000).then(answer.succeed, answer.fail);
			pumpUntil(answer.settled, 8.0);

			Assert.isNull(answer.address, "a refusal produced an address");
			Assert.notNull(answer.error, "a refusal left the query outstanding");

			if (answer.error == null) {
				return;
			}

			Assert.isTrue(answer.error.indexOf("refused") >= 0, "the failure should say it was refused: " + answer.error);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		server.close();
	}

	/**
		A success carrying no address is answered without being answered.

		Saying so beats waiting out the deadline and then blaming the network
		for a server that replied promptly and unhelpfully.
	**/
	public function testASuccessWithoutAnAddressIsReported():Void {
		if (unsupported()) return;

		var server = new FakeStunServer();
		var answer = new Outcome();

		try {
			server.omitAddress = true;
			server.start();

			StunClient.discover("127.0.0.1", server.port, 6000).then(answer.succeed, answer.fail);
			pumpUntil(answer.settled, 8.0);

			Assert.isNull(answer.address, "a reply with no address produced one anyway");
			Assert.notNull(answer.error, "a reply with no address left the query outstanding");

			if (answer.error == null) {
				return;
			}

			Assert.isTrue(answer.error.indexOf("mapped address") >= 0, "the failure should say what was missing: " + answer.error);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		server.close();
	}

	/**
		Somebody else's answer is not this question's answer.

		The socket is bound and anything at all can arrive on it. A reply is
		believed because its transaction matches the request, and that is the
		whole of what stops a third party who can reach the port from handing
		this host an address of their choosing -- which it would then advertise
		to peers as its own.

		The server sends a well-formed success with a transaction nobody asked
		for, immediately followed by the real one. Taking the first would be a
		silent and complete compromise of the answer.
	**/
	public function testAStrangersAnswerIsNotBelieved():Void {
		if (unsupported()) return;

		var server = new FakeStunServer();
		var answer = new Outcome();

		try {
			server.forgeFirst = true;
			server.start();

			StunClient.discover("127.0.0.1", server.port, 6000).then(answer.succeed, answer.fail);
			pumpUntil(answer.settled, 8.0);

			Assert.isNull(answer.error, answer.error);
			Assert.notNull(answer.address, "the real answer was refused along with the forged one");

			if (answer.address == null) {
				return;
			}

			Assert.equals(REPORTED_ADDRESS, answer.address.address);
			Assert.notEquals(FakeStunServer.FORGED_ADDRESS, answer.address.address);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		server.close();
	}

	/** There is nothing to ask without a server to ask. **/
	public function testAServerAddressIsRequired():Void {
		if (unsupported()) return;

		var answer = new Outcome();
		StunClient.discover("", 3478, 1000).then(answer.succeed, answer.fail);

		// Refused before anything is bound or sent, so there is nothing to wait
		// for: a query with no server should not cost a deadline to find out.
		Assert.isTrue(answer.settled(), "a query with no server was left outstanding");
		Assert.isNull(answer.address);

		if (answer.error != null) {
			Assert.isTrue(answer.error.indexOf("required") >= 0, "the failure should name what is missing: " + answer.error);
		}
	}

	// ------------------------------------------------------------------

	private function unsupported():Bool {
		if (!StunClient.isSupported) {
			Assert.isFalse(StunClient.isSupported);
			return true;
		}

		return false;
	}

	/**
		Drives the runtime until something settles.

		utest's own asynchrony is not enough here. Nothing pumps the runtime
		while a fixture waits, so a future needing a datagram to come back never
		resolves -- and the runner exits having reported nothing at all, which
		is how these cases first ran: silently, and completely.
		`DatagramSocketTest` pumps for the same reason.
	**/
	private static function pumpUntil(done:Void->Bool, timeout:Float):Void {
		var runtime = CrossByte.current();
		var deadline = Sys.time() + timeout;

		while (!done() && Sys.time() < deadline) {
			runtime.pump(1 / 60, 0);
			Sys.sleep(0.001);
		}
	}
}

/** Whichever way a query went, and whether it went either way yet. **/
private class Outcome {
	public var address:ReflexiveAddress;
	public var error:String;

	private var __settled:Bool = false;

	public function new() {}

	public function succeed(value:ReflexiveAddress):Void {
		address = value;
		__settled = true;
	}

	public function fail(reason:String):Void {
		error = reason;
		__settled = true;
	}

	public function settled():Bool {
		return __settled;
	}
}

/**
	A STUN server on loopback that can be told to misbehave.

	Bytes in and bytes out through `DatagramSocket`, so it stands wherever
	`StunClient` runs rather than only where the WebRTC stack does.
**/
private class FakeStunServer {
	/** The address a forged reply would hand over, if one were believed. **/
	public static inline var FORGED_ADDRESS:String = "192.0.2.66";

	public var port(default, null):Int = 0;

	/** How many requests to drop before answering any. **/
	public var ignoreFirst:Int = 0;

	public var ignoreEverything:Bool = false;

	/** Answer with an error rather than an address. **/
	public var refuse:Bool = false;

	/** Answer with a success that carries no mapped address. **/
	public var omitAddress:Bool = false;

	/** Send a well-formed answer to a question nobody asked, first. **/
	public var forgeFirst:Bool = false;

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

		if (forgeFirst) {
			// A transaction of its own, so this is a complete and well-formed
			// answer to a question this client never asked.
			var forged = new StunMessage(StunMessage.BINDING_SUCCESS, StunMessage.bindingRequest().transactionId,
				[StunMessage.xorMappedAddress(FORGED_ADDRESS, 9999)]);
			__send(forged, e.srcAddress, e.srcPort);
		}

		var reply = refuse ? new StunMessage(StunMessage.BINDING_ERROR, request.transactionId,
			[StunMessage.errorCode(400, "Bad Request")]) : new StunMessage(StunMessage.BINDING_SUCCESS, request.transactionId,
			omitAddress ? [] : [StunMessage.xorMappedAddress(StunClientTest.REPORTED_ADDRESS, StunClientTest.REPORTED_PORT)]);

		__send(reply, e.srcAddress, e.srcPort);
	}

	private function __send(message:StunMessage, address:String, port:Int):Void {
		if (__socket == null) {
			return;
		}

		var payload:ByteArray = message.encode();
		__socket.send(payload, 0, payload.length, address, port);
	}
}
