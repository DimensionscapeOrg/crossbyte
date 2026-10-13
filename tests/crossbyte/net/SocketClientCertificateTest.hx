package crossbyte.net;

import crossbyte.errors.ArgumentError;
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ProgressEvent;
import crossbyte.events.ServerSocketConnectEvent;
import utest.Assert;
import utest.Async;

/**
	Mutual TLS from the dialing side: a `Socket` or a `wss://` `WebSocket`
	presents a certificate with `setCertificate`, a server that requires one
	(`requireClientCertificate`) lets it in, and each end reads the other's
	certificate as `peerCertificate`, by its `commonName` and `der`.
**/
class SocketClientCertificateTest extends utest.Test {
	public function testACertificateNeedsItsKey():Void {
		var fixture = TLSTestFixture.selfSigned();
		if (fixture == null) {
			Assert.warn("no certificate toolchain on this machine; the case did not run");
			return;
		}
		var socket = new Socket();
		Assert.raises(() -> socket.setCertificate(fixture.certificate, null), ArgumentError);
		Assert.raises(() -> socket.setCertificate(null, fixture.key), ArgumentError);
		socket.setCertificate(fixture.certificate, fixture.key);
		socket.setCertificate(null, null);
		Assert.isNull(socket.peerCertificate, "a socket never connected has a peer certificate");
	}

	/** A certificate loaded from a file or from PEM says its name and its bytes, the same either way. **/
	public function testALoadedCertificateSaysItsCommonNameAndItsDer():Void {
		var chain = TLSChainFixture.get();
		var fixture = TLSTestFixture.trusted();
		if (chain == null || fixture == null) {
			Assert.warn("no certificate toolchain on this machine; the case did not run");
			return;
		}
		Assert.equals("crossbyte-test-client", chain.client.commonName);
		Assert.equals("localhost", fixture.certificate.commonName);
		var der = chain.client.der;
		Assert.notNull(der);
		Assert.equals(0x30, der.get(0), "the DER does not start with a sequence");
		var again = Certificate.fromPem(sys.io.File.getContent(haxe.io.Path.join([chain.directory, "client.pem"])));
		Assert.equals(der.toHex(), again.der.toHex(), "a certificate read from PEM text is not the one read from its file");
		// A chain's first certificate is the leaf's.
		Assert.equals("localhost", chain.fullChain.commonName);
		// And read back from its own DER, as a peer's is.
		var fromDer = @:privateAccess Certificate.__fromDer(der);
		Assert.equals("crossbyte-test-client", fromDer.commonName);
		Assert.equals(der.toHex(), fromDer.der.toHex());
	}

	#if (cpp || java || jvm || nodejs)
	/**
		A client presenting a certificate the server's authority issued is let
		in, and moves bytes; the server reads the client's certificate and the
		client the server's.
	**/
	@:timeout(20000)
	public function testAClientPresentsItsCertificateAndEachEndReadsTheOthers(async:Async):Void {
		var setup = __server();
		if (setup == null) {
			async.done();
			return;
		}
		var server = setup.server;
		var accepted:Array<Socket> = [];
		var heard = "";
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) {
			var socket = e.socket;
			accepted.push(socket);
			socket.addEventListener(ProgressEvent.SOCKET_DATA, _ -> heard += socket.readUtfBytes(socket.bytesAvailable));
		});
		server.bind(0, "127.0.0.1");
		server.listen();
		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var client = new Socket();
			client.secure = true;
			client.certAuthority = setup.fixture.certificate;
			client.setCertificate(setup.chain.client, setup.chain.clientKey);
			var connected = false;
			var failure:String = null;
			client.addEventListener(Event.CONNECT, function(_) {
				connected = true;
				client.writeUtfBytes("from a known client");
				client.flush();
			});
			client.addEventListener(IOErrorEvent.IO_ERROR, (e:IOErrorEvent) -> failure = e.text);
			client.connect("127.0.0.1", server.localPort);
			NetPump.until(() -> heard.length >= 19 || failure != null, 10.0, function(_) {
				Assert.isNull(failure, "a client presenting a certificate the authority issued was refused: " + failure);
				Assert.equals("from a known client", heard);
				Assert.equals(1, accepted.length);
				if (accepted.length > 0) {
					var peer = accepted[0].peerCertificate;
					Assert.notNull(peer, "the server cannot read the client's certificate");
					if (peer != null) {
						Assert.equals("crossbyte-test-client", peer.commonName);
						Assert.equals(setup.chain.client.der.toHex(), peer.der.toHex(), "the certificate read is not the one presented");
					}
				}
				var serverCertificate = client.peerCertificate;
				Assert.notNull(serverCertificate, "the client cannot read the server's certificate");
				if (serverCertificate != null) {
					Assert.equals("localhost", serverCertificate.commonName);
				}
				try client.close() catch (_:Dynamic) {}
				try server.close() catch (_:Dynamic) {}
				async.done();
			});
		});
	}

	/** Without one, the server lets nothing in. **/
	@:timeout(20000)
	public function testAClientPresentingNoCertificateIsNotLetIn(async:Async):Void {
		var setup = __server();
		if (setup == null) {
			async.done();
			return;
		}
		var server = setup.server;
		var accepted = 0;
		server.addEventListener(ServerSocketConnectEvent.CONNECT, _ -> accepted++);
		server.bind(0, "127.0.0.1");
		server.listen();
		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var client = new Socket();
			client.secure = true;
			client.certAuthority = setup.fixture.certificate;
			var ended = false;
			client.addEventListener(IOErrorEvent.IO_ERROR, _ -> ended = true);
			client.addEventListener(Event.CLOSE, _ -> ended = true);
			client.connect("127.0.0.1", server.localPort);
			NetPump.until(() -> ended && server.handshakeFailures >= 1, 10.0, function(_) {
				Assert.isTrue(ended, "a client presenting no certificate was not turned away");
				Assert.equals(0, accepted, "a client presenting no certificate was let in");
				try client.close() catch (_:Dynamic) {}
				try server.close() catch (_:Dynamic) {}
				async.done();
			});
		});
	}

	/** A `wss://` client presents one too, and the session reads it. **/
	@:timeout(20000)
	public function testAWebSocketClientPresentsItsCertificate(async:Async):Void {
		var chain = TLSChainFixture.get();
		var fixture = TLSTestFixture.trusted();
		if (chain == null || fixture == null) {
			Assert.warn("no certificate toolchain on this machine; the case did not run");
			async.done();
			return;
		}
		var server = new ServerWebSocket(true);
		server.cert = {certificate: fixture.certificate, key: fixture.key};
		server.requireClientCertificate(chain.root);
		var sessions:Array<WebSocket> = [];
		server.addEventListener(ServerSocketConnectEvent.CONNECT, (e:ServerSocketConnectEvent) -> sessions.push(cast e.socket));
		server.bind(0, "127.0.0.1");
		server.listen();
		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var client = new WebSocket();
			client.secure = true;
			client.certAuthority = fixture.certificate;
			client.setCertificate(chain.client, chain.clientKey);
			var opened = false;
			var failure:String = null;
			client.addEventListener(Event.CONNECT, _ -> opened = true);
			client.addEventListener(IOErrorEvent.IO_ERROR, (e:IOErrorEvent) -> failure = e.text);
			client.connect("127.0.0.1", server.localPort);
			NetPump.until(() -> (opened && sessions.length > 0) || failure != null, 10.0, function(_) {
				Assert.isNull(failure, "a wss:// client presenting a certificate was refused: " + failure);
				Assert.equals(1, sessions.length);
				if (sessions.length > 0) {
					var peer = sessions[0].peerCertificate;
					Assert.notNull(peer, "the session cannot read the client's certificate");
					if (peer != null) {
						Assert.equals("crossbyte-test-client", peer.commonName);
					}
				}
				var serverCertificate = client.peerCertificate;
				Assert.isTrue(serverCertificate != null && serverCertificate.commonName == "localhost", "the client cannot read the server's certificate");
				try client.close() catch (_:Dynamic) {}
				for (session in sessions) {
					try session.close() catch (_:Dynamic) {}
				}
				try server.close() catch (_:Dynamic) {}
				async.done();
			});
		});
	}

	/** A TLS server presenting the fixture's certificate and requiring the chain's root to have issued the client's. **/
	private static function __server():Null<{server:ServerSocket, fixture:TLSTestFixture.TLSFixtureData, chain:TLSChainFixture.TLSChainData}> {
		var chain = TLSChainFixture.get();
		var fixture = TLSTestFixture.trusted();
		if (chain == null || fixture == null) {
			Assert.warn("no certificate toolchain on this machine; the case did not run");
			return null;
		}
		var server = new ServerSocket(true);
		server.setCertificate(fixture.certificate, fixture.key);
		server.requireClientCertificate(chain.root);
		server.handshakeTimeout = 5;
		return {server: server, fixture: fixture, chain: chain};
	}
	#end
}
