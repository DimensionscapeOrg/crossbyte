package crossbyte.net.rtc;

import crossbyte.core.CrossByte;
import crossbyte.errors.ArgumentError;
import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.io.ByteArray;
import crossbyte.net.DatagramSocket;
import crossbyte.net.ice.IceAgent;
import crossbyte.net.ice.IceCandidate;
import crossbyte.net.ice.IceCredentials;
import utest.Assert;

/**
	The whole stack over real sockets: ICE finds the path, DTLS encrypts it,
	SCTP carries it, DCEP names the channels, and a message crosses.

	Every layer below has its own tests against a harness that can be made to
	misbehave, which is where the protocol properties are proven. What this
	proves is the assembly: that the layers share one socket without taking each
	other's traffic, that they are driven from one clock, and that a caller who
	only ever sees `PeerConnection` and `DataChannel` gets a working connection
	out of the pieces.

	Loopback, so nothing here crosses a NAT, the punching was proven where a
	fake network could be built. This is the plumbing test, and the closest an
	automated suite can get to the browser test that still waits on a browser.
**/
class PeerConnectionTest extends utest.Test {
	private function unsupported():Bool {
		if (!PeerConnection.isSupported) {
			Assert.isFalse(PeerConnection.isSupported);
			return true;
		}

		return false;
	}

	/**
		Two peers, a channel, and a message each way. The point of everything.
	**/
	public function testTwoPeersConnectAndTalk():Void {
		if (unsupported()) return;

		var alice = new PeerConnection(true);
		var bob = new PeerConnection(false);

		var accepted:DataChannel = null;
		var heardByBob:String = null;
		var heardByAlice:String = null;

		try {
			bob.onChannel = function(channel:DataChannel):Void {
				accepted = channel;
				channel.onMessage = text -> heardByBob = text;
			};

			alice.bind(0, "127.0.0.1");
			bob.bind(0, "127.0.0.1");

			// The signalling exchange, played by the test: each description
			// crosses to the other side the way an application would carry it.
			alice.connect(bob.description());
			bob.connect(alice.description());

			pumpUntil(() -> alice.connected && bob.connected, 15.0);

			Assert.isTrue(alice.connected, "the controlling peer never became ready");
			Assert.isTrue(bob.connected, "the controlled peer never became ready");

			if (!alice.connected || !bob.connected) {
				return;
			}

			var chat = alice.createDataChannel("chat");
			pumpUntil(() -> chat.open && accepted != null, 5.0);

			Assert.isTrue(chat.open, "the channel was never acknowledged");
			Assert.notNull(accepted, "the peer never saw the channel");

			if (!chat.open || accepted == null) {
				return;
			}

			Assert.equals("chat", accepted.label);

			chat.send("across the whole stack");
			pumpUntil(() -> heardByBob != null, 5.0);
			Assert.equals("across the whole stack", heardByBob, "a message did not survive the full stack");

			// And back, because a connection that only works one way is a bug
			// that a one-directional test blesses.
			chat.onMessage = text -> heardByAlice = text;
			accepted.send("and back again");
			pumpUntil(() -> heardByAlice != null, 5.0);
			Assert.equals("and back again", heardByAlice, "the return direction did not work");
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		alice.close();
		bob.close();
	}

	/**
		A peer that closes its connection is heard at once, and so are the
		channels on it.

		`close()` sent nothing, and an ABORT or close_notify arriving from the
		peer was swallowed below this class, there was no event to deliver
		it to. So a departed peer was noticed, if at all, by ICE consent thirty
		seconds later, with channels reporting themselves open the whole time.
		The five seconds allowed here are a sixth of that.
	**/
	public function testAPeerThatClosesIsReportedAtOnce():Void {
		if (unsupported()) return;

		var alice = new PeerConnection(true);
		var bob = new PeerConnection(false);
		var accepted:DataChannel = null;

		try {
			bob.onChannel = channel -> accepted = channel;

			alice.bind(0, "127.0.0.1");
			bob.bind(0, "127.0.0.1");
			alice.connect(bob.description());
			bob.connect(alice.description());

			pumpUntil(() -> alice.connected && bob.connected, 15.0);

			if (!alice.connected || !bob.connected) {
				Assert.fail("the two never connected, so there is no departure to report");
				alice.close();
				bob.close();
				return;
			}

			var chat = alice.createDataChannel("chat");
			pumpUntil(() -> chat.open && accepted != null, 5.0);

			if (!chat.open || accepted == null) {
				Assert.fail("the channel never opened");
				alice.close();
				bob.close();
				return;
			}

			var reasons:Array<String> = [];
			var settled:String = null;
			var channelCloses:Int = 0;

			alice.onClose = reason -> reasons.push(reason);
			alice.closed.then(reason -> settled = reason);
			chat.onClose = () -> channelCloses++;

			bob.close();
			pumpUntil(() -> reasons.length > 0, 5.0);

			Assert.equals(1, reasons.length, "a peer that closed its connection was reported " + reasons.length + " times");
			Assert.isFalse(alice.connected, "the connection still reports itself up after the peer closed it");
			Assert.isFalse(chat.open, "a channel on a connection the peer closed still reports itself open");
			Assert.equals(1, channelCloses, "the channel's onClose ran " + channelCloses + " times");

			if (reasons.length > 0) {
				// The ABORT is inside the session and goes first, so it is what
				// is heard; the close_notify behind it finds the door shut.
				Assert.isTrue(reasons[0].indexOf("aborted") >= 0, "the reason does not say the peer left: " + reasons[0]);
				Assert.equals(reasons[0], settled, "`closed` and `onClose` disagree about why");
				Assert.equals(reasons[0], alice.closeReason);
			}
		} catch (e:Dynamic) {
			Assert.fail("unexpected: " + Std.string(e));
		}

		alice.close();
		bob.close();
	}

	/**
		A peer whose DTLS session ends is heard even with no ABORT before it.

		The close_notify on its own, as a peer that tears down the session
		without the association inside it sends it, and a fatal alert takes
		the same path.
	**/
	public function testAPeerThatEndsOnlyItsDtlsSessionIsReported():Void {
		if (unsupported()) return;

		var alice = new PeerConnection(true);
		var bob = new PeerConnection(false);

		try {
			alice.bind(0, "127.0.0.1");
			bob.bind(0, "127.0.0.1");
			alice.connect(bob.description());
			bob.connect(alice.description());

			pumpUntil(() -> alice.connected && bob.connected, 15.0);

			if (!alice.connected || !bob.connected) {
				Assert.fail("the two never connected");
				alice.close();
				bob.close();
				return;
			}

			var reasons:Array<String> = [];
			alice.onClose = reason -> reasons.push(reason);

			// Just the session, and nothing inside it.
			@:privateAccess bob.__dtls.close();
			pumpUntil(() -> reasons.length > 0, 5.0);

			Assert.equals(1, reasons.length, "a close_notify on its own was not reported");
			Assert.isFalse(alice.connected);

			if (reasons.length > 0) {
				Assert.isTrue(reasons[0].indexOf("DTLS") >= 0, "the reason does not name the layer that ended: " + reasons[0]);
			}
		} catch (e:Dynamic) {
			Assert.fail("unexpected: " + Std.string(e));
		}

		alice.close();
		bob.close();
	}

	/**
		Closing closes the channels, settles what was waiting, and says why.

		`close()` left every channel open with `onClose` never run, and a
		channel still waiting for its acknowledgement left `opened` pending,
		an application had to walk its own list of channels and close each by
		hand to find out it was finished with them.
	**/
	public function testClosingClosesEveryChannel():Void {
		if (unsupported()) return;

		var alice = new PeerConnection(true);
		var bob = new PeerConnection(false);

		try {
			alice.bind(0, "127.0.0.1");
			bob.bind(0, "127.0.0.1");
			alice.connect(bob.description());
			bob.connect(alice.description());

			pumpUntil(() -> alice.connected && bob.connected, 15.0);

			if (!alice.connected || !bob.connected) {
				Assert.fail("the two never connected");
				alice.close();
				bob.close();
				return;
			}

			var chat = alice.createDataChannel("chat");
			pumpUntil(() -> chat.open, 5.0);

			// Created and closed before the peer can have answered.
			var late = alice.createDataChannel("late");
			var lateSettled:Bool = false;
			late.opened.then(_ -> lateSettled = true, _ -> lateSettled = true);

			var closes:Int = 0;
			var reasons:Array<String> = [];
			chat.onClose = () -> closes++;
			late.onClose = () -> closes++;
			alice.onClose = reason -> reasons.push(reason);

			alice.close();

			Assert.equals(2, closes, "closing the connection ran onClose for " + closes + " of its two channels");
			Assert.isFalse(chat.open);
			Assert.isTrue(lateSettled, "a channel still waiting for its acknowledgement left `opened` pending");
			Assert.equals(1, reasons.length, "closing was reported " + reasons.length + " times");

			// Once, whatever happens next.
			alice.close();
			Assert.equals(1, reasons.length);
		} catch (e:Dynamic) {
			Assert.fail("unexpected: " + Std.string(e));
		}

		alice.close();
		bob.close();
	}

	/**
		A connection that cannot finish coming up gives up, and says where.

		The peer here answers connectivity checks and then nothing: its
		description says it will open the DTLS handshake, and it never does.
		As the DTLS server this end waited for a ClientHello with no timer
		running, for as long as the process lived, which is exactly what a
		browser tab closed straight after ICE leaves behind, holding a socket,
		a tick listener and a TLS session.
	**/
	public function testAConnectionThatCannotFinishGivesUp():Void {
		if (unsupported()) return;

		var alice = new PeerConnection(true);
		var peer = new IceOnlyPeer();
		var failure:String = null;
		var closedWith:String = null;

		try {
			alice.ready.then(_ -> {}, error -> failure = error);
			alice.onClose = reason -> closedWith = reason;
			alice.readyTimeout = 2.0;

			alice.bind(0, "127.0.0.1");
			alice.connect(peer.description());
			peer.start(alice.description());

			pumpWith(peer, () -> failure != null, 10.0);

			Assert.notNull(failure, "a connection whose peer never opened the handshake never gave up");
			Assert.isTrue(alice.agent.state == crossbyte.net.ice.IceAgentState.CONNECTED || closedWith != null,
				"the path was never found, so this is not the case being tested");

			if (failure != null) {
				Assert.isTrue(failure.indexOf("ready within") >= 0, "the failure does not say the connection timed out: " + failure);
				Assert.isTrue(failure.indexOf("DTLS") >= 0, "the failure does not name the phase that did not finish: " + failure);
				Assert.equals(failure, closedWith, "`onClose` and `ready` disagree about why");
			}
		} catch (e:Dynamic) {
			Assert.fail("unexpected: " + Std.string(e));
		}

		alice.close();
		peer.close();
	}

	/**
		Consent lost before the connection is ready ends it.

		Consent was checked only once everything above ICE was up, so a peer
		that vanished during the DTLS handshake or the SCTP one was ignored,
		and neither of those would ever finish.
	**/
	public function testLosingConsentBeforeReadyEndsTheConnection():Void {
		if (unsupported()) return;

		var alice = new PeerConnection(true);
		var peer = new IceOnlyPeer();
		var failure:String = null;

		try {
			alice.ready.then(_ -> {}, error -> failure = error);

			// Well past the consent timeout, so that is what has to catch it.
			alice.readyTimeout = 1000.0;

			alice.bind(0, "127.0.0.1");
			alice.connect(peer.description());
			peer.start(alice.description());

			pumpWith(peer, () -> alice.agent.state == crossbyte.net.ice.IceAgentState.CONNECTED, 10.0);

			if (alice.agent.state != crossbyte.net.ice.IceAgentState.CONNECTED) {
				Assert.fail("the path was never found, so there is no consent to lose");
				alice.close();
				peer.close();
				return;
			}

			// The peer goes, mid-handshake.
			peer.close();
			alice.poll(haxe.Timer.stamp() + crossbyte.net.ice.IceAgent.CONSENT_TIMEOUT + 10.0);

			Assert.notNull(failure, "consent lost before the connection was ready was ignored");

			if (failure != null) {
				Assert.isTrue(failure.indexOf("consent") >= 0, "the failure does not say consent was lost: " + failure);
			}
		} catch (e:Dynamic) {
			Assert.fail("unexpected: " + Std.string(e));
		}

		alice.close();
		peer.close();
	}

	private static function pumpWith(peer:IceOnlyPeer, done:Void->Bool, timeout:Float):Void {
		var runtime = CrossByte.current();
		var deadline = haxe.Timer.stamp() + timeout;

		while (!done() && haxe.Timer.stamp() < deadline) {
			runtime.pump(1 / 60, 0);
			peer.poll(haxe.Timer.stamp());
			Sys.sleep(0.001);
		}
	}

	/**
		A peer that stops answering takes the connection down with it.

		The agent runs the consent timer (RFC 7675) and IceAgentTest covers it
		there. This is the other half: the agent giving up has to reach the
		layer that actually transmits, or the timer is a mechanism whose result
		nobody reads. `ready` resolved when the path came up, so a path that
		stops being one cannot be reported through it.
	**/
	public function testLosingConsentTakesTheConnectionDown():Void {
		if (unsupported()) return;

		var alice = new PeerConnection(true);
		var bob = new PeerConnection(false);

		try {
			alice.bind(0, "127.0.0.1");
			bob.bind(0, "127.0.0.1");

			alice.connect(bob.description());
			bob.connect(alice.description());

			pumpUntil(() -> alice.connected && bob.connected, 15.0);
			Assert.isTrue(alice.connected, "the two never connected, so there is no consent to lose");

			if (!alice.connected) {
				return;
			}

			var reasons:Array<String> = [];
			alice.onClose = reason -> reasons.push(reason);

			// Gone without saying so, which is the case consent exists for:
			// closed with the goodbyes kept from reaching alice.
			@:privateAccess bob.__socket.close();
			bob.close();

			// The same clock the runtime tick uses, moved past the thirty
			// seconds the RFC allows. Waiting it out in real time would put
			// half a minute into the suite for one assertion.
			alice.poll(haxe.Timer.stamp() + crossbyte.net.ice.IceAgent.CONSENT_TIMEOUT + 10.0);

			Assert.isFalse(alice.connected,
				"the peer stopped answering and this connection went on reporting itself up");

			// And said so, rather than leaving `connected` to be polled.
			Assert.equals(1, reasons.length, "losing consent was reported " + reasons.length + " times");

			if (reasons.length > 0) {
				Assert.isTrue(reasons[0].indexOf("consent") >= 0, "the reason does not say consent was lost: " + reasons[0]);
			}
		} catch (e:Dynamic) {
			Assert.fail("unexpected: " + Std.string(e));
		}

		alice.close();
	}

	/**
		The security capstone: a peer presenting a certificate that is not the
		one it signalled is refused, after a handshake that succeeded.

		Everything below works perfectly in this test, the path is found, the
		DTLS handshake completes, and the connection still must not come up,
		because the certificate is not the one signalling promised. This is the
		difference between a session encrypted against eavesdroppers and one
		encrypted against the wrong peer entirely.
	**/
	public function testAPeerWithTheWrongCertificateIsRefused():Void {
		if (unsupported()) return;

		var alice = new PeerConnection(true);
		var bob = new PeerConnection(false);
		var failure:String = null;

		try {
			alice.ready.then(_ -> {}, error -> failure = error);
			bob.ready.then(_ -> {}, _ -> {});

			alice.bind(0, "127.0.0.1");
			bob.bind(0, "127.0.0.1");

			// Bob's description, except the fingerprint names a certificate he
			// does not hold, which is what an attacker in the signalling path
			// cannot avoid: they can substitute a fingerprint, but then the
			// handshake presents a certificate that does not match it.
			var lied = bob.description();
			lied.fingerprint = DtlsCertificate.generate("impostor", 1).fingerprint;

			alice.connect(lied);
			bob.connect(alice.description());

			pumpUntil(() -> failure != null, 15.0);

			Assert.notNull(failure, "a certificate that was not the one signalled was accepted");
			Assert.isFalse(alice.connected, "the connection reported itself up against the wrong certificate");

			if (failure != null) {
				Assert.isTrue(failure.indexOf("fingerprint") >= 0, "the refusal does not say what was wrong: " + failure);
			}
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		alice.close();
		bob.close();
	}

	/**
		The two roles are separate, and a browser is what makes that visible.

		A browser offers, so it is ICE-controlling, and it offers `actpass`, so
		the peer answering it is ICE-controlled *and* the DTLS client at the same
		time. One bit cannot hold both.

		This drives the answering side exactly as the interop peer does and
		checks it lands on that combination. Before the roles were separated it
		took the ICE role for both, so it declined to send the ClientHello a
		browser was waiting for, and would have declined to open the SCTP
		association even if the handshake had somehow completed.
	**/
	public function testAnAnswererIsIceControlledAndTheDtlsClient():Void {
		if (unsupported()) return;

		var answerer = new PeerConnection(false);

		try {
			answerer.bind(0, "127.0.0.1");

			// An offer as a browser writes one: it is controlling, and it leaves
			// the DTLS role to the answer.
			answerer.connect({
				usernameFragment: "OfFr",
				password: "an-offerers-password-long-enough",
				fingerprint: "AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99",
				candidates: [],
				setup: "actpass"
			});

			Assert.isFalse(answerer.iceControlling, "the answerer should not be nominating");
			Assert.isTrue(answerer.dtlsClient, "the answerer takes the client role an actpass offer leaves it");

			// And it says so in its own description, since the offerer has to be
			// told which half was taken.
			Assert.equals("active", answerer.description().setup);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		answerer.close();
	}

	/**
		The offerer learns its DTLS role from the answer.

		It proposes `actpass` having no opinion, and an answer of `active` makes
		it the server. A peer that assumed the client role because it was
		ICE-controlling would send a ClientHello into another ClientHello.
	**/
	public function testAnOffererTakesWhateverTheAnswerLeavesIt():Void {
		if (unsupported()) return;

		var offerer = new PeerConnection(true);

		try {
			offerer.bind(0, "127.0.0.1");

			Assert.equals("actpass", offerer.description().setup, "an offer should leave the DTLS role open");
			Assert.isTrue(offerer.iceControlling);

			offerer.connect({
				usernameFragment: "AnSw",
				password: "an-answerers-password-long-enough",
				fingerprint: "AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99",
				candidates: [],
				setup: "active"
			});

			Assert.isFalse(offerer.dtlsClient, "the answer claimed the client role, so the offerer is the server");
			Assert.isTrue(offerer.iceControlling, "answering did not change who nominates");
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		offerer.close();
	}

	/**
		A description without a fingerprint is refused before anything is built.

		The alternative is a connection that is encrypted and unauthenticated,
		which looks secure in every way that does not matter.
	**/
	public function testADescriptionWithoutAFingerprintIsRefused():Void {
		if (unsupported()) return;

		var alice = new PeerConnection(true);
		var bob = new PeerConnection(false);

		try {
			alice.bind(0, "127.0.0.1");
			bob.bind(0, "127.0.0.1");

			var bare = bob.description();
			bare.fingerprint = "";

			Assert.raises(() -> alice.connect(bare), ArgumentError);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		alice.close();
		bob.close();
	}

	/**
		A description it cannot use is refused before the agent is touched.

		connect() added every candidate and then built the IceCredentials, which
		validates the fragment and the password. A description that failed that
		therefore threw halfway: the candidates were in, agent.start was never
		reached, and the connection was left configured for something that could
		never be started. Failing first costs nothing and leaves the object as it
		was, so a caller can try a corrected description on it.
	**/
	public function testADescriptionItCannotUseLeavesTheAgentAlone():Void {
		if (unsupported()) return;

		var alice = new PeerConnection(true);
		var bob = new PeerConnection(false);

		try {
			alice.bind(0, "127.0.0.1");
			bob.bind(0, "127.0.0.1");

			var description = bob.description();
			Assert.isTrue(description.candidates.length > 0, "bob offered no candidates, so this proves nothing");

			// Shorter than MIN_PASSWORD_LENGTH, so IceCredentials refuses it.
			description.password = "tooshort";

			var refused:Bool = false;
			try {
				alice.connect(description);
			} catch (_:ArgumentError) {
				refused = true;
			}

			Assert.isTrue(refused, "a description with an unusable password was accepted");
			Assert.equals(0, @:privateAccess alice.agent.__remotes.length,
				"the peer's candidates were added before connect() found it could not use the description");
		} catch (e:Dynamic) {
			Assert.fail("unexpected: " + Std.string(e));
		}

		alice.close();
		bob.close();
	}

	/**
		The description carries everything the peer needs and nothing secret.

		The ICE password crosses signalling by design, it authenticates checks
		on a path that does not exist yet, so it has nowhere else to go. The
		DTLS private key must not: it never leaves the machine, and a
		description that included it would be publishing the session's whole
		security to the signalling channel.
	**/
	public function testTheDescriptionCarriesNoPrivateKey():Void {
		if (unsupported()) return;

		var connection = new PeerConnection(true);

		try {
			connection.bind(0, "127.0.0.1");

			var description = connection.description();

			Assert.notNull(description.usernameFragment);
			Assert.notNull(description.password);
			Assert.equals(connection.certificate.fingerprint, description.fingerprint);
			Assert.isTrue(description.candidates.length > 0, "a bound connection should have a host candidate to offer");

			var serialised = haxe.Json.stringify(description);
			Assert.isFalse(serialised.indexOf("PRIVATE KEY") >= 0, "the private key is in the description");
			Assert.isFalse(serialised.indexOf(connection.certificate.privateKeyPem) >= 0);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		connection.close();
	}

	/**
		Channels are refused before the stack is up, in so many words.
	**/
	public function testChannelsCannotBeCreatedBeforeReady():Void {
		if (unsupported()) return;

		var connection = new PeerConnection(true);

		try {
			connection.bind(0, "127.0.0.1");
			Assert.raises(() -> connection.createDataChannel("early"), ArgumentError);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		connection.close();
	}

	private static function pumpUntil(done:Void->Bool, timeout:Float):Void {
		var runtime = CrossByte.current();
		var deadline = Sys.time() + timeout;

		while (!done() && Sys.time() < deadline) {
			runtime.pump(1 / 60, 0);
			Sys.sleep(0.001);
		}
	}

	/**
		Closing before the connection comes up tells whoever was waiting.

		close() settled the reflexive and relayed futures with a reason, and said
		why in a comment, leaving one forever pending is worse than saying what
		happened, and then left `ready` pending. Those two only exist when the
		caller asked for them, so the gap was invisible unless someone awaited the
		connection itself and then closed it, after which neither handler could
		ever run.
	**/
	public function testClosingBeforeReadyTellsWhoeverWasWaiting():Void {
		if (unsupported()) return;

		var connection = new PeerConnection(true);
		var resolved:Bool = false;
		var failure:String = null;

		connection.ready.then(_ -> resolved = true, error -> failure = error);
		connection.close();

		Assert.isFalse(resolved, "a connection that never came up reported itself ready");
		Assert.notNull(failure, "closing before the connection was ready left `ready` pending forever");
	}

	/**
		One unusable candidate does not abort the whole connection.

		The candidates come from the peer. Building each one validates its port
		and component, and the loop in connect() did not guard that, so a
		description carrying a single bad candidate threw part-way through:
		some candidates added, the rest dropped, and agent.start never reached.
		The connection could then never come up, and the throw surfaced in the
		application that merely relayed the description.
	**/
	public function testOneUnusableCandidateDoesNotAbortTheConnection():Void {
		if (unsupported()) return;

		var alice = new PeerConnection(true);
		var bob = new PeerConnection(false);

		try {
			alice.bind(0, "127.0.0.1");
			bob.bind(0, "127.0.0.1");

			var description = bob.description();
			var usable:Int = description.candidates.length;
			Assert.isTrue(usable > 0, "bob offered no candidates, so this proves nothing");

			// A port nothing can be dialled on, ahead of the good ones so that
			// aborting on it would take every one of them with it.
			description.candidates.insert(0, {address: "127.0.0.1", port: 70000, type: "host", priority: 1});

			alice.connect(description);

			var accepted:Int = @:privateAccess alice.agent.__remotes.length;
			Assert.equals(usable, accepted,
				"one unusable candidate cost " + (usable - accepted) + " good ones");
		} catch (e:Dynamic) {
			Assert.fail("connect() threw on a description carrying one unusable candidate: " + Std.string(e));
		}

		alice.close();
		bob.close();
	}
}

/**
	A peer that does ICE and nothing else.

	It answers connectivity checks, so the path is found, and its description
	claims the DTLS client role, so the other end waits for a ClientHello that
	never comes, the shape a browser tab closed straight after ICE leaves.
**/
private class IceOnlyPeer {
	public var agent(default, null):IceAgent;

	private var socket:DatagramSocket;
	private var closed:Bool = false;

	public function new() {
		agent = new IceAgent(false);
		socket = new DatagramSocket();
		socket.bind(0, "127.0.0.1");
		socket.addEventListener(DatagramSocketDataEvent.DATA, function(e:DatagramSocketDataEvent):Void {
			if (!closed) {
				agent.receive(e.data, e.srcAddress, e.srcPort, haxe.Timer.stamp());
			}
		});
		socket.receive();

		agent.onSend = function(payload:ByteArray, address:String, port:Int):Void {
			if (closed) {
				return;
			}

			try {
				socket.send(payload, 0, payload.length, address, port);
			} catch (_:Dynamic) {}
		};

		agent.addLocalCandidate(IceCandidate.host("127.0.0.1", socket.localPort));
	}

	public function description():PeerDescription {
		return {
			usernameFragment: agent.localCredentials.usernameFragment,
			password: agent.localCredentials.password,
			fingerprint: DtlsCertificate.generate("ice-only", 1).fingerprint,
			candidates: [
				{
					address: "127.0.0.1",
					port: socket.localPort,
					type: "host",
					priority: IceCandidate.host("127.0.0.1", socket.localPort).priority
				}
			],
			setup: "active"
		};
	}

	public function start(remote:PeerDescription):Void {
		for (candidate in remote.candidates) {
			agent.addRemoteCandidate(new IceCandidate((candidate.type : String), candidate.address, candidate.port, 1, candidate.priority));
		}

		agent.start(new IceCredentials(remote.usernameFragment, remote.password), haxe.Timer.stamp());
	}

	public function poll(now:Float):Void {
		if (!closed) {
			agent.poll(now);
		}
	}

	public function close():Void {
		if (closed) {
			return;
		}

		closed = true;
		agent.close();

		try {
			socket.close();
		} catch (_:Dynamic) {}
	}
}
