package crossbyte.net;

#if !(js && !nodejs)
#if (cpp || hl || neko || java || jvm || nodejs)
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ProgressEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.http.HTTPVersion;
import crossbyte.url.URLLoader;
import crossbyte.url.URLRequest;
#end
import utest.Assert;
import utest.Async;

/**
	A certificate outside its dates is refused, on every target with TLS:
	one that has expired, and one not valid yet. By each of CrossByte's own
	clients (`Socket`, `WebSocket`, `NetConnection` and `URLLoader`), and by
	a server that requires a client's certificate. Both when an authority
	the other end trusts issued it and when it is self-signed and pinned as
	its own authority.

	The jvm let a pinned one through: PKIX checks no trust anchor's dates,
	and a pinned self-signed certificate is the anchor. Natively mbedTLS and
	on Node OpenSSL refused it; the jvm now holds every certificate a peer
	presents to its dates as well (`JvmDatedTrust`).

	Each set of cases runs beside the same certificates in date, presented
	the same way, which have to be let in: a client that cannot connect at
	all refuses too, and would pass the rest for the wrong reason.

	The certificates below are kept here rather than made by a test: one
	already expired stays as it is, one dated 2099 is not valid yet for as
	long as anyone will run this, and nothing has to have `openssl` to run
	these. Each names `localhost` and `127.0.0.1`, the address written as a
	DNS name too, since mbedTLS compares the name it was given as text; so
	its dates are all that is wrong with it.
**/
class CertificateExpiryTest extends utest.Test {
	#if (cpp || hl || neko || java || jvm || nodejs)
	@:timeout(30000)
	public function testAnExpiredCertificateIsRefusedEvenPinned(async:Async):Void {
		__probe(Certificate.fromPem(EXPIRED_CERTIFICATE), "a certificate that expired in 2020 was let in", async);
	}

	@:timeout(30000)
	public function testACertificateNotYetValidIsRefusedEvenPinned(async:Async):Void {
		__probe(Certificate.fromPem(NOT_YET_VALID_CERTIFICATE), "a certificate not valid until 2099 was let in", async);
	}

	/** A secure `Socket` refuses a server presenting a certificate outside its dates. **/
	@:timeout(90000)
	public function testASocketRefusesACertificateOutsideItsDates(async:Async):Void {
		__eachCase(function(dated, next) {
			__serveTls(dated.certificate, dated.key, null, function(server) {
				__dialSocket(server.port, dated.authority, null, function(outcome) {
					server.close();
					__judge("a Socket", dated, outcome, server.accepted());
					next();
				});
			});
		}, () -> async.done());
	}

	/**
		And a server requiring a client certificate refuses one outside its
		dates. The verdict is the server's: under TLS 1.3 a client's
		certificate travels after the server's Finished, so the client can
		believe itself connected a moment before it is turned away.
	**/
	@:timeout(90000)
	public function testAServerRefusesAClientCertificateOutsideItsDates(async:Async):Void {
		var issued:Certificate = Certificate.fromPem(ISSUED);
		var authority:Certificate = Certificate.fromPem(AUTHORITY);
		__eachCase(function(dated, next) {
			__serveTls(issued, Key.fromPem(DATED_KEY), dated.authority, function(server) {
				__dialSocket(server.port, authority, {certificate: dated.certificate, key: dated.key}, function(outcome) {
					NetPump.until(() -> server.accepted() > 0 || server.failures() >= 1, 10.0, function(_) {
						var accepted:Int = server.accepted();
						server.close();
						if (dated.inDate) {
							Assert.equals(1, accepted, 'a client presenting ${dated.what} was not let in: ' + outcome.failure);
						} else {
							Assert.equals(0, accepted, 'a client presenting ${dated.what} was let in');
						}
						next();
					});
				});
			});
		}, () -> async.done());
	}

	#if (cpp || java || jvm || nodejs)
	/**
		A `wss://` `WebSocket` refuses a server presenting a certificate
		outside its dates. Not on neko and HashLink, where a `WebSocket`
		client cannot connect: its handshake key needs secure random bytes,
		which neither has.
	**/
	@:timeout(90000)
	public function testAWebSocketRefusesACertificateOutsideItsDates(async:Async):Void {
		__eachCase(function(dated, next) {
			var server = new ServerWebSocket(true);
			server.cert = {certificate: dated.certificate, key: dated.key};
			server.handshakeTimeout = 5;
			var sessions:Array<WebSocket> = [];
			server.addEventListener(ServerSocketConnectEvent.CONNECT, (e:ServerSocketConnectEvent) -> sessions.push(cast e.socket));
			server.bind(0, "127.0.0.1");
			server.listen();
			NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
				var client = new WebSocket();
				client.secure = true;
				client.certAuthority = dated.authority;
				var outcome:DialOutcome = {connected: false, failure: null};
				client.addEventListener(Event.CONNECT, _ -> outcome.connected = true);
				client.addEventListener(IOErrorEvent.IO_ERROR, (e:IOErrorEvent) -> if (outcome.failure == null) outcome.failure = e.text);
				client.addEventListener(Event.CLOSE, _ -> if (outcome.failure == null) outcome.failure = "closed");
				client.connect("127.0.0.1", server.localPort);
				__settle(outcome, () -> sessions.length > 0, function() {
					try client.close() catch (_:Dynamic) {}
					for (session in sessions) {
						try session.close() catch (_:Dynamic) {}
					}
					try server.close() catch (_:Dynamic) {}
					__judge("a WebSocket", dated, outcome, sessions.length);
					next();
				});
			});
		}, () -> async.done());
	}
	#end

	/**
		A `tls://` or `wss://` `NetConnection` given an authority to trust
		refuses a `NetHost` presenting a certificate outside its dates. Only
		`tls://` on neko and HashLink, for the reason above.
	**/
	@:timeout(120000)
	public function testANetConnectionRefusesACertificateOutsideItsDates(async:Async):Void {
		var schemes:Array<String> = #if (hl || neko) ["tls"] #else ["tls", "wss"] #end;
		function scheme(index:Int):Void {
			if (index >= schemes.length) {
				async.done();
				return;
			}
			var name:String = schemes[index];
			__eachCase(function(dated, next) {
				var accepted:Int = 0;
				var host = new NetHost('$name://127.0.0.1:0', _ -> accepted++, null, null, true, {certificate: dated.certificate, key: dated.key});
				NetPump.until(() -> host.localPort != 0, 5.0, function(_) {
					var outcome:DialOutcome = {connected: false, failure: null};
					var connection = new NetConnection('$name://127.0.0.1:${host.localPort}' + (name == "wss" ? "/" : ""), null,
						() -> outcome.connected = true, reason -> if (outcome.failure == null) outcome.failure = "closed: " + reason,
						reason -> if (outcome.failure == null) outcome.failure = Std.string(reason), false, {certAuthority: dated.authority});
					__settle(outcome, () -> accepted > 0, function() {
						try connection.close() catch (_:Dynamic) {}
						try host.close() catch (_:Dynamic) {}
						__judge('a $name:// NetConnection', dated, outcome, accepted);
						next();
					});
				});
			}, () -> scheme(index + 1));
		}
		scheme(0);
	}

	/**
		An `https` `URLLoader` refuses a server presenting a certificate
		outside its dates: over HTTP/1.1, over HTTP/2 where TLS can negotiate
		it, and with the server's key pinned as well where a pin can be
		checked (on Node a pinned request makes its own connection).
	**/
	@:timeout(180000)
	public function testAnHttpsLoadRefusesACertificateOutsideItsDates(async:Async):Void {
		var ways:Array<{what:String, version:HTTPVersion, pinned:Bool}> = [{what: "an https URLLoader", version: HTTPVersion.HTTP_1_1, pinned: false}];
		#if (cpp || java || jvm || nodejs)
		ways.push({what: "a pinned https URLLoader", version: HTTPVersion.HTTP_1_1, pinned: true});
		#end
		#if !nodejs
		if (crossbyte._internal.socket.FlexSocket.alpnSupported) {
			ways.push({what: "an HTTP/2 URLLoader", version: HTTPVersion.HTTP_2, pinned: false});
		}
		#end

		function way(index:Int):Void {
			if (index >= ways.length) {
				#if !nodejs
				crossbyte._internal.http.HttpConnectionPool.clear();
				crossbyte._internal.http.h2.H2ConnectionPool.closeAll();
				#end
				async.done();
				return;
			}
			var how = ways[index];
			__eachCase(function(dated, next) {
				__serveHttps(dated, how.version, function(port, served, close) {
					var outcome:DialOutcome = {connected: false, failure: null};
					var loader = new URLLoader();
					loader.addEventListener(Event.COMPLETE, _ -> outcome.connected = true);
					loader.addEventListener(IOErrorEvent.IO_ERROR, (e:IOErrorEvent) -> outcome.failure = e.text);
					var request = new URLRequest('https://127.0.0.1:$port/');
					request.httpVersion = how.version;
					request.readTimeout = 5.0;
					request.certAuthority = dated.authority;
					if (how.pinned) {
						request.pinnedPublicKeys = [crossbyte._internal.http.PublicKeyPins.pinOf(dated.certificate.der)];
					}
					loader.load(request);
					NetPump.until(() -> outcome.connected || outcome.failure != null, 20.0, function(_) {
						var answered:Int = served();
						close();
						__judge(how.what, dated, outcome, answered);
						next();
					});
				});
			}, () -> way(index + 1));
		}
		way(0);
	}

	/** `pinned`, presented and pinned as its own authority, through `TlsProbe`: refused. **/
	private static function __probe(pinned:Certificate, message:String, async:Async):Void {
		var server = new ServerSocket(true);
		server.addEventListener(ServerSocketConnectEvent.CONNECT, e -> try e.socket.close() catch (_:Dynamic) {});
		server.setCertificate(pinned, Key.fromPem(DATED_KEY));
		server.bind(0, "127.0.0.1");
		server.listen();
		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			TlsProbe.run(server.localPort, {serverName: "localhost", trust: pinned}, function(outcome) {
				Assert.notNull(outcome.error, message);
				server.close();
				async.done();
			});
		});
	}

	/**
		Each certificate, beside what the other end trusts and whether it is in
		its dates: issued by `AUTHORITY`, then self-signed and pinned.
	**/
	private static function __cases():Array<DatedCase> {
		return [
			__case("a certificate its authority issued, in its dates", ISSUED, DATED_KEY, AUTHORITY, true),
			__case("a certificate its authority issued that expired in 2020", ISSUED_EXPIRED, DATED_KEY, AUTHORITY, false),
			__case("a certificate its authority issued that is not valid until 2099", ISSUED_NOT_YET_VALID, DATED_KEY, AUTHORITY, false),
			__case("a self-signed certificate pinned as its own authority, in its dates", AUTHORITY, AUTHORITY_KEY, AUTHORITY, true),
			__case("a self-signed certificate pinned as its own authority that expired in 2020", EXPIRED_CERTIFICATE, DATED_KEY,
				EXPIRED_CERTIFICATE, false),
			__case("a self-signed certificate pinned as its own authority that is not valid until 2099", NOT_YET_VALID_CERTIFICATE, DATED_KEY,
				NOT_YET_VALID_CERTIFICATE, false)
		];
	}

	private static function __case(what:String, certificate:String, key:String, authority:String, inDate:Bool):DatedCase {
		return {
			what: what,
			certificate: Certificate.fromPem(certificate),
			key: Key.fromPem(key),
			authority: Certificate.fromPem(authority),
			certificatePem: certificate,
			keyPem: key,
			inDate: inDate
		};
	}

	/** `each` for every case in turn, each given the call that runs the next; then `done`. **/
	private static function __eachCase(each:(DatedCase, Void->Void) -> Void, done:Void->Void):Void {
		var cases:Array<DatedCase> = __cases();
		function next(index:Int):Void {
			if (index >= cases.length) {
				done();
				return;
			}
			each(cases[index], () -> next(index + 1));
		}
		next(0);
	}

	/**
		What a client made of `dated`: let in, when it is in its dates, and
		otherwise refused over the certificate, with the server (which
		`accepted` connections) never reached.
	**/
	private static function __judge(client:String, dated:DatedCase, outcome:DialOutcome, accepted:Int):Void {
		if (dated.inDate) {
			Assert.isTrue(outcome.connected, '$client refused ${dated.what}: ' + outcome.failure);
			Assert.equals(1, accepted, 'the server never saw $client given ${dated.what}');
			return;
		}
		Assert.isFalse(outcome.connected, '$client accepted ${dated.what}');
		Assert.isTrue(__isCertificateRefusal(outcome.failure), '$client failed on ${dated.what}, but not over the certificate: ' + outcome.failure);
		Assert.equals(0, accepted, 'the server was reached by $client, which should have refused ${dated.what}');
	}

	/**
		Whether `failure` is a TLS layer refusing a certificate, in any of the
		ways the targets word it: mbedTLS reports an X509 verification
		failure, the JDK a PKIX path or a certificate's NotAfter or NotBefore,
		and Node a certificate expired or not yet valid.
	**/
	private static function __isCertificateRefusal(failure:Null<String>):Bool {
		if (failure == null) {
			return false;
		}
		for (sign in ["X509", "ertificate", "PKIX", "NotAfter", "NotBefore", "expired", "not yet valid"]) {
			if (failure.indexOf(sign) >= 0) {
				return true;
			}
		}
		return false;
	}

	/**
		Waits until `outcome` is settled (connected and `reached`, or failed),
		and a little longer, so a connection the client should have refused
		has the chance to reach the server if it got that far; then `then`.
	**/
	private static function __settle(outcome:DialOutcome, reached:Void->Bool, then:Void->Void):Void {
		NetPump.until(() -> (outcome.connected && reached()) || outcome.failure != null, 10.0, _ -> NetPump.wait(0.2, then));
	}

	/**
		A secure `Socket` to `port`, trusting `trust` and presenting `present`
		if given, and what it made of the server.
	**/
	private static function __dialSocket(port:Int, trust:Certificate, present:Null<{certificate:Certificate, key:Key}>, then:DialOutcome->Void):Void {
		var client = new Socket();
		client.secure = true;
		client.certAuthority = trust;
		if (present != null) {
			client.setCertificate(present.certificate, present.key);
		}
		var outcome:DialOutcome = {connected: false, failure: null};
		client.addEventListener(Event.CONNECT, _ -> outcome.connected = true);
		client.addEventListener(IOErrorEvent.IO_ERROR, (e:IOErrorEvent) -> if (outcome.failure == null) outcome.failure = e.text);
		client.addEventListener(Event.CLOSE, _ -> if (outcome.failure == null) outcome.failure = "closed");
		client.connect("127.0.0.1", port);
		__settle(outcome, () -> true, function() {
			try client.close() catch (_:Dynamic) {}
			then(outcome);
		});
	}

	/**
		A TLS `ServerSocket` presenting `certificate`, requiring a client
		certificate `clientAuthority` issued when given one, and answering an
		HTTP request with a 200 and closing.
	**/
	private static function __serveTls(certificate:Certificate, key:Key, clientAuthority:Null<Certificate>, then:TlsServer->Void):Void {
		var server = new ServerSocket(true);
		server.setCertificate(certificate, key);
		if (clientAuthority != null) {
			server.requireClientCertificate(clientAuthority);
		}
		server.handshakeTimeout = 5;
		var accepted:Array<Socket> = [];
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) {
			var peer:Socket = e.socket;
			accepted.push(peer);
			var seen:String = "";
			peer.addEventListener(ProgressEvent.SOCKET_DATA, function(_) {
				seen += peer.readUtfBytes(peer.bytesAvailable);
				if (seen.indexOf("\r\n\r\n") >= 0) {
					seen = "";
					peer.writeUtfBytes("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 7\r\nConnection: close\r\n\r\nin date");
					peer.flush();
				}
			});
		});
		server.bind(0, "127.0.0.1");
		server.listen();
		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			then({
				port: server.localPort,
				accepted: () -> accepted.length,
				failures: () -> server.handshakeFailures,
				close: function() {
					for (peer in accepted) {
						try peer.close() catch (_:Dynamic) {}
					}
					try server.close() catch (_:Dynamic) {}
				}
			});
		});
	}

	/**
		An `https` server presenting `dated`'s certificate, answering 200 to
		`version`: HTTP/1.1 from `__serveTls`, and HTTP/2 from an `HTTPServer`,
		which takes its certificate and key from files, written for it.
		`served` counts what reached it.
	**/
	private static function __serveHttps(dated:DatedCase, version:HTTPVersion, then:(port:Int, served:Void->Int, close:Void->Void) -> Void):Void {
		#if !nodejs
		if (version == HTTPVersion.HTTP_2) {
			var directory:String = haxe.io.Path.join([__tempDirectory(), "crossbyte-dated-" + Std.random(0x3FFFFFFF)]);
			sys.FileSystem.createDirectory(directory);
			var certificatePath:String = haxe.io.Path.join([directory, "cert.pem"]);
			var keyPath:String = haxe.io.Path.join([directory, "key.pem"]);
			sys.io.File.saveContent(certificatePath, dated.certificatePem);
			sys.io.File.saveContent(keyPath, dated.keyPem);
			var served:Int = 0;
			var router = new crossbyte.http.Router();
			router.get("/", ctx -> {
				served++;
				ctx.handler.respond(200, "text/plain", "in date");
			});
			var config = new crossbyte.http.HTTPServerConfig("127.0.0.1", 0);
			config.tlsCertificatePath = certificatePath;
			config.tlsKeyPath = keyPath;
			config.http2Enabled = true;
			config.middleware.push(router.middleware());
			var server = new crossbyte.http.HTTPServer(config);
			then(server.localPort, () -> served, function() {
				try server.close() catch (_:Dynamic) {}
				for (path in [certificatePath, keyPath]) {
					try sys.FileSystem.deleteFile(path) catch (_:Dynamic) {}
				}
				try sys.FileSystem.deleteDirectory(directory) catch (_:Dynamic) {}
			});
			return;
		}
		#end
		__serveTls(dated.certificate, dated.key, null, server -> then(server.port, server.accepted, server.close));
	}

	#if !nodejs
	private static function __tempDirectory():String {
		for (candidate in [Sys.getEnv("TEMP"), Sys.getEnv("TMP"), Sys.getEnv("TMPDIR"), "/tmp"]) {
			if (candidate != null && candidate != "" && sys.FileSystem.exists(candidate)) {
				return candidate;
			}
		}
		return ".";
	}
	#end
	#end

	/** Self-signed for `localhost` and `127.0.0.1`, valid for 1 January 2020 alone. **/
	public static final EXPIRED_CERTIFICATE:String = [
		"-----BEGIN CERTIFICATE-----",
		"MIIDMDCCAhigAwIBAgIUUtdpcCqwCP2B2guOa6yO5R3HAIMwDQYJKoZIhvcNAQEL",
		"BQAwFDESMBAGA1UEAwwJbG9jYWxob3N0MB4XDTIwMDEwMTAwMDAwMFoXDTIwMDEw",
		"MjAwMDAwMFowFDESMBAGA1UEAwwJbG9jYWxob3N0MIIBIjANBgkqhkiG9w0BAQEF",
		"AAOCAQ8AMIIBCgKCAQEAlJSZil++936YOc7990bxDgKOMWWhsYcUBSE51+Nixw3q",
		"hFoAQkgbC9Pz7Laz71NZd8jl5vryfKbOIAd2yLsF5qbUzAlBwZW5Qf/JM1eLFsKH",
		"l6tGfQnu/MEJtBbf61DOWBIQqAMe3o9S8s6CFIRRbpqMf+dqAF88EV7OW3C2Th1O",
		"Lc9qttkFgV3OdshKtPKI2XqvxMy+cRzm3F7yIED6m2sFZif7gaXd/jUvkOk14txO",
		"1Vb28itrAyFHylGjFWU2QrjEsVGmxUjnY93XdIAIbL+XMmkreNQFmdRcCyC4FnQA",
		"mZTKs8D7KKrxC2NqAr8XeBFFS12nxXCmbc4Y3NMlMQIDAQABo3oweDAdBgNVHQ4E",
		"FgQU3X22eL33Xl8o+2G6dkb0cebyOU4wHwYDVR0jBBgwFoAU3X22eL33Xl8o+2G6",
		"dkb0cebyOU4wDwYDVR0TAQH/BAUwAwEB/zAlBgNVHREEHjAcgglsb2NhbGhvc3SC",
		"CTEyNy4wLjAuMYcEfwAAATANBgkqhkiG9w0BAQsFAAOCAQEAdOg4H+RCPtiDOf/p",
		"bNU95nMaNK4fITg8po2HvXelWAeWkHVSL3BP0XJ057aPZRJv4Ol79rWhibudtlM3",
		"uEkZtx54DZbpoPjl5NgIWw9XbZwzdey1nH81KrIA5tvG4g+fICxmi0zfPVY7ZKah",
		"6uKG+WF3E1mPQXUa5QzpeTcjGGI2CailuCS5+7jgqNBCHZ3DIvv3wofgRK+BZVrb",
		"XmulJoqbrq9X7y0nXE0OYSpvEwYLx0QIdNNnZEJAReQpejn22ifMJPQhV62LoPUv",
		"AqWIPbOLTufEqppSWmjxDP8JBCOTTdP6u5/1NRspdPoY9uaAMW3nERyFnDqwyf1Y",
		"JsyQqQ==",
		"-----END CERTIFICATE-----"
	].join("\n");

	/** Self-signed for `localhost` and `127.0.0.1`, valid for 1 January 2099 alone. **/
	public static final NOT_YET_VALID_CERTIFICATE:String = [
		"-----BEGIN CERTIFICATE-----",
		"MIIDNDCCAhygAwIBAgIUO/vHc9rGGCf1/N6Yg2fhPYm4srIwDQYJKoZIhvcNAQEL",
		"BQAwFDESMBAGA1UEAwwJbG9jYWxob3N0MCIYDzIwOTkwMTAxMDAwMDAwWhgPMjA5",
		"OTAxMDIwMDAwMDBaMBQxEjAQBgNVBAMMCWxvY2FsaG9zdDCCASIwDQYJKoZIhvcN",
		"AQEBBQADggEPADCCAQoCggEBAJSUmYpfvvd+mDnO/fdG8Q4CjjFlobGHFAUhOdfj",
		"YscN6oRaAEJIGwvT8+y2s+9TWXfI5eb68nymziAHdsi7Beam1MwJQcGVuUH/yTNX",
		"ixbCh5erRn0J7vzBCbQW3+tQzlgSEKgDHt6PUvLOghSEUW6ajH/nagBfPBFezltw",
		"tk4dTi3ParbZBYFdznbISrTyiNl6r8TMvnEc5txe8iBA+ptrBWYn+4Gl3f41L5Dp",
		"NeLcTtVW9vIrawMhR8pRoxVlNkK4xLFRpsVI52Pd13SACGy/lzJpK3jUBZnUXAsg",
		"uBZ0AJmUyrPA+yiq8QtjagK/F3gRRUtdp8Vwpm3OGNzTJTECAwEAAaN6MHgwHQYD",
		"VR0OBBYEFN19tni9915fKPthunZG9HHm8jlOMB8GA1UdIwQYMBaAFN19tni9915f",
		"KPthunZG9HHm8jlOMA8GA1UdEwEB/wQFMAMBAf8wJQYDVR0RBB4wHIIJbG9jYWxo",
		"b3N0ggkxMjcuMC4wLjGHBH8AAAEwDQYJKoZIhvcNAQELBQADggEBAFkbi9IzpfmR",
		"yCWWJ8gd3ol+ShDpD7122cV0RWq36vBOabCld5FfNwQj7s5HI55DsRYw5lckUtcY",
		"M2GlCEuxW+j6UKCsE1nTa/tR5rxFia0k8O1jLwibFPkNbtEo4bALFfTfOBsDsuxY",
		"x83oWT+xgupZBtWgcPO1PxpJzHrX948GneDOcUDxBKXPb2DneIgrNWuV4OIs/pQH",
		"AaPAdj7BQqT8cVG+1jkF6LL778ci0yNTLfBSIgwM5cx7wn14K7d4BVydJmfrp/Iy",
		"/I9fca0lUmtFGmVFEOPIX/FoM1UZ+hSz8OoXTQjf7xA/IKYOTD9/11uAKsYrF0bY",
		"QFFyC6Ov4sI=",
		"-----END CERTIFICATE-----"
	].join("\n");

	/** An authority, valid from 2020 to 2120, which issued the three below; it names `localhost` and `127.0.0.1` too, so it can be presented itself. **/
	public static final AUTHORITY:String = [
		"-----BEGIN CERTIFICATE-----",
		"MIIDXDCCAkSgAwIBAgIUcXrh98nPH6is+AA0Cc9pHqX7WzMwDQYJKoZIhvcNAQEL",
		"BQAwKTEnMCUGA1UEAwweQ3Jvc3NCeXRlIERhdGVkIFRlc3QgQXV0aG9yaXR5MCAX",
		"DTIwMDEwMTAwMDAwMFoYDzIxMjAwMTAxMDAwMDAwWjApMScwJQYDVQQDDB5Dcm9z",
		"c0J5dGUgRGF0ZWQgVGVzdCBBdXRob3JpdHkwggEiMA0GCSqGSIb3DQEBAQUAA4IB",
		"DwAwggEKAoIBAQDEJrNFc1qQr11afuhClF+bq2DOsUgosihqAXj+L6vr6O+nM1/2",
		"dHgGQuOftsbqcEsLv770yqG9OUL+BtwvQT6OWTAONuPq+zbmp/M5O7lC4fof6RZl",
		"VVfdaaWW1+omCIdTQHqknRU6lvnGVhWI5AxX6mnfC2QK/xToax/3cjk0azBwSS1g",
		"H2cEL1QcYv28URSCPKpGwYvf6kRxWJCdjnQeYsjSD3Qxoej9dZTn1FVNQ7/wKP6+",
		"S8g6P50eD068ScFWLx8FA0uj49xjxwgqQ8lpbdTfAYNqLWH68GZLii04BOCqBLhh",
		"xVEVRb6Z62Z5USn/TMoN5d86QPtAUDp5MdsFAgMBAAGjejB4MB0GA1UdDgQWBBSJ",
		"4FHT2mpmgj9GnVa3ybpx0fOErjAfBgNVHSMEGDAWgBSJ4FHT2mpmgj9GnVa3ybpx",
		"0fOErjAPBgNVHRMBAf8EBTADAQH/MCUGA1UdEQQeMByCCWxvY2FsaG9zdIIJMTI3",
		"LjAuMC4xhwR/AAABMA0GCSqGSIb3DQEBCwUAA4IBAQCmtNsHLyVZC3H20LtDjnSI",
		"GphMM2eb4jQqDRdKuPIWGNElI4AoUBB5L7q5xUyi+UWNQdlFlbQRWjqy1lE1B2qy",
		"Egyqs/WPEjkil2c9QT4iPQcb1IRd/C4gSUbtYXRfHacAy5t/VddhNXzyljOd6mN1",
		"zaJFNHGNnWFw28luJrzK/Bja6RdhlNkOmN/vQcRNwrvyuAM798pd2X9qlr09zmtX",
		"G+tRrxdzBAtwKMKBP15EuqNp68z2Y5PASaYYSQtl1SU5wSQB25zLzopDLx0CUU7E",
		"1DyDMEEsY3gH/dS36M7twr/YnYxXsYex3AKGjdD7HyPHe3Cp9BTNTk+JkwqXPqQa",
		"-----END CERTIFICATE-----"
	].join("\n");

	/** The key of `AUTHORITY`. **/
	public static final AUTHORITY_KEY:String = [
		"-----BEGIN PRIVATE KEY-----",
		"MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDEJrNFc1qQr11a",
		"fuhClF+bq2DOsUgosihqAXj+L6vr6O+nM1/2dHgGQuOftsbqcEsLv770yqG9OUL+",
		"BtwvQT6OWTAONuPq+zbmp/M5O7lC4fof6RZlVVfdaaWW1+omCIdTQHqknRU6lvnG",
		"VhWI5AxX6mnfC2QK/xToax/3cjk0azBwSS1gH2cEL1QcYv28URSCPKpGwYvf6kRx",
		"WJCdjnQeYsjSD3Qxoej9dZTn1FVNQ7/wKP6+S8g6P50eD068ScFWLx8FA0uj49xj",
		"xwgqQ8lpbdTfAYNqLWH68GZLii04BOCqBLhhxVEVRb6Z62Z5USn/TMoN5d86QPtA",
		"UDp5MdsFAgMBAAECggEABSfJPXGPN09MolTEkP9qVeKWvEf/kAZCtqqMPg4NtDke",
		"l2PryUP9ZZi7d9arerzx1AC5qaBryNfo8VlHzzwlQ0OH1k/OBL6OjlhqtZ3ivCXJ",
		"V65eJtKr6QdeUU0ie9ZsjB0dPBde1/fg37wie8MWqfbgynp3qixTJdqu7+eCJmUB",
		"CZ6P4wD+QVaDfJ9HhIk0AZP4GY6XlE/lnST8AmUcuN4dsQFcjjjgHb8dGrQpl03+",
		"EkdHfJI+vuvS23lFIObR6V+XvzUdPIMB1ueWoIyLGjJ/rcJca0apVnI4gCQKsNDj",
		"9LV4UCHjQdSKedP/75VO+035AQ38lVDVXLIKcPEizwKBgQDqv//5mq2x6DFGmWNV",
		"IWIZTsCn+gtLqYltYFUBomFvH+lcFVXR1O6MOw4hwRCIKGaLM66l15uNdHeyFGXi",
		"aQnNWU79pxgD9mgrlACjx2SZaGl3onz7dJBDgZTkPdTZ2HJyGfjHPtNFiS2NwZZ0",
		"2/GhLoOiWFFD9Vs5sJ0VVUaKFwKBgQDV6Dodw/nOU2NdOg93SlkXLKbJE5zkAdge",
		"nxTGlVou1Xqa3bYO6t33YbEdIHutHvsr7WWAO9Bb4/DSZZCpmx2mOuyYvUe7EDSr",
		"/pnzHc/bZxrTDf5Mtqkj9QBpQR/8hn+qSyv3cAzQNwnztPatwb/By4Q5KxEhbdrh",
		"XKmv9H9hQwKBgBfR561yLpHQ178sLVIkEwoyXYYt7xt8Vn+MuNNzoKNf/5PiblTe",
		"YF5GV8bBCmZmgxE4603UtOoDmWmufDAfLGlz2HoQjHVKeYOCfxYfU2vlll4XVMtH",
		"JqRS78LBK2n3dpVxYTcGfvWdV8v8isHM15XdXGoKwCQ/L0SJUUcq4f99AoGASCHr",
		"lyYDE0SjeUie9ocny9zO0Xe/rFPC4XCbvOuYYbqzgY3KWvVwrH9RDpVpn1OXN5Ty",
		"aW/CL3qKNyjww4D/WpL8PfV2PuqUGHvexlEDSuVV8l4BpzThjLKN1PCVLL7eRjrb",
		"NLGgYIZu4LPhi26Oj3dluzF+sVsuOFjbD+7PFakCgYEAxExHq4PYI8jR1ebSNwW0",
		"Alntij1KZGg7Ns8IdMzPHniN5p36Tw5uTKlHGWoQ2t5PrRRa97z05rW1BSOlcyVV",
		"uPE3KXb2O1ysj/i2GWqlnxNHdN9yn+TcUDDrOAZRG3/F65Qclxtttbe08M7Fei2h",
		"mn2Q8d6o3tnhKVFW5WKI3EI=",
		"-----END PRIVATE KEY-----"
	].join("\n");

	/** For `localhost` and `127.0.0.1`, issued by `AUTHORITY` for a server or a client, valid from 2020 to 2120. **/
	public static final ISSUED:String = [
		"-----BEGIN CERTIFICATE-----",
		"MIIDYzCCAkugAwIBAgICA+kwDQYJKoZIhvcNAQELBQAwKTEnMCUGA1UEAwweQ3Jv",
		"c3NCeXRlIERhdGVkIFRlc3QgQXV0aG9yaXR5MCAXDTIwMDEwMTAwMDAwMFoYDzIx",
		"MjAwMTAxMDAwMDAwWjAUMRIwEAYDVQQDDAlsb2NhbGhvc3QwggEiMA0GCSqGSIb3",
		"DQEBAQUAA4IBDwAwggEKAoIBAQCUlJmKX773fpg5zv33RvEOAo4xZaGxhxQFITnX",
		"42LHDeqEWgBCSBsL0/PstrPvU1l3yOXm+vJ8ps4gB3bIuwXmptTMCUHBlblB/8kz",
		"V4sWwoeXq0Z9Ce78wQm0Ft/rUM5YEhCoAx7ej1LyzoIUhFFumox/52oAXzwRXs5b",
		"cLZOHU4tz2q22QWBXc52yEq08ojZeq/EzL5xHObcXvIgQPqbawVmJ/uBpd3+NS+Q",
		"6TXi3E7VVvbyK2sDIUfKUaMVZTZCuMSxUabFSOdj3dd0gAhsv5cyaSt41AWZ1FwL",
		"ILgWdACZlMqzwPsoqvELY2oCvxd4EUVLXafFcKZtzhjc0yUxAgMBAAGjgacwgaQw",
		"HQYDVR0OBBYEFN19tni9915fKPthunZG9HHm8jlOMB8GA1UdIwQYMBaAFIngUdPa",
		"amaCP0adVrfJunHR84SuMAwGA1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgWgMB0G",
		"A1UdJQQWMBQGCCsGAQUFBwMBBggrBgEFBQcDAjAlBgNVHREEHjAcgglsb2NhbGhv",
		"c3SCCTEyNy4wLjAuMYcEfwAAATANBgkqhkiG9w0BAQsFAAOCAQEAOEBuJXXWxaf9",
		"rMiehPw3X4fAKO91b58uk8tjjl10hHCMGkr090040lA3qIuXg1+mLZs5vbe+1kOe",
		"J1CrwVTp7ijIxaHa2ZyILwEfcJZhdS3M7MYBV/Y0DZktEJCN51e4YEM8d7rG+qeW",
		"wYtIImXnF0tHI5Y169f5UHJLwr+iFcaZ8oBMy14TXwwV7/o/D6eMN1qO+kiVgST+",
		"AjnZdy7FvPVnP4z7yDymONLPAP0Y/7JNzTFbSk/7g0Vt85lC6w9wCbZixkWNNUyE",
		"+DPHY+RmfowDHhT5Y2qxWlWekSrBxc9wv77Rw3asHNmBmNeTBusnrPgrVGIH9Ksf",
		"5HHjXfFaSQ==",
		"-----END CERTIFICATE-----"
	].join("\n");

	/** As `ISSUED`, valid for 1 January 2020 alone. **/
	public static final ISSUED_EXPIRED:String = [
		"-----BEGIN CERTIFICATE-----",
		"MIIDYTCCAkmgAwIBAgICA+owDQYJKoZIhvcNAQELBQAwKTEnMCUGA1UEAwweQ3Jv",
		"c3NCeXRlIERhdGVkIFRlc3QgQXV0aG9yaXR5MB4XDTIwMDEwMTAwMDAwMFoXDTIw",
		"MDEwMjAwMDAwMFowFDESMBAGA1UEAwwJbG9jYWxob3N0MIIBIjANBgkqhkiG9w0B",
		"AQEFAAOCAQ8AMIIBCgKCAQEAlJSZil++936YOc7990bxDgKOMWWhsYcUBSE51+Ni",
		"xw3qhFoAQkgbC9Pz7Laz71NZd8jl5vryfKbOIAd2yLsF5qbUzAlBwZW5Qf/JM1eL",
		"FsKHl6tGfQnu/MEJtBbf61DOWBIQqAMe3o9S8s6CFIRRbpqMf+dqAF88EV7OW3C2",
		"Th1OLc9qttkFgV3OdshKtPKI2XqvxMy+cRzm3F7yIED6m2sFZif7gaXd/jUvkOk1",
		"4txO1Vb28itrAyFHylGjFWU2QrjEsVGmxUjnY93XdIAIbL+XMmkreNQFmdRcCyC4",
		"FnQAmZTKs8D7KKrxC2NqAr8XeBFFS12nxXCmbc4Y3NMlMQIDAQABo4GnMIGkMB0G",
		"A1UdDgQWBBTdfbZ4vfdeXyj7Ybp2RvRx5vI5TjAfBgNVHSMEGDAWgBSJ4FHT2mpm",
		"gj9GnVa3ybpx0fOErjAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIFoDAdBgNV",
		"HSUEFjAUBggrBgEFBQcDAQYIKwYBBQUHAwIwJQYDVR0RBB4wHIIJbG9jYWxob3N0",
		"ggkxMjcuMC4wLjGHBH8AAAEwDQYJKoZIhvcNAQELBQADggEBABN8E/v4E70HTXIW",
		"wrYD+nm5Jdfgn2+AvuTO+z7s1He33I18lkmErV014iotT4Wy9mRK6fivB/xvEC/6",
		"nR+q/dAfThH9PXc6mLkiG5EO6wNyBMXm2lnn4m1w9QEmRLGbKXFgGYVmsz7SMZIH",
		"5QWaucrD968Nwpj0jsRmEXxJV/reWkE/K3GqxF0gLclcZ/oabyoPYb/t4yOn9imB",
		"MWw0gOk5hUPX7mf5kxsoc+XONQ2iy9riAtWIG0kw4pV8LAne4IxkeGompdCt2/Ye",
		"EJoOOKAf7AiQsgKU7ovdiadO5T65EolVONU3vU0gP9OkolUzb0XKI54Lq2vL2Iic",
		"811JIKc=",
		"-----END CERTIFICATE-----"
	].join("\n");

	/** As `ISSUED`, valid for 1 January 2099 alone. **/
	public static final ISSUED_NOT_YET_VALID:String = [
		"-----BEGIN CERTIFICATE-----",
		"MIIDZTCCAk2gAwIBAgICA+swDQYJKoZIhvcNAQELBQAwKTEnMCUGA1UEAwweQ3Jv",
		"c3NCeXRlIERhdGVkIFRlc3QgQXV0aG9yaXR5MCIYDzIwOTkwMTAxMDAwMDAwWhgP",
		"MjA5OTAxMDIwMDAwMDBaMBQxEjAQBgNVBAMMCWxvY2FsaG9zdDCCASIwDQYJKoZI",
		"hvcNAQEBBQADggEPADCCAQoCggEBAJSUmYpfvvd+mDnO/fdG8Q4CjjFlobGHFAUh",
		"OdfjYscN6oRaAEJIGwvT8+y2s+9TWXfI5eb68nymziAHdsi7Beam1MwJQcGVuUH/",
		"yTNXixbCh5erRn0J7vzBCbQW3+tQzlgSEKgDHt6PUvLOghSEUW6ajH/nagBfPBFe",
		"zltwtk4dTi3ParbZBYFdznbISrTyiNl6r8TMvnEc5txe8iBA+ptrBWYn+4Gl3f41",
		"L5DpNeLcTtVW9vIrawMhR8pRoxVlNkK4xLFRpsVI52Pd13SACGy/lzJpK3jUBZnU",
		"XAsguBZ0AJmUyrPA+yiq8QtjagK/F3gRRUtdp8Vwpm3OGNzTJTECAwEAAaOBpzCB",
		"pDAdBgNVHQ4EFgQU3X22eL33Xl8o+2G6dkb0cebyOU4wHwYDVR0jBBgwFoAUieBR",
		"09pqZoI/Rp1Wt8m6cdHzhK4wDAYDVR0TAQH/BAIwADAOBgNVHQ8BAf8EBAMCBaAw",
		"HQYDVR0lBBYwFAYIKwYBBQUHAwEGCCsGAQUFBwMCMCUGA1UdEQQeMByCCWxvY2Fs",
		"aG9zdIIJMTI3LjAuMC4xhwR/AAABMA0GCSqGSIb3DQEBCwUAA4IBAQALHiO7iTn0",
		"8EB7rscDJaAvtmdro8mA6Lzx8UVxj8obVE1rxwl8go3g8v0pylEbFdfnRAz9SROD",
		"mimbVk86enjJRDZr0vP5UrpS7BXxSC4auIgX5DEFBAr5Q0gnvDxqsz5lWn7+S01N",
		"0amTyC8us5kQa4j1W3zYxNT2vzpzJ2EuuYWnthkNv6HGP39oDl360KxDl2BDPw7J",
		"cU4CI9izPH3zGVPezJowNEFLBXRcf4a/lmqyQKhBFIcuyPo40MNm4KWf/m1IgUF2",
		"//r7xiQwBXP9hkXbrqp41c2K58zVC3v51DEabsIRuwgePFHLcii1RBFTx4HMUjP+",
		"lyHzCLx20W+L",
		"-----END CERTIFICATE-----"
	].join("\n");

	/** The key of every certificate here but `AUTHORITY`. **/
	public static final DATED_KEY:String = [
		"-----BEGIN PRIVATE KEY-----",
		"MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCUlJmKX773fpg5",
		"zv33RvEOAo4xZaGxhxQFITnX42LHDeqEWgBCSBsL0/PstrPvU1l3yOXm+vJ8ps4g",
		"B3bIuwXmptTMCUHBlblB/8kzV4sWwoeXq0Z9Ce78wQm0Ft/rUM5YEhCoAx7ej1Ly",
		"zoIUhFFumox/52oAXzwRXs5bcLZOHU4tz2q22QWBXc52yEq08ojZeq/EzL5xHObc",
		"XvIgQPqbawVmJ/uBpd3+NS+Q6TXi3E7VVvbyK2sDIUfKUaMVZTZCuMSxUabFSOdj",
		"3dd0gAhsv5cyaSt41AWZ1FwLILgWdACZlMqzwPsoqvELY2oCvxd4EUVLXafFcKZt",
		"zhjc0yUxAgMBAAECggEABaeMmtinOb/Ifw22ulgJsTrtaqmXoFwXydSwgPvzPMhV",
		"rB0JPLyGA/qYYkI3QZTKVz3O6w4Sl6YY+tzR21SLxlIDz/KLvThrnRyFDZZHsbFs",
		"S9w9seFEhju5+O+0bJ4OBknEtsIspPNvKJStnGaHO1Z4IZ9+2B4HuRECuTXmSD10",
		"LYClGXK1IuMaTKqcVYH2KpKifbbqrKFmVOgRkqZoQJI5nGcVqbWMwIqgoG8kPo3p",
		"rdUb7NjWYGeBtdtMSprjRNkHdNNiiDz1/x3ZCxzSpnmz2zxF9adToR/Re4UpInOU",
		"CweVSCGBoDf0qymNofQ7SD6NJ1F163ZzpwB5rZuIiQKBgQDEkie02uYrqIU77zSM",
		"XLLotvGMFeM4WxbRClN8QFKxG+nb5bE5p68aok94wmlkB9kkznRCoEpI2Hrdn3zp",
		"u14r7tgu9t+j6bP/Q+SM7F8VBHSNn6n0Y+pzN6tHOu8sAKtxLyAFplCBVjeXF48M",
		"GJDkDkarxfzrIANcKBoC8O1yOQKBgQDBgCpct/RHfyOByMa+S0kQQQpiPubQsEKf",
		"LJ9/MVCDDmwDHRzgEyOOoWkdtgExiRaq7pGKQRim+OtnS2fldXczndaSYbcq3MND",
		"fkdOxQ9b/mvFhAEuPIPtjzz4S6tG0QE7RwgujvtCSG2kBYm9+S4WNtwmI9gcH4tt",
		"3i08L3BquQKBgGt2S2a/1N1BP7VITD3/338BpIOk45dHlO2q64Ed2Rch33Nr2rte",
		"RIgW+8NU5TDeaYOJql1SK8ovLtxB+JP+7rit1lm2dQSzGsgOYb/46PIggWd7Rfpp",
		"NR7P7D8ApQg1RYSW8raj+Zb7f2CGbJl8RJmohFIb5uzTj4KuGapJ9EVhAoGAE91c",
		"e/hGk7BxrLk37gE8lvaWYk+i0nnF3SFvnlcptMqePBOZC0frtpDLgclVhghU02d6",
		"eX8FUN7tC8Wp/Nx6SEpD5PMzIqtXQG6OU3/Xe9I6riRHGsALqy+xSqw6ASMjxTod",
		"lOoI0V0uJFCNO3uBR7aKE0BKx1hVsAnHCw6zs8ECgYEAv6OnzQFC8sEBX2F1mUyQ",
		"LR6B8Th0T/h1ZqmITcHUaGheDSctcODHes1mvHg5Uic5SBnwSEQ94WGJQbkn6RJQ",
		"rpVdj5voiowQX3AelAKGsFUAwFj411bUx/SGz1Dye8uQX4HAdDJaBUS5RzsSGNKp",
		"8mkjGWimgwo2SQK/5e8vopE=",
		"-----END PRIVATE KEY-----"
	].join("\n");
}

#if (cpp || hl || neko || java || jvm || nodejs)
private typedef DatedCase = {
	/** The certificate, as a failure names it. **/
	var what:String;

	var certificate:Certificate;
	var key:Key;

	/** What the other end trusts. **/
	var authority:Certificate;

	/** The certificate and key as text, for a server that reads them from files. **/
	var certificatePem:String;

	var keyPem:String;

	/** Whether it is valid today, and so has to be let in. **/
	var inDate:Bool;
}

private typedef DialOutcome = {
	var connected:Bool;
	var failure:Null<String>;
}

private typedef TlsServer = {
	var port:Int;
	var accepted:Void->Int;
	var failures:Void->Float;
	var close:Void->Void;
}
#end
#end
