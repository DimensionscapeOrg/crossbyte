package crossbyte.net;

import crossbyte.core.CrossByte;
import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.io.ByteArray;
import crossbyte.net._internal.stun.StunMessage;
import crossbyte.net._internal.stun.StunMessage.StunAttribute;
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

	/**
		A timeout of 0 sets no deadline, as it does for a connection: the
		question is still being asked past the three seconds 0 used to mean.
		Closing the socket it is asked through ends it at once -- it ended
		only at the next ask, whose send failed, and with no deadline the
		gaps double out of reach.
	**/
	public function testATimeoutOfZeroAsksUntilItsSocketCloses():Void {
		if (unsupported()) return;

		var server = new FakeStunServer();
		var answer = new Outcome();
		var socket = new DatagramSocket();

		try {
			server.ignoreEverything = true;
			server.start();
			socket.bind(0, "127.0.0.1");

			StunClient.discover("127.0.0.1", server.port, 0, socket).then(answer.succeed, answer.fail);
			// Past the three seconds 0 meant, and the fourth ask, at 3.5 s.
			pumpUntil(answer.settled, 4.0);

			Assert.isFalse(answer.settled(), "a question with no deadline was given up: " + answer.error);
			Assert.isTrue(server.received >= 4, "the question stopped being asked, after " + server.received);

			var closedAt:Float = haxe.Timer.stamp();
			socket.close();
			pumpUntil(answer.settled, 2.0);
			Assert.notNull(answer.error, "closing the socket did not end a question with no deadline");
			Assert.isTrue(haxe.Timer.stamp() - closedAt < 1.0, "the question outlived its socket by " + (haxe.Timer.stamp() - closedAt) + " s");
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try socket.close() catch (_:Dynamic) {}
		server.close();
	}

	/**
		Classifying filtering needs a deadline -- a filtering NAT answers with
		silence -- so a timeout of 0, which is none, fails at once, saying so,
		rather than waiting out such a NAT for good.
	**/
	public function testClassifyingFilteringWithNoDeadlineFailsAtOnce():Void {
		if (unsupported()) return;

		var answer:String = null;
		var cause:Dynamic = null;
		var future = StunClient.classifyFiltering("127.0.0.1", 3478, 0);
		future.then(_ -> {}, function(error:String) {
			answer = error;
			cause = future.cause;
		});

		Assert.notNull(answer, "a filtering test with no deadline did not fail at once");
		Assert.isTrue(Std.isOfType(cause, crossbyte.errors.ArgumentError), "its cause is not an ArgumentError: " + cause);
	}

	/**
		A server name that does not resolve fails the question at once. Names
		are looked up off the runtime's thread now, so the failure arrives as
		the socket's ioError after the send returns -- and nothing listened
		for it, so the question sat out its whole deadline.
	**/
	public function testANameThatDoesNotResolveFailsAtOnce():Void {
		if (unsupported()) return;

		var answer = new Outcome();
		// .invalid never resolves (RFC 2606). The deadline is long enough
		// that reaching it cannot pass for failing at once.
		var started:Float = haxe.Timer.stamp();
		StunClient.discover("stun.nowhere.invalid", 3478, 20000).then(answer.succeed, answer.fail);
		pumpUntil(answer.settled, 12.0);
		var took:Float = haxe.Timer.stamp() - started;

		Assert.notNull(answer.error, 'still waiting after ${Math.round(took)} s for a name that cannot resolve');
		if (answer.error != null) {
			Assert.isTrue(answer.error.indexOf("stun.nowhere.invalid") >= 0, "the failure should name the server: " + answer.error);
		}
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

	/**
		A damaged answer is not believed, and the sound one behind it is.

		The damaged one carries this question's transaction and an address of
		its own, and a FINGERPRINT that does not match -- which RFC 8489 has a
		client drop. It was taken, so whatever a mangled datagram now said was
		this host's address.
	**/
	public function testAnAnswerWithABadFingerprintIsNotBelieved():Void {
		if (unsupported()) return;

		var server = new FakeStunServer();
		var answer = new Outcome();

		try {
			server.badFingerprintFirst = true;
			server.start();

			StunClient.discover("127.0.0.1", server.port, 6000).then(answer.succeed, answer.fail);
			pumpUntil(answer.settled, 8.0);

			Assert.isNull(answer.error, answer.error);
			Assert.notNull(answer.address, "no answer at all");

			if (answer.address != null) {
				Assert.equals(REPORTED_ADDRESS, answer.address.address, "the answer with a bad FINGERPRINT was believed");
			}
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		server.close();
	}

	/**
		Answers that only ever come damaged are reported as damaged. Silence
		and a path that mangles every answer are different faults to go
		looking for, and the deadline's message used to name only the first.
	**/
	public function testAnswersThatOnlyComeDamagedAreSaidToBe():Void {
		if (unsupported()) return;

		var server = new FakeStunServer();
		var answer = new Outcome();

		try {
			server.badFingerprintFirst = true;
			server.onlyDamaged = true;
			server.start();

			StunClient.discover("127.0.0.1", server.port, 1200).then(answer.succeed, answer.fail);
			pumpUntil(answer.settled, 4.0);

			Assert.isNull(answer.address, "a damaged answer was believed");

			if (answer.error != null) {
				Assert.isTrue(answer.error.indexOf("FINGERPRINT") >= 0, "the failure should say the answers came damaged: " + answer.error);
			} else {
				Assert.fail("never settled");
			}
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		server.close();
	}

	/**
		An answer requiring an attribute this client does not understand is
		reported, not used. It was used, and the attribute -- whatever it
		changed about the answer -- ignored.
	**/
	public function testAnAnswerRequiringAnUnknownAttributeIsNotUsed():Void {
		if (unsupported()) return;

		var server = new FakeStunServer();
		var answer = new Outcome();

		try {
			server.unknownAttribute = true;
			server.start();

			StunClient.discover("127.0.0.1", server.port, 6000).then(answer.succeed, answer.fail);
			pumpUntil(answer.settled, 8.0);

			Assert.isNull(answer.address, "an answer that cannot be understood was used");
			Assert.notNull(answer.error, "the question was left outstanding");

			if (answer.error != null) {
				Assert.isTrue(answer.error.indexOf("7FAA") >= 0, "the failure should name the attribute: " + answer.error);
			}
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		server.close();
	}

	/** An IPv6 address comes back as one, where it used to read as none. **/
	public function testAnIPv6AddressIsReturned():Void {
		if (unsupported()) return;

		var server = new FakeStunServer();
		var answer = new Outcome();

		try {
			server.answerIPv6 = true;
			server.start();

			StunClient.discover("127.0.0.1", server.port, 6000).then(answer.succeed, answer.fail);
			pumpUntil(answer.settled, 8.0);

			Assert.isNull(answer.error, answer.error);

			if (answer.address != null) {
				Assert.equals(FakeStunServer.REPORTED_IPV6, answer.address.address);
				Assert.equals(REPORTED_PORT, answer.address.port);
				// Bracketed: unbracketed, the port reads as the address's last group.
				Assert.equals("[" + FakeStunServer.REPORTED_IPV6 + "]:" + REPORTED_PORT, answer.address.toString());
			} else {
				Assert.fail("no address");
			}
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		server.close();
	}

	/**
		Asked through one socket, two servers see one mapping -- the socket's.

		Each question used to bind a socket of its own, so it answered for a
		port nobody used, and two questions compared two mappings: through any
		NAT, and on loopback too, every comparison read as a symmetric NAT.
		The auditor's program printed exactly that.

		The servers report the source they see, so the answer is the socket's
		real port, and the socket is left as it was found: open, and not
		receiving.
	**/
	public function testAskingThroughACallersSocketDescribesThatSocket():Void {
		if (unsupported()) return;

		var first = new FakeStunServer();
		var second = new FakeStunServer();
		var socket = new DatagramSocket();
		var fromFirst = new Outcome();
		var fromSecond = new Outcome();

		try {
			first.echo = true;
			second.echo = true;
			first.start();
			second.start();
			socket.bind(0, "127.0.0.1");

			StunClient.discover("127.0.0.1", first.port, 4000, socket).then(fromFirst.succeed, fromFirst.fail);
			pumpUntil(fromFirst.settled, 6.0);
			StunClient.discover("127.0.0.1", second.port, 4000, socket).then(fromSecond.succeed, fromSecond.fail);
			pumpUntil(fromSecond.settled, 6.0);

			Assert.isNull(fromFirst.error, fromFirst.error);
			Assert.isNull(fromSecond.error, fromSecond.error);

			if (fromFirst.address != null && fromSecond.address != null) {
				Assert.equals(socket.localPort, fromFirst.address.port, "the answer was not about the socket given");
				Assert.equals(fromFirst.address.toString(), fromSecond.address.toString(), "one socket read as two mappings");
			} else {
				Assert.fail("no answer");
			}

			Assert.isTrue(socket.bound, "the caller's socket was closed");
			Assert.isFalse(socket.receiving, "a socket that was not receiving was left receiving");
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		socket.close();
		first.close();
		second.close();
	}

	/**
		A socket already receiving keeps receiving, and keeps its own listener
		-- which hears the answer too, as it hears every datagram.
	**/
	public function testACallersListenerIsLeftInPlace():Void {
		if (unsupported()) return;

		var server = new FakeStunServer();
		var socket = new DatagramSocket();
		var answer = new Outcome();
		var heard:Int = 0;

		try {
			server.start();
			socket.bind(0, "127.0.0.1");
			socket.addEventListener(DatagramSocketDataEvent.DATA, function(_):Void {
				heard++;
			});
			socket.receive();

			StunClient.discover("127.0.0.1", server.port, 4000, socket).then(answer.succeed, answer.fail);
			pumpUntil(answer.settled, 6.0);

			Assert.isNull(answer.error, answer.error);
			Assert.isTrue(socket.receiving, "the caller's socket stopped receiving");
			Assert.isTrue(heard >= 1, "the caller's own listener was removed or never called");
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		socket.close();
		server.close();
	}

	/** A socket with no port, or with only one peer, cannot be asked through. **/
	public function testASocketThatCannotAskIsRefused():Void {
		if (unsupported()) return;

		var unbound = new DatagramSocket();
		var connected = new DatagramSocket();
		var fromUnbound = new Outcome();
		var fromConnected = new Outcome();

		try {
			StunClient.discover("127.0.0.1", 3478, 1000, unbound).then(fromUnbound.succeed, fromUnbound.fail);
			connected.bind(0, "127.0.0.1");
			connected.connect("127.0.0.1", 9);
			StunClient.discover("127.0.0.1", 3478, 1000, connected).then(fromConnected.succeed, fromConnected.fail);

			Assert.isTrue(fromUnbound.settled() && fromConnected.settled(), "refused later rather than at once");

			if (fromUnbound.error != null) {
				Assert.isTrue(fromUnbound.error.indexOf("not bound") >= 0, fromUnbound.error);
			} else {
				Assert.fail("an unbound socket was asked through");
			}

			if (fromConnected.error != null) {
				Assert.isTrue(fromConnected.error.indexOf("connected") >= 0, fromConnected.error);
			} else {
				Assert.fail("a connected socket was asked through");
			}
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		unbound.close();
		connected.close();
	}

	/**
		A probe reports where the answer came from and what the server says of
		itself: asked to change both, it answers from its other address and
		port, and says so.
	**/
	public function testAProbeSaysWhereTheServerAnsweredFrom():Void {
		if (unsupported()) return;

		var server = new FakeRfc5780Server();
		var socket = new DatagramSocket();
		var probe:Null<StunProbe> = null;
		var error:Null<String> = null;

		try {
			server.start();
			socket.bind(0, "127.0.0.1");

			StunClient.probe("127.0.0.1", server.primaryPort, 4000, socket, true, true).then(function(p) probe = p, function(e) error = e);
			pumpUntil(() -> probe != null || error != null, 6.0);

			Assert.isNull(error, error);

			if (probe != null) {
				var alternate = FakeRfc5780Server.ALTERNATE + ":" + server.alternatePort;
				Assert.equals(alternate, probe.from.toString(), "the answer did not come from the other address and port");
				Assert.equals(alternate, Std.string(probe.otherAddress));
				Assert.equals(alternate, Std.string(probe.responseOrigin));
				Assert.equals("127.0.0.1:" + socket.localPort, probe.mapped.toString());
			} else {
				Assert.fail("no probe");
			}
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		socket.close();
		server.close();
	}

	/**
		RFC 5780's mapping tests tell the three behaviours apart.

		The server models a NAT by what it reports, since loopback has none:
		one mapping for every destination, one per destination address, and
		one per address and port. And with no model at all it reports what it
		sees, which is loopback's truth -- no NAT, endpoint-independent --
		through a socket of the classification's own, the path whose separate
		sockets used to make every NAT look symmetric.
	**/
	public function testMappingIsClassified():Void {
		if (unsupported()) return;

		Assert.equals("ENDPOINT_INDEPENDENT", classify(true, null, ENDPOINT_INDEPENDENT, false), "no NAT, own socket");
		Assert.equals("ENDPOINT_INDEPENDENT", classify(true, ENDPOINT_INDEPENDENT, ENDPOINT_INDEPENDENT, true));
		Assert.equals("ADDRESS_DEPENDENT", classify(true, ADDRESS_DEPENDENT, ENDPOINT_INDEPENDENT, true));
		Assert.equals("ADDRESS_AND_PORT_DEPENDENT", classify(true, ADDRESS_AND_PORT_DEPENDENT, ENDPOINT_INDEPENDENT, true));
	}

	/**
		RFC 5780's filtering tests tell the three behaviours apart. What a
		filtering NAT does is drop the answer, so the model's server does not
		send what the NAT would not let in, and the classification has to wait
		out a deadline to see it.
	**/
	public function testFilteringIsClassified():Void {
		if (unsupported()) return;

		Assert.equals("ENDPOINT_INDEPENDENT", classify(false, null, ENDPOINT_INDEPENDENT, false), "no NAT, own socket");
		Assert.equals("ADDRESS_DEPENDENT", classify(false, null, ADDRESS_DEPENDENT, true));
		Assert.equals("ADDRESS_AND_PORT_DEPENDENT", classify(false, null, ADDRESS_AND_PORT_DEPENDENT, true));
	}

	/** A server with no second address says why it cannot classify. **/
	public function testAServerWithoutAnOtherAddressCannotClassify():Void {
		if (unsupported()) return;

		var server = new FakeRfc5780Server();
		var result:Null<NatBehavior> = null;
		var error:Null<String> = null;

		try {
			server.omitOtherAddress = true;
			server.start();

			StunClient.classifyMapping("127.0.0.1", server.primaryPort, 2000).then(function(b) result = b, function(e) error = e);
			pumpUntil(() -> result != null || error != null, 5.0);

			Assert.isNull(result, "classified through a server that cannot answer from a second address");

			if (error != null) {
				Assert.isTrue(error.indexOf("OTHER-ADDRESS") >= 0, error);
			} else {
				Assert.fail("never settled");
			}
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		server.close();
	}

	/**
		A server that ignores CHANGE-REQUEST is caught, rather than read as a
		NAT letting everything in -- which its answer from where it was asked
		would otherwise look exactly like.
	**/
	public function testAServerIgnoringChangeRequestIsCaught():Void {
		if (unsupported()) return;

		var server = new FakeRfc5780Server();
		var result:Null<NatBehavior> = null;
		var error:Null<String> = null;

		try {
			server.ignoreChangeRequest = true;
			server.start();

			StunClient.classifyFiltering("127.0.0.1", server.primaryPort, 2000).then(function(b) result = b, function(e) error = e);
			pumpUntil(() -> result != null || error != null, 5.0);

			Assert.isNull(result, "classified filtering through a server that never changed where it answered from");

			if (error != null) {
				Assert.isTrue(error.indexOf("CHANGE-REQUEST") >= 0, error);
			} else {
				Assert.fail("never settled");
			}
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		server.close();
	}

	// ------------------------------------------------------------------

	/**
		Runs a classification against a server modelling `mapping` and
		`filtering`, and names what it found or why it failed.
	**/
	private static function classify(mappingTest:Bool, mapping:Null<NatBehavior>, filtering:NatBehavior, callersSocket:Bool):String {
		var server = new FakeRfc5780Server();
		var socket:Null<DatagramSocket> = null;
		var result:Null<NatBehavior> = null;
		var error:Null<String> = null;

		try {
			server.mapping = mapping;
			server.filtering = filtering;
			server.start();

			if (callersSocket) {
				socket = new DatagramSocket();
				socket.bind(0, "127.0.0.1");
			}

			// Short, since a filtering NAT is seen only by waiting one out.
			var question = mappingTest ? StunClient.classifyMapping("127.0.0.1", server.primaryPort, 700,
				socket) : StunClient.classifyFiltering("127.0.0.1", server.primaryPort, 700, socket);
			question.then(function(b) result = b, function(e) error = e);
			pumpUntil(() -> result != null || error != null, 6.0);
		} catch (e:Dynamic) {
			error = Std.string(e);
		}

		if (socket != null) {
			socket.close();
		}

		server.close();
		return result != null ? Std.string(result) : "failed: " + error;
	}

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
		var deadline = haxe.Timer.stamp() + timeout;

		while (!done() && haxe.Timer.stamp() < deadline) {
			runtime.pump(1 / 60, 0);
			crossbyte.sys.System.sleep(0.001);
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

	/** An IPv6 address to report, for `answerIPv6`. **/
	public static inline var REPORTED_IPV6:String = "2001:db8::42";

	/** Report the source the request came from, as a real server does, rather than a made-up one. **/
	public var echo:Bool = false;

	/** Send this question's answer with a forged address and a FINGERPRINT that does not match, first. **/
	public var badFingerprintFirst:Bool = false;

	/** Send nothing but the damaged answer. **/
	public var onlyDamaged:Bool = false;

	/** Answer with a comprehension-required attribute, 0x7FAA, that nothing defines. **/
	public var unknownAttribute:Bool = false;

	/** Report an IPv6 address. **/
	public var answerIPv6:Bool = false;

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

		if (badFingerprintFirst) {
			// This question's own transaction, so only the FINGERPRINT gives
			// it away.
			var damaged = new StunMessage(StunMessage.BINDING_SUCCESS, request.transactionId,
				[StunMessage.xorMappedAddress(FORGED_ADDRESS, 9999)]);
			var bytes:ByteArray = damaged.encode();
			@:privateAccess damaged.__appendFingerprint(bytes);
			bytes[bytes.length - 1] = bytes[bytes.length - 1] ^ 0x01;
			bytes.position = 0;
			__sendBytes(bytes, e.srcAddress, e.srcPort);

			if (onlyDamaged) {
				return;
			}
		}

		var attributes:Array<StunAttribute> = [];

		if (!omitAddress) {
			if (answerIPv6) {
				attributes.push(StunMessage.xorMappedAddress(REPORTED_IPV6, StunClientTest.REPORTED_PORT, request.transactionId));
			} else if (echo) {
				attributes.push(StunMessage.xorMappedAddress(e.srcAddress, e.srcPort));
			} else {
				attributes.push(StunMessage.xorMappedAddress(StunClientTest.REPORTED_ADDRESS, StunClientTest.REPORTED_PORT));
			}
		}

		if (unknownAttribute) {
			var value = new ByteArray();
			value.writeInt(0);
			value.position = 0;
			attributes.push(new StunAttribute(0x7FAA, value));
		}

		var reply = refuse ? new StunMessage(StunMessage.BINDING_ERROR, request.transactionId,
			[StunMessage.errorCode(400, "Bad Request")]) : new StunMessage(StunMessage.BINDING_SUCCESS, request.transactionId, attributes);

		__send(reply, e.srcAddress, e.srcPort);
	}

	private function __send(message:StunMessage, address:String, port:Int):Void {
		__sendBytes(message.encode(), address, port);
	}

	private function __sendBytes(payload:ByteArray, address:String, port:Int):Void {
		if (__socket == null) {
			return;
		}

		__socket.send(payload, 0, payload.length, address, port);
	}
}

/**
	An RFC 5780 server on loopback: two addresses, 127.0.0.1 and 127.0.0.2,
	each on the same two ports, answering from whichever a CHANGE-REQUEST
	asks for and saying where the others are.

	Loopback has no NAT, so the server can be told to model one: to report
	the mapping a NAT of some behaviour would have made, and not to send an
	answer that NAT would have filtered. With no model it reports the source
	it sees, which is the truth about loopback.
**/
private class FakeRfc5780Server {
	public static inline var PRIMARY:String = "127.0.0.1";
	public static inline var ALTERNATE:String = "127.0.0.2";

	public var primaryPort(default, null):Int = 0;
	public var alternatePort(default, null):Int = 0;

	/** The mapping behaviour to model, or null for none: the source reported as seen. **/
	public var mapping:Null<NatBehavior> = null;

	/** Which answers the modelled NAT lets back in. **/
	public var filtering:NatBehavior = ENDPOINT_INDEPENDENT;

	/** Answer from where asked, whatever a CHANGE-REQUEST says. **/
	public var ignoreChangeRequest:Bool = false;

	/** Leave OTHER-ADDRESS out, as a server with one address does. **/
	public var omitOtherAddress:Bool = false;

	/** One socket per address and port: index = address * 2 + port. **/
	private var __sockets:Array<DatagramSocket> = [];

	/** Where the modelled NAT has seen its client send: addresses, and address:port pairs. **/
	private var __sentTo:Map<String, Bool> = new Map();

	public function new() {}

	/**
		Binds all four. The second address has to take the ports the system
		gave the first, which something else may hold there, so a clash is
		tried again with fresh ports rather than assumed away.
	**/
	public function start():Void {
		var last:String = null;

		for (_ in 0...20) {
			try {
				var a = __open(PRIMARY, 0);
				__sockets.push(a);
				var b = __open(PRIMARY, 0);
				__sockets.push(b);
				var c = __open(ALTERNATE, a.localPort);
				__sockets.push(c);
				var d = __open(ALTERNATE, b.localPort);
				__sockets.push(d);
				primaryPort = a.localPort;
				alternatePort = b.localPort;

				for (i in 0...4) {
					__listen(i);
				}

				return;
			} catch (e:Dynamic) {
				last = Std.string(e);
				close();
			}
		}

		throw "could not bind " + PRIMARY + " and " + ALTERNATE + " on a shared pair of ports: " + last;
	}

	public function close():Void {
		for (socket in __sockets) {
			try {
				socket.close();
			} catch (_:Dynamic) {}
		}

		__sockets = [];
	}

	private function __open(address:String, port:Int):DatagramSocket {
		var socket = new DatagramSocket();

		try {
			socket.bind(port, address);
		} catch (e:Dynamic) {
			try {
				socket.close();
			} catch (_:Dynamic) {}
			throw e;
		}

		return socket;
	}

	private function __listen(index:Int):Void {
		var socket = __sockets[index];
		socket.addEventListener(DatagramSocketDataEvent.DATA, function(e:DatagramSocketDataEvent):Void {
			__onDatagram(index, e);
		});
		socket.receive();
	}

	private inline function __address(index:Int):String {
		return (index >> 1) == 0 ? PRIMARY : ALTERNATE;
	}

	private inline function __port(index:Int):Int {
		return (index & 1) == 0 ? primaryPort : alternatePort;
	}

	private function __onDatagram(index:Int, e:DatagramSocketDataEvent):Void {
		var request = StunMessage.decode(e.data);

		if (request == null || request.type != StunMessage.BINDING_REQUEST) {
			return;
		}

		// The modelled NAT has now seen its client send here.
		__sentTo.set(__address(index), true);
		__sentTo.set(__address(index) + ":" + __port(index), true);

		var flags:Int = 0;
		var change = request.attribute(StunMessage.ATTR_CHANGE_REQUEST);

		if (change != null && change.length >= 4) {
			change.position = 3;
			flags = change.readUnsignedByte();
		}

		var from:Int = index;

		if (!ignoreChangeRequest) {
			var address:Int = (index >> 1) ^ ((flags & 0x04) != 0 ? 1 : 0);
			var port:Int = (index & 1) ^ ((flags & 0x02) != 0 ? 1 : 0);
			from = (address << 1) | port;
		}

		var letIn:Bool = switch (filtering) {
			case ENDPOINT_INDEPENDENT: true;
			case ADDRESS_DEPENDENT: __sentTo.exists(__address(from));
			case ADDRESS_AND_PORT_DEPENDENT: __sentTo.exists(__address(from) + ":" + __port(from));
		}

		if (!letIn) {
			return;
		}

		var mapped:StunAttribute = switch (mapping) {
			case null: StunMessage.xorMappedAddress(e.srcAddress, e.srcPort);
			case ENDPOINT_INDEPENDENT: StunMessage.xorMappedAddress(StunClientTest.REPORTED_ADDRESS, 40000);
			case ADDRESS_DEPENDENT: StunMessage.xorMappedAddress(StunClientTest.REPORTED_ADDRESS, 40000 + (index >> 1));
			case ADDRESS_AND_PORT_DEPENDENT: StunMessage.xorMappedAddress(StunClientTest.REPORTED_ADDRESS, 40000 + index);
		}

		// OTHER-ADDRESS is the other of both, from wherever it was asked.
		var other:Int = index ^ 3;
		var attributes:Array<StunAttribute> = [mapped];

		if (!omitOtherAddress) {
			attributes.push(StunMessage.plainAddress(StunMessage.ATTR_OTHER_ADDRESS, __address(other), __port(other)));
		}

		attributes.push(StunMessage.plainAddress(StunMessage.ATTR_RESPONSE_ORIGIN, __address(from), __port(from)));

		var payload:ByteArray = new StunMessage(StunMessage.BINDING_SUCCESS, request.transactionId, attributes).encode();
		__sockets[from].send(payload, 0, payload.length, e.srcAddress, e.srcPort);
	}
}
