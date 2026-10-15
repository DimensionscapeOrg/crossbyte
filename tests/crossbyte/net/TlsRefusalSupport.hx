package crossbyte.net;

#if (cpp || hl || neko || java || jvm || nodejs)
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ProgressEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.http.HTTPVersion;
import crossbyte.url.URLLoader;
import crossbyte.url.URLRequest;
import utest.Assert;

/**
	Runs each of CrossByte's TLS clients against a server presenting a given
	certificate, and holds what it made of it to what it should have: let in,
	or refused over the certificate with the server never reached. And a
	server requiring a client certificate against a client presenting one.

	The clients are the ones a program dials with: a secure `Socket`, a
	`wss://` `WebSocket`, a `tls://` or `wss://` `NetConnection`, and an
	`https` `URLLoader`, over HTTP/1.1, over HTTP/2 where TLS can negotiate
	it, and with the server's key pinned where a pin can be checked. Not
	`TlsProbe`, which dials through what lies under them.

	Every case list a test runs here should hold one that is let in beside
	the ones refused: a client that cannot connect at all refuses too.
**/
class TlsRefusalSupport {
	/** The clients this target has, each as a failure names it. **/
	public static function clients():Array<TlsClient> {
		var clients:Array<TlsClient> = [SocketClient];
		#if !(hl || neko)
		clients.push(WebSocketClient);
		#end
		return clients.concat(netConnections()).concat(loaders());
	}

	/**
		`tls://` on every target, and `wss://` but on neko and HashLink, where
		a WebSocket client cannot connect: its handshake key needs secure
		random bytes, which neither has.
	**/
	public static function netConnections():Array<TlsClient> {
		return #if (hl || neko) [NetConnectionClient("tls")] #else [NetConnectionClient("tls"), NetConnectionClient("wss")] #end;
	}

	/**
		An `https` `URLLoader` over HTTP/1.1; pinning the server's key,
		natively, on the jvm and on Node (neko and HashLink refuse a pinned
		request whatever the server presents, and on Node a pinned request
		makes its own connection); and over HTTP/2 where TLS can negotiate it.
	**/
	public static function loaders():Array<TlsClient> {
		var loaders:Array<TlsClient> = [LoaderClient(HTTPVersion.HTTP_1_1, false)];
		#if (cpp || java || jvm || nodejs)
		loaders.push(LoaderClient(HTTPVersion.HTTP_1_1, true));
		#end
		#if !nodejs
		if (crossbyte._internal.socket.FlexSocket.alpnSupported) {
			loaders.push(LoaderClient(HTTPVersion.HTTP_2, false));
		}
		#end
		return loaders;
	}

	/** Each of `cases` through each of `clients`, in turn; then `done`. **/
	public static function throughEach(clients:Array<TlsClient>, cases:Array<TlsCase>, done:Void->Void):Void {
		function next(index:Int):Void {
			if (index >= clients.length) {
				__clearPools();
				done();
				return;
			}
			through(clients[index], cases, () -> next(index + 1));
		}
		next(0);
	}

	/** How `client` is named in a failure. **/
	public static function nameOf(client:TlsClient):String {
		return switch (client) {
			case SocketClient: "a Socket";
			case WebSocketClient: "a WebSocket";
			case NetConnectionClient(scheme): 'a $scheme:// NetConnection';
			case LoaderClient(version, pinned): (pinned ? "a pinned " : "an ") + (version == HTTPVersion.HTTP_2 ? "HTTP/2" : "https") + " URLLoader";
		}
	}

	/** Each of `cases` through `client`, in turn; then `done`. **/
	public static function through(client:TlsClient, cases:Array<TlsCase>, done:Void->Void):Void {
		function next(index:Int):Void {
			if (index >= cases.length) {
				done();
				return;
			}
			dial(client, cases[index], () -> next(index + 1));
		}
		next(0);
	}

	/**
		A server presenting `tried`'s certificate, dialled by `client`
		trusting `tried.authority`, and the outcome judged; then `then`.
	**/
	public static function dial(client:TlsClient, tried:TlsCase, then:Void->Void):Void {
		var host:String = tried.host != null ? tried.host : "127.0.0.1";
		var name:String = nameOf(client);
		switch (client) {
			case SocketClient:
				serveTls(tried.certificate, tried.key, null, function(server) {
					dialSocket(host, server.port, tried.authority, null, function(outcome) {
						server.close();
						judge(name, tried, outcome, server.accepted());
						then();
					});
				});
			case WebSocketClient:
				__dialWebSocket(name, host, tried, then);
			case NetConnectionClient(scheme):
				__dialNetConnection(name, scheme, host, tried, then);
			case LoaderClient(version, pinned):
				__serveHttps(tried, version, function(port, served, close) {
					var outcome:DialOutcome = {connected: false, failure: null};
					var loader = new URLLoader();
					loader.addEventListener(Event.COMPLETE, _ -> outcome.connected = true);
					loader.addEventListener(IOErrorEvent.IO_ERROR, (e:IOErrorEvent) -> outcome.failure = e.text);
					var request = new URLRequest('https://$host:$port/');
					request.httpVersion = version;
					request.readTimeout = 5.0;
					request.certAuthority = tried.authority;
					if (pinned) {
						// The key presented, so the pin passes and only the
						// certificate's own check can refuse it.
						request.pinnedPublicKeys = [crossbyte._internal.http.PublicKeyPins.pinOf(tried.certificate.der)];
					}
					loader.load(request);
					NetPump.until(() -> outcome.connected || outcome.failure != null, 20.0, function(_) {
						var answered:Int = served();
						close();
						judge(name, tried, outcome, answered);
						then();
					});
				});
		}
	}

	/**
		A server presenting `server`, which `serverAuthority` issued and the
		client trusts, requiring a client certificate `clientAuthority`
		issued, and a secure `Socket` presenting `tried`'s certificate: let in
		or not, as `tried.accepted` says. The verdict is the server's: under
		TLS 1.3 a client's certificate travels after the server's Finished, so
		the client can believe itself connected a moment before it is turned
		away.
	**/
	public static function presentToServer(server:{certificate:Certificate, key:Key}, serverAuthority:Certificate, clientAuthority:Null<Certificate>,
			tried:TlsCase, then:Void->Void):Void {
		serveTls(server.certificate, server.key, clientAuthority, function(listener) {
			dialSocket("127.0.0.1", listener.port, serverAuthority, {certificate: tried.certificate, key: tried.key}, function(outcome) {
				NetPump.until(() -> listener.accepted() > 0 || listener.failures() >= 1, 10.0, function(_) {
					var accepted:Int = listener.accepted();
					listener.close();
					if (tried.accepted) {
						Assert.equals(1, accepted, 'a client presenting ${tried.what} was not let in: ' + outcome.failure);
					} else {
						Assert.equals(0, accepted, 'a client presenting ${tried.what} was let in');
					}
					then();
				});
			});
		});
	}

	/** `presentToServer` for each of `cases` in turn; then `done`. **/
	public static function presentEach(server:{certificate:Certificate, key:Key}, serverAuthority:Certificate, clientAuthority:Null<Certificate>,
			cases:Array<TlsCase>, done:Void->Void):Void {
		function next(index:Int):Void {
			if (index >= cases.length) {
				done();
				return;
			}
			var tried:TlsCase = cases[index];
			// A case may name the authority the server requires, as a pinned
			// self-signed client certificate does.
			var authority:Null<Certificate> = clientAuthority != null ? clientAuthority : tried.authority;
			presentToServer(server, serverAuthority, authority, tried, () -> next(index + 1));
		}
		next(0);
	}

	/**
		A case: a server presenting `certificate`, to a client trusting
		`authority` (the system's authorities when null) and dialling `host`.
	**/
	public static function tlsCase(what:String, certificatePem:String, keyPem:String, authority:Null<Certificate>, accepted:Bool,
			?host:String):TlsCase {
		return {
			what: what,
			certificate: Certificate.fromPem(certificatePem),
			key: Key.fromPem(keyPem),
			certificatePem: certificatePem,
			keyPem: keyPem,
			authority: authority,
			host: host,
			accepted: accepted
		};
	}

	/** A case from a fixture `TLSTestFixture` or `TLSChainFixture` made. **/
	public static function fixtureCase(what:String, certificatePath:String, keyPath:String, authority:Null<Certificate>, accepted:Bool,
			?host:String):TlsCase {
		return tlsCase(what, sys.io.File.getContent(certificatePath), sys.io.File.getContent(keyPath), authority, accepted, host);
	}

	/**
		What a client made of `tried`: let in, when it should be, and
		otherwise refused over the certificate, with the server (which
		`accepted` connections) never reached.
	**/
	public static function judge(client:String, tried:TlsCase, outcome:DialOutcome, accepted:Int):Void {
		if (tried.accepted) {
			Assert.isTrue(outcome.connected, '$client refused ${tried.what}: ' + outcome.failure);
			Assert.equals(1, accepted, 'the server never saw $client given ${tried.what}');
			return;
		}
		Assert.isFalse(outcome.connected, '$client accepted ${tried.what}');
		Assert.isTrue(isCertificateRefusal(outcome.failure), '$client failed on ${tried.what}, but not over the certificate: ' + outcome.failure);
		Assert.equals(0, accepted, 'the server was reached by $client, which should have refused ${tried.what}');
	}

	/**
		Whether `failure` is a TLS layer refusing a certificate, in any of the
		ways the targets word it: mbedTLS reports an X509 verification
		failure; the JDK a PKIX path, a certificate's NotAfter or NotBefore,
		or no subject alternative name to match; Node a certificate expired,
		not yet valid, self-signed or unverified, or a name missing from its
		altnames.
	**/
	public static function isCertificateRefusal(failure:Null<String>):Bool {
		if (failure == null) {
			return false;
		}
		for (sign in ["X509", "ertificate", "PKIX", "NotAfter", "NotBefore", "expired", "not yet valid", "subject alternative", "altnames"]) {
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
	public static function settle(outcome:DialOutcome, reached:Void->Bool, then:Void->Void):Void {
		NetPump.until(() -> (outcome.connected && reached()) || outcome.failure != null, 10.0, _ -> NetPump.wait(0.2, then));
	}

	/**
		A secure `Socket` to `host` on `port`, trusting `trust` and presenting
		`present` if given, and what it made of the server.
	**/
	public static function dialSocket(host:String, port:Int, trust:Null<Certificate>, present:Null<{certificate:Certificate, key:Key}>,
			then:DialOutcome->Void):Void {
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
		client.connect(host, port);
		settle(outcome, () -> true, function() {
			try client.close() catch (_:Dynamic) {}
			then(outcome);
		});
	}

	/**
		A TLS `ServerSocket` presenting `certificate`, requiring a client
		certificate `clientAuthority` issued when given one, and answering an
		HTTP request with a 200 and closing.
	**/
	public static function serveTls(certificate:Certificate, key:Key, clientAuthority:Null<Certificate>, then:TlsServer->Void):Void {
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
					peer.writeUtfBytes("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok");
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

	private static function __dialWebSocket(name:String, host:String, tried:TlsCase, then:Void->Void):Void {
		var server = new ServerWebSocket(true);
		server.cert = {certificate: tried.certificate, key: tried.key};
		server.handshakeTimeout = 5;
		var sessions:Array<WebSocket> = [];
		server.addEventListener(ServerSocketConnectEvent.CONNECT, (e:ServerSocketConnectEvent) -> sessions.push(cast e.socket));
		server.bind(0, "127.0.0.1");
		server.listen();
		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var client = new WebSocket();
			client.secure = true;
			client.certAuthority = tried.authority;
			var outcome:DialOutcome = {connected: false, failure: null};
			client.addEventListener(Event.CONNECT, _ -> outcome.connected = true);
			client.addEventListener(IOErrorEvent.IO_ERROR, (e:IOErrorEvent) -> if (outcome.failure == null) outcome.failure = e.text);
			client.addEventListener(Event.CLOSE, _ -> if (outcome.failure == null) outcome.failure = "closed");
			client.connect(host, server.localPort);
			settle(outcome, () -> sessions.length > 0, function() {
				try client.close() catch (_:Dynamic) {}
				for (session in sessions) {
					try session.close() catch (_:Dynamic) {}
				}
				try server.close() catch (_:Dynamic) {}
				judge(name, tried, outcome, sessions.length);
				then();
			});
		});
	}

	private static function __dialNetConnection(name:String, scheme:String, host:String, tried:TlsCase, then:Void->Void):Void {
		var accepted:Int = 0;
		var server = new NetHost('$scheme://127.0.0.1:0', _ -> accepted++, null, null, true, {certificate: tried.certificate, key: tried.key});
		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var outcome:DialOutcome = {connected: false, failure: null};
			var tls:Null<TLSOptions> = tried.authority != null ? {certAuthority: tried.authority} : null;
			var connection = new NetConnection('$scheme://$host:${server.localPort}' + (scheme == "wss" ? "/" : ""), null,
				() -> outcome.connected = true, reason -> if (outcome.failure == null) outcome.failure = "closed: " + reason,
				reason -> if (outcome.failure == null) outcome.failure = Std.string(reason), false, tls);
			settle(outcome, () -> accepted > 0, function() {
				try connection.close() catch (_:Dynamic) {}
				try server.close() catch (_:Dynamic) {}
				judge(name, tried, outcome, accepted);
				then();
			});
		});
	}

	/**
		An `https` server presenting `tried`'s certificate, answering 200 to
		`version`: HTTP/1.1 from `serveTls`, and HTTP/2 from an `HTTPServer`,
		which takes its certificate and key from files, written for it.
		`served` counts what reached it.
	**/
	private static function __serveHttps(tried:TlsCase, version:HTTPVersion, then:(port:Int, served:Void->Int, close:Void->Void) -> Void):Void {
		#if !nodejs
		if (version == HTTPVersion.HTTP_2) {
			var directory:String = haxe.io.Path.join([__tempDirectory(), "crossbyte-refusal-" + Std.random(0x3FFFFFFF)]);
			sys.FileSystem.createDirectory(directory);
			var certificatePath:String = haxe.io.Path.join([directory, "cert.pem"]);
			var keyPath:String = haxe.io.Path.join([directory, "key.pem"]);
			sys.io.File.saveContent(certificatePath, tried.certificatePem);
			sys.io.File.saveContent(keyPath, tried.keyPem);
			var served:Int = 0;
			var router = new crossbyte.http.Router();
			router.get("/", ctx -> {
				served++;
				ctx.handler.respond(200, "text/plain", "ok");
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
		serveTls(tried.certificate, tried.key, null, server -> then(server.port, server.accepted, server.close));
	}

	/** Connections kept by the loaders, to servers closed since. **/
	private static function __clearPools():Void {
		#if !nodejs
		crossbyte._internal.http.HttpConnectionPool.clear();
		crossbyte._internal.http.h2.H2ConnectionPool.closeAll();
		#end
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
}

/** A client `TlsRefusalSupport` dials with. **/
enum TlsClient {
	SocketClient;
	WebSocketClient;
	NetConnectionClient(scheme:String);
	LoaderClient(version:HTTPVersion, pinned:Bool);
}

typedef TlsCase = {
	/** The certificate, as a failure names it. **/
	var what:String;

	/** What the server presents (or, given to a server, the client). **/
	var certificate:Certificate;

	var key:Key;

	/** The certificate and key as text, for a server that reads them from files. **/
	var certificatePem:String;

	var keyPem:String;

	/** What the client trusts; the system's authorities when null. **/
	var authority:Null<Certificate>;

	/** What the client dials; 127.0.0.1 when null. **/
	var host:Null<String>;

	/** Whether the client has to be let in. **/
	var accepted:Bool;
}

typedef DialOutcome = {
	var connected:Bool;
	var failure:Null<String>;
}

typedef TlsServer = {
	var port:Int;
	var accepted:Void->Int;
	var failures:Void->Float;
	var close:Void->Void;
}
#end
