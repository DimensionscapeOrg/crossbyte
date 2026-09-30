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

	/**
		A client presents its certificate to a server that asks for one, the
		whole chain from its file, from a context of its own. What an HTTPS or
		wss client needs to reach a server requiring mutual TLS.
	**/
	public function testAClientPresentsItsCertificateToAServerThatAsks():Void {
		var chain = TLSChainFixture.get();
		if (chain == null) {
			Assert.pass();
			return;
		}

		var server = JdkTlsPeer.listen({
			present: {chain: __path(chain, "direct.pem"), key: chain.directKey},
			trust: [__path(chain, "root.pem")],
			timeout: 5000
		});
		server.setNeedClientAuth(true);
		var port = server.getLocalPort();
		var presented:String = null;
		var done = new sys.thread.Lock();

		sys.thread.Thread.create(() -> {
			try {
				var accepted:SSLSocket = cast server.accept();
				accepted.setSoTimeout(5000);
				accepted.startHandshake();
				var chainSeen = accepted.getSession().getPeerCertificates();
				presented = chainSeen.length > 0 ? JdkTlsPeer.hex(chainSeen[0].getEncoded()) : "none";
				// Answers, so the client knows it was let in whatever the version.
				JdkTlsPeer.send(accepted, "ok");
				accepted.close();
			} catch (e:Dynamic) {
				presented = "refused: " + Std.string(e);
			}
			done.release();
		});

		var answer:String = null;
		var failure = __dial(port, function(client) {
			client.setCA(@:privateAccess chain.root.__native);
			client.setCertificate(@:privateAccess chain.client.__native, @:privateAccess chain.clientKey.__native);
		}, function(client) {
			var buffer = haxe.io.Bytes.alloc(2);
			client.input.readFullBytes(buffer, 0, 2);
			answer = buffer.toString();
		});
		done.wait(10);
		server.close();

		var expected = JdkTlsPeer.hex(JdkTlsPeer.certificates(__path(chain, "client.pem"))[0].getEncoded());
		Assert.isNull(failure, "a client presenting a trusted certificate was refused: " + failure);
		Assert.equals(expected, presented, "the server did not see the client's certificate");
		Assert.equals("ok", answer);
	}

	// ------------------------------------------------ a handshake that fails

	/**
		A client's handshake gives up at its timeout. Its loop caught every
		error, a read that timed out among them, slept 2 ms and tried again,
		ten thousand times: a server that accepted and said nothing held an
		https request for ten thousand times its timeout, and one of the HTTP
		client's pool threads with it.
	**/
	public function testAStalledHandshakeGivesUpAtItsTimeout():Void {
		// Accepts nothing and sends nothing: the system completes each TCP
		// handshake into the listen queue, and no TLS ever answers.
		var silent = new sys.net.Socket();
		silent.bind(new sys.net.Host("127.0.0.1"), 0);
		silent.listen(4);
		var port = silent.host().port;

		var outcome = __dialOnThread(port, function(client) {
			client.verifyCert = false;
			client.setTimeout(0.4);
		}, 8);
		silent.close();

		Assert.isTrue(outcome.finished, "a handshake with a silent server was still waiting after 8 s, with a 0.4 s timeout");
		Assert.notNull(outcome.failure, "a handshake with a silent server succeeded");
		Assert.isTrue(outcome.took < 3, 'a handshake with a 0.4 s timeout gave up after ${outcome.took} s');
	}

	/**
		A connection reset mid-handshake fails the connect at once, with the
		reset as its reason. It was caught and retried like a stall, for 25
		seconds or so, and then reported as a handshake that "did not
		complete".
	**/
	public function testAResetMidHandshakeFailsAtOnceWithItsCause():Void {
		var listener = java.nio.channels.ServerSocketChannel.open();
		listener.bind(new java.net.InetSocketAddress("127.0.0.1", 0), 4);
		var port:Int = (cast listener.getLocalAddress() : java.net.InetSocketAddress).getPort();

		// Takes the connection and resets it: a lingering close of zero
		// sends RST rather than FIN.
		sys.thread.Thread.create(() -> {
			try {
				var accepted = listener.accept();
				accepted.socket().setSoLinger(true, 0);
				accepted.close();
			} catch (_:Dynamic) {}
		});

		var outcome = __dialOnThread(port, function(client) {
			client.verifyCert = false;
			client.setTimeout(10);
		}, 8);
		try {
			listener.close();
		} catch (_:Dynamic) {}

		Assert.isTrue(outcome.finished, "a reset handshake was still being retried after 8 s");
		Assert.notNull(outcome.failure, "a reset handshake succeeded");
		Assert.isTrue(outcome.took < 3, 'a reset handshake took ${outcome.took} s to fail');
		if (outcome.failure != null) {
			Assert.isTrue(outcome.failure.indexOf("did not complete") < 0, "the reset was reported without its cause: " + outcome.failure);
		}
	}

	/**
		A record larger than the buffer it is read into is still read. The
		buffer fills, the engine answers "underflow", not a whole record yet,
		and a read into a full buffer takes nothing, so without growing it
		the handshake waited on a record that could never complete. The engine
		keeps records to the size its session states, so the buffer is shrunk
		here to make one larger than it.
	**/
	public function testARecordLargerThanTheReadBufferIsStillRead():Void {
		var fixture = TLSTestFixture.selfSigned();
		if (fixture == null) {
			Assert.pass();
			return;
		}

		var outcome = __serve(function(server) server.setCertificate(fixture.certificate, fixture.key), function(port) {
			var client = new FlexSocket(true);
			client.verifyCert = false;
			client.setBlocking(false);
			client.connect("127.0.0.1", port);
			// The size its buffers are made at. A certificate message alone
			// is larger than this.
			@:privateAccess (cast client : crossbyte._internal.socket._jvm.JvmSsl.JvmSslSocket).__bufferSize = 512;

			var done = false;
			var deadline = haxe.Timer.stamp() + 5;
			while (!done && haxe.Timer.stamp() < deadline) {
				try {
					client.handshake();
					done = true;
				} catch (e:haxe.io.Error) {
					switch (e) {
						case Blocked:
							crossbyte.sys.System.sleep(0.001);
						default:
							throw e;
					}
				}
			}
			client.close();

			if (!done) {
				throw "the handshake never completed with a 512 byte read buffer";
			}
		});

		Assert.isTrue(outcome.finished, "the client neither finished nor failed");
		Assert.isNull(outcome.failure, outcome.failure);
	}

	// ------------------------------------------------ what a connection costs

	/**
		A read takes every record that has already arrived, as far as the
		caller's buffer goes. It stopped after one, 16 KB, so the runtime
		read a large upload one record per pump, and paid a select over every
		connection it held for each: a 10 MB upload took 2.4 s beside 2,000
		idle connections.
	**/
	public function testATlsReadTakesEveryRecordAlreadyReceived():Void {
		var fixture = TLSTestFixture.selfSigned();
		if (fixture == null) {
			Assert.pass();
			return;
		}

		var listener = __listener(fixture);
		var sent = new sys.thread.Lock();
		var finish = new sys.thread.Lock();
		var failure:String = null;

		sys.thread.Thread.create(() -> {
			try {
				var peer = JdkTlsPeer.connect(listener.port, {trust: [fixture.certificatePath]});
				// Three whole records' worth.
				var out = peer.getOutputStream();
				out.write(haxe.io.Bytes.alloc(3 * 16384).getData());
				out.flush();
				sent.release();
				finish.wait(10);
				peer.close();
			} catch (e:Dynamic) {
				failure = Std.string(e);
				sent.release();
			}
		});

		var got:Int = -1;
		try {
			var accepted = listener.acceptAndHandshake(10);
			sent.wait(10);
			// Long enough for all of it to reach this end's socket.
			crossbyte.sys.System.sleep(0.3);
			got = accepted.input.readBytes(haxe.io.Bytes.alloc(65536), 0, 65536);
			finish.release();
			accepted.close();
		} catch (e:Dynamic) {
			finish.release();
			if (failure == null) {
				failure = Std.string(e);
			}
		}
		listener.close();

		Assert.isNull(failure, failure);
		Assert.equals(3 * 16384, got, 'one read took $got bytes of the ${3 * 16384} already received');
	}

	/**
		An idle connection holds no engine buffers. Each held three for its
		whole life, a record's worth of ciphertext each way and one of
		plaintext, some 50 KB a connection, half a gigabyte at 10,000 idle
		HTTPS connections. They are taken from the thread's pool when a read
		or write needs one and given back when it empties.
	**/
	public function testAnIdleTlsConnectionHoldsNoEngineBuffers():Void {
		var fixture = TLSTestFixture.selfSigned();
		if (fixture == null) {
			Assert.pass();
			return;
		}

		var listener = __listener(fixture);
		var pairs:Array<crossbyte._internal.socket._jvm.JvmSsl.JvmSslSocket> = [];
		var count:Int = 150;
		var failure:String = null;
		var before:Float = __usedHeap();

		try {
			for (i in 0...count) {
				var client = new crossbyte._internal.socket._jvm.JvmSsl.JvmSslSocket();
				client.verifyCert = false;
				client.setBlocking(false);
				client.connect(new sys.net.Host("127.0.0.1"), listener.port);
				pairs.push(client);
				var server = listener.accept(5);
				pairs.push(server);
				__stepHandshakes(client, server, 10);

				// A round trip each way, so every buffer has been needed once.
				__exchange(client, server, "ping");
				__exchange(server, client, "pong");
			}
		} catch (e:Dynamic) {
			failure = Std.string(e);
		}

		var after:Float = __usedHeap();
		var perConnection:Float = (after - before) / pairs.length;

		for (socket in pairs) {
			try {
				socket.close();
			} catch (_:Dynamic) {}
		}
		listener.close();

		Assert.isNull(failure, failure);
		Assert.isTrue(perConnection < 28 * 1024, 'an idle TLS connection holds ${Math.round(perConnection / 1024)} KB');
	}

	// ------------------------------------------------------------- sessions

	/**
		A listener resumes the sessions it issued. Every connection it accepted
		was given a context of its own, and a context is where a server keeps
		its sessions, so a client offering one back was never recognised: 0 of
		900 resumed, each paying a full handshake. One context per listener now.
	**/
	public function testAListenerResumesTheSessionsItIssued():Void {
		var chain = TLSChainFixture.get();
		if (chain == null) {
			Assert.pass();
			return;
		}

		var ids:Array<String> = [];
		var outcome = __serve(function(server) server.setCertificate(chain.direct, chain.directKey), function(port) {
			// One client context for both: it is where the client keeps the
			// session it offers back.
			var context = JdkTlsPeer.context({trust: [__path(chain, "root.pem")]});
			for (i in 0...2) {
				var peer = JdkTlsPeer.connect(port, {context: context, protocols: ["TLSv1.2"]});
				ids.push(JdkTlsPeer.hex(peer.getSession().getId()));
				peer.close();
			}
		});

		Assert.isNull(outcome.failure, outcome.failure);
		Assert.equals(2, ids.length);
		Assert.equals(ids[0], ids[1], "the second connection was given a new session rather than resuming the first");
	}

	/**
		A client resumes its session with a server it has connected to before.
		Each connection built a context of its own, which is where a client
		keeps the sessions it can offer back, so every one paid a full
		handshake, and read the JDK's trust store again to make it.
	**/
	public function testAClientResumesItsSessionWithAServer():Void {
		var chain = TLSChainFixture.get();
		if (chain == null) {
			Assert.pass();
			return;
		}

		var server = JdkTlsPeer.listen({present: {chain: __path(chain, "direct.pem"), key: chain.directKey}, protocols: ["TLSv1.2"], timeout: 5000});
		var sessions = __sessionsOf(server, 2);
		var root = @:privateAccess chain.root.__native;
		var first = __dial(server.getLocalPort(), function(client) client.setCA(root));
		var second = __dial(server.getLocalPort(), function(client) client.setCA(root));
		var ids = sessions();
		server.close();

		Assert.isNull(first, first);
		Assert.isNull(second, second);
		Assert.equals(2, ids.length);
		Assert.equals(ids[0], ids[1], "the client's second connection did not resume the session of its first");
	}

	/**
		And a session is only offered back by a connection made the same way.
		One made without verifying the server is never resumed by one that
		verifies: resuming skips the certificate, so it would take the first
		connection's word for a server the second never checked.
	**/
	public function testASessionMadeWithoutVerificationIsNotResumedByOneThatVerifies():Void {
		var chain = TLSChainFixture.get();
		if (chain == null) {
			Assert.pass();
			return;
		}

		var server = JdkTlsPeer.listen({present: {chain: __path(chain, "direct.pem"), key: chain.directKey}, protocols: ["TLSv1.2"], timeout: 5000});
		var sessions = __sessionsOf(server, 2);
		var unverified = __dial(server.getLocalPort(), function(client) client.verifyCert = false);
		var verified = __dial(server.getLocalPort(), function(client) client.setCA(@:privateAccess chain.root.__native));
		var ids = sessions();
		server.close();

		Assert.isNull(unverified, unverified);
		Assert.isNull(verified, verified);
		Assert.equals(2, ids.length);
		Assert.notEquals(ids[0], ids[1], "a connection that verifies resumed a session made without verification");
	}

	// ----------------------------------------------- after the first handshake

	/**
		A TLS 1.2 renegotiation is carried through. After the first handshake
		no delegated task ran and no handshake record was wrapped, so a peer
		that renegotiated, a server asking for a client certificate part way
		through, or a client that asks for new keys, waited on an answer that
		never came, and neither side was told.
	**/
	public function testATls12RenegotiationIsCarriedThrough():Void {
		var chain = TLSChainFixture.get();
		if (chain == null) {
			Assert.pass();
			return;
		}

		var first:String = null;
		var second:String = null;
		var renegotiated:Int = 0;
		var outcome = __serve(function(server) server.setCertificate(chain.direct, chain.directKey), function(port) {
			var peer = JdkTlsPeer.connect(port, {trust: [__path(chain, "root.pem")], protocols: ["TLSv1.2"], timeout: 5000});
			var counter = new HandshakeCounter();
			peer.addHandshakeCompletedListener(counter);

			JdkTlsPeer.send(peer, "one");
			first = JdkTlsPeer.receive(peer, 3);

			// Asks for a new handshake on the same connection; it completes
			// as the exchange below carries it through.
			peer.startHandshake();
			JdkTlsPeer.send(peer, "two");
			second = JdkTlsPeer.receive(peer, 3);

			// Told on a thread of the JDK's own.
			if (counter.completed.wait(2)) {
				renegotiated = 1;
			}
			peer.close();
		}, __echo);

		Assert.isTrue(outcome.finished, "the client neither finished nor failed");
		Assert.isNull(outcome.failure, "the connection did not survive a renegotiation: " + outcome.failure);
		Assert.equals("one", first);
		Assert.equals("two", second, "nothing came back after the renegotiation");
		Assert.equals(1, renegotiated, "the renegotiation did not complete");
	}

	/**
		A server carries a client's renegotiations through only so many times.
		Each is a full handshake the server pays for, a private-key
		operation, on a connection already admitted, so a client able to ask
		without limit has the server's CPU for the price of a record. Node
		allows three, and so does this; the next closes the connection.
	**/
	public function testAServerRefusesRenegotiationsPastItsLimit():Void {
		var chain = TLSChainFixture.get();
		if (chain == null) {
			Assert.pass();
			return;
		}

		var answered:Int = 0;
		var ended:String = null;
		var outcome = __serve(function(server) server.setCertificate(chain.direct, chain.directKey), function(port) {
			var peer = JdkTlsPeer.connect(port, {trust: [__path(chain, "root.pem")], protocols: ["TLSv1.2"], timeout: 5000});
			try {
				for (i in 0...5) {
					peer.startHandshake();
					JdkTlsPeer.send(peer, "x");
					if (JdkTlsPeer.receive(peer, 1) != "x") {
						break;
					}
					answered++;
				}
			} catch (e:Dynamic) {
				ended = Std.string(e);
			}
			try {
				peer.close();
			} catch (_:Dynamic) {}
		}, __echo);

		Assert.isTrue(outcome.finished, "the client neither finished nor failed");
		Assert.equals(3, answered, 'the server carried $answered renegotiations through');
	}

	/**
		A handshake the server refuses tells the client why. It closed with
		nothing said, and the client reported the server as having hung up,
		"Remote host terminated the handshake", rather than the certificate
		it had not presented.
	**/
	public function testARefusedHandshakeSendsItsAlert():Void {
		var chain = TLSChainFixture.get();
		if (chain == null) {
			Assert.pass();
			return;
		}

		var refusal:String = null;
		var outcome = __serve(function(server) {
			server.setCertificate(chain.direct, chain.directKey);
			server.requireClientCertificate(chain.root);
		}, function(port) {
			try {
				// TLS 1.2, so the refusal arrives inside the handshake.
				var peer = JdkTlsPeer.connect(port, {trust: [__path(chain, "root.pem")], protocols: ["TLSv1.2"], timeout: 5000});
				peer.close();
			} catch (e:Dynamic) {
				refusal = Std.string(e);
			}
		});

		Assert.isTrue(outcome.finished, "the client neither finished nor failed");
		Assert.notNull(refusal, "a client with no certificate was let in by a server requiring one");
		if (refusal != null) {
			Assert.isTrue(refusal.indexOf("Received fatal alert") >= 0, "the client was not told why it was refused: " + refusal);
		}
	}

	/** And a client refusing a server's certificate tells the server. **/
	public function testAClientRefusingACertificateSendsItsAlert():Void {
		var chain = TLSChainFixture.get();
		if (chain == null) {
			Assert.pass();
			return;
		}

		// The JDK's own server, presenting a certificate from an authority the
		// client was not given.
		var server = JdkTlsPeer.listen({present: {chain: __path(chain, "direct.pem"), key: chain.directKey}, protocols: ["TLSv1.2"], timeout: 5000});
		var port = server.getLocalPort();
		var heard:String = null;
		var done = new sys.thread.Lock();

		sys.thread.Thread.create(() -> {
			try {
				var accepted:SSLSocket = cast server.accept();
				accepted.setSoTimeout(5000);
				accepted.startHandshake();
				accepted.close();
			} catch (e:Dynamic) {
				heard = Std.string(e);
			}
			done.release();
		});

		var client = new FlexSocket(true);
		client.setTimeout(5);
		var failure:String = null;
		try {
			client.connect("127.0.0.1", port);
		} catch (e:Dynamic) {
			failure = Std.string(e);
		}
		// Closed only once the server is done with it. Closed at once, with the
		// rest of the server's flight still arriving, the client's kernel
		// answers that with a reset, and under load the server met it writing,
		// "Software caused connection abort", before reading the alert
		// that had already gone. That race is TCP's, not the alert's.
		done.wait(10);
		try {
			client.close();
		} catch (_:Dynamic) {}
		server.close();

		Assert.notNull(failure, "a client given no authority for the server accepted it");
		Assert.notNull(heard, "the server's handshake completed with a client that refused it");
		if (heard != null) {
			Assert.isTrue(heard.indexOf("Received fatal alert") >= 0, "the server was not told why the client refused it: " + heard);
		}
	}

	// ----------------------------------------------------------- helpers

	/**
		A CrossByte TLS listener driven by hand: bound on 127.0.0.1, accepting
		and stepping handshakes on the calling thread, with no runtime.
	**/
	private static function __listener(fixture:TLSTestFixture.TLSFixtureData):{
		port:Int,
		accept:Float->crossbyte._internal.socket._jvm.JvmSsl.JvmSslSocket,
		acceptAndHandshake:Float->crossbyte._internal.socket._jvm.JvmSsl.JvmSslSocket,
		close:Void->Void
	} {
		var listener = new crossbyte._internal.socket._jvm.JvmSsl.JvmSslSocket();
		listener.verifyCert = false;
		listener.setCertificate(@:privateAccess fixture.certificate.__native, @:privateAccess fixture.key.__native);
		listener.setBlocking(false);
		listener.bind(new sys.net.Host("127.0.0.1"), 0);
		listener.listen(16);

		function accept(seconds:Float):crossbyte._internal.socket._jvm.JvmSsl.JvmSslSocket {
			var deadline = haxe.Timer.stamp() + seconds;
			while (haxe.Timer.stamp() < deadline) {
				try {
					var accepted:crossbyte._internal.socket._jvm.JvmSsl.JvmSslSocket = cast listener.accept();
					accepted.setBlocking(false);
					return accepted;
				} catch (e:haxe.io.Error) {
					crossbyte.sys.System.sleep(0.001);
				}
			}
			throw "nothing connected within " + seconds + " s";
		}

		return {
			port: listener.host().port,
			accept: accept,
			acceptAndHandshake: function(seconds:Float) {
				var accepted = accept(seconds);
				__stepHandshakes(null, accepted, seconds);
				return accepted;
			},
			close: function() {
				try {
					listener.close();
				} catch (_:Dynamic) {}
			}
		};
	}

	/** Steps one or two non-blocking handshakes until both are done. **/
	private static function __stepHandshakes(a:Null<crossbyte._internal.socket._jvm.JvmSsl.JvmSslSocket>,
			b:crossbyte._internal.socket._jvm.JvmSsl.JvmSslSocket, seconds:Float):Void {
		var deadline = haxe.Timer.stamp() + seconds;
		var aDone = a == null;
		var bDone = false;
		while (!(aDone && bDone)) {
			if (haxe.Timer.stamp() > deadline) {
				throw "the handshake did not complete within " + seconds + " s";
			}
			if (!aDone) {
				aDone = __stepped(a);
			}
			if (!bDone) {
				bDone = __stepped(b);
			}
			if (!(aDone && bDone)) {
				crossbyte.sys.System.sleep(0.0005);
			}
		}
	}

	private static function __stepped(socket:crossbyte._internal.socket._jvm.JvmSsl.JvmSslSocket):Bool {
		try {
			socket.handshake();
			return true;
		} catch (e:haxe.io.Error) {
			switch (e) {
				case Blocked:
					return false;
				default:
					throw e;
			}
		}
	}

	/** Writes `text` on `from` and reads it on `to`, both non-blocking. **/
	private static function __exchange(from:crossbyte._internal.socket._jvm.JvmSsl.JvmSslSocket,
			to:crossbyte._internal.socket._jvm.JvmSsl.JvmSslSocket, text:String):Void {
		var bytes = haxe.io.Bytes.ofString(text);
		var written = 0;
		var deadline = haxe.Timer.stamp() + 5;
		while (written < bytes.length) {
			try {
				written += from.output.writeBytes(bytes, written, bytes.length - written);
			} catch (e:haxe.io.Error) {
				crossbyte.sys.System.sleep(0.0005);
			}
			if (haxe.Timer.stamp() > deadline) {
				throw "could not write";
			}
		}

		var buffer = haxe.io.Bytes.alloc(bytes.length);
		var got = 0;
		while (got < bytes.length) {
			try {
				got += to.input.readBytes(buffer, got, bytes.length - got);
			} catch (e:haxe.io.Error) {
				crossbyte.sys.System.sleep(0.0005);
			}
			if (haxe.Timer.stamp() > deadline) {
				throw "nothing arrived";
			}
		}
	}

	/**
		Accepts `count` connections on a JDK listener, on a thread of its own,
		and hands back each one's session id once they are all done.
	**/
	private static function __sessionsOf(server:SSLServerSocket, count:Int):Void->Array<String> {
		var ids:Array<String> = [];
		var done = new sys.thread.Lock();

		sys.thread.Thread.create(() -> {
			for (i in 0...count) {
				try {
					var accepted:SSLSocket = cast server.accept();
					accepted.setSoTimeout(5000);
					accepted.startHandshake();
					ids.push(JdkTlsPeer.hex(accepted.getSession().getId()));
					accepted.close();
				} catch (e:Dynamic) {
					ids.push("failed: " + Std.string(e));
				}
			}
			done.release();
		});

		return function() {
			done.wait(20);
			return ids;
		};
	}

	/** Bytes in use on the heap once what can be collected has been. **/
	private static function __usedHeap():Float {
		var runtime = java.lang.Runtime.getRuntime();
		for (i in 0...3) {
			java.lang.System.gc();
			crossbyte.sys.System.sleep(0.05);
		}
		return cast(runtime.totalMemory(), Float) - cast(runtime.freeMemory(), Float);
	}

	/**
		A CrossByte TLS client connecting to `port` on a thread of its own,
		configured by `configure`, waited on for up to `seconds`. A connect
		still going then is closed from here, so no thread is left behind.
	**/
	private static function __dialOnThread(port:Int, configure:FlexSocket->Void,
			seconds:Float):{finished:Bool, failure:Null<String>, took:Float} {
		var client = new FlexSocket(true);
		configure(client);

		var failure:Null<String> = null;
		var took:Float = -1;
		var handoff = new sys.thread.Lock();

		sys.thread.Thread.create(() -> {
			var started = haxe.Timer.stamp();
			try {
				client.connect("127.0.0.1", port);
			} catch (e:Dynamic) {
				failure = Std.string(e);
			}
			took = haxe.Timer.stamp() - started;
			handoff.release();
		});

		var finished = handoff.wait(seconds);
		try {
			client.close();
		} catch (_:Dynamic) {}
		if (!finished) {
			// Closed under it, so the thread ends rather than retrying on.
			handoff.wait(30);
		}

		return {finished: finished, failure: failure, took: took};
	}

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
		`configure`, and runs `connected` on it once it is. Null when all of
		that worked; the failure when it did not.
	**/
	private static function __dial(port:Int, configure:Null<FlexSocket->Void>, ?connected:FlexSocket->Void):Null<String> {
		var client = new FlexSocket(true);
		try {
			client.setTimeout(10);
			if (configure != null) {
				configure(client);
			}
			client.connect("127.0.0.1", port);
			if (connected != null) {
				connected(client);
			}
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
				crossbyte.sys.System.sleep(0.002);
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

/** Released when the JDK socket it is attached to completes a handshake. **/
private class HandshakeCounter implements HandshakeCompletedListener {
	public final completed:sys.thread.Lock = new sys.thread.Lock();

	public function new() {}

	public function handshakeCompleted(event:HandshakeCompletedEvent):Void {
		completed.release();
	}
}
#end
