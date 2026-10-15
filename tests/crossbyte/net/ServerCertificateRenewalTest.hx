package crossbyte.net;

#if !(js && !nodejs)
import crossbyte.core.CrossByte;
import crossbyte.errors.ArgumentError;
import crossbyte.errors.Error as CBError;
import crossbyte.errors.IllegalOperationError;
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ProgressEvent;
import crossbyte.events.ServerSocketConnectEvent;
import utest.Assert;
import utest.Async;

/**
	A TLS server given a new certificate while it runs: each handshake from
	then on presents the new one, and each connection already up goes on
	with the one it began with, so a certificate renewed on disk is taken
	without a restart or a dropped client. Over a `ServerSocket`, a
	`ServerWebSocket`, a `tls://` `NetHost`, an `HTTPServer` reading its
	files again, a server spread over runtimes (and with `reusePort`, a
	listener on each), and SNI certificates replaced together.

	Which certificate a handshake met is told by trusting only one: a probe
	that trusts the old certificate is refused once the new one is presented,
	and one that trusts the new is let in. The two are made for the same
	names, so nothing else tells them apart.
**/
class ServerCertificateRenewalTest extends utest.Test {
	/** Where no certificate is presented, none is taken, and a closed server takes none. **/
	public function testACertificateIsRefusedWhereNoneIsPresented():Void {
		var fixture = TLSTestFixture.trusted();
		if (fixture == null) {
			Assert.warn("no certificate toolchain on this machine; the case did not run");
			return;
		}
		var plain = new ServerSocket();
		Assert.raises(() -> plain.setCertificate(fixture.certificate, fixture.key), CBError);
		Assert.raises(() -> plain.clearSniCertificates(), CBError);
		plain.close();

		var host = new NetHost("tcp://127.0.0.1:0");
		Assert.raises(() -> host.setCertificate(fixture.certificate, fixture.key), IllegalOperationError);
		host.close();

		#if (cpp || hl || neko || java || jvm || nodejs)
		var secure = new ServerSocket(true);
		Assert.raises(() -> secure.setCertificate(null, fixture.key), ArgumentError);
		Assert.raises(() -> secure.setCertificate(fixture.certificate, null), ArgumentError);
		Assert.raises(() -> secure.addSniCertificate(_ -> true, fixture.certificate, null), ArgumentError);
		secure.setCertificate(fixture.certificate, fixture.key);
		secure.close();
		Assert.raises(() -> secure.setCertificate(fixture.certificate, fixture.key), CBError);
		Assert.raises(() -> secure.clearSniCertificates(), CBError);
		#end
	}

	#if (cpp || hl || neko || java || jvm || nodejs)
	/**
		A `ServerSocket` listening with one certificate and given another:
		new handshakes meet the new one, and natively, on the jvm and on Node
		a connection made before the change still carries data both ways.
	**/
	@:timeout(60000)
	public function testARunningServerPresentsTheNewCertificate(async:Async):Void {
		var pair = __pair();
		if (pair == null) {
			async.done();
			return;
		}
		var server = new ServerSocket(true);
		var peers:Array<Socket> = [];
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) {
			var peer = e.socket;
			peers.push(peer);
			peer.addEventListener(ProgressEvent.SOCKET_DATA, function(_) {
				peer.writeUtfBytes(peer.readUtfBytes(peer.bytesAvailable).toUpperCase());
				peer.flush();
			});
		});
		server.setCertificate(pair.first.certificate, pair.first.key);
		server.bind(0, "127.0.0.1");
		server.listen();
		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var port:Int = server.localPort;
			__keptConnection(port, pair.first.certificate, function(kept) {
				TlsProbe.run(port, {serverName: "localhost", trust: pair.first.certificate}, function(before) {
					Assert.isNull(before.error, "the first certificate was not presented to begin with: " + before.error);
					server.setCertificate(pair.second.certificate, pair.second.key);
					__presentsOnly(port, "localhost", pair.second.certificate, pair.first.certificate, "a ServerSocket", function() {
						kept.exchange("after", function(answer) {
							#if (cpp || java || jvm || nodejs)
							Assert.equals("AFTER", answer, "a connection made before the change stopped carrying data");
							#end
							kept.close();
							for (peer in peers) {
								try peer.close() catch (_:Dynamic) {}
							}
							server.close();
							async.done();
						});
					});
				});
			});
		});
	}

	/**
		A `tls://` `NetHost` given a new certificate presents it from then on,
		through `INetHost.setCertificate`.
	**/
	@:timeout(60000)
	public function testAHostPresentsTheNewCertificate(async:Async):Void {
		var pair = __pair();
		if (pair == null) {
			async.done();
			return;
		}
		var host = new NetHost("tls://127.0.0.1:0", null, null, null, true, {certificate: pair.first.certificate, key: pair.first.key});
		NetPump.until(() -> host.localPort != 0, 5.0, function(_) {
			var port:Int = host.localPort;
			TlsProbe.run(port, {serverName: "localhost", trust: pair.first.certificate}, function(before) {
				Assert.isNull(before.error, "the host's first certificate was not presented: " + before.error);
				host.setCertificate(pair.second.certificate, pair.second.key);
				__presentsOnly(port, "localhost", pair.second.certificate, pair.first.certificate, "a tls:// host", function() {
					host.close();
					async.done();
				});
			});
		});
	}
	#end

	#if (cpp || java || jvm || nodejs)
	/** A `ServerWebSocket` given a new `cert` presents it from then on. **/
	@:timeout(60000)
	public function testARunningWebSocketServerPresentsTheNewCertificate(async:Async):Void {
		var pair = __pair();
		if (pair == null) {
			async.done();
			return;
		}
		var server = new ServerWebSocket(true);
		server.cert = {certificate: pair.first.certificate, key: pair.first.key};
		server.bind(0, "127.0.0.1");
		server.listen();
		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var port:Int = server.localPort;
			TlsProbe.run(port, {serverName: "localhost", trust: pair.first.certificate}, function(before) {
				Assert.isNull(before.error, "the first certificate was not presented to begin with: " + before.error);
				server.cert = {certificate: pair.second.certificate, key: pair.second.key};
				__presentsOnly(port, "localhost", pair.second.certificate, pair.first.certificate, "a ServerWebSocket", function() {
					server.close();
					async.done();
				});
			});
		});
	}

	/**
		SNI certificates replaced on a running server, by clearing them and
		adding the new in one pass: a name they cover meets the new one, and
		once cleared, no longer the old.
	**/
	@:timeout(60000)
	public function testSniCertificatesAreReplacedTogether(async:Async):Void {
		var pair = __pair();
		// Made fresh each day, unlike selfSignedFor's, which last one.
		var old = TLSTestFixture.trusted(["alt.example"]);
		var renewed = TLSTestFixture.trusted(["alt.example", "localhost"]);
		if (pair == null || old == null || renewed == null) {
			Assert.warn("no certificate toolchain on this machine; the case did not run");
			async.done();
			return;
		}
		var server = new ServerSocket(true);
		server.setCertificate(pair.first.certificate, pair.first.key);
		server.addSniCertificate(name -> name == "alt.example", old.certificate, old.key);
		// A server takes connections only for someone listening for them.
		server.addEventListener(ServerSocketConnectEvent.CONNECT, e -> try e.socket.close() catch (_:Dynamic) {});
		server.bind(0, "127.0.0.1");
		server.listen();
		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var port:Int = server.localPort;
			TlsProbe.run(port, {serverName: "alt.example", trust: old.certificate}, function(before) {
				Assert.isNull(before.error, "the name's first certificate was not presented to begin with: " + before.error);
				server.clearSniCertificates();
				server.addSniCertificate(name -> name == "alt.example", renewed.certificate, renewed.key);
				__presentsOnly(port, "alt.example", renewed.certificate, old.certificate, "an SNI name", function() {
					// And cleared alone, the name gets the server's own.
					server.clearSniCertificates();
					TlsProbe.run(port, {serverName: "alt.example", trust: renewed.certificate}, function(cleared) {
						Assert.notNull(cleared.error, "a cleared SNI certificate was still presented");
						TlsProbe.run(port, {serverName: "localhost", trust: pair.first.certificate}, function(unnamed) {
							Assert.isNull(unnamed.error, "clearing the SNI certificates took the server's own away: " + unnamed.error);
							server.close();
							async.done();
						});
					});
				});
			});
		});
	}
	#end

	#if (cpp || hl || neko || java || jvm)
	/**
		`HTTPServer.reloadCertificate()` reads the configured files again:
		a renewal written over them is presented from then on. On a server
		with no TLS it is refused.
	**/
	@:timeout(60000)
	public function testAnHttpServerReadsItsCertificateAgain(async:Async):Void {
		var pair = __pair();
		if (pair == null) {
			async.done();
			return;
		}
		var directory = crossbyte.io.File.createTempDirectory();
		var certPath:String = haxe.io.Path.join([directory.nativePath, "cert.pem"]);
		var keyPath:String = haxe.io.Path.join([directory.nativePath, "key.pem"]);
		sys.io.File.copy(pair.first.certificatePath, certPath);
		sys.io.File.copy(pair.first.keyPath, keyPath);

		var plain = new crossbyte.http.HTTPServer(new crossbyte.http.HTTPServerConfig("127.0.0.1", 0));
		Assert.raises(() -> plain.reloadCertificate(), IllegalOperationError);
		plain.close();

		var config = new crossbyte.http.HTTPServerConfig("127.0.0.1", 0);
		config.tlsCertificatePath = certPath;
		config.tlsKeyPath = keyPath;
		var server = new crossbyte.http.HTTPServer(config);
		var port:Int = server.localPort;
		TlsProbe.run(port, {serverName: "localhost", trust: pair.first.certificate}, function(before) {
			Assert.isNull(before.error, "the configured certificate was not presented to begin with: " + before.error);
			sys.io.File.copy(pair.second.certificatePath, certPath);
			sys.io.File.copy(pair.second.keyPath, keyPath);
			server.reloadCertificate();
			__presentsOnly(port, "localhost", pair.second.certificate, pair.first.certificate, "an HTTPServer", function() {
				server.close();
				try directory.deleteDirectory(true) catch (_:Dynamic) {}
				async.done();
			});
		});
	}
	#end

	#if (cpp || java || jvm)
	/**
		A server spread over runtimes presents a new certificate on every
		one: without `reusePort` every connection is accepted from the one
		listener, and with it (on Linux) each runtime's own listener is given
		the change on that runtime.
	**/
	@:timeout(60000)
	public function testEveryRuntimeOfASpreadServerPresentsTheNewCertificate():Void {
		var pair = __pair();
		if (pair == null) {
			return;
		}
		for (reusePort in [false, true]) {
			if (reusePort && !SpreadSupport.reusePortExpected()) {
				continue;
			}
			var acceptor:CrossByte = SpreadSupport.runtime();
			var runtimes:Array<CrossByte> = [for (_ in 0...3) SpreadSupport.runtime()];
			var server:ServerSocket = SpreadSupport.on(acceptor, () -> {
				var server = new ServerSocket(true);
				server.setCertificate(pair.first.certificate, pair.first.key);
				server.reusePort = reusePort;
				server.runtimes = runtimes;
				server.addEventListener(ServerSocketConnectEvent.CONNECT, e -> try e.socket.close() catch (_:Dynamic) {});
				server.bind(0, "127.0.0.1");
				server.listen();
				return server;
			});
			var label:String = reusePort ? "with reusePort" : "without reusePort";
			for (i in 0...6) {
				Assert.isNull(__blockingHandshake(server.localPort, pair.first.certificate), '$label, connection $i before the change did not meet the first certificate');
			}
			SpreadSupport.on(acceptor, () -> server.setCertificate(pair.second.certificate, pair.second.key));
			// With reusePort each runtime takes it at its next pass.
			crossbyte.sys.System.sleep(0.2);
			for (i in 0...9) {
				Assert.isNull(__blockingHandshake(server.localPort, pair.second.certificate), '$label, connection $i after the change did not meet the new certificate');
				Assert.notNull(__blockingHandshake(server.localPort, pair.first.certificate), '$label, connection $i after the change met the old certificate');
			}
			SpreadSupport.on(acceptor, () -> server.close());
			SpreadSupport.stop([acceptor].concat(runtimes));
		}
	}

	/** A verified handshake from this thread: null, or why it failed. **/
	private static function __blockingHandshake(port:Int, trusted:Certificate):Null<String> {
		var client = new crossbyte._internal.socket.FlexSocket(true);
		try {
			client.setTimeout(5);
			client.setCA(@:privateAccess trusted.__native);
			client.setHostname("localhost");
			client.connect("127.0.0.1", port);
			client.close();
			return null;
		} catch (error:Dynamic) {
			try client.close() catch (_:Dynamic) {}
			return Std.string(error);
		}
	}
	#end

	#if (cpp || hl || neko || java || jvm || nodejs)
	/** Two certificates for the same names, or null with a warning where none can be made. **/
	private static function __pair():Null<{first:TLSTestFixture.TLSFixtureData, second:TLSTestFixture.TLSFixtureData}> {
		var first = TLSTestFixture.trusted();
		var second = TLSTestFixture.trusted(["127.0.0.1", "localhost"]);
		if (first == null || second == null) {
			Assert.warn("no certificate toolchain on this machine; the case did not run");
			return null;
		}
		Assert.notEquals(first.certificate.der.toHex(), second.certificate.der.toHex(), "the two fixtures are one certificate, so this proves nothing");
		return {first: first, second: second};
	}

	/** That `serverName` on `port` meets `current` and no longer `previous`. **/
	private static function __presentsOnly(port:Int, serverName:String, current:Certificate, previous:Certificate, what:String, then:Void->Void):Void {
		TlsProbe.run(port, {serverName: serverName, trust: current}, function(now) {
			Assert.isNull(now.error, '$what given a new certificate did not present it: ' + now.error);
			TlsProbe.run(port, {serverName: serverName, trust: previous}, function(old) {
				Assert.notNull(old.error, '$what given a new certificate still presented the old one');
				then();
			});
		});
	}

	/**
		A connection made now and kept: natively, on the jvm and on Node a
		CrossByte `Socket` trusting `trusted`, through which `exchange` sends
		and reads the server's answer. On neko and HashLink nothing, there
		being no client here to hold one with.
	**/
	private static function __keptConnection(port:Int, trusted:Certificate, then:KeptConnection->Void):Void {
		var kept = new KeptConnection();
		#if (cpp || java || jvm || nodejs)
		var client = new Socket();
		client.secure = true;
		client.certAuthority = trusted;
		kept.client = client;
		var connected:Bool = false;
		client.addEventListener(Event.CONNECT, _ -> connected = true);
		client.addEventListener(IOErrorEvent.IO_ERROR, (e:IOErrorEvent) -> kept.failure = e.text);
		client.addEventListener(ProgressEvent.SOCKET_DATA, _ -> kept.heard += client.readUtfBytes(client.bytesAvailable));
		client.connect("127.0.0.1", port);
		NetPump.until(() -> connected || kept.failure != null, 10.0, function(_) {
			Assert.isTrue(connected, "the connection kept across the change never came up: " + kept.failure);
			then(kept);
		});
		#else
		then(kept);
		#end
	}
	#end
}

#if (cpp || hl || neko || java || jvm || nodejs)
private class KeptConnection {
	public var client:Null<Socket> = null;
	public var failure:Null<String> = null;
	public var heard:String = "";

	public function new() {}

	public function exchange(text:String, then:Null<String>->Void):Void {
		if (client == null) {
			then(null);
			return;
		}
		heard = "";
		client.writeUtfBytes(text);
		client.flush();
		NetPump.until(() -> heard.length >= text.length || failure != null, 10.0, _ -> then(heard));
	}

	public function close():Void {
		if (client != null) {
			try client.close() catch (_:Dynamic) {}
		}
	}
}
#end
#end
