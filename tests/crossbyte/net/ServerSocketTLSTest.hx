package crossbyte.net;

import crossbyte.errors.Error as CBError;
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

		server.close();
		Assert.isFalse(server.listening);
	}
	#else
	public function testSecureServerIsRejectedOnJvm():Void {
		Assert.raises(() -> new ServerSocket(true), CBError);
	}
	#end
}
