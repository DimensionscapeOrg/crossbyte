package crossbyte.net;

import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.events.WebSocketCloseEvent;
import utest.Assert;
import utest.Async;

/**
	A `wss://` client checks who it is talking to.

	Every secure client used to be built with verification switched off, so a
	`WebSocket`: and a `NetConnection` to a `wss://` address, accepted any
	certificate for any host: whoever could sit in the path could present one
	of their own and read everything. There was no way to turn verification
	on.

	Each case runs the same server, presenting a self-signed certificate, so
	the client's settings are the only thing that differs between them. The
	refusal on its own would prove little, a client that cannot connect at
	all refuses too, which is why it sits beside the cases showing the same
	server is reachable once the client is told to trust it.

	Not on eval, where a TLS handshake cannot be made non-blocking and would
	stall the runtime the server is waiting on.
**/
class WebSocketTLSTest extends utest.Test {
	#if (cpp || java || jvm || nodejs)
	@:timeout(30000)
	public function testASelfSignedServerIsRefusedByDefault(async:Async):Void {
		__against(TLSTestFixture.trusted(), function(_) {}, function(outcome) {
			Assert.isFalse(outcome.connected, "a self-signed certificate was accepted without being trusted");
			Assert.isTrue(outcome.ended, "the refused connection was never reported as ended");
			Assert.isTrue(__isCertificateRefusal(outcome.failure), "the connection failed, but not over the certificate: " + outcome.failure);
			Assert.equals(0, outcome.sessions, "the server completed an upgrade the client should have refused");
		}, async);
	}

	@:timeout(30000)
	public function testVerificationCanBeTurnedOff(async:Async):Void {
		__against(TLSTestFixture.trusted(), function(client) client.verifyCert = false, function(outcome) {
			Assert.isTrue(outcome.connected, "verifyCert = false did not stop the client verifying: " + outcome.failure);
			Assert.equals(1, outcome.sessions, "the server never saw the upgrade");
		}, async);
	}

	@:timeout(30000)
	public function testTheServerIsTrustedThroughTheAuthoritySupplied(async:Async):Void {
		var fixture = TLSTestFixture.trusted();
		__against(fixture, function(client) client.certAuthority = fixture.certificate, function(outcome) {
			Assert.isTrue(outcome.connected, "the client refused a server its certAuthority vouches for: " + outcome.failure);
			Assert.equals(1, outcome.sessions, "the server never saw the upgrade");
		}, async);
	}

	@:timeout(30000)
	public function testATrustedCertificateForAnotherHostIsRefused(async:Async):Void {
		// Trusted, and for somebody else. A client that checks the chain and
		// not the name accepts any valid certificate for any host, which is
		// most of what verification is for gone.
		var fixture = TLSTestFixture.trusted(["elsewhere.example"]);
		__against(fixture, function(client) client.certAuthority = fixture.certificate, function(outcome) {
			Assert.isFalse(outcome.connected, "a certificate naming another host was accepted");
			Assert.isTrue(outcome.ended, "the refused connection was never reported as ended");
			Assert.isTrue(__isCertificateRefusal(outcome.failure), "the connection failed, but not over the certificate: " + outcome.failure);
			Assert.equals(0, outcome.sessions, "the server completed an upgrade the client should have refused");
		}, async);
	}

	/**
		Whether `failure` is a TLS layer refusing a certificate, in any of the
		three ways the targets word it: mbedTLS reports an X509 verification
		failure, the JDK a PKIX path or subject-alternative-name failure, and
		Node a self-signed certificate or a name missing from its altnames.
		A connection refused for any other reason proves nothing about
		verification.
	**/
	private static function __isCertificateRefusal(failure:String):Bool {
		if (failure == null) {
			return false;
		}

		for (sign in ["X509", "ertificate", "PKIX", "subject alternative", "altnames"]) {
			if (failure.indexOf(sign) >= 0) {
				return true;
			}
		}

		return false;
	}

	@:timeout(30000)
	public function testSecureIsAPublicSettingThatChoosesWss(async:Async):Void {
		// The same server, with the client left on ws://. It sends a plain
		// upgrade into a TLS listener and cannot get anywhere, which is what
		// shows `secure` is what chose TLS in the cases above.
		__against(TLSTestFixture.trusted(), function(client) client.secure = false, function(outcome) {
			Assert.isFalse(outcome.connected, "a plain client completed an upgrade against a TLS listener");
			Assert.equals(0, outcome.sessions);

			// And promptly: the server's handshake fails on the first bytes it
			// reads, and closing that connection is what tells the client. The
			// server used to drop a session whose TLS failed without closing its
			// socket, so the client sat waiting on an answer until a deadline
			// of its own, and the server held the descriptor for good.
			Assert.isTrue(outcome.ended, "the client was never told the connection had ended");
			Assert.isTrue(outcome.endedAfter < 3.0, 'the connection took ${outcome.endedAfter} s to end after its TLS handshake failed');
		}, async);
	}

	/**
		Runs one client against a TLS `ServerWebSocket` presenting `fixture`,
		and reports what happened.

		`secure` is set before `configure` runs, so a case can take it away
		again. The server is closed on every path, since a listener left
		behind strands its port for the cases after it.
	**/
	private function __against(fixture:TLSTestFixture.TLSFixtureData, configure:WebSocket->Void, check:TLSOutcome->Void, async:Async):Void {
		if (fixture == null) {
			// No openssl on this machine to make a certificate with.
			Assert.warn("no certificate toolchain on this machine; the wss cases did not run");
			async.done();
			return;
		}

		var server = new ServerWebSocket(true);
		server.cert = {certificate: fixture.certificate, key: fixture.key};
		server.handshakeTimeout = 5;

		var outcome:TLSOutcome = {connected: false, ended: false, endedAfter: -1.0, sessions: 0, failure: null};
		var started:Float = 0.0;
		var sessions:Array<WebSocket> = [];

		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) {
			outcome.sessions++;
			sessions.push(cast e.socket);
		});

		server.bind(0, "127.0.0.1");
		server.listen();

		var client = new WebSocket();

		function ended():Void {
			if (!outcome.ended) {
				outcome.ended = true;
				outcome.endedAfter = haxe.Timer.stamp() - started;
			}
		}

		client.addEventListener(Event.CONNECT, function(_) outcome.connected = true);
		client.addEventListener(Event.CLOSE, function(e:Event) {
			ended();
			var close = Std.downcast(e, WebSocketCloseEvent);
			if (outcome.failure == null && close != null) {
				outcome.failure = "closed with " + close.code + " (" + close.reason + ")";
			}
		});
		client.addEventListener(IOErrorEvent.IO_ERROR, function(e:Event) {
			ended();
			var error = Std.downcast(e, IOErrorEvent);
			outcome.failure = error == null ? "ioError" : error.text;
		});

		function finish():Void {
			try client.close() catch (_:Dynamic) {}
			for (session in sessions) {
				try session.close() catch (_:Dynamic) {}
			}
			try server.close() catch (_:Dynamic) {}
			check(outcome);
			async.done();
		}

		// Node claims the port a turn after listen(), so it is read once known.
		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			client.secure = true;
			configure(client);
			started = haxe.Timer.stamp();
			client.connect("127.0.0.1", server.localPort);

			NetPump.until(() -> (outcome.connected && outcome.sessions > 0) || outcome.ended, 10.0, function(_) {
				// A little longer, so a session the client was about to refuse
				// has the chance to be counted if the server got that far.
				NetPump.wait(0.2, finish);
			});
		});
	}
	#end
}

private typedef TLSOutcome = {
	var connected:Bool;
	var ended:Bool;
	var endedAfter:Float;
	var sessions:Int;
	var failure:String;
}
