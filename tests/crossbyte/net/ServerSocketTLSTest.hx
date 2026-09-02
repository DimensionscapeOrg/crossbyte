package crossbyte.net;

import crossbyte.errors.Error as CBError;
#if cpp
import crossbyte._internal.socket.AlpnSocket;
import crossbyte._internal.socket.NativeAlpn;
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

		// TLS configuration is meaningless on a plain listener and must not
		// silently no-op.
		Assert.raises(() -> server.setCertificate(null, null), CBError);
		Assert.raises(() -> server.addSNICertificate((_) -> true, null, null), CBError);
		Assert.raises(() -> server.requireClientCertificate(null), CBError);
		Assert.raises(() -> server.setALPN(["h2"]), CBError);

		server.close();
	}

	// Everything below builds a secure ServerSocket, which eval refuses at
	// construction because its sys.ssl.Socket cannot install a certificate.
	// The refusal itself is asserted in the #else at the end.
	#if !eval
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

	#else
	public function testSecureServerIsRejectedOnEval():Void {
		// Loudly, at construction, and saying which target and why. Before
		// this it surfaced several calls later from inside the standard
		// library as a bare "Not implemented", with nothing pointing at the
		// target as the reason.
		Assert.raises(() -> new ServerSocket(true), CBError);

		try {
			new ServerSocket(true);
			Assert.fail("expected a refusal");
		} catch (e:CBError) {
			Assert.isTrue(e.message.indexOf("eval") >= 0, "the message should name the target: " + e.message);
		}
	}
	#end

	// The jvm end-to-end handshake and its ALPN negotiation are deliberately not
	// here. Both need a blocking TLS client on a thread of its own while the
	// runtime is pumped, and two such cases sharing one runtime interfered with
	// each other and with the socket cases around them: a clean run, then nine
	// failures, then a hang, over three consecutive runs. That is worse than no
	// coverage, because a suite that fails at random teaches people to ignore it.
	//
	// They belong in an integration harness beside ci/interop and ci/relay,
	// which is where the note at the top of this class already puts the native
	// end-to-end handshake. The backend was verified against openssl s_client --
	// TLS 1.3, verify return code 0 -- and ALPN against the JDK's own client
	// offering the reverse preference order, so the server's choice won rather
	// than being echoed back. Both by hand, both reproducible, neither in CI.

	#if cpp
	public function testAlpnBridgeRefusesAHandleThatIsNotAnSslConfig():Void {
		// The bridge reads mbedTLS handles back out of hxcpp objects whose
		// layout is private to its SSL.cpp. That is only safe because every
		// cast is guarded by hxcpp's own class id, so the wrong object is
		// refused rather than reinterpreted -- and if that layout ever changes
		// this is what fails, loudly, instead of corrupting memory.
		Assert.isTrue(NativeAlpn.isAvailable());
		Assert.isTrue(NativeAlpn.set("not a config", ["h2"]) < 0);
		Assert.isTrue(NativeAlpn.set(null, ["h2"]) < 0);
		Assert.isNull(NativeAlpn.selected("not a context"));

		// Releasing a handle that was never configured must be a no-op, not a
		// free of something it does not own.
		NativeAlpn.release("not a config");
		Assert.pass();
	}

	public function testAlpnListsAreReplacedAndReleasedWithoutLeaking():Void {
		// mbedTLS stores the list by reference and never frees it, so the
		// bridge owns every allocation. This churns install, replace and
		// release across many configs: a double free or a stale entry keyed by
		// a reused address shows up here as a crash rather than as drift.
		for (i in 0...500) {
			var conf = cpp.NativeSsl.conf_new(false);

			Assert.equals(0, NativeAlpn.set(conf, ["h2", "http/1.1"]));
			// Replaced, which must free the first list rather than orphan it.
			Assert.equals(0, NativeAlpn.set(conf, ["h2"]));
			// Cleared through the empty-list path, which must not hand NULL to
			// mbedtls_ssl_conf_alpn_protocols -- that walks the list before
			// testing it and segfaults.
			Assert.equals(0, NativeAlpn.set(conf, []));
			Assert.equals(0, NativeAlpn.set(conf, ["h2"]));

			NativeAlpn.release(conf);
			// Idempotent: a socket closed twice must not free twice.
			NativeAlpn.release(conf);

			if (i % 100 == 0) {
				cpp.vm.Gc.run(true);
			}
		}

		cpp.vm.Gc.run(true);
		Assert.pass();
	}

	public function testAlpnRejectsNamesMbedtlsWillNotAccept():Void {
		var conf = cpp.NativeSsl.conf_new(false);

		// Empty names and names over 255 bytes are rejected by mbedTLS itself
		// (RFC 7301 3.1). The bridge must surface that rather than install a
		// list it already handed over.
		Assert.isTrue(NativeAlpn.set(conf, [""]) != 0);
		Assert.isTrue(NativeAlpn.set(conf, [StringTools.rpad("", "x", 300)]) != 0);

		// Still usable afterwards, so a rejected call left nothing behind.
		Assert.equals(0, NativeAlpn.set(conf, ["h2"]));
		NativeAlpn.release(conf);
	}

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
}
