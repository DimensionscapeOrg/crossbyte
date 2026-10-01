package crossbyte.net;

import crossbyte.errors.Error as CBError;
import crossbyte.errors.IOError;
import crossbyte.events.ServerSocketConnectEvent;
import utest.Assert;
import utest.Async;

/**
	The TLS surface of a `ServerWebSocket`, end to end, on every target that
	can serve `wss://`.

	A `ServerWebSocket` terminates TLS on a socket of its own, not the one the
	`ServerSocket` it extends would have built, so what it inherits has to be
	proved here rather than assumed from `ServerSocketTLSTest`.

	Not on eval, which cannot install a server certificate, nor on hl and
	neko, whose TLS servers are covered by the HTTP server's cases.
**/
class ServerWebSocketTLSTest extends utest.Test {
	#if (cpp || java || jvm || nodejs)
	/**
		A certificate assigned once the server is bound is refused, and a
		secure server will not listen without one.

		Natively the TLS configuration is built in `bind()`, so a `cert`
		assigned afterwards was taken without a word and never presented, and
		`listen()` did not ask whether there was one: the server listened, and
		every handshake failed silently.
	**/
	public function testTheCertificateIsWantedBeforeBind():Void {
		var fixture = TLSTestFixture.trusted();
		if (fixture == null) {
			Assert.warn("no certificate toolchain on this machine; the case did not run");
			return;
		}

		var server = new ServerWebSocket(true);
		server.bind(0, "127.0.0.1");
		Assert.raises(() -> server.cert = {certificate: fixture.certificate, key: fixture.key}, CBError);
		Assert.raises(() -> server.certAuthority = fixture.certificate, CBError);
		Assert.raises(() -> server.listen(), IOError);
		Assert.isFalse(server.listening, "a secure server with no certificate listened");
		try server.close() catch (_:Dynamic) {}
	}

	/**
		TLS settings on a plain server are refused rather than kept: a server
		given a certificate it will never present is a mistake its owner
		should hear about. `null` asks for nothing, and is let be.
	**/
	public function testTlsSettingsAreRefusedOnAPlainServer():Void {
		var fixture = TLSTestFixture.trusted();
		if (fixture == null) {
			Assert.warn("no certificate toolchain on this machine; the case did not run");
			return;
		}

		var server = new ServerWebSocket();
		Assert.raises(() -> server.cert = {certificate: fixture.certificate, key: fixture.key}, CBError);
		Assert.raises(() -> server.certAuthority = fixture.certificate, CBError);
		server.certAuthority = null;
		Assert.isNull(server.cert);
		try server.close() catch (_:Dynamic) {}
	}

	/**
		`certAuthority` asks every client for a certificate that authority
		issued, and lets in only those that present one.

		Natively it installed the authority and left verification off -- the
		constructor turned it off, so that ordinary clients would not be asked
		-- so a server told to require client certificates let in a client
		that presented none. Node asked and refused, so the one setting meant
		two different things depending on where the server ran.
	**/
	@:timeout(30000)
	public function testCertAuthorityLetsInOnlyClientsWithACertificateItIssued(async:Async):Void {
		var fixture = TLSTestFixture.trusted();
		var chain = TLSChainFixture.get();
		if (fixture == null || chain == null) {
			Assert.warn("no certificate toolchain on this machine; the case did not run");
			async.done();
			return;
		}

		__serve(function(server) {
			server.cert = {certificate: fixture.certificate, key: fixture.key};
			server.certAuthority = chain.root;
		}, function(server, sessions, finish) {
			TlsProbe.run(server.localPort, {upgrade: true}, function(without) {
				TlsProbe.run(server.localPort, {upgrade: true, present: {certificate: chain.client, key: chain.clientKey}}, function(with) {
					NetPump.until(() -> sessions.length > 0, 2.0, function(_) {
						Assert.isFalse(__upgraded(without), "a client presenting no certificate was let in: " + without.status);
						Assert.isNull(with.error, "a client presenting a certificate the authority issued was refused: " + with.error);
						Assert.isTrue(__upgraded(with), "a client presenting a certificate the authority issued was not upgraded: " + with.status);
						Assert.equals(1, sessions.length, "the sessions opened were not exactly the one with a certificate");
						finish();
					});
				});
			});
		}, async);
	}

	/**
		`setCertificate()`, inherited from `ServerSocket`, installs the
		certificate a `ServerWebSocket` presents, and `cert` reads it back.

		It reached into the listener `ServerSocket` builds, which a
		`ServerWebSocket` never does -- a null dereference natively, which on
		hxcpp ends the process -- and on Node it was stored where this
		server's listener never looked, so listen() refused for want of a
		certificate it had been given.
	**/
	@:timeout(30000)
	public function testSetCertificateServesWss(async:Async):Void {
		var fixture = TLSTestFixture.trusted();
		if (fixture == null) {
			Assert.warn("no certificate toolchain on this machine; the case did not run");
			async.done();
			return;
		}

		__serve(function(server) {
			server.setCertificate(fixture.certificate, fixture.key);
			Assert.notNull(server.cert, "cert does not read back what setCertificate() installed");
		}, function(server, sessions, finish) {
			TlsProbe.run(server.localPort, {upgrade: true, trust: fixture.certificate}, function(outcome) {
				NetPump.until(() -> sessions.length > 0, 2.0, function(_) {
					Assert.isNull(outcome.error, "a client trusting the certificate installed could not connect: " + outcome.error);
					Assert.isTrue(__upgraded(outcome), "the upgrade was not answered with 101: " + outcome.status);
					Assert.equals(1, sessions.length, "no session opened");
					finish();
				});
			});
		}, async);
	}

	/**
		`addSNICertificate()` presents the certificate for the name a client
		asks for, and the default for any other.

		Checked by the client verifying what it is shown: a certificate
		naming `alt.example` verifies only when asked for by that name, so a
		server that ignored the name -- or never installed the entry -- is
		refused.
	**/
	@:timeout(30000)
	public function testSniPresentsTheCertificateForTheNameAsked(async:Async):Void {
		var fixture = TLSTestFixture.trusted();
		var alternate = TLSTestFixture.trusted(["alt.example"]);
		if (fixture == null || alternate == null) {
			Assert.warn("no certificate toolchain on this machine; the case did not run");
			async.done();
			return;
		}

		__serve(function(server) {
			server.cert = {certificate: fixture.certificate, key: fixture.key};
			server.addSNICertificate(name -> name == "alt.example", alternate.certificate, alternate.key);
		}, function(server, sessions, finish) {
			TlsProbe.run(server.localPort, {serverName: "alt.example", trust: alternate.certificate}, function(claimed) {
				TlsProbe.run(server.localPort, {serverName: "localhost", trust: fixture.certificate}, function(unclaimed) {
					Assert.isNull(claimed.error, "the certificate for the name asked for was not presented: " + claimed.error);
					Assert.isNull(unclaimed.error, "a name no entry claims did not get the default certificate: " + unclaimed.error);
					finish();
				});
			});
		}, async);
	}

	/**
		`setALPN()` reaches the handshake, and the session reports what was
		agreed in `alpnProtocol`.
	**/
	@:timeout(30000)
	public function testAlpnIsNegotiatedAndReportedBySessions(async:Async):Void {
		var fixture = TLSTestFixture.trusted();
		if (fixture == null) {
			Assert.warn("no certificate toolchain on this machine; the case did not run");
			async.done();
			return;
		}

		// Read as the session opens: the probe hangs up once it has its answer.
		var reported:Array<String> = [];
		__serve(function(server) {
			server.cert = {certificate: fixture.certificate, key: fixture.key};
			server.setALPN(["http/1.1"]);
			server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) reported.push(e.socket.alpnProtocol));
		}, function(server, sessions, finish) {
			TlsProbe.run(server.localPort, {upgrade: true, alpn: ["h2", "http/1.1"]}, function(outcome) {
				NetPump.until(() -> sessions.length > 0, 2.0, function(_) {
					Assert.isNull(outcome.error, "the client could not connect: " + outcome.error);
					Assert.equals("http/1.1", outcome.alpn, "the client and server did not agree on the protocol the server offers");
					Assert.same(["http/1.1"], reported, "the session does not report the protocol it agreed");
					finish();
				});
			});
		}, async);
	}

	/** Whether the server answered a probe's upgrade with 101. **/
	private static function __upgraded(outcome:TlsProbe.TlsProbeOutcome):Bool {
		return outcome.status != null && outcome.status.indexOf(" 101 ") >= 0;
	}

	/**
		A secure server, configured by `configure` before it binds, with the
		sessions it opens collected; `body` runs once its port is known, and
		everything is closed when it calls `finish`.
	**/
	private function __serve(configure:ServerWebSocket->Void, body:(ServerWebSocket, Array<WebSocket>, Void->Void)->Void, async:Async):Void {
		var server = new ServerWebSocket(true);
		server.handshakeTimeout = 5;
		var sessions:Array<WebSocket> = [];
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) sessions.push(cast e.socket));
		configure(server);
		server.bind(0, "127.0.0.1");
		server.listen();

		function finish():Void {
			for (session in sessions) {
				try session.close() catch (_:Dynamic) {}
			}
			try server.close() catch (_:Dynamic) {}
			// Settle what closing started, so it does not surface in the next
			// case.
			NetPump.wait(0.1, () -> async.done());
		}

		// Node claims the port a turn after listen(), so it is read once known.
		NetPump.until(() -> server.localPort != 0, 5.0, function(_) body(server, sessions, finish));
	}
	#end
}
