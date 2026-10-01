package crossbyte.net;

/**
	A TLS client a test points at a server, to learn what the server agreed
	to: whether the handshake succeeded, which ALPN protocol it chose, and,
	asked to upgrade, the status line it answered a WebSocket upgrade with.

	CrossByte's own `WebSocket` client cannot do what these tests need of a
	peer. It names the host it dialled as SNI, offers no ALPN, and presents
	no certificate of its own, so a server's SNI entries, its ALPN list and
	its demand for a client certificate are each out of its reach.

	Natively the client is a blocking `FlexSocket` on a thread of its own,
	while the runtime the server runs on is pumped; on Node it is Node's own
	`tls.connect`. Every blocking call is bounded, so a server that never
	answers cannot strand the thread.
**/
class TlsProbe {
	private static inline var UPGRADE:String = "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
		+ "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n";

	/**
		Connects to `port` on 127.0.0.1 as `options` say, and calls `then` with
		what happened.
	**/
	public static function run(port:Int, options:TlsProbeOptions, then:TlsProbeOutcome->Void):Void {
		var outcome:TlsProbeOutcome = {error: null, alpn: null, status: null};

		#if nodejs
		var settings:Dynamic = {port: port, host: "127.0.0.1", rejectUnauthorized: options.trust != null};
		if (options.trust != null) {
			settings.ca = [@:privateAccess options.trust.__pem];
		}
		if (options.serverName != null) {
			settings.servername = options.serverName;
		}
		if (options.alpn != null) {
			settings.ALPNProtocols = options.alpn;
		}
		if (options.present != null) {
			settings.cert = @:privateAccess options.present.certificate.__pem;
			settings.key = @:privateAccess options.present.key.__pem;
		}

		var finished:Bool = false;
		var head:String = "";
		var socket:Dynamic = null;
		socket = js.node.Tls.connect(settings, function():Void {
			var negotiated:Dynamic = socket.alpnProtocol;
			outcome.alpn = Std.isOfType(negotiated, String) ? negotiated : null;
			if (options.upgrade == true) {
				socket.write(UPGRADE);
			} else {
				finished = true;
				socket.destroy();
			}
		});
		socket.on("data", function(chunk:Dynamic):Void {
			head += Std.string(chunk);
			var end:Int = head.indexOf("\r\n");
			if (end >= 0 && outcome.status == null) {
				outcome.status = head.substr(0, end);
				finished = true;
				socket.destroy();
			}
		});
		socket.on("error", function(e:Dynamic):Void {
			if (outcome.error == null) {
				outcome.error = Std.string(e.message);
			}
			finished = true;
		});
		socket.on("close", function(_):Void {
			finished = true;
		});

		NetPump.until(() -> finished, 20.0, function(_) then(outcome));
		#elseif (cpp || java || jvm || hl || neko)
		// Released by the client thread once it has written `outcome`, so what
		// it wrote is published to this thread rather than raced for.
		var handoff = new sys.thread.Lock();

		sys.thread.Thread.create(() -> {
			var client = new crossbyte._internal.socket.FlexSocket(true);
			try {
				client.setTimeout(5);
				client.verifyCert = options.trust != null;
				if (options.trust != null) {
					client.setCA(@:privateAccess options.trust.__native);
				}
				if (options.serverName != null) {
					client.setHostname(options.serverName);
				}
				if (options.alpn != null) {
					client.setALPN(options.alpn);
				}
				if (options.present != null) {
					client.setCertificate(@:privateAccess options.present.certificate.__native, @:privateAccess options.present.key.__native);
				}
				client.connect("127.0.0.1", port);
				outcome.alpn = client.getALPN();

				if (options.upgrade == true) {
					client.output.writeString(UPGRADE);
					client.output.flush();
					outcome.status = client.input.readLine();
				}
			} catch (e:Dynamic) {
				outcome.error = Std.string(e);
			}

			try {
				client.close();
			} catch (_:Dynamic) {}
			handoff.release();
		});

		var finished:Bool = false;
		NetPump.until(() -> finished || (finished = handoff.wait(0.002)), 20.0, function(_) {
			if (!finished && outcome.error == null) {
				outcome.error = "the probe neither finished nor failed";
			}
			then(outcome);
		});
		#else
		outcome.error = "no TLS client on this target";
		then(outcome);
		#end
	}
}

typedef TlsProbeOptions = {
	/** The SNI name sent, and the name the certificate is checked against. **/
	@:optional var serverName:String;

	/** The authority to verify the server against; `null` verifies nothing. **/
	@:optional var trust:Certificate;

	/** ALPN protocols to offer. **/
	@:optional var alpn:Array<String>;

	/** A certificate to present when the server asks for one. **/
	@:optional var present:{certificate:Certificate, key:Key};

	/** Whether to send a WebSocket upgrade once connected. **/
	@:optional var upgrade:Bool;
}

typedef TlsProbeOutcome = {
	/** Why the connection failed, or `null`. **/
	var error:Null<String>;

	/** The ALPN protocol agreed, or `null`. **/
	var alpn:Null<String>;

	/** The first line of the answer to the upgrade, or `null`. **/
	var status:Null<String>;
}
