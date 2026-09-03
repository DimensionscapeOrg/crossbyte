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

	#if (java || jvm)
	/**
		A real handshake, against the JDK's own TLS client.

		The peer is `javax.net.ssl.SSLSocket` -- the blocking API this backend
		deliberately does not use -- so this proves the SSLEngine server
		interoperates with an independent implementation rather than that two
		halves of the same code agree.

		The client runs on its own thread because it blocks; the server is driven
		by pumping the runtime, which is how a secure ServerSocket completes a
		handshake in production: through the pump on the tick, not inline.
	**/
	public function testARealHandshakeCompletesAgainstTheJdkClient():Void {
		__againstTheJdk(null, null, function(server, outcome) {
			Assert.isNull(outcome.error, "the JDK client could not complete the handshake: " + outcome.error);
			Assert.equals(1, outcome.accepted, "the server never reported an accepted TLS connection");
		});
	}

	/**
		ALPN is negotiated, by server preference.

		The client offers the reverse order, so agreement on `h2` cannot be an
		echo of what it asked for first -- the same trick the cpp case uses
		against mbedTLS.
	**/
	public function testAlpnIsNegotiatedAgainstTheJdkClient():Void {
		__againstTheJdk(["h2", "http/1.1"], ["http/1.1", "h2"], function(server, outcome) {
			Assert.isNull(outcome.error, "the JDK client could not complete the handshake: " + outcome.error);
			Assert.equals("h2", outcome.agreed, "the client and server did not agree on the server's first choice");
			Assert.equals("h2", outcome.reported, "the server does not report the protocol it negotiated");
		});
	}

	/**
		A client that presents no certificate is refused when one is required.

		`requireClientCertificate` installs a trust store, which on its own only
		says which authorities would be acceptable. The handshake has to actually
		ask, and this is what catches it not asking: without the demand the
		connection completes and the server accepts an unauthenticated peer.
	**/
	public function testAClientWithNoCertificateIsRefusedWhenOneIsRequired():Void {
		var fixture = TLSTestFixture.selfSigned();
		if (fixture == null) {
			Assert.pass();
			return;
		}

		// The server's verdict is what is asserted, not the client's. Under
		// TLS 1.3 the certificate travels after the server's Finished, so a
		// client's startHandshake can return successfully and only learn later
		// that it was rejected. What matters here is that the server refused.
		__againstTheJdk(null, null, function(server, outcome) {
			Assert.equals(0, outcome.accepted, "a client presenting no certificate was accepted");
		}, function(server) server.requireClientCertificate(fixture.certificate));
	}

	/** And is let through when it presents one the server trusts. **/
	public function testAClientWithTheRightCertificateIsAccepted():Void {
		var fixture = TLSTestFixture.selfSigned();
		if (fixture == null) {
			Assert.pass();
			return;
		}

		__againstTheJdk(null, null, function(server, outcome) {
			Assert.isNull(outcome.error, "a client presenting a trusted certificate was refused: " + outcome.error);
			Assert.equals(1, outcome.accepted, "the server did not accept an authenticated client");
		}, function(server) server.requireClientCertificate(fixture.certificate), true);
	}

	/**
		Server Name Indication picks the certificate matching the name asked for.

		Two certificates are needed to say anything: with one, a server that
		selects correctly and a server that ignores the name entirely look
		exactly alike. So the client asks for each name in turn and the
		certificate it is actually handed is compared against both.

		The name is set explicitly on the client rather than taken from the
		connect address, because an IP literal carries no SNI at all and these
		connect to 127.0.0.1.
	**/
	public function testSniPresentsTheCertificateForTheNameAsked():Void {
		var fallback = TLSTestFixture.selfSigned();
		var alternate = TLSTestFixture.selfSignedFor("alt.example");

		if (fallback == null || alternate == null) {
			// No certificate toolchain on this machine.
			Assert.pass();
			return;
		}

		var fallbackHex = __hexOf(fallback);
		var alternateHex = __hexOf(alternate);
		Assert.notEquals(fallbackHex, alternateHex, "the two fixtures are the same certificate, so this proves nothing");

		// A name the entry claims gets the alternate certificate.
		__againstTheJdk(null, null, function(server, outcome) {
			Assert.isNull(outcome.error, "the handshake for the claimed name failed: " + outcome.error);
			Assert.equals(alternateHex, JvmTlsPeer.presented, "the server did not present the certificate for the name asked for");
		}, function(server) server.addSNICertificate(function(name) return name == "alt.example",
			alternate.certificate, alternate.key), false, alternate.certificate, "alt.example");

		// A name no entry claims falls back to the one installed with
		// setCertificate.
		__againstTheJdk(null, null, function(server, outcome) {
			Assert.isNull(outcome.error, "the handshake for the unclaimed name failed: " + outcome.error);
			Assert.equals(fallbackHex, JvmTlsPeer.presented, "an unclaimed name did not fall back to the default certificate");
		}, function(server) server.addSNICertificate(function(name) return name == "alt.example",
			alternate.certificate, alternate.key), false, fallback.certificate, "other.example");
	}

	private function __hexOf(fixture:crossbyte.net.TLSTestFixture.TLSFixtureData):String {
		return haxe.io.Bytes.ofData(@:privateAccess fixture.certificate.__native.native.getEncoded()).toHex();
	}

	/**
		The jvm client speaks TLS, and verifies what it is given.

		`FlexSocket(true)` used to hand back a socket that did a plain TCP
		connect and no TLS at all, which is why OAuth refused to run here. It now
		terminates TLS as the client.

		Verification is asserted through its refusal. The server presents a
		self-signed certificate, which is not in the JDK's default trust store,
		so a client that checks must reject it -- and one that connects happily
		is not checking. The refusal has to name the certificate rather than be
		any old failure, or a plain connection error would pass this too.

		Reaching a real HTTPS host would be the other half and is not done here:
		a case that needs the internet fails for reasons that have nothing to do
		with this library.
	**/
	public function testTheJvmClientTerminatesTlsAndVerifies():Void {
		var fixture = TLSTestFixture.selfSigned();
		if (fixture == null) {
			Assert.pass();
			return;
		}

		var runtime = crossbyte.core.CrossByte.current();
		var server = new ServerSocket(true);

		// A ServerSocket only registers its accept tick once something is
		// listening for connections, so without this it never accepts and the
		// client waits on a handshake that has no other end.
		server.addEventListener(crossbyte.events.ServerSocketConnectEvent.CONNECT,
			function(e:crossbyte.events.ServerSocketConnectEvent) {});
		server.setCertificate(fixture.certificate, fixture.key);

		try {
			server.bind(0, "127.0.0.1");
			server.listen();

			var port = server.localPort;
			var failure:String = null;
			var connected = false;
			var finished = false;

			sys.thread.Thread.create(() -> {
				var client = new crossbyte._internal.socket.FlexSocket(true);

				try {
					client.setTimeout(10);
					client.connect("127.0.0.1", port);
					connected = true;
				} catch (e:Dynamic) {
					failure = Std.string(e);
				}

				try {
					client.close();
				} catch (_:Dynamic) {}

				finished = true;
			});

			var deadline = Sys.time() + 20;
			while (Sys.time() < deadline && !finished) {
				runtime.pump(1 / 60, 0);
				Sys.sleep(0.002);
			}

			Assert.isTrue(finished, "the client neither connected nor failed within the deadline");
			Assert.isFalse(connected, "a self-signed certificate was accepted, so the client is not verifying");
			Assert.notNull(failure, "the client reported no failure");
			// Specifically a failure from the TLS layer. Matching loosely on
			// "certificate" was not enough: with the client's engine removed
			// entirely, connect refused with "set a certificate before
			// listening", which contains the word and passed a test that should
			// have caught exactly that.
			Assert.isTrue(failure.indexOf("SSLHandshakeException") >= 0,
				"the refusal did not come from the TLS layer, so this may not be a verification failure at all: " + failure);
			Assert.isTrue(failure.indexOf("PKIX") >= 0 || failure.indexOf("Validator") >= 0,
				"the refusal is not a certificate-validation failure: " + failure);
		} catch (e:Dynamic) {
			try {
				server.close();
			} catch (_:Dynamic) {}
			throw e;
		}

		try {
			server.close();
		} catch (_:Dynamic) {}
	}

	/**
		Runs one secure server against one JDK client and hands back what both
		saw. The listener is closed on every path: a case that leaves one bound
		strands a port and breaks the socket cases after it.
	**/
	private function __againstTheJdk(serverAlpn:Null<Array<String>>, clientAlpn:Null<Array<String>>,
			check:(ServerSocket, {error:String, accepted:Int, agreed:String, reported:String}) -> Void,
			?configure:ServerSocket->Void, presentCertificate:Bool = false, ?trust:Certificate,
			?serverName:String):Void {
		var fixture = TLSTestFixture.selfSigned();
		if (fixture == null) {
			// No certificate toolchain on this machine.
			Assert.pass();
			return;
		}

		var runtime = crossbyte.core.CrossByte.current();
		var server = new ServerSocket(true);
		var accepted = 0;
		var reported:String = null;

		server.addEventListener(crossbyte.events.ServerSocketConnectEvent.CONNECT,
			function(e:crossbyte.events.ServerSocketConnectEvent) {
				accepted++;
				reported = e.socket.alpnProtocol;
			});

		server.setCertificate(fixture.certificate, fixture.key);

		if (serverAlpn != null) {
			server.setALPN(serverAlpn);
		}

		if (configure != null) {
			configure(server);
		}

		try {
			server.bind(0, "127.0.0.1");
			server.listen();

			var port = server.localPort;
			var agreed:String = null;
			var error:String = null;
			var finished = false;

			sys.thread.Thread.create(() -> {
				try {
					agreed = JvmTlsPeer.handshake("127.0.0.1", port, trust != null ? trust : fixture.certificate,
						clientAlpn, presentCertificate ? {certificate: fixture.certificate, key: fixture.key} : null,
						serverName);
				} catch (e:Dynamic) {
					error = Std.string(e);
				}

				finished = true;
			});

			var deadline = Sys.time() + 20;
			while (Sys.time() < deadline && !finished) {
				runtime.pump(1 / 60, 0);
				Sys.sleep(0.002);
			}

			// A few more passes so a connection completing on the client's last
			// breath still reaches the pump before the assertions read it.
			var settle = Sys.time() + 0.5;
			while (Sys.time() < settle) {
				runtime.pump(1 / 60, 0);
				Sys.sleep(0.002);
			}

			check(server, {error: error, accepted: accepted, agreed: agreed, reported: reported});
		} catch (e:Dynamic) {
			try {
				server.close();
			} catch (_:Dynamic) {}
			throw e;
		}

		try {
			server.close();
		} catch (_:Dynamic) {}
	}
	#end

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
