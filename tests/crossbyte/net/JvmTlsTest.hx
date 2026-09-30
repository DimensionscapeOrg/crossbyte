package crossbyte.net;

#if (java || jvm)
import crossbyte._internal.socket.FlexSocket;
import crossbyte._internal.socket._jvm.JvmSslExterns;
import crossbyte.events.ServerSocketConnectEvent;
import utest.Assert;

/**
	The jvm TLS backend against the JDK's own TLS stack, one behaviour each.

	`ServerSocketTLSTest` covers the handshake, ALPN, SNI and client
	certificates with one self-signed certificate. What needs more than that
	is here: chains and bundles, which need an authority; failures, which
	need a peer that misbehaves; and what a connection costs, which needs
	more than one.
**/
class JvmTlsTest extends utest.Test {
	// ------------------------------------------------------------ chains

	/**
		A server presents every certificate of its PEM file, not just the
		first. A certificate from an authority comes as `fullchain.pem`, the
		leaf and then the intermediate that issued it, and a client trusts
		only the root: presented alone, the leaf cannot be traced to it, and
		curl, Node, browsers and the JDK all refuse the server.
	**/
	public function testAServerPresentsTheWholeChainOfItsFile():Void {
		var chain = TLSChainFixture.get();
		if (chain == null) {
			Assert.pass();
			return;
		}

		var presented:Int = -1;
		var outcome = __serve(function(server) server.setCertificate(chain.fullChain, chain.leafKey), function(port) {
			var peer = JdkTlsPeer.connect(port, {trust: [__path(chain, "root.pem")]});
			presented = peer.getSession().getPeerCertificates().length;
			peer.close();
		});

		Assert.isTrue(outcome.finished, "the client neither finished nor failed");
		Assert.isNull(outcome.failure, "a client trusting only the root refused the server's chain: " + outcome.failure);
		Assert.equals(2, presented, 'the server presented $presented of the two certificates in its file');
	}

	/**
		A PEM file holding the key beside the chain, a common way to ship
		one, is read for its certificates. The JDK's reader fails on the first
		block that is not a certificate, where native and Node pass over it.
	**/
	public function testACertificateFileMayCarryItsKeyToo():Void {
		var chain = TLSChainFixture.get();
		if (chain == null) {
			Assert.pass();
			return;
		}

		var combined:String = sys.io.File.getContent(__path(chain, "leaf.key")) + sys.io.File.getContent(__path(chain, "fullchain.pem"));
		var presented:Int = -1;
		var outcome = __serve(function(server) server.setCertificate(Certificate.fromPem(combined), chain.leafKey), function(port) {
			var peer = JdkTlsPeer.connect(port, {trust: [__path(chain, "root.pem")]});
			presented = peer.getSession().getPeerCertificates().length;
			peer.close();
		});

		Assert.isNull(outcome.failure, "a certificate file with its key in it could not be served: " + outcome.failure);
		Assert.equals(2, presented, 'the server presented $presented of the two certificates in its file');
	}

	/** The same for a certificate chosen by the name the client asks for. **/
	public function testAnSniCertificatePresentsItsWholeChain():Void {
		var chain = TLSChainFixture.get();
		if (chain == null) {
			Assert.pass();
			return;
		}

		var presented:Int = -1;
		var outcome = __serve(function(server) {
			server.setCertificate(chain.direct, chain.directKey);
			server.addSNICertificate(function(name) return name == "chain.test", chain.fullChain, chain.leafKey);
		}, function(port) {
			var peer = JdkTlsPeer.connect(port, {trust: [__path(chain, "root.pem")], serverName: "chain.test"});
			presented = peer.getSession().getPeerCertificates().length;
			peer.close();
		});

		Assert.isTrue(outcome.finished, "the client neither finished nor failed");
		Assert.isNull(outcome.failure, "a client trusting only the root refused the chain chosen by SNI: " + outcome.failure);
		Assert.equals(2, presented, 'the SNI entry presented $presented of the two certificates in its file');
	}

	/**
		A client trusts every authority of a bundle it is given, as its own CA
		or as the default every socket falls back to. The first entry alone
		was trusted, so a certificate from any other authority in the file was
		refused.
	**/
	public function testAClientTrustsEveryAuthorityOfABundle():Void {
		var chain = TLSChainFixture.get();
		if (chain == null) {
			Assert.pass();
			return;
		}

		var own:String = "not run";
		var byDefault:String = "not run";
		var outcome = __serve(function(server) server.setCertificate(chain.direct, chain.directKey), function(port) {
			own = __dial(port, function(client) client.setCA(@:privateAccess chain.bundle.__native));

			var previous = FlexSocket.DEFAULT_CA;
			FlexSocket.DEFAULT_CA = @:privateAccess chain.bundle.__native;
			try {
				byDefault = __dial(port, null);
			} catch (e:Dynamic) {
				FlexSocket.DEFAULT_CA = previous;
				throw e;
			}
			FlexSocket.DEFAULT_CA = previous;
		});

		Assert.isTrue(outcome.finished, "the client neither finished nor failed");
		Assert.isNull(own, "a client given a bundle refused a certificate from its second authority: " + own);
		Assert.isNull(byDefault, "the default bundle's second authority was not trusted: " + byDefault);
	}

	/** And a server requiring client certificates accepts one from any of them. **/
	public function testAServerTrustsEveryAuthorityOfItsClientBundle():Void {
		var chain = TLSChainFixture.get();
		if (chain == null) {
			Assert.pass();
			return;
		}

		var answer:String = null;
		var outcome = __serve(function(server) {
			server.setCertificate(chain.direct, chain.directKey);
			server.requireClientCertificate(chain.bundle);
		}, function(port) {
			var peer = JdkTlsPeer.connect(port, {
				trust: [__path(chain, "root.pem")],
				present: {chain: __path(chain, "client.pem"), key: chain.clientKey}
			});
			// The verdict on a client's certificate can come after the
			// client's handshake has returned (TLS 1.3 sends it after the
			// server's Finished), so it is read off a round trip.
			JdkTlsPeer.send(peer, "ping");
			answer = JdkTlsPeer.receive(peer, 4);
			peer.close();
		}, __echo);

		Assert.isTrue(outcome.finished, "the client neither finished nor failed");
		Assert.isNull(outcome.failure, "a client certificate from the bundle's second authority was refused: " + outcome.failure);
		Assert.equals("ping", answer, "the server did not answer a client whose certificate it should trust");
	}

	// ----------------------------------------------------------- helpers

	/** Echoes whatever a connection sends. **/
	private static function __echo(socket:crossbyte.net.Socket):Void {
		socket.addEventListener(crossbyte.events.ProgressEvent.SOCKET_DATA, function(_) {
			var bytes = new crossbyte.io.ByteArray();
			socket.readBytes(bytes, 0, socket.bytesAvailable);
			socket.writeBytes(bytes, 0, bytes.length);
			socket.flush();
		});
	}

	private static function __path(chain:TLSChainFixture.TLSChainData, name:String):String {
		return haxe.io.Path.join([chain.directory, name]);
	}

	/**
		Connects a CrossByte TLS client that verifies, configured by
		`configure`. Null when it connected; the failure when it did not.
	**/
	private static function __dial(port:Int, configure:Null<FlexSocket->Void>):Null<String> {
		var client = new FlexSocket(true);
		try {
			client.setTimeout(10);
			if (configure != null) {
				configure(client);
			}
			client.connect("127.0.0.1", port);
		} catch (e:Dynamic) {
			try {
				client.close();
			} catch (_:Dynamic) {}
			return Std.string(e);
		}
		try {
			client.close();
		} catch (_:Dynamic) {}
		return null;
	}

	/**
		A CrossByte TLS server configured by `configure`, and `peer` run
		against it on a thread of its own while the runtime is pumped here,
		which is how a secure server completes handshakes in production. Every
		connection it accepted, and the server, are closed on every path.
	**/
	private function __serve(configure:ServerSocket->Void, peer:Int->Void, ?onAccept:crossbyte.net.Socket->Void,
			seconds:Float = 20):{finished:Bool, failure:Null<String>, accepted:Int, handshakeFailures:Int} {
		var runtime = crossbyte.core.CrossByte.current();
		var server = new ServerSocket(true);
		var accepted:Array<crossbyte.net.Socket> = [];

		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) {
			accepted.push(e.socket);
			if (onAccept != null) {
				onAccept(e.socket);
			}
		});

		var failure:Null<String> = null;
		// The worker writes what the assertions read and then releases this.
		// Read after a wait() that returned true, those writes are published
		// rather than raced for.
		var handoff = new sys.thread.Lock();
		var finished = false;

		try {
			configure(server);
			server.bind(0, "127.0.0.1");
			server.listen();
			var port = server.localPort;

			sys.thread.Thread.create(() -> {
				try {
					peer(port);
				} catch (e:Dynamic) {
					failure = Std.string(e);
				}
				handoff.release();
			});

			var deadline = haxe.Timer.stamp() + seconds;
			while (haxe.Timer.stamp() < deadline && !finished) {
				runtime.pump(1 / 60, 0);
				finished = handoff.wait(0.002);
			}

			// A few more passes, so a connection completing on the peer's last
			// breath reaches the pump before the assertions read it.
			var settle = haxe.Timer.stamp() + 0.3;
			while (haxe.Timer.stamp() < settle) {
				runtime.pump(1 / 60, 0);
				Sys.sleep(0.002);
			}
		} catch (e:Dynamic) {
			if (failure == null) {
				failure = Std.string(e);
			}
		}

		var failures = server.handshakeFailures;
		for (socket in accepted) {
			try {
				socket.close();
			} catch (_:Dynamic) {}
		}
		try {
			server.close();
		} catch (_:Dynamic) {}

		return {
			finished: finished,
			failure: failure,
			accepted: accepted.length,
			handshakeFailures: failures
		};
	}
}
#end
