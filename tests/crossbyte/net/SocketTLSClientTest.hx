package crossbyte.net;

import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ProgressEvent;
import crossbyte.events.ServerSocketConnectEvent;
import utest.Assert;
import utest.Async;

/**
	A `Socket` with `secure` set connects over TLS, and checks whom it is
	talking to.

	It did neither: on a client `Socket`, `secure` was read only to report it,
	so a client asking for TLS spoke plain TCP, into a TLS listener, which
	could make nothing of it, and there was no certificate to check. A
	protocol that runs over TLS on a plain stream, TURN over TLS among them,
	had no way to have it.

	Each case runs a TLS `ServerSocket` presenting a self-signed certificate
	and answering what it reads in capitals, so the client's settings are
	the only thing that differs between them. A refusal proves little on its
	own, a client that cannot connect at all refuses too, which is why
	it sits beside the cases showing the same server is reachable once the
	client is told to trust it.

	Not on eval, where a TLS handshake cannot be made non-blocking and would
	stall the runtime the server is waiting on.
**/
class SocketTLSClientTest extends utest.Test {
	private static inline var HELLO:String = "hello over TLS";

	#if (cpp || java || jvm || nodejs)
	@:timeout(30000)
	public function testASecureClientExchangesBytesWithATlsServer(async:Async):Void {
		var fixture = TLSTestFixture.trusted();
		__against(fixture, function(client) client.certAuthority = fixture.certificate, function(outcome) {
			Assert.isTrue(outcome.connected, "the secure client never connected: " + outcome.failure);
			Assert.equals(HELLO, outcome.serverHeard, "the TLS server did not read what the client wrote");
			Assert.equals(HELLO.toUpperCase(), outcome.clientHeard, "the client did not read what the server answered");
			Assert.isTrue(outcome.serverSideSecure, "the server's end does not say it is TLS");
		}, async);
	}

	@:timeout(30000)
	public function testACertificateForAnotherHostIsRefused(async:Async):Void {
		// Trusted, and for somebody else. A client that checks the chain and
		// not the name accepts any valid certificate for any host, which is
		// most of what verification is for gone.
		var fixture = TLSTestFixture.trusted(["elsewhere.example"]);
		__against(fixture, function(client) client.certAuthority = fixture.certificate, function(outcome) {
			Assert.isFalse(outcome.connected, "a certificate naming another host was accepted");
			Assert.isTrue(__isCertificateRefusal(outcome.failure), "the connection failed, but not over the certificate: " + outcome.failure);
			Assert.isNull(outcome.serverHeard, "the server read from a client that should have refused it");
		}, async);
	}

	@:timeout(30000)
	public function testAServerTheClientDoesNotTrustIsRefused(async:Async):Void {
		__against(TLSTestFixture.trusted(), function(_) {}, function(outcome) {
			Assert.isFalse(outcome.connected, "a self-signed certificate was accepted without being trusted");
			Assert.isTrue(__isCertificateRefusal(outcome.failure), "the connection failed, but not over the certificate: " + outcome.failure);
			Assert.isNull(outcome.serverHeard, "the server read from a client that should have refused it");
		}, async);
	}

	@:timeout(30000)
	public function testVerificationCanBeTurnedOff(async:Async):Void {
		__against(TLSTestFixture.trusted(), function(client) client.verifyCert = false, function(outcome) {
			Assert.isTrue(outcome.connected, "verifyCert = false did not stop the client verifying: " + outcome.failure);
			Assert.equals(HELLO.toUpperCase(), outcome.clientHeard, "the client did not read what the server answered");
		}, async);
	}
	#end

	#if (cpp || java || jvm)
	/**
		A listener that takes the connection and never answers the hello: the
		client gives up at its `timeout`, which counts the handshake, rather
		than waiting on it for good.
	**/
	@:timeout(30000)
	public function testAHandshakeNobodyAnswersEndsAtTheTimeout(async:Async):Void {
		var listener = new sys.net.Socket();
		listener.bind(new sys.net.Host("127.0.0.1"), 0);
		listener.listen(4);
		var port:Int = listener.host().port;

		var client = new Socket();
		client.secure = true;
		client.timeout = 1000;
		var connected:Bool = false;
		var failure:String = null;
		var endedAfter:Float = -1;
		var started:Float = haxe.Timer.stamp();
		client.addEventListener(Event.CONNECT, _ -> connected = true);
		client.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent) {
			failure = e.text;
			endedAfter = haxe.Timer.stamp() - started;
		});
		client.connect("127.0.0.1", port);

		var peer:sys.net.Socket = null;
		NetPump.until(() -> {
			if (peer == null && sys.net.Socket.select([listener], [], [], 0).read.length > 0) {
				peer = listener.accept();
			}
			return failure != null || connected;
		}, 10.0, function(_) {
			Assert.isFalse(connected, "a handshake nobody answered was taken as done");
			Assert.notNull(failure, "a handshake nobody answered was waited on for good");
			Assert.isTrue(endedAfter >= 0.9 && endedAfter < 5.0, 'the attempt ended ${endedAfter} s in, for a 1 s timeout');
			if (failure != null) {
				Assert.isTrue(failure.indexOf("TLS") >= 0, "the failure does not say it was the handshake: " + failure);
			}
			try client.close() catch (_:Dynamic) {}
			if (peer != null) {
				try peer.close() catch (_:Dynamic) {}
			}
			try listener.close() catch (_:Dynamic) {}
			async.done();
		});
	}
	#end

	#if (cpp || java || jvm || nodejs)
	/**
		Whether `failure` is a TLS layer refusing a certificate, in any of the
		ways the targets word it: mbedTLS reports an X509 verification
		failure, the JDK a PKIX path or subject-alternative-name failure, and
		Node a self-signed certificate or a name missing from its altnames.
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

	/**
		Runs one secure client against a TLS `ServerSocket` presenting
		`fixture`, which answers what it reads in capitals, and reports what
		happened. The server is closed on every path, since a listener left
		behind strands its port for the cases after it.
	**/
	private function __against(fixture:TLSTestFixture.TLSFixtureData, configure:Socket->Void, check:TLSClientOutcome->Void, async:Async):Void {
		if (fixture == null) {
			// No openssl on this machine to make a certificate with.
			Assert.warn("no certificate toolchain on this machine; the TLS client cases did not run");
			async.done();
			return;
		}

		var server = new ServerSocket(true);
		server.setCertificate(fixture.certificate, fixture.key);

		var outcome:TLSClientOutcome = {
			connected: false,
			failure: null,
			serverHeard: null,
			clientHeard: null,
			serverSideSecure: false
		};
		var accepted:Array<Socket> = [];

		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) {
			var peer:Socket = e.socket;
			accepted.push(peer);
			outcome.serverSideSecure = peer.secure;
			peer.addEventListener(ProgressEvent.SOCKET_DATA, function(_) {
				var text:String = peer.readUTFBytes(peer.bytesAvailable);
				outcome.serverHeard = (outcome.serverHeard == null ? "" : outcome.serverHeard) + text;
				peer.writeUTFBytes(text.toUpperCase());
				peer.flush();
			});
		});

		server.bind(0, "127.0.0.1");
		server.listen();

		var client = new Socket();
		client.addEventListener(Event.CONNECT, function(_) {
			outcome.connected = true;
			client.writeUTFBytes(HELLO);
			client.flush();
		});
		client.addEventListener(ProgressEvent.SOCKET_DATA, function(_) {
			var text:String = client.readUTFBytes(client.bytesAvailable);
			outcome.clientHeard = (outcome.clientHeard == null ? "" : outcome.clientHeard) + text;
		});
		client.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent) {
			if (outcome.failure == null) {
				outcome.failure = e.text;
			}
		});
		// Closed by the server, that is, rather than by finish() below.
		var finishing:Bool = false;
		client.addEventListener(Event.CLOSE, function(_) {
			if (outcome.failure == null && !finishing) {
				outcome.failure = "closed";
			}
		});

		function finish():Void {
			finishing = true;
			try client.close() catch (_:Dynamic) {}
			for (peer in accepted) {
				try peer.close() catch (_:Dynamic) {}
			}
			try server.close() catch (_:Dynamic) {}
			check(outcome);
			async.done();
		}

		// Node claims the port a turn after listen(), so it is read once known.
		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			client.secure = true;
			configure(client);
			client.connect("127.0.0.1", server.localPort);

			NetPump.until(() -> (outcome.clientHeard != null && outcome.clientHeard.length >= HELLO.length) || outcome.failure != null, 10.0, function(_) {
				// A little longer, so bytes the server should never have read
				// have the chance to be counted if it got that far.
				NetPump.wait(0.2, finish);
			});
		});
	}
	#end
}

private typedef TLSClientOutcome = {
	var connected:Bool;
	var failure:String;
	var serverHeard:String;
	var clientHeard:String;
	var serverSideSecure:Bool;
}
