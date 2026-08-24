package crossbyte.net;

import crossbyte.errors.Error as CBError;
#if cpp
import crossbyte._internal.socket.AlpnSocket;
#end
import utest.Assert;

/**
 * TLS surface of `ServerSocket`.
 *
 * These cover construction, certificate-installation guards, and the
 * listen-time precondition. The end-to-end handshake (which needs a
 * certificate and a client thread) is exercised by the native TLS
 * integration harness rather than the unit suite.
 */
class ServerSocketTLSTest extends utest.Test {
	public function testPlainServerDefaultsAndRejectsTlsConfiguration():Void {
		var server = new ServerSocket();
		Assert.isFalse(server.secure);
		Assert.equals(0, server.pendingHandshakeCount());
		Assert.equals(10.0, server.handshakeTimeout);

		#if (!java && !jvm)
		// TLS configuration is meaningless on a plain listener and must not
		// silently no-op.
		Assert.raises(() -> server.setCertificate(null, null), CBError);
		Assert.raises(() -> server.addSNICertificate((_) -> true, null, null), CBError);
		Assert.raises(() -> server.requireClientCertificate(null), CBError);
		Assert.raises(() -> server.setALPN(["h2"]), CBError);
		#end

		server.close();
	}

	#if (!java && !jvm)
	public function testServerWebSocketReportsItsOwnSecureFlag():Void {
		// ServerWebSocket used to set a private __isSecure and then call
		// super() with no argument, so the `secure` property it inherits read
		// false on a server that was terminating TLS. Two fields for one fact,
		// and the public one was the wrong one. It is here rather than beside
		// the other WebSocket cases because what it is really asserting is
		// that the flag ServerSocket exposes describes the subclass too.
		var plain = new ServerWebSocket();
		Assert.isFalse(plain.secure);

		var secure = new ServerWebSocket(true);
		Assert.isTrue(secure.secure);
	}

	public function testSecureServerRequiresCertificateBeforeListen():Void {
		var server = new ServerSocket(true);
		Assert.isTrue(server.secure);
		Assert.equals(0, server.pendingHandshakeCount());

		server.bind(0, "127.0.0.1");
		Assert.isTrue(server.bound);

		// Listening without a certificate would present clients with a
		// handshake that can never succeed.
		Assert.raises(() -> server.listen(), crossbyte.errors.IOError);
		Assert.isFalse(server.listening);

		server.close();
	}

	// Both of the cases below install a certificate, and eval's
	// sys.ssl.Socket.setCertificate is a stub that throws. The rest of this
	// class runs there: constructing a secure server, the guards that reject
	// TLS material on a plain one, and the bind-time precondition all work
	// without a certificate ever being handed over.
	#if !eval
	public function testSecureServerAcceptsCertificateAndListens():Void {
		var fixture = TLSTestFixture.selfSigned();
		if (fixture == null) {
			// No certificate toolchain available on this machine.
			Assert.pass();
			return;
		}

		var server = new ServerSocket(true);
		server.setCertificate(fixture.certificate, fixture.key);
		server.bind(0, "127.0.0.1");
		server.listen();

		Assert.isTrue(server.listening);
		Assert.isTrue(server.localPort > 0);
		Assert.equals(0, server.pendingHandshakeCount());

		// TLS material is materialized during bind(), so later changes would
		// silently not apply and must be rejected instead.
		Assert.raises(() -> server.setCertificate(fixture.certificate, fixture.key), CBError);
		Assert.raises(() -> server.requireClientCertificate(fixture.certificate), CBError);
		Assert.raises(() -> server.setALPN(["h2"]), CBError);

		server.close();
		Assert.isFalse(server.listening);
	}

	public function testSecureServerAcceptsAlpnBeforeBind():Void {
		var fixture = TLSTestFixture.selfSigned();
		if (fixture == null) {
			// No certificate toolchain available on this machine.
			Assert.pass();
			return;
		}

		var server = new ServerSocket(true);
		server.setCertificate(fixture.certificate, fixture.key);

		// Accepted on every target. Where ALPN cannot reach the handshake the
		// call is a no-op rather than an error, so a server can offer h2
		// unconditionally and keep serving HTTP/1.1 where it is not available.
		server.setALPN(["h2", "http/1.1"]);
		server.setALPN(null);
		server.setALPN(["h2"]);

		server.bind(0, "127.0.0.1");
		server.listen();
		Assert.isTrue(server.listening);

		server.close();
	}

	#end

	#if cpp
	public function testAlpnIsNegotiatedOverARealHandshake():Void {
		var fixture = TLSTestFixture.selfSigned();
		if (fixture == null) {
			Assert.pass();
			return;
		}

		// Driven through AlpnSocket rather than ServerSocket: a secure
		// ServerSocket defers its accept and handshake to the runtime tick
		// loop, which a synchronous case has no way to turn. AlpnSocket is
		// what ServerSocket installs as its listener, so this covers the same
		// negotiation one layer down; the event-loop path belongs to the
		// integration harness.
		var port:Int = 48242;
		var server = new AlpnSocket();
		server.verifyCert = false;
		server.setCertificate(fixture.certificate.__native, fixture.key.__native);
		server.setALPN(["h2", "http/1.1"]);
		server.bind(new sys.net.Host("127.0.0.1"), port);
		server.listen(1);

		var client = sys.thread.Thread.create(() -> {
			try {
				var c = new AlpnSocket();
				c.verifyCert = false;
				// Deliberately the reverse order: mbedTLS resolves ALPN by
				// server preference, so agreement on h2 cannot be an echo of
				// what the client asked for first.
				c.setALPN(["http/1.1", "h2"]);
				c.connect(new sys.net.Host("127.0.0.1"), port);
				sys.thread.Thread.readMessage(true);
				c.close();
			} catch (_:Dynamic) {}
		});

		var accepted = server.accept();
		accepted.handshake();

		Assert.equals("h2", AlpnSocket.negotiated(accepted));

		client.sendMessage("done");
		accepted.close();
		server.close();
	}
	#end
	#else
	public function testSecureServerIsRejectedOnJvm():Void {
		Assert.raises(() -> new ServerSocket(true), CBError);
	}
	#end
}
