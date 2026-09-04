package crossbyte.http;

import crossbyte.io.File;
import crossbyte.io.ByteArray;
import crossbyte.net.TLSTestFixture;
import utest.Assert;

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
		var fixture = TLSTestFixture.selfSigned();
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

					// Self-signed, so the client cannot build a path to it.
					// Verification is what ServerSocketTLSTest checks; this
					// case is about the server presenting anything at all.
					client.verifyCert = false;
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

				finished = true;
			});

			var deadline = Sys.time() + 20;
			while (Sys.time() < deadline && !finished) {
				crossbyte.core.CrossByte.current().pump(1 / 60, 0);
				Sys.sleep(0.002);
			}
		} catch (e:Dynamic) {
			try {
				server.close();
			} catch (_:Dynamic) {}
			throw e;
		}

		try {
			server.close();
		} catch (_:Dynamic) {}

		Assert.isTrue(finished, "the client neither answered nor failed within the deadline");
		Assert.isNull(failure, "the request over TLS failed: " + failure);
		Assert.notNull(response, "no response came back");
		Assert.isTrue(response.indexOf("200") >= 0, "the server did not answer 200: " + response.substr(0, 120));
		Assert.isTrue(response.indexOf("over tls") >= 0, "the body did not come back: " + response.substr(0, 200));
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
}
