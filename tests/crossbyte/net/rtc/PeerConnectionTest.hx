package crossbyte.net.rtc;

import crossbyte.core.CrossByte;
import crossbyte.errors.ArgumentError;
import crossbyte.io.ByteArray;
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

	Loopback, so nothing here crosses a NAT -- the punching was proven where a
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
		The security capstone: a peer presenting a certificate that is not the
		one it signalled is refused, after a handshake that succeeded.

		Everything below works perfectly in this test -- the path is found, the
		DTLS handshake completes -- and the connection still must not come up,
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
			// does not hold -- which is what an attacker in the signalling path
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
		The description carries everything the peer needs and nothing secret.

		The ICE password crosses signalling by design -- it authenticates checks
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
}
