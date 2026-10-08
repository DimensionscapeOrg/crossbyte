package crossbyte.net;

#if cpp
import crossbyte._internal.http.NativeTlsPeer;
import crossbyte._internal.socket.AlpnSocket;
import crossbyte._internal.socket.NativeAlpn;
import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ProgressEvent;
import crossbyte.events.ServerSocketConnectEvent;
import utest.Assert;

/**
	Which TLS version native connections run, and the parts of TLS 1.3 the
	rest of the suite does not reach on its own.

	hxcpp's mbedTLS 3.6 negotiates TLS 1.3 whenever the peer offers it
	(2.28 tops out at TLS 1.2), so every native TLS case in the suite runs
	over 1.3 against itself. These pin that it does, and cover what 1.3
	changes beyond that. A returning client resumes from a 1.3 ticket,
	which is a pre-shared key rather than 1.2's sealed session. A server
	that is not mbedTLS (Node, which is OpenSSL) sends tickets after the
	handshake that an mbedTLS client has to take in its stride. And a peer
	that can only offer TLS 1.1 is still turned away.

	The version expected follows the mbedTLS the program was built with, so
	the same cases hold against 2.28. The Node cases are skipped where there
	is no node.
**/
class TlsProtocolTest extends utest.Test {
	private static inline var HELLO:String = "hello over tls";

	/** Marks the end of a node process's output among its lines. **/
	private static inline var END:String = "#end of output";

	/** TLSv1.3 where hxcpp's mbedTLS speaks it; 2.28 tops out at 1.2. **/
	private static function __newest():String {
		return NativeTlsPeer.mbedtlsVersion() >= 0x03000000 ? "TLSv1.3" : "TLSv1.2";
	}

	/** The protocol the hxcpp TLS context under a secure `Socket` runs. **/
	private static function __protocolOf(socket:Socket):Null<String> {
		var inner:Dynamic = @:privateAccess socket.__socket;
		return NativeTlsPeer.protocol(@:privateAccess (cast inner : sys.ssl.Socket).ssl);
	}

	/**
		Which end the configuration under a secure `Socket`'s TLS context says
		it is: 1 for a server, 0 for a client.
	**/
	private static function __endpointOf(socket:Socket):Int {
		var inner:Dynamic = @:privateAccess socket.__socket;
		return NativeTlsPeer.endpoint(@:privateAccess (cast inner : sys.ssl.Socket).ssl);
	}

	public function testBothEndsOfANativeConnectionRunTheNewestVersion():Void {
		var fixture = TLSTestFixture.trusted();
		if (fixture == null) {
			// No openssl to make a certificate with.
			Assert.pass();
			return;
		}

		var server = new ServerSocket(true);
		server.setCertificate(fixture.certificate, fixture.key);
		var accepted:Array<Socket> = [];
		var serverProtocol:String = null;
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) {
			var peer = e.socket;
			accepted.push(peer);
			peer.addEventListener(ProgressEvent.SOCKET_DATA, function(_) {
				serverProtocol = __protocolOf(peer);
				var text = peer.readUTFBytes(peer.bytesAvailable);
				peer.writeUTFBytes(text.toUpperCase());
				peer.flush();
			});
		});
		server.bind(0, "127.0.0.1");
		server.listen();

		var heard:String = "";
		var failure:String = null;
		var clientProtocol:String = null;
		var client = new Socket();
		client.secure = true;
		client.certAuthority = fixture.certificate;
		client.addEventListener(Event.CONNECT, function(_) {
			client.writeUTFBytes(HELLO);
			client.flush();
		});
		client.addEventListener(ProgressEvent.SOCKET_DATA, function(_) {
			heard += client.readUTFBytes(client.bytesAvailable);
		});
		client.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent) {
			if (failure == null) {
				failure = e.text;
			}
		});

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			client.connect("127.0.0.1", server.localPort);
			NetPump.until(() -> heard.length >= HELLO.length || failure != null, 15.0, function(_) {
				clientProtocol = __protocolOf(client);
			});
		});

		try client.close() catch (_:Dynamic) {}
		for (peer in accepted) {
			try peer.close() catch (_:Dynamic) {}
		}
		try server.close() catch (_:Dynamic) {}

		Assert.isNull(failure, "the connection failed: " + failure);
		Assert.equals(HELLO.toUpperCase(), heard, "the bytes did not make the round trip");
		Assert.equals(__newest(), clientProtocol, "the client's end");
		Assert.equals(__newest(), serverProtocol, "the server's end");
	}

	/**
		Node offering every version it has: the newest both speak is agreed,
		and a second and third connection resume. Over TLS 1.3 that is the
		server's ticket presented back as a pre-shared key, with a fresh key
		exchange beside it.
	**/
	public function testAReturningClientResumesOverTheNewestVersion():Void {
		var fixture = TLSTestFixture.selfSigned();
		if (fixture == null) {
			// No openssl to make a certificate with.
			Assert.pass();
			return;
		}

		var server = new ServerSocket(true);
		var accepted:Array<Socket> = [];
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) {
			var peer = e.socket;
			accepted.push(peer);
			peer.addEventListener(ProgressEvent.SOCKET_DATA, function(_) {
				peer.readUTFBytes(peer.bytesAvailable);
				peer.writeUTFBytes("pong");
				peer.flush();
			});
		});
		server.setCertificate(fixture.certificate, fixture.key);
		server.bind(0, "127.0.0.1");
		server.listen();
		var port:Int = server.localPort;

		// Three connections, each offering the session the last was given, and
		// what each agreed. One line: a line break inside a Haxe string is the
		// checkout's, CRLF on Windows.
		var script:String = "const tls=require('tls');const port=+process.argv[1];let session;const out=[];"
			+ "function go(n){if(n===0){console.log(JSON.stringify(out));return;}"
			+ "const s=tls.connect({port,host:'127.0.0.1',rejectUnauthorized:false,session});"
			+ "s.on('session',x=>{session=x;});"
			+ "s.on('secureConnect',()=>{s.write('ping');});"
			+ "s.on('data',()=>{out.push([s.getProtocol(),s.isSessionReused()]);s.end();});"
			+ "s.on('close',()=>go(n-1));"
			+ "s.on('error',e=>{console.log('error '+e.message);process.exit(1);});}go(3);";

		var node = __node(["-e", script, Std.string(port)], 30.0);

		for (peer in accepted) {
			try peer.close() catch (_:Dynamic) {}
		}
		try server.close() catch (_:Dynamic) {}

		Assert.isTrue(node.finished, "node neither finished nor failed within the deadline");
		if (!node.launched) {
			// No node on this machine: nothing to resume with.
			Assert.pass();
			return;
		}
		var newest = __newest();
		Assert.equals('[["$newest",false],["$newest",true],["$newest",true]]', node.lines.join("|"),
			"the first connection is a full handshake and the rest resume, all over " + newest);
	}

	/**
		The native client against Node's TLS server, which is OpenSSL's: the
		newest version both speak, a certificate checked against the name, and
		the two tickets OpenSSL sends after a TLS 1.3 handshake taken without
		disturbing the reads around them.
	**/
	public function testANativeClientRunsTheNewestVersionAgainstOpenSsl():Void {
		var fixture = TLSTestFixture.trusted();
		if (fixture == null) {
			// No openssl to make a certificate with.
			Assert.pass();
			return;
		}

		var script:String = "const tls=require('tls'),fs=require('fs');"
			+ "const srv=tls.createServer({key:fs.readFileSync(process.argv[1]),cert:fs.readFileSync(process.argv[2])},s=>{"
			+ "console.log('protocol '+s.getProtocol());"
			+ "s.on('data',d=>s.write(d.toString().toUpperCase()));s.on('error',()=>{});});"
			+ "srv.listen(0,'127.0.0.1',()=>console.log('port '+srv.address().port));";

		var lines = new sys.thread.Deque<String>();
		var process:sys.io.Process = null;
		try {
			process = new sys.io.Process("node", ["-e", script, fixture.keyPath, fixture.certificatePath]);
		} catch (_:Dynamic) {
			// No node on this machine.
			Assert.pass();
			return;
		}
		var stdout = process.stdout;
		sys.thread.Thread.create(() -> {
			try {
				while (true) {
					lines.add(StringTools.trim(stdout.readLine()));
				}
			} catch (_:Dynamic) {}
			lines.add(END);
		});

		// What node has said so far, and the first line starting with `prefix`
		// within `timeout`; null once node has ended without saying it.
		var seen:Array<String> = [];
		var ended:Bool = false;
		function next(prefix:String, timeout:Float):Null<String> {
			var deadline:Float = haxe.Timer.stamp() + timeout;
			while (true) {
				for (line in seen) {
					if (StringTools.startsWith(line, prefix)) {
						return line.substr(prefix.length);
					}
				}
				if (ended || haxe.Timer.stamp() >= deadline) {
					return null;
				}
				var line:Null<String> = lines.pop(false);
				if (line == null) {
					crossbyte.sys.System.sleep(0.005);
				} else if (line == END) {
					ended = true;
				} else {
					seen.push(line);
				}
			}
		}

		var portText:Null<String> = next("port ", 15.0);
		if (portText == null) {
			try process.kill() catch (_:Dynamic) {}
			var code:Null<Int> = try process.exitCode() catch (_:Dynamic) null;
			try process.close() catch (_:Dynamic) {}
			// On POSIX a missing program still starts a process, which exits
			// 127 without a word; that is no node, as a failed start is on
			// Windows. A node that ran and printed no port failed.
			Assert.isTrue(code == 127 && seen.length == 0, "node printed no port (exit " + code + "): " + seen.join(" / "));
			return;
		}

		var heard:String = "";
		var failure:String = null;
		var clientProtocol:String = null;
		var client = new Socket();
		client.secure = true;
		client.certAuthority = fixture.certificate;
		client.addEventListener(Event.CONNECT, function(_) {
			client.writeUTFBytes(HELLO);
			client.flush();
		});
		client.addEventListener(ProgressEvent.SOCKET_DATA, function(_) {
			heard += client.readUTFBytes(client.bytesAvailable);
		});
		client.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent) {
			if (failure == null) {
				failure = e.text;
			}
		});
		client.connect("127.0.0.1", Std.parseInt(portText));

		// A second message after the first answer: the tickets arrive between
		// the handshake and the first reply, and a client that mishandled them
		// would show it here or on the read before.
		var second:Bool = false;
		NetPump.until(() -> {
			if (!second && heard.length >= HELLO.length) {
				second = true;
				client.writeUTFBytes(HELLO);
				client.flush();
			}
			return heard.length >= HELLO.length * 2 || failure != null;
		}, 15.0, function(_) {
			clientProtocol = __protocolOf(client);
		});
		var nodeProtocol:Null<String> = next("protocol ", 5.0);

		try client.close() catch (_:Dynamic) {}
		try process.kill() catch (_:Dynamic) {}
		try process.close() catch (_:Dynamic) {}

		Assert.isNull(failure, "the connection failed: " + failure);
		Assert.equals(HELLO.toUpperCase() + HELLO.toUpperCase(), heard, "both messages made the round trip");
		Assert.equals(__newest(), clientProtocol, "the native client's end");
		Assert.equals(__newest(), nodeProtocol, "Node's end");
	}

	/**
		A client that can offer nothing newer than TLS 1.1 is refused by the
		server, rather than by its own side: Node is told it may use the old
		versions at all, so the alert it reports is the server's.
	**/
	public function testAClientOfferingOnlyTls11IsRefused():Void {
		var fixture = TLSTestFixture.selfSigned();
		if (fixture == null) {
			Assert.warn("no openssl to make a certificate with; not run");
			return;
		}

		var server = new ServerSocket(true);
		var accepted:Array<Socket> = [];
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) {
			accepted.push(e.socket);
		});
		server.setCertificate(fixture.certificate, fixture.key);
		server.bind(0, "127.0.0.1");
		server.listen();
		var port:Int = server.localPort;

		var script:String = "const tls=require('tls');"
			+ "const s=tls.connect({port:+process.argv[1],host:'127.0.0.1',rejectUnauthorized:false,"
			+ "minVersion:'TLSv1',maxVersion:'TLSv1.1',ciphers:'DEFAULT@SECLEVEL=0'});"
			+ "s.on('secureConnect',()=>{console.log('connected '+s.getProtocol());process.exit(0);});"
			+ "s.on('error',e=>{console.log('error '+e.code);process.exit(0);});";

		var node = __node(["-e", script, Std.string(port)], 30.0);

		for (peer in accepted) {
			try peer.close() catch (_:Dynamic) {}
		}
		try server.close() catch (_:Dynamic) {}

		Assert.isTrue(node.finished, "node neither finished nor failed within the deadline");
		if (!node.launched) {
			// No node on this machine.
			Assert.pass();
			return;
		}
		Assert.equals(0, accepted.length, "a TLS 1.1 client was accepted");
		Assert.equals("error ERR_SSL_TLSV1_ALERT_PROTOCOL_VERSION", node.lines.join("|"),
			"the client should hear the server's protocol_version alert");
	}

	/**
		A connection a TLS server accepted carries on after the server stops
		accepting, on a configuration that is still its own.

		hxcpp gives every connection a listener accepts the listener's mbedTLS
		configuration, which mbedTLS reads on each record, so closing the
		listener must not free it, or every connection the server had accepted
		would read freed memory. `stopAccepting()` closes the listener so a
		successor can bind while the connections finish, as a graceful
		shutdown does. 3.6 keeps the configuration's flags first, where the
		allocator writes its own bookkeeping, and on Linux a connection would
		take that garbage for a renegotiation request and crash in the
		handshake it began. The fork keeps a configuration until the last
		connection on it has gone.
	**/
	public function testAnAcceptedConnectionOutlivesItsListener():Void {
		var fixture = TLSTestFixture.trusted();
		if (fixture == null) {
			// No openssl to make a certificate with.
			Assert.pass();
			return;
		}

		var server = new ServerSocket(true);
		server.setCertificate(fixture.certificate, fixture.key);
		var accepted:Array<Socket> = [];
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) {
			var peer = e.socket;
			accepted.push(peer);
			peer.addEventListener(ProgressEvent.SOCKET_DATA, function(_) {
				var text = peer.readUTFBytes(peer.bytesAvailable);
				peer.writeUTFBytes(text.toUpperCase());
				peer.flush();
			});
		});
		server.bind(0, "127.0.0.1");
		server.listen();

		var heard:String = "";
		var failure:String = null;
		var client = new Socket();
		client.secure = true;
		client.certAuthority = fixture.certificate;
		client.addEventListener(Event.CONNECT, function(_) {
			client.writeUTFBytes(HELLO);
			client.flush();
		});
		client.addEventListener(ProgressEvent.SOCKET_DATA, function(_) {
			heard += client.readUTFBytes(client.bytesAvailable);
		});
		client.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent) {
			if (failure == null) {
				failure = e.text;
			}
		});

		var before:Int = -2;
		var after:Int = -2;
		NetPump.until(() -> server.localPort != 0, 5.0, _ -> {});
		client.connect("127.0.0.1", server.localPort);
		NetPump.until(() -> heard.length >= HELLO.length || failure != null, 15.0, _ -> {});
		if (accepted.length == 1) {
			before = __endpointOf(accepted[0]);
			server.stopAccepting();
			after = __endpointOf(accepted[0]);
		}
		// Only over a configuration still there. Over a freed one mbedTLS
		// reads whatever the memory holds by then, and the run would end in a
		// crash, not in the assertion.
		if (after == 1) {
			client.writeUTFBytes(HELLO);
			client.flush();
			NetPump.until(() -> heard.length >= HELLO.length * 2 || failure != null, 15.0, _ -> {});
		}

		try client.close() catch (_:Dynamic) {}
		for (peer in accepted) {
			try peer.close() catch (_:Dynamic) {}
		}
		try server.close() catch (_:Dynamic) {}

		Assert.isNull(failure, "the connection failed: " + failure);
		Assert.equals(1, accepted.length, "the server did not accept the one connection");
		Assert.equals(1, before, "the accepted connection's configuration is not a server's");
		Assert.equals(1, after, "the accepted connection's configuration went with its listener");
		if (after == 1) {
			Assert.equals(HELLO.toUpperCase() + HELLO.toUpperCase(), heard, "the connection did not carry on after the listener closed");
		}
	}

	/**
		An accepted connection still names the protocol it agreed after its
		listener has closed.

		A connection points at the name its handshake agreed on, inside the
		listener's ALPN list, and keeps no copy; the list is CrossByte's, and
		must not be freed when the listener closes, under connections that
		(now the configuration outlives the listener) carry on. Freed, it
		would have a connection asked after that read its protocol from freed
		memory, and lists made next take the memory over: these of the same
		sizes, on Linux, every time.
	**/
	public function testAnAcceptedConnectionKeepsItsProtocolAfterItsListenerCloses():Void {
		var fixture = TLSTestFixture.selfSigned();
		if (fixture == null) {
			// No openssl to make a certificate with.
			Assert.pass();
			return;
		}

		// AlpnSocket, which ServerSocket listens with, driven directly: one
		// connection, accepted and handshaken in step with the client thread.
		var server = new AlpnSocket();
		server.verifyCert = false;
		server.setCertificate(fixture.certificate.__native, fixture.key.__native);
		server.setALPN(["h2", "http/1.1"]);
		server.bind(new sys.net.Host("127.0.0.1"), 0);
		server.listen(1);
		var port:Int = server.host().port;

		var client = sys.thread.Thread.create(() -> {
			try {
				var socket = new AlpnSocket();
				socket.verifyCert = false;
				socket.setALPN(["h2"]);
				socket.connect(new sys.net.Host("127.0.0.1"), port);
				sys.thread.Thread.readMessage(true);
				socket.close();
			} catch (_:Dynamic) {}
		});

		var accepted = server.accept();
		accepted.handshake();
		var agreed:Null<String> = AlpnSocket.negotiated(accepted);

		server.close();
		// Allocations the size of the listener's list and its names.
		var others:Array<Dynamic> = [];
		for (_ in 0...16) {
			var conf:Dynamic = cpp.NativeSsl.conf_new(false);
			NativeAlpn.set(conf, ["xy", "abcdefgh"]);
			others.push(conf);
		}
		var later:Null<String> = AlpnSocket.negotiated(accepted);

		client.sendMessage("done");
		accepted.close();
		for (conf in others) {
			NativeAlpn.release(conf);
			cpp.NativeSsl.conf_close(conf);
		}

		Assert.equals("h2", agreed, "the handshake did not agree on h2");
		Assert.equals("h2", later, "the connection's protocol went with its listener");
	}

	/**
		Runs node to completion while the runtime is pumped, so the servers in
		this process answer it. `launched` is false when there is no node.
	**/
	private static function __node(args:Array<String>, timeout:Float):{finished:Bool, launched:Bool, lines:Array<String>} {
		var runtime = CrossByte.current();
		var result = {finished: false, launched: false, lines: ([] : Array<String>)};
		var handoff = new sys.thread.Lock();
		sys.thread.Thread.create(() -> {
			try {
				var node = new sys.io.Process("node", args);
				result.launched = true;
				var text = StringTools.trim(node.stdout.readAll().toString());
				// On POSIX a missing program still starts a process: the fork
				// succeeds and the child exits 127 when exec finds nothing.
				if (node.exitCode() == 127 && text == "") {
					result.launched = false;
				}
				node.close();
				result.lines = text == "" ? [] : ~/\r?\n/g.split(text);
			} catch (e:Dynamic) {
				result.lines = ["could not run node: " + Std.string(e)];
			}
			handoff.release();
		});

		var deadline = haxe.Timer.stamp() + timeout;
		var last = haxe.Timer.stamp();
		while (haxe.Timer.stamp() < deadline && !result.finished) {
			var now = haxe.Timer.stamp();
			runtime.pump(now - last, 0);
			last = now;
			result.finished = handoff.wait(0.002);
		}
		return result;
	}
}
#end
