package crossbyte.net;

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
		`certAuthority` asks every client for a certificate that authority
		issued, and lets in only those that present one.

		Natively it installed the authority and left verification off, the
		constructor turned it off, so that ordinary clients would not be asked,
		so a server told to require client certificates let in a client
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
