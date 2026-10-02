package crossbyte.http;

import crossbyte.io.File;
import crossbyte.io.ByteArray;
import crossbyte.net.TLSTestFixture;
#if (cpp || hl || neko || java || jvm)
import crossbyte._internal.http.Http;
import crossbyte._internal.http.HttpConnectionPool;
import crossbyte._internal.http.PublicKeyPins;
import crossbyte._internal.http.h2.H2ConnectionPool;
import crossbyte._internal.socket.FlexSocket;
import crossbyte.events.ProgressEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.net.ServerSocket;
import crossbyte.net.TLSTestFixture.TLSFixtureData;
import crossbyte.url.URLRequestHeader;
import haxe.io.Bytes;
#end
import utest.Assert;
import crossbyte.test.Require;

/**
	HTTPS end to end through `HTTPServer`, from a configuration to a response.

	Nothing covered this on any target. `ServerSocketTLSTest` proves the socket
	layer terminates TLS, and the HTTP cases prove the server answers requests,
	but the seam between them -- `HTTPServerConfig.tlsCertificatePath` being
	loaded and installed on the listener -- was joined by no test at all. It was
	also broken on jvm: the constructor built a secure `ServerSocket` and then
	skipped `setCertificate` behind a `#if (!java && !jvm)` gate left over from
	when the jvm target had no TLS, so an HTTPS configuration there produced a
	listener with nothing to present.

	A gap of exactly that shape is why this is an end-to-end case and not an
	assertion about the configuration object: the configuration was always
	right, and every piece it named worked. Only the wiring was missing.
**/
class HTTPServerTLSTest extends utest.Test {
	/**
		A configured HTTPS server answers a real request over TLS.

		The client is CrossByte's own, which is the weaker choice and the
		portable one -- the same case then runs on cpp, hl, neko and jvm. What
		it can be fooled by is a TLS bug both halves share; what it catches, and
		what actually shipped, is a server that never installed its certificate.
		The handshake against a foreign implementation is `ServerSocketTLSTest`'s
		job, and it does it against openssl and the JDK.
	**/
	#if (cpp || hl || neko || java || jvm)
	public function testAConfiguredServerAnswersOverTls():Void {
		// Names 127.0.0.1, so the client can check it once told to trust it.
		var fixture = TLSTestFixture.trusted();
		if (fixture == null) {
			// No certificate toolchain on this machine.
			Assert.pass();
			return;
		}

		var root = File.createTempDirectory();
		var page = new ByteArray();
		page.writeUTFBytes("<html><body>over tls</body></html>");
		root.resolvePath("index.html").save(page);

		var config = new HTTPServerConfig("127.0.0.1", 0, root);
		config.tlsCertificatePath = fixture.certificatePath;
		config.tlsKeyPath = fixture.keyPath;

		Assert.isTrue(config.tlsEnabled, "the fixture did not produce an https configuration");

		var server = new HTTPServer(config);
		var response:String = null;
		var failure:String = null;
		// The worker below writes what the assertions here read, and then
		// releases the lock. Read back after a wait() that returned true,
		// those writes are published rather than raced for: a plain flag
		// polled from this thread promises nothing about what the other
		// one wrote before setting it.
		var handoff = new sys.thread.Lock();
		var finished = false;

		// The constructor binds and listens from the configuration, so there is
		// nothing to start here -- and a bind() of its own throws
		// AlreadyBoundException.
		try {
			var port = server.localPort;

			sys.thread.Thread.create(() -> {
				var client = new crossbyte._internal.socket.FlexSocket(true);

				try {
					client.setTimeout(10);

					// Self-signed, so trusted as its own authority: the check
					// then proves the server presented the certificate it was
					// configured with. It was turned off here, which neko's
					// TLS does not honour, and which proved only that the
					// server presented something.
					client.setCA(@:privateAccess fixture.certificate.__native);
					client.connect("127.0.0.1", port);

					client.output.writeString("GET /index.html HTTP/1.1\r\n"
						+ "Host: 127.0.0.1\r\n"
						+ "Connection: close\r\n\r\n");
					client.output.flush();

					var buffer = new StringBuf();

					try {
						while (true) {
							buffer.addChar(client.input.readByte());
						}
					} catch (_:haxe.io.Eof) {} catch (_:Dynamic) {}

					response = buffer.toString();
				} catch (e:Dynamic) {
					failure = Std.string(e);
				}

				try {
					client.close();
				} catch (_:Dynamic) {}

				handoff.release();
			});

			var deadline = haxe.Timer.stamp() + 20;
			while (haxe.Timer.stamp() < deadline && !finished) {
				crossbyte.core.CrossByte.current().pump(1 / 60, 0);
				finished = handoff.wait(0.002);
			}
		} catch (e:Dynamic) {
			try {
				server.close();
			} catch (_:Dynamic) {}
			try {
				root.deleteDirectory(true);
			} catch (_:Dynamic) {}
			throw e;
		}

		try {
			server.close();
		} catch (_:Dynamic) {}

		// The document root is a temp directory of our own making, and
		// nothing below reads from it again. Left behind, one per run, it
		// is litter the next developer gets to wonder about.
		try {
			root.deleteDirectory(true);
		} catch (_:Dynamic) {}

		Assert.isTrue(finished, "the client neither answered nor failed within the deadline");
		Assert.isNull(failure, "the request over TLS failed: " + failure);
		Require.notNull(response, "no response came back");
		Assert.isTrue(response.indexOf("200") >= 0, "the server did not answer 200: " + response.substr(0, 120));
		Assert.isTrue(response.indexOf("over tls") >= 0, "the body did not come back: " + response.substr(0, 200));
	}
	#end

	#if (cpp || hl || neko || java || jvm)
	/**
		A request body larger than one TLS record arrives whole, over both
		versions.

		The client wrote the body with `Output.writeBytes`, which writes what it
		can and says how much, and over TLS that is one record, 16 KB, at most:
		the rest of a larger body was dropped, and the server waited for it
		until the request timed out. HTTP/2 wrote each frame the same way, so
		a DATA frame of the largest default size lost its last nine bytes.
	**/
	public function testALargeUploadOverTlsArrivesWhole():Void {
		// Names 127.0.0.1, so the client can verify it once told to trust it.
		var fixture = TLSTestFixture.trusted();
		if (fixture == null) {
			// No certificate toolchain on this machine.
			Assert.pass();
			return;
		}

		var router = new Router();
		router.post("/upload", ctx -> ctx.handler.respond(200, "text/plain", "got " + ctx.handler.requestBody.length));
		var config = new HTTPServerConfig("127.0.0.1", 0);
		config.tlsCertificatePath = fixture.certificatePath;
		config.tlsKeyPath = fixture.keyPath;
		config.http2Enabled = FlexSocket.alpnSupported;
		config.middleware.push(router.middleware());
		var server = new HTTPServer(config);
		var port:Int = server.localPort;

		var versions:Array<HTTPVersion> = [HTTPVersion.HTTP_1_1];
		if (FlexSocket.alpnSupported) {
			versions.push(HTTPVersion.HTTP_2);
		}

		var body = Bytes.alloc(64 * 1024);
		body.fill(0, body.length, "x".code);
		var outcomes:Array<String> = [];
		// Trusted as the client's CA for the length of the case.
		var trusted = FlexSocket.DEFAULT_CA;
		FlexSocket.DEFAULT_CA = @:privateAccess fixture.certificate.__native;

		for (version in versions) {
			var outcome:String = null;
			var handoff = new sys.thread.Lock();
			sys.thread.Thread.create(() -> {
				try {
					var http = new Http('https://127.0.0.1:$port/upload', "POST", null, null, "application/octet-stream", body, version, 5000);
					http.onComplete = data -> outcome = "COMPLETED " + data.toString();
					http.onError = (message, ?data) -> outcome = message;
					http.load();
				} catch (e:Dynamic) {
					outcome = "threw " + Std.string(e);
				}
				handoff.release();
			});

			var finished:Bool = false;
			var deadline:Float = haxe.Timer.stamp() + 20;
			while (!finished && haxe.Timer.stamp() < deadline) {
				crossbyte.core.CrossByte.current().pump(1 / 60, 0);
				finished = handoff.wait(0.002);
			}
			outcomes.push(version + ": " + (finished ? outcome : "never returned"));
		}

		FlexSocket.DEFAULT_CA = trusted;
		HttpConnectionPool.clear();
		H2ConnectionPool.closeAll();
		try {
			server.close();
		} catch (_:Dynamic) {}

		for (i in 0...versions.length) {
			Assert.equals(versions[i] + ": COMPLETED got 65536", outcomes[i]);
		}
	}
	#end

	#if (cpp || hl || neko || java || jvm)
	/**
		A request trusts the authority it names, and a refusal says why.

		`URLRequest` had no TLS settings at all: trusting a private authority
		meant setting `FlexSocket.DEFAULT_CA` through `@:privateAccess`, for
		every request in the process at once. And whatever went wrong -- an
		untrusted certificate, a refused port -- the request failed with
		"Connection Failed" and nothing else.
	**/
	public function testARequestTrustsTheAuthorityItNames():Void {
		var fixture = TLSTestFixture.trusted();
		if (fixture == null) {
			// No certificate toolchain on this machine.
			Assert.pass();
			return;
		}

		var server = __tlsServer(fixture);
		var url:String = 'https://127.0.0.1:${server.port}/who';
		var outcomes:Array<String> = [];
		for (version in __versions()) {
			// The fixture is in no system store, so the defaults refuse it --
			// with the reason.
			var refused:String = __fetch(url, null, version);
			outcomes.push(version + " unconfigured: " + refused);
			outcomes.push(version + " trusting: " + __fetch(url, new HTTPTLSOptions(true, fixture.certificate), version));
			outcomes.push(version + " unchecked: " + __fetch(url, new HTTPTLSOptions(false), version));
			__clearPools();
		}
		server.close();

		var i:Int = 0;
		for (version in __versions()) {
			var refused:String = outcomes[i++];
			var prefix:String = version == HTTPVersion.HTTP_2 ? "HTTP/2 request failed: " : "Connection Failed: ";
			Assert.isTrue(refused.indexOf(prefix) >= 0, "an untrusted server was not refused as a failed connection: " + refused);
			Assert.isTrue(StringTools.trim(refused.substr(refused.indexOf(prefix) + prefix.length)).length > 0, "the refusal did not say why: " + refused);
			Assert.isTrue(StringTools.startsWith(outcomes[i++], version + " trusting: COMPLETED conn "), "the authority the request named was not trusted");
			#if neko
			// neko's TLS checks the server whatever it is told: verifyCert =
			// false cannot be honoured there, and the request is refused as a
			// checked one would be rather than going out unchecked.
			Assert.isTrue(outcomes[i++].indexOf("Connection Failed: ") >= 0, "verifyCert = false was taken on neko, whose TLS cannot skip the check");
			#else
			Assert.isTrue(StringTools.startsWith(outcomes[i++], version + " unchecked: COMPLETED conn "), "verifyCert = false still checked");
			#end
		}
		for (outcome in outcomes) {
			// Every line, in the report, when something above failed.
			Assert.isTrue(outcome.indexOf("never returned") < 0, outcome);
		}
	}

	/**
		A kept connection carries only a request made under the same TLS.

		The pool kept connections by origin alone. A request that turned
		verification off left behind a connection to a server nobody had
		checked, and the next request to that origin -- one that did check --
		was sent down it: its verification never ran.
	**/
	public function testAConnectionIsReusedOnlyUnderTheSameTls():Void {
		var fixture = TLSTestFixture.trusted();
		if (fixture == null) {
			Assert.pass();
			return;
		}

		var server = __tlsServer(fixture);
		var url:String = 'https://127.0.0.1:${server.port}/who';
		// A connection opened unchecked -- or on neko, whose TLS cannot skip
		// the check, one checked against an authority the defaults do not
		// trust, which a request trusting only the system's must not ride
		// either.
		function opening():HTTPTLSOptions {
			return #if neko new HTTPTLSOptions(true, fixture.certificate) #else new HTTPTLSOptions(false) #end;
		}
		for (version in __versions()) {
			__clearPools();
			var first:String = __fetch(url, opening(), version);
			var checked:String = __fetch(url, null, version);
			// The same settings again, in a new object: kept for this one.
			var again:String = __fetch(url, opening(), version);

			Assert.isTrue(StringTools.startsWith(first, "COMPLETED conn "), version + ": the unchecked request failed: " + first);
			Assert.isFalse(StringTools.startsWith(checked, "COMPLETED"), version + ": a checking request was sent down an unchecked connection: " + checked);
			Assert.equals(first, again, version + ": a request under the same settings was not given the kept connection");
		}
		__clearPools();
		server.close();
	}

	/**
		A pinned request fails at a server whose key it does not pin, before
		anything is sent, and passes one whose key it does. Natively and on the
		jvm; hl and neko cannot see the server's certificate, and refuse a
		pinned request rather than send it unchecked.
	**/
	public function testAPinnedRequestChecksTheServersKey():Void {
		var fixture = TLSTestFixture.trusted();
		if (fixture == null) {
			Assert.pass();
			return;
		}

		var pin:Null<String> = __pinOf(fixture);
		Require.notNull(pin, "the fixture's certificate could not be read for its key");
		// A digest of 32 zero bytes: a well-formed pin no key has.
		var wrong:String = "sha256/" + haxe.crypto.Base64.encode(Bytes.alloc(32));

		var server = __tlsServer(fixture);
		var url:String = 'https://127.0.0.1:${server.port}/who';
		for (version in __versions()) {
			__clearPools();
			var pinned:String = __fetch(url, new HTTPTLSOptions(true, fixture.certificate, null, null, [wrong, pin]), version);
			var mispinned:String = __fetch(url, new HTTPTLSOptions(true, fixture.certificate, null, null, [wrong]), version);

			#if (cpp || java || jvm)
			Assert.isTrue(StringTools.startsWith(pinned, "COMPLETED conn "), version + ": a server with a pinned key was refused: " + pinned);
			Assert.isTrue(mispinned.indexOf("is not one this request pins") >= 0, version + ": a server with no pinned key was not refused: " + mispinned);
			#else
			Assert.isTrue(pinned.indexOf("not available on this target") >= 0, version + ": a pin was not refused where it cannot be checked: " + pinned);
			Assert.isTrue(mispinned.indexOf("not available on this target") >= 0, version + ": a pin was not refused where it cannot be checked: " + mispinned);
			#end
		}
		// Only the pinned requests reached the server's handler, and a
		// mispinned one never did: nothing is sent before the check.
		Assert.equals(#if (cpp || java || jvm) __versions().length #else 0 #end, server.served(), "a request reached a server whose key it did not pin");
		__clearPools();
		server.close();
	}

	/**
		A request presents the client certificate it is given to a server that
		asks for one -- mutual TLS, which could not be done at all -- and
		leaves it behind when a redirect takes it to another origin, as it
		leaves `Authorization`.
	**/
	public function testAClientCertificateIsPresentedToTheOriginNamed():Void {
		var serverFixture = TLSTestFixture.trusted();
		// A second pair, made fresh like the first: a verifying server refuses
		// an expired client certificate, and `selfSignedFor`'s often is.
		var clientFixture = TLSTestFixture.trusted(["crossbyte-client"]);
		if (serverFixture == null || clientFixture == null) {
			Assert.pass();
			return;
		}

		var guarded = __mutualServer(serverFixture, clientFixture.certificate);
		var direct:String = 'https://127.0.0.1:${guarded.port}/';
		var anonymous:String = __fetch(direct, new HTTPTLSOptions(true, serverFixture.certificate));
		var afterAnonymous:Int = guarded.admitted();
		var presented:String = __fetch(direct, new HTTPTLSOptions(true, serverFixture.certificate, clientFixture.certificate, clientFixture.key));
		var afterPresented:Int = guarded.admitted();

		// Another origin -- another port -- sending the request on to the
		// guarded server.
		var router = new Router();
		router.get("/away", ctx -> ctx.handler.respond(302, "text/plain", "", [new URLRequestHeader("Location", direct)]));
		var config = new HTTPServerConfig("127.0.0.1", 0);
		config.tlsCertificatePath = serverFixture.certificatePath;
		config.tlsKeyPath = serverFixture.keyPath;
		config.middleware.push(router.middleware());
		var redirecting = new HTTPServer(config);
		var redirected:String = __fetch('https://127.0.0.1:${redirecting.localPort}/away',
			new HTTPTLSOptions(true, serverFixture.certificate, clientFixture.certificate, clientFixture.key));
		var afterRedirect:Int = guarded.admitted();

		__clearPools();
		guarded.close();
		try {
			redirecting.close();
		} catch (_:Dynamic) {}

		Assert.isFalse(StringTools.startsWith(anonymous, "COMPLETED"), "a server requiring a certificate answered a request presenting none: " + anonymous);
		Assert.equals(0, afterAnonymous, "a client with no certificate was let in");
		Assert.equals("COMPLETED hello, client", presented, "the client certificate was not presented");
		Assert.equals(1, afterPresented, "the client that presented a certificate was not let in");
		Assert.isFalse(StringTools.startsWith(redirected, "COMPLETED"), "the client certificate followed a redirect to another origin: " + redirected);
		Assert.equals(1, afterRedirect, "the client certificate followed a redirect to another origin");
	}

	/** HTTP/1.1, and HTTP/2 where TLS can negotiate it. */
	private static function __versions():Array<HTTPVersion> {
		var versions:Array<HTTPVersion> = [HTTPVersion.HTTP_1_1];
		if (FlexSocket.alpnSupported) {
			versions.push(HTTPVersion.HTTP_2);
		}
		return versions;
	}

	private static function __clearPools():Void {
		HttpConnectionPool.clear();
		H2ConnectionPool.closeAll();
	}

	/**
		An HTTPS server on `fixture`, over both versions where it can, whose
		`/who` answers "conn N": which of the connections it has seen the
		request arrived on, counted from 0. `served` counts the answers.
	**/
	private static function __tlsServer(fixture:TLSFixtureData):{port:Int, served:Void->Int, close:Void->Void} {
		var connections:Array<Dynamic> = [];
		var served:Int = 0;
		var router = new Router();
		router.get("/who", ctx -> {
			// The socket the request came in on: one per connection, over
			// either version, where HTTP/2 makes a handler per stream.
			var socket:Dynamic = @:privateAccess ctx.handler.__origin;
			var index:Int = connections.indexOf(socket);
			if (index < 0) {
				connections.push(socket);
				index = connections.length - 1;
			}
			served++;
			ctx.handler.respond(200, "text/plain", "conn " + index);
		});
		var config = new HTTPServerConfig("127.0.0.1", 0);
		config.tlsCertificatePath = fixture.certificatePath;
		config.tlsKeyPath = fixture.keyPath;
		config.http2Enabled = FlexSocket.alpnSupported;
		config.middleware.push(router.middleware());
		var server = new HTTPServer(config);
		return {
			port: server.localPort,
			served: () -> served,
			close: () -> try {
				server.close();
			} catch (_:Dynamic) {}
		};
	}

	/**
		A TLS server requiring a client certificate signed by `authority`,
		answering whatever it is sent with "hello, client". `admitted` counts
		the connections the handshake let through.
	**/
	private static function __mutualServer(fixture:TLSFixtureData, authority:crossbyte.net.Certificate):{port:Int, admitted:Void->Int, close:Void->Void} {
		var server = new ServerSocket(true);
		server.setCertificate(fixture.certificate, fixture.key);
		server.requireClientCertificate(authority);
		var admitted:Int = 0;
		var clients:Array<crossbyte.net.Socket> = [];
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent):Void {
			admitted++;
			var socket:crossbyte.net.Socket = e.socket;
			clients.push(socket);
			var seen:String = "";
			socket.addEventListener(ProgressEvent.SOCKET_DATA, function(_):Void {
				seen += socket.readUTFBytes(socket.bytesAvailable);
				if (seen.indexOf("\r\n\r\n") >= 0) {
					seen = "";
					socket.writeUTFBytes("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 13\r\nConnection: close\r\n\r\nhello, client");
					socket.flush();
				}
			});
		});
		server.bind(0, "127.0.0.1");
		server.listen();
		return {
			port: server.localPort,
			admitted: () -> admitted,
			close: () -> {
				for (client in clients) {
					try {
						client.close();
					} catch (_:Dynamic) {}
				}
				try {
					server.close();
				} catch (_:Dynamic) {}
			}
		};
	}

	/** The pin of `fixture`'s certificate, read from its PEM. */
	private static function __pinOf(fixture:TLSFixtureData):Null<String> {
		var pem:String = sys.io.File.getContent(fixture.certificatePath);
		var start:Int = pem.indexOf("-----BEGIN CERTIFICATE-----");
		var end:Int = pem.indexOf("-----END CERTIFICATE-----");
		if (start < 0 || end < start) {
			return null;
		}
		var body:String = ~/\s/g.replace(pem.substring(start + "-----BEGIN CERTIFICATE-----".length, end), "");
		return PublicKeyPins.pinOf(haxe.crypto.Base64.decode(body));
	}

	/**
		What `Http` makes of a GET of `url` under `tls`: "COMPLETED <body>" or
		the error it reported. Run on a thread of its own, as `URLLoader` runs
		it, while this one pumps the runtime the servers answer on; waited
		for on a lock, which publishes what the thread wrote.
	**/
	private static function __fetch(url:String, tls:Null<HTTPTLSOptions>, ?version:HTTPVersion):String {
		var outcome:String = null;
		var handoff = new sys.thread.Lock();
		sys.thread.Thread.create(() -> {
			try {
				var http = new Http(url, "GET", null, null, null, null, version != null ? version : HTTPVersion.HTTP_1_1, 5000);
				http.tls = tls;
				http.onComplete = data -> outcome = "COMPLETED " + data.toString();
				http.onError = (message, ?data) -> outcome = message;
				http.load();
			} catch (e:Dynamic) {
				outcome = "threw " + Std.string(e);
			}
			handoff.release();
		});

		var finished:Bool = false;
		var deadline:Float = haxe.Timer.stamp() + 30;
		while (!finished && haxe.Timer.stamp() < deadline) {
			crossbyte.core.CrossByte.current().pump(1 / 60, 0);
			finished = handoff.wait(0.002);
		}
		return finished ? (outcome != null ? outcome : "reported nothing") : "never returned";
	}
	#end

	#if (cpp || java || jvm)
	/**
		Closing an HTTP/2 session leaves its TLS socket to the reader thread,
		rather than closing it under the reader's read.

		`H2ClientSession.close` closed the socket from the calling thread --
		the pool's sweep, a request discarding the session, `closeAll` --
		while the session's reader sat in a read on it. That freed the
		socket's mbedTLS context under the read, and when the read returned,
		with the server answering the GOAWAY, mbedTLS carried on with it: a
		SIGSEGV in `mbedtls_ssl_read`, seen on Linux in this class's own
		pool clean-up. The socket stands in for the TLS one here and records
		whether it was closed while a read was under way.
	**/
	public function testClosingAnHttp2SessionLeavesItsSocketToTheReader():Void {
		var fixture = TLSTestFixture.trusted();
		if (fixture == null || !FlexSocket.alpnSupported) {
			Assert.pass();
			return;
		}

		var server = __tlsServer(fixture);
		var socket = new TracingTlsSocket();
		socket.setALPN(["h2"]);
		socket.setCA(@:privateAccess fixture.certificate.__native);
		socket.setTimeout(10);

		var session:crossbyte._internal.http.h2.H2ClientSession = null;
		var outcome:String = null;
		var handoff = new sys.thread.Lock();
		sys.thread.Thread.create(() -> {
			try {
				socket.connect(new sys.net.Host("127.0.0.1"), server.port);
				socket.setTimeout(0);
				socket.tracer = new TracingInput(socket.input);
				var settings = new crossbyte._internal.http.h2.H2Settings();
				settings.enablePush = false;
				var connection = new crossbyte._internal.http.h2.H2Connection(socket.tracer, socket.output, settings);
				session = new crossbyte._internal.http.h2.H2ClientSession('https://127.0.0.1:${server.port}', socket, connection);
				var stream = session.execute("GET", "https", '127.0.0.1:${server.port}', "/who", [], null, 10);
				outcome = "status " + stream.status;
			} catch (e:Dynamic) {
				outcome = "threw " + Std.string(e);
			}
			handoff.release();
		});

		var runtime = crossbyte.core.CrossByte.current();
		var finished:Bool = false;
		var deadline:Float = haxe.Timer.stamp() + 20;
		while (!finished && haxe.Timer.stamp() < deadline) {
			runtime.pump(1 / 60, 0);
			finished = handoff.wait(0.002);
		}
		Assert.equals("status 200", outcome, "the request over the session did not complete");

		if (session != null) {
			// The reader back in a read, waiting on the next frame.
			deadline = haxe.Timer.stamp() + 5;
			while (!socket.tracer.reading && haxe.Timer.stamp() < deadline) {
				runtime.pump(1 / 60, 0);
				handoff.wait(0.002);
			}
			Assert.isTrue(socket.tracer.reading, "the reader never went back to reading");

			session.close();
			// The server sees the session end, closes, and the read returns.
			deadline = haxe.Timer.stamp() + 10;
			while (!socket.wasClosed && haxe.Timer.stamp() < deadline) {
				runtime.pump(1 / 60, 0);
				handoff.wait(0.002);
			}
			Assert.isTrue(socket.wasClosed, "the session's socket was never closed");
			Assert.isFalse(socket.closedDuringRead, "the session's socket was closed under the reader's read");
		}

		if (!socket.wasClosed) {
			try {
				socket.close();
			} catch (_:Dynamic) {}
		}
		server.close();
	}
	#end

	/**
		`tlsEnabled` follows both paths being set, not either.

		A server given one of the two would otherwise construct a secure
		listener it has no key for, or a plaintext one the caller believes is
		encrypted -- the second being the dangerous direction.
	**/
	public function testTlsNeedsBothPaths():Void {
		var config = new HTTPServerConfig("127.0.0.1", 0);
		Assert.isFalse(config.tlsEnabled, "an unconfigured server claimed TLS");

		config.tlsCertificatePath = "cert.pem";
		Assert.isFalse(config.tlsEnabled, "a certificate with no key claimed TLS");

		config.tlsCertificatePath = null;
		config.tlsKeyPath = "key.pem";
		Assert.isFalse(config.tlsEnabled, "a key with no certificate claimed TLS");

		config.tlsCertificatePath = "cert.pem";
		Assert.isTrue(config.tlsEnabled, "both paths set did not enable TLS");

		// Empty is not the same as unset for a caller reading from an
		// environment variable, and is just as much "not configured".
		config.tlsCertificatePath = "";
		Assert.isFalse(config.tlsEnabled, "an empty certificate path claimed TLS");
	}

	/**
		One of the two paths, and not the other, is refused rather than served
		as plain HTTP. `tlsEnabled` answered false for it, which the case above
		pins, and the server went on to listen in plaintext for a caller who
		had asked for HTTPS and been told nothing: a misspelt key variable was
		an unencrypted server.
	**/
	public function testHalfATlsConfigurationIsRefused():Void {
		for (half in [{certificate: "cert.pem", key: null}, {certificate: null, key: "key.pem"}, {certificate: "cert.pem", key: ""}]) {
			var config = new HTTPServerConfig("127.0.0.1", 0);
			config.tlsCertificatePath = half.certificate;
			config.tlsKeyPath = half.key;
			var refused:Bool = false;
			try {
				config.validate();
			} catch (_:crossbyte.errors.ArgumentError) {
				refused = true;
			}
			Assert.isTrue(refused, 'a certificate of ${half.certificate} with a key of ${half.key} was accepted as plain HTTP');
		}

		// Neither, which is plain HTTP on purpose, is fine.
		var plain = new HTTPServerConfig("127.0.0.1", 0);
		plain.tlsCertificatePath = "";
		plain.validate();
		Assert.isFalse(plain.tlsEnabled);
	}
}

#if (cpp || java || jvm)
/** Reads through `inner`, and says while one of its reads is under way. */
private class TracingInput extends haxe.io.Input {
	public var reading(default, null):Bool = false;

	private final __inner:haxe.io.Input;

	public function new(inner:haxe.io.Input) {
		__inner = inner;
	}

	override public function readByte():Int {
		reading = true;
		try {
			var byte:Int = __inner.readByte();
			reading = false;
			return byte;
		} catch (e:Dynamic) {
			reading = false;
			throw e;
		}
	}

	override public function readBytes(buffer:Bytes, position:Int, length:Int):Int {
		reading = true;
		try {
			var count:Int = __inner.readBytes(buffer, position, length);
			reading = false;
			return count;
		} catch (e:Dynamic) {
			reading = false;
			throw e;
		}
	}
}

/** A TLS client socket that records whether it was closed while being read. */
private class TracingTlsSocket extends #if cpp crossbyte._internal.socket.AlpnSocket #else crossbyte._internal.socket._jvm.JvmSsl.JvmSslSocket #end {
	public var tracer:Null<TracingInput> = null;
	public var wasClosed(default, null):Bool = false;
	public var closedDuringRead(default, null):Bool = false;

	override public function close():Void {
		if (tracer != null && tracer.reading) {
			closedDuringRead = true;
		}
		wasClosed = true;
		super.close();
	}
}
#end
