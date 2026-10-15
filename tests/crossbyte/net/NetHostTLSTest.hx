package crossbyte.net;

import crossbyte.errors.ArgumentError;
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ProgressEvent;
import crossbyte.io.ByteArray;
import utest.Assert;
import utest.Async;

/**
	A `wss://` `NetHost` serves with the certificate it is given.

	It can be given one before it binds: a TLS server's material has to be
	in place before it binds, so a constructor binding its
	`ServerWebSocket` itself, with no way to reach `cert` first, would fail
	every handshake with nothing to say why.
**/
class NetHostTLSTest extends utest.Test {
	// An address that is not this machine's, from a block kept for
	// documentation (RFC 5737): a host refused before it binds never touches
	// it, and one that tried to bind it could not.
	private static inline var ELSEWHERE:String = "192.0.2.1:8443";

	public function testAWssHostWithoutACertificateIsRefused():Void {
		Assert.raises(() -> new NetHost('wss://$ELSEWHERE'), ArgumentError);
	}

	/** `tls://` is TCP with TLS: a port is needed, and it asks for TLS. **/
	public function testTheTlsSchemeIsTcpWithTls():Void {
		var endpoint = Endpoint.parseUrl("tls://hub.internal:7000");
		Assert.equals(Protocol.TCP, endpoint.protocol);
		Assert.isTrue(endpoint.secure);
		Assert.equals(7000, endpoint.port);
		Assert.isFalse(Endpoint.parseUrl("tcp://hub.internal:7000").secure);
		Assert.raises(() -> Endpoint.parseUrl("tls://hub.internal"), ArgumentError);
		Assert.raises(() -> Endpoint.parseUrl("tls://hub.internal:7000/path"), ArgumentError);
	}

	public function testATlsHostWithoutACertificateAndKeyIsRefused():Void {
		Assert.raises(() -> new NetHost('tls://$ELSEWHERE'), ArgumentError);
		var fixture = TLSTestFixture.selfSigned();
		if (fixture == null) {
			Assert.warn("no certificate toolchain on this machine; the case did not run");
			return;
		}
		Assert.raises(() -> new NetHost('tls://$ELSEWHERE', null, null, null, false, {certificate: fixture.certificate}), ArgumentError);
		Assert.raises(() -> new NetHost('wss://$ELSEWHERE', null, null, null, false, {key: fixture.key}), ArgumentError);
	}

	/** A connection given options it would not use says so, rather than dialling plain. **/
	public function testAConnectionGivenTlsOptionsItWouldNotUseIsRefused():Void {
		var fixture = TLSTestFixture.selfSigned();
		if (fixture == null) {
			Assert.warn("no certificate toolchain on this machine; the case did not run");
			return;
		}
		var tls:TLSOptions = {certAuthority: fixture.certificate};
		Assert.raises(() -> new NetConnection('tcp://$ELSEWHERE', null, null, null, null, false, tls), ArgumentError);
		Assert.raises(() -> new NetConnection('ws://$ELSEWHERE', null, null, null, null, false, tls), ArgumentError);
		Assert.raises(() -> new NetConnection('rudp://$ELSEWHERE', null, null, null, null, false, tls), ArgumentError);
		Assert.raises(() -> new NetConnection('tls://$ELSEWHERE', null, null, null, null, false, {certificate: fixture.certificate}), ArgumentError);
	}

	public function testACertificateForAHostThatWouldNotUseItIsRefused():Void {
		var fixture = TLSTestFixture.selfSigned();
		if (fixture == null) {
			Assert.warn("no certificate toolchain on this machine; the case did not run");
			return;
		}
		Assert.raises(() -> new NetHost('tcp://$ELSEWHERE', null, null, null, false, {certificate: fixture.certificate, key: fixture.key}),
			ArgumentError);
	}

	#if (cpp || java || jvm || nodejs)
	/**
		A `tls://` host requiring client certificates and a `tls://`
		connection presenting one, from one set of options as Yggdrasil's
		hosts dial each other: bytes both ways, and the host reads who
		dialled it.
	**/
	@:timeout(20000)
	public function testATlsHostAndConnectionTalkOverMutualTls(async:Async):Void {
		__mutual("tls", async);
	}

	/** And a `wss://` host and connection, the same way. **/
	@:timeout(20000)
	public function testAWssHostAndConnectionTalkOverMutualTls(async:Async):Void {
		__mutual("wss", async);
	}

	private static function __mutual(scheme:String, async:Async):Void {
		var fixture = TLSTestFixture.trusted();
		var chain = TLSChainFixture.get();
		if (fixture == null || chain == null) {
			Assert.warn("no certificate toolchain on this machine; the case did not run");
			async.done();
			return;
		}
		var dialers:Array<Null<String>> = [];
		var hostTls:TLSOptions = {certificate: fixture.certificate, key: fixture.key, clientAuthority: chain.root};
		var host = new NetHost('$scheme://127.0.0.1:0', function(connection:INetConnection) {
			var accepted:NetConnection = NetConnection.fromINetConnection(connection);
			var socket:Socket = scheme == "tls" ? NetConnection.toSocket(accepted) : NetConnection.toWebSocket(accepted);
			var peer = socket.peerCertificate;
			dialers.push(peer == null ? null : peer.commonName);
			connection.onData = input -> {
				var answer = new ByteArray();
				answer.writeUtfBytes(input.readUtfBytes(input.bytesAvailable).toUpperCase());
				answer.position = 0;
				connection.send(answer);
			};
			connection.readEnabled = true;
		}, null, null, true, hostTls);

		NetPump.until(() -> host.localPort != 0, 5.0, function(_) {
			var heard = "";
			var failure:Reason = null;
			var dialTls:TLSOptions = {certAuthority: fixture.certificate, certificate: chain.client, key: chain.clientKey};
			var connection:NetConnection = null;
			connection = new NetConnection('$scheme://127.0.0.1:${host.localPort}' + (scheme == "wss" ? "/" : ""), input -> heard += input.readUtfBytes(input.bytesAvailable),
				() -> {
					var hello = new ByteArray();
					hello.writeUtfBytes("over " + scheme);
					hello.position = 0;
					connection.send(hello);
				}, null, reason -> failure = reason, true, dialTls);
			NetPump.until(() -> heard.length >= 4 + scheme.length || failure != null, 10.0, function(_) {
				Assert.isNull(failure, "a connection presenting a certificate the authority issued failed: " + failure);
				Assert.equals(("over " + scheme).toUpperCase(), heard);
				Assert.same(["crossbyte-test-client"], dialers, "the host could not read who dialled it");
				var socket:Socket = scheme == "tls" ? NetConnection.toSocket(connection) : NetConnection.toWebSocket(connection);
				Assert.isTrue(socket.secure, "the connection is not secure");
				Assert.equals("localhost", socket.peerCertificate == null ? null : socket.peerCertificate.commonName);
				connection.close();

				// One presenting nothing is turned away.
				var bare:NetConnection = null;
				var bareReady = false;
				var bareEnded = false;
				bare = new NetConnection('$scheme://127.0.0.1:${host.localPort}' + (scheme == "wss" ? "/" : ""), null, () -> bareReady = true,
					_ -> bareEnded = true, null, false, {certAuthority: fixture.certificate});
				NetPump.until(() -> bareEnded, 10.0, function(_) {
					Assert.isTrue(bareEnded, "a connection presenting no certificate was not turned away");
					Assert.equals(1, dialers.length, "a connection presenting no certificate was let in");

					// And one trusting only the system's authorities refuses the host.
					var untrusting:NetConnection = null;
					var refused:Reason = null;
					untrusting = new NetConnection('$scheme://127.0.0.1:${host.localPort}' + (scheme == "wss" ? "/" : ""), null, null, null,
						reason -> refused = reason, false, {certificate: chain.client, key: chain.clientKey});
					NetPump.until(() -> refused != null, 10.0, function(_) {
						Assert.notNull(refused, "a connection that does not trust the host's certificate connected");
						Assert.equals(1, dialers.length);
						try untrusting.close() catch (_:Dynamic) {}
						try bare.close() catch (_:Dynamic) {}
						host.close();
						async.done();
					});
				});
			});
		});
	}

	@:timeout(20000)
	public function testAWssHostServesWithTheCertificateItWasGiven(async:Async):Void {
		var fixture = TLSTestFixture.trusted();
		if (fixture == null) {
			Assert.warn("no certificate toolchain on this machine; the wss host did not run");
			async.done();
			return;
		}

		// Port 0: wherever the system has one free, rather than a port taken
		// from a listener just closed on the assumption that nothing has taken
		// it since.
		var host = new NetHost('wss://127.0.0.1:0', function(connection:INetConnection) {
			connection.onData = input -> {
				var answer = new ByteArray();
				answer.writeUtfBytes(input.readUtfBytes(input.bytesAvailable).toUpperCase());
				answer.position = 0;
				connection.send(answer);
			};
			connection.readEnabled = true;
		}, null, null, true, {certificate: fixture.certificate, key: fixture.key});

		// Node claims the port a turn after listen().
		NetPump.until(() -> host.localPort != 0, 5.0, function(_) {
			var heard:String = "";
			var failure:String = null;
			var client = new WebSocket();
			client.secure = true;
			client.certAuthority = fixture.certificate;
			client.addEventListener(Event.CONNECT, function(_) {
				client.writeUtfBytes("over wss");
				client.flush();
			});
			client.addEventListener(ProgressEvent.SOCKET_DATA, function(_) heard += client.readUtfBytes(client.bytesAvailable));
			client.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent) failure = e.text);
			client.connect("127.0.0.1", host.localPort);

			NetPump.until(() -> heard.length >= 8 || failure != null, 10.0, function(_) {
				Assert.equals("OVER WSS", heard, "the wss host did not answer: " + failure);
				try client.close() catch (_:Dynamic) {}
				try host.close() catch (_:Dynamic) {}
				async.done();
			});
		});
	}
	#end
}
