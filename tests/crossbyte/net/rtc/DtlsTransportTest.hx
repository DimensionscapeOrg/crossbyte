package crossbyte.net.rtc;

import crossbyte.errors.ArgumentError;
import crossbyte.io.ByteArray;
import utest.Assert;

/**
	Two DTLS sessions handed each other's datagrams, with no network between
	them.

	The transport owns no socket for the same reason the ICE agent does not --
	the one it would want is already carrying connectivity checks -- and the
	same benefit follows: a real handshake, retransmission timers and all, runs
	to completion here deterministically.

	Native only, because mbedTLS is. Elsewhere these assert that it says so.
**/
class DtlsTransportTest extends utest.Test {
	private function unsupported():Bool {
		if (!DtlsTransport.isSupported) {
			Assert.isFalse(DtlsTransport.isSupported);
			return true;
		}

		return false;
	}

	public function testSupportIsReportedHonestly():Void {
		if (!DtlsCertificate.isSupported) {
			Assert.isFalse(DtlsTransport.isSupported, "a transport claimed support on a target with no certificates to run it with");
			return;
		}

		Assert.isTrue(DtlsTransport.isSupported);
	}

	/**
		A handshake between two peers who each know only the other's
		fingerprint.

		This is the whole arrangement WebRTC uses in place of a certificate
		authority, and it either works end to end or it does not.
	**/
	public function testTwoPeersHandshakeAndCarryData():Void {
		if (unsupported()) return;

		var pair = Pair.make();
		var delivered:String = null;
		var back:String = null;

		pair.server.onMessage = function(payload) {
			payload.position = 0;
			delivered = payload.readUTFBytes(payload.length);
		};

		pair.client.onMessage = function(payload) {
			payload.position = 0;
			back = payload.readUTFBytes(payload.length);
		};

		Assert.isTrue(pair.run(() -> pair.client.connected && pair.server.connected), "the DTLS handshake never completed");

		pair.client.send(text("from the client"));
		pair.run(() -> delivered != null);
		Assert.equals("from the client", delivered);

		pair.server.send(text("from the server"));
		pair.run(() -> back != null);
		Assert.equals("from the server", back, "the session carried data one way only");

		pair.close();
	}

	/**
		The case the fingerprint exists for.

		An attacker who can answer gets a perfectly good DTLS handshake -- the
		cryptography is not what identifies the peer here, because there is no
		authority to appeal to. What identifies it is that the certificate
		presented hashes to what arrived over signalling. So this hands a peer a
		certificate that is not the one that was promised, and requires that the
		session is refused *after* the handshake succeeds.
	**/
	public function testAHandshakeWithTheWrongCertificateIsRefused():Void {
		if (unsupported()) return;

		var impostor = DtlsCertificate.generate("impostor", 30);
		var pair = Pair.make(impostor);
		var failure:String = null;

		pair.client.established.then(_ -> {}, error -> failure = error);
		pair.run(() -> failure != null);

		Assert.notNull(failure, "a certificate that was not the one signalled was accepted");
		Assert.isFalse(pair.client.connected, "the transport reported itself connected to the wrong peer");
		Assert.isTrue(failure.indexOf("fingerprint") >= 0, "the refusal does not say what was wrong: " + failure);

		pair.close();
	}

	/**
		There is no way to build one of these that skips the check.

		Making the fingerprint a constructor argument is deliberate: an
		implementation that lets it be supplied later has a window in which the
		session is established and unverified, and something will eventually use
		it in that window.
	**/
	public function testATransportCannotBeBuiltWithoutAFingerprint():Void {
		if (!DtlsCertificate.isSupported) {
			Assert.raises(() -> new DtlsTransport(null, "AA:BB", true), ArgumentError);
			return;
		}

		var certificate = DtlsCertificate.generate("crossbyte-test", 30);

		Assert.raises(() -> new DtlsTransport(certificate, null, true), ArgumentError);
		Assert.raises(() -> new DtlsTransport(certificate, "", true), ArgumentError);
		Assert.raises(() -> new DtlsTransport(null, certificate.fingerprint, true), ArgumentError);
	}

	/**
		One socket, several protocols, told apart by the first byte.

		RFC 7983 is what lets ICE checks and an encrypted session share a port:
		below 2 is STUN, 20 to 63 is DTLS. A transport that took everything
		would swallow the connectivity checks still keeping the path alive.
	**/
	public function testTrafficThatIsNotDtlsIsLeftAlone():Void {
		var stun = new ByteArray();
		stun.writeByte(0x00);
		stun.writeByte(0x01);
		stun.position = 0;
		Assert.isFalse(DtlsTransport.looksLikeDtls(stun), "a STUN binding request was taken for DTLS");

		var media = new ByteArray();
		media.writeByte(0x80);
		media.position = 0;
		Assert.isFalse(DtlsTransport.looksLikeDtls(media));

		var handshake = new ByteArray();
		handshake.writeByte(22);
		handshake.position = 0;
		Assert.isTrue(DtlsTransport.looksLikeDtls(handshake), "a DTLS handshake record was not recognised");

		Assert.isFalse(DtlsTransport.looksLikeDtls(null));
		Assert.isFalse(DtlsTransport.looksLikeDtls(new ByteArray()));
	}

	/**
		Sending before the session exists is refused rather than guessed at.

		The alternatives are to drop the message or to buffer it, and a
		transport that quietly does one where the caller assumed the other is
		worse than one that says no.
	**/
	public function testSendingBeforeTheHandshakeIsRefused():Void {
		if (unsupported()) return;

		var pair = Pair.make();

		Assert.raises(() -> pair.client.send(text("too early")), ArgumentError);

		pair.close();
	}

	private static function text(value:String):ByteArray {
		var out = new ByteArray();
		out.writeUTFBytes(value);
		out.position = 0;
		return out;
	}
}

/** A client and a server, and the queues that stand in for a network. **/
private class Pair {
	public var client:DtlsTransport;
	public var server:DtlsTransport;

	private var toServer:Array<ByteArray> = [];
	private var toClient:Array<ByteArray> = [];
	private var now:Float = 0;

	/**
		@param serverCertificate A certificate for the server that is *not* the
		one the client was told to expect, for the case that matters.
	**/
	public static function make(?serverCertificate:DtlsCertificate):Pair {
		var clientCertificate = DtlsCertificate.generate("client", 30);
		var promised = DtlsCertificate.generate("server", 30);
		var presented = serverCertificate != null ? serverCertificate : promised;

		var pair = new Pair();
		pair.client = new DtlsTransport(clientCertificate, promised.fingerprint, true);
		pair.server = new DtlsTransport(presented, clientCertificate.fingerprint, false);

		pair.client.onSend = payload -> pair.toServer.push(payload);
		pair.server.onSend = payload -> pair.toClient.push(payload);

		return pair;
	}

	private function new() {}

	public function run(done:Void->Bool):Bool {
		for (_ in 0...400) {
			client.poll(now);
			server.poll(now);

			var outbound = toServer;
			toServer = [];

			for (payload in outbound) {
				server.receive(payload, now);
			}

			var inbound = toClient;
			toClient = [];

			for (payload in inbound) {
				client.receive(payload, now);
			}

			if (done()) {
				return true;
			}

			now += 0.02;
		}

		return done();
	}

	public function close():Void {
		try client.close() catch (_:Dynamic) {}
		try server.close() catch (_:Dynamic) {}
	}
}
