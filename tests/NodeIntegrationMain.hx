import crossbyte._internal.php.PHPBridge;
import crossbyte._internal.php.PHPMode;
import crossbyte._internal.php.PHPRequest;
import crossbyte._internal.php.PHPResponse;
import crossbyte.core.Application;
import crossbyte.io.ByteArray;
import crossbyte.events.Event;
import crossbyte.events.HTTPStatusEvent;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.NativeProcessEvent;
import crossbyte.events.ProgressEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.http.HTTPServer;
import crossbyte.http.HTTPServerConfig;
import crossbyte.io.File;
import crossbyte.events.TickEvent;
import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.events.ReliableDatagramSocketConnectEvent;
import crossbyte.net.DatagramSocket;
import crossbyte.net.ReliableDatagramServerSocket;
import crossbyte.net.ReliableDatagramSocket;
import crossbyte.net.ServerSocket;
import crossbyte.net.ServerWebSocket;
import crossbyte.net.Socket;
import crossbyte.net.WebSocket;
import crossbyte.sys.NativeProcess;
import crossbyte.sys.NativeProcessStartupInfo;
import crossbyte.url.URLLoader;
import crossbyte.url.URLRequest;

/**
	The parts of CrossByte that only exist on Node, exercised against Node.

	`JsTestMain` deliberately holds nothing needing a socket, a subprocess or a
	runtime driving itself -- it is the portable suite, and it has to mean the
	same thing on the browser build. Everything written for Node specifically
	therefore had no home: the self-driven loop, sockets over `js.node.net`,
	`URLLoader` over Node's HTTP client, `NativeProcess` over `child_process`.

	This is the same work a utest case would do, written as a program instead.
	The things it covers are asynchronous, and one of them owns the process: a
	loop that drives itself cannot be tested from inside a harness that is
	already driving a runtime of its own.

	Exits non-zero if anything fails, so CI notices.
**/
class NodeIntegrationMain extends Application {
	// Every server in this file binds port 0 and reads back the port the OS
	// assigned. They used to be fixed, 50561 to 50565, and Windows reserves
	// ports in blocks for Hyper-V, WinNAT and WSL -- blocks that move between
	// boots, so the same unchanged test passed one day and failed the next.
	// Confirmed rather than guessed, both times: `netsh int ipv4 show
	// excludedportrange protocol=udp` listed 50474-50573 when the datagram
	// stage stopped with "still 0 after 201 tries", and `protocol=tcp` listed
	// 50501-50600 when the run died at its first server with `listen EACCES`
	// -- green on CI only because that runner's blocks fell somewhere else.
	//
	// A server written against Node reads its port from address() in the
	// listen callback. A CrossByte one reads localPort, which on Node stays 0
	// until listen() has claimed a port, so those stages wait for it first.
	private var httpPort:Int = 0;
	private var echoPort:Int = 0;
	private var wsPort:Int = 0;
	private var udpPort:Int = 0;
	private static inline var TIMEOUT_MS:Int = 30000;
	private static inline var ROUND_TRIP:String = "round-trip";
	private static inline var WS_SHORT:String = "hello-over-websocket";
	private static inline var WS_GUID:String = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

	private static var failures:Int = 0;
	private static var checks:Int = 0;

	private var ticks:Int = 0;
	private var tickDeltas:Array<Float> = [];
	private var timerFired:Bool = false;
	private var loopStarted:Float;

	private var httpServer:js.node.http.Server;
	private var echoServer:js.node.net.Server;
	private var listener:ServerSocket;
	private var accepted:Socket;
	private var phpBackend:ServerSocket;
	private var phpPeer:Socket;
	private var phpAnswered:Bool = false;
	private var silentPeer:Socket;
	private var webServer:HTTPServer;
	private var webRoot:String;
	private var wsServer:js.node.net.Server;
	private var ws:WebSocket;
	private var wsReceived:String = "";
	private var receiver:DatagramSocket;
	private var sender:DatagramSocket;
	private var stray:DatagramSocket;
	private var datagrams:Int = 0;
	private var rdServer:ReliableDatagramServerSocket;
	private var rdClient:ReliableDatagramSocket;
	private var rdAccepted:ReliableDatagramSocket;
	private var rdBurst:Array<String> = [];
	private var wsListener:ServerWebSocket;
	private var wsClient:WebSocket;
	private var wsAccepted:WebSocket;
	private var tlsServer:ServerSocket;
	private var tlsAccepted:Socket;

	public function new() {
		super();
		addEventListener(Event.INIT, onInit);
	}

	private function onInit(event:Event):Void {
		// A ceiling on the whole run. Every stage below waits on something, and
		// one that never completes would otherwise leave CI holding an idle
		// Node process instead of reporting a failure.
		//
		// Unreferenced, because an armed timer is itself a reason for Node to
		// stay alive -- with this one referenced the process sat here for the
		// full thirty seconds after passing, and the guard reported a timeout
		// on a run that had already finished.
		var guard = js.Node.setTimeout(function():Void {
			Sys.println("TIMED OUT after " + TIMEOUT_MS + "ms with " + checks + " checks done");
			Sys.exit(1);
		}, TIMEOUT_MS);
		untyped guard.unref();

		check("Event.INIT reached the application", true, "");

		// File.spaceAvailable compiled cleanly here and then threw
		// `ReferenceError: sys is not defined` when called: it shelled out
		// through sys.io.Process, which type-checks on Node because hxnodejs
		// allows the `sys` package but generates nothing for it. It reads the
		// filesystem directly now.
		var free:Float = File.applicationStorageDirectory.spaceAvailable;
		check("File.spaceAvailable answers on Node", free > 1024 * 1024, "reported " + free + " bytes free");

		// Node is where the platform conditionals hurt most, and where
		// SysSupportTest cannot reach: `#if windows` is never set here, so on
		// Windows this target answered every platform question with the branch
		// written for POSIX. PLATFORM read "undefined" and appStorageDir read
		// HOME -- the profile root when Git Bash had set it, a different place
		// than a native build uses for the same data, and the literal string
		// "undefined" when nothing had.
		check("System.PLATFORM identifies the host on Node", crossbyte.sys.System.PLATFORM != "undefined",
			"reported " + crossbyte.sys.System.PLATFORM);

		var storage:String = crossbyte.sys.System.appStorageDir;
		check("System.appStorageDir does not depend on HOME", storage != null && storage != "undefined" && storage != Sys.getEnv("HOME"),
			"reported " + storage + " with HOME=" + Sys.getEnv("HOME"));

		crossByte.tps = 60;
		loopStarted = haxe.Timer.stamp();
		crossByte.addEventListener(TickEvent.TICK, onTick);
		haxe.Timer.delay(function():Void {
			timerFired = true;
		}, 50);
	}

	// ---- 1. the self-driven loop -----------------------------------------

	private function onTick(event:TickEvent):Void {
		ticks++;
		tickDeltas.push(event.delta);

		if (ticks < 30) {
			return;
		}

		crossByte.removeEventListener(TickEvent.TICK, onTick);

		var elapsed:Float = haxe.Timer.stamp() - loopStarted;
		var mean:Float = 0;
		for (delta in tickDeltas) {
			mean += delta;
		}
		mean /= tickDeltas.length;

		check("the loop ran with nobody pumping it", ticks == 30, "got " + ticks + " ticks");
		check("haxe.Timer fired off those ticks", timerFired, "the timer never ran");
		check("uptime advanced", crossByte.uptime > 0.2, "uptime " + crossByte.uptime);
		// 30 ticks at 60/s is half a second. The bounds are wide because what
		// is under test is that a configured rate was honoured at all, not how
		// tightly Node's timers hold it.
		check("tps was honoured", elapsed > 0.3 && elapsed < 2.0, "30 ticks at tps=60 took " + elapsed + "s");
		check("tick deltas are real", mean > 0.004 && mean < 0.1, "mean delta " + mean);
		check("stamp() is not a constant", haxe.Timer.stamp() > 0, "stamp " + haxe.Timer.stamp());

		startHttpServer();
	}

	// ---- 2. URLLoader over Node's HTTP client ----------------------------

	private function startHttpServer():Void {
		httpServer = js.node.Http.createServer(function(request, response):Void {
			var body:String = "";

			request.on("data", function(chunk):Void {
				body += Std.string(chunk);
			});

			request.on("end", function():Void {
				response.writeHead(200, {"Content-Type": "text/plain"});
				response.end(request.method == "POST" ? "echo:" + body : "crossbyte-over-node");
			});
		});

		httpServer.listen(0, "127.0.0.1", function():Void {
			httpPort = httpServer.address().port;
			getRequest();
		});
	}

	private function getRequest():Void {
		var loader = new URLLoader();
		var sawProgress:Bool = false;
		var status:Int = -1;

		loader.addEventListener(HTTPStatusEvent.HTTP_STATUS, function(e:HTTPStatusEvent):Void {
			status = e.status;
		});

		loader.addEventListener(ProgressEvent.PROGRESS, function(_):Void {
			sawProgress = true;
		});

		loader.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent):Void {
			check("URLLoader GET succeeded", false, "io error: " + e.text);
			postRequest();
		});

		loader.addEventListener(Event.COMPLETE, function(_):Void {
			check("URLLoader GET returned the body", Std.string(loader.data).indexOf("crossbyte-over-node") >= 0, "got " + loader.data);
			check("URLLoader GET reported 200", status == 200, "status " + status);
			check("URLLoader GET reported progress", sawProgress, "no progress event");
			postRequest();
		});

		loader.load(new URLRequest("http://127.0.0.1:" + httpPort + "/hello"));
	}

	private function postRequest():Void {
		var loader = new URLLoader();

		loader.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent):Void {
			check("URLLoader POST succeeded", false, "io error: " + e.text);
			startEchoServer();
		});

		loader.addEventListener(Event.COMPLETE, function(_):Void {
			check("URLLoader POST sent its body", Std.string(loader.data) == "echo:payload-42", "got " + loader.data);
			httpServer.close();
			startEchoServer();
		});

		var request = new URLRequest("http://127.0.0.1:" + httpPort + "/echo");
		request.method = "POST";
		request.data = "payload-42";
		loader.load(request);
	}

	// ---- 3. crossbyte.net.Socket over js.node.net ------------------------

	private function startEchoServer():Void {
		echoServer = js.node.Net.createServer(function(connection):Void {
			connection.on("data", function(chunk):Void {
				connection.write(chunk);
			});
		});

		echoServer.listen(0, "127.0.0.1", function():Void {
			echoPort = echoServer.address().port;
			connectSocket();
		});
	}

	private function connectSocket():Void {
		var socket = new Socket();
		var connected:Bool = false;

		socket.addEventListener(Event.CONNECT, function(_):Void {
			connected = true;
			socket.writeUTFBytes(ROUND_TRIP);
			socket.flush();
		});

		socket.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent):Void {
			check("Socket connected", false, "io error: " + e.text);
			runSubprocess();
		});

		socket.addEventListener(ProgressEvent.SOCKET_DATA, function(_):Void {
			if (socket.bytesAvailable < ROUND_TRIP.length) {
				return;
			}

			var received = socket.readUTFBytes(ROUND_TRIP.length);
			check("Socket connected", connected, "no connect event");
			check("Socket round-tripped its bytes", received == ROUND_TRIP, "got " + received);
			check("Socket knows its remote end", socket.remoteAddress == "127.0.0.1", "got " + socket.remoteAddress);
			check("Socket knows its remote port", socket.remotePort == echoPort, "got " + socket.remotePort);
			check("Socket knows its local port", socket.localPort > 0, "got " + socket.localPort);
			socket.close();
			echoServer.close();
			startListener();
		});

		socket.connect("127.0.0.1", echoPort);
	}

	// ---- 4. crossbyte.net.ServerSocket over js.node.net.Server -----------

	private function startListener():Void {
		listener = new ServerSocket();

		check("ServerSocket is supported on Node", ServerSocket.isSupported, "reported unsupported");

		listener.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent):Void {
			// Held in a field on purpose: the class documents that the
			// application owns the accepted socket, and one only referenced by
			// a local would be collectable the moment this returns.
			accepted = e.socket;

			check("ServerSocket accepted a connection", accepted != null, "no socket on the event");
			check("accepted socket knows its peer", accepted.remoteAddress == "127.0.0.1", "got " + accepted.remoteAddress);

			accepted.addEventListener(ProgressEvent.SOCKET_DATA, function(_):Void {
				if (accepted.bytesAvailable < ROUND_TRIP.length) {
					return;
				}

				var request = accepted.readUTFBytes(ROUND_TRIP.length);
				check("ServerSocket read the client bytes", request == ROUND_TRIP, "got " + request);
				accepted.writeUTFBytes(request.toUpperCase());
				accepted.flush();
			});
		});

		// Port 0, so the run cannot collide with whatever else is on the
		// machine -- and so that resolving the assigned port is covered.
		listener.bind(0, "127.0.0.1");
		listener.listen();

		check("bind() marked the server bound", listener.bound, "not bound");
		check("listen() marked the server listening", listener.listening, "not listening");

		// listen() on Node claims the port asynchronously, so the assigned
		// port is not readable until it has. A tick is the runtime's own way
		// of waiting, and the loop is already running.
		waitForPort(0);
	}

	private function waitForPort(attempts:Int):Void {
		if (listener.localPort > 0) {
			check("port 0 resolved to a real port", listener.localPort > 0, "got " + listener.localPort);
			connectToListener();
			return;
		}

		if (attempts > 200) {
			check("port 0 resolved to a real port", false, "still 0 after " + attempts + " ticks");
			finishListener();
			return;
		}

		haxe.Timer.delay(function():Void {
			waitForPort(attempts + 1);
		}, 5);
	}

	private function connectToListener():Void {
		var client = new Socket();

		client.addEventListener(Event.CONNECT, function(_):Void {
			client.writeUTFBytes(ROUND_TRIP);
			client.flush();
		});

		client.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent):Void {
			check("client reached the ServerSocket", false, "io error: " + e.text);
			finishListener();
		});

		client.addEventListener(ProgressEvent.SOCKET_DATA, function(_):Void {
			if (client.bytesAvailable < ROUND_TRIP.length) {
				return;
			}

			var reply = client.readUTFBytes(ROUND_TRIP.length);
			check("ServerSocket replied through the accepted socket", reply == ROUND_TRIP.toUpperCase(), "got " + reply);
			client.close();
			finishListener();
		});

		client.connect("127.0.0.1", listener.localPort);
	}

	private function finishListener():Void {
		if (accepted != null) {
			accepted.close();
		}

		listener.close();
		check("close() stopped the server listening", !listener.listening, "still listening");
		startWebServer();
	}

	// ---- 5. crossbyte.http.HTTPServer on top of that ---------------------

	private function startWebServer():Void {
		webRoot = js.node.Path.join(js.node.Os.tmpdir(), "crossbyte-node-http-" + js.Node.process.pid);

		if (!sys.FileSystem.exists(webRoot)) {
			sys.FileSystem.createDirectory(webRoot);
		}

		sys.io.File.saveContent(js.node.Path.join(webRoot, "index.html"), "<h1>served-from-node</h1>");
		sys.io.File.saveContent(js.node.Path.join(webRoot, "data.json"), "{\"served\":true}");

		var config = new HTTPServerConfig();
		config.address = "127.0.0.1";
		config.port = 0;
		config.rootDirectory = new File(webRoot);
		config.directoryIndex = ["index.html"];

		// This refused until the bridge stopped reading synchronously: Node has
		// no blocking socket read, so PHP could not be served here at all and
		// validate() said so at startup. Stage 12 is the demonstration that it
		// now can, and this is the config-level half of it.
		var refusedPhp:String = null;

		try {
			config.phpEnabled = true;
			config.validate();
		} catch (e:Dynamic) {
			refusedPhp = Std.string(e);
		}

		config.phpEnabled = false;
		check("a PHP-enabled config is accepted on Node", refusedPhp == null, "still refused: " + refusedPhp);

		// Binds and listens in its constructor; calling bind() again here is
		// a second bind on the same socket, which a native target refuses
		// outright.
		webServer = new HTTPServer(config);

		check("HTTPServer is listening", webServer.listening, "not listening");

		// HTTPServer is a ServerSocket, so port 0 resolves the same way it does
		// in stage 4: not until Node has claimed one.
		waitForWebPort(0);
	}

	private function waitForWebPort(attempts:Int):Void {
		if (webServer.localPort > 0) {
			check("HTTPServer resolved port 0 to a real port", webServer.localPort > 0, "got " + webServer.localPort);
			requestIndex();
			return;
		}

		if (attempts > 200) {
			check("HTTPServer resolved port 0 to a real port", false, "still 0 after " + attempts + " tries");
			stopWebServer();
			return;
		}

		haxe.Timer.delay(function():Void {
			waitForWebPort(attempts + 1);
		}, 5);
	}

	private function requestIndex():Void {
		var loader = new URLLoader();
		var status:Int = -1;

		loader.addEventListener(HTTPStatusEvent.HTTP_STATUS, function(e:HTTPStatusEvent):Void {
			status = e.status;
		});

		loader.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent):Void {
			check("HTTPServer served the directory index", false, "io error: " + e.text);
			stopWebServer();
		});

		loader.addEventListener(Event.COMPLETE, function(_):Void {
			// "/" rather than "/index.html", so what is checked is that the
			// directory index was chosen, not just that a file was read.
			check("HTTPServer served the directory index", Std.string(loader.data).indexOf("served-from-node") >= 0, "got " + loader.data);
			check("HTTPServer answered 200", status == 200, "status " + status);
			requestFile();
		});

		loader.load(new URLRequest("http://127.0.0.1:" + webServer.localPort + "/"));
	}

	private function requestFile():Void {
		var loader = new URLLoader();
		var contentType:String = null;

		loader.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent):Void {
			check("HTTPServer served a named file", false, "io error: " + e.text);
			stopWebServer();
		});

		loader.addEventListener(Event.COMPLETE, function(_):Void {
			check("HTTPServer served a named file", Std.string(loader.data).indexOf("\"served\":true") >= 0, "got " + loader.data);
			stopWebServer();
		});

		loader.load(new URLRequest("http://127.0.0.1:" + webServer.localPort + "/data.json"));
	}

	private function stopWebServer():Void {
		webServer.close();
		check("HTTPServer stopped listening", !webServer.listening, "still listening");

		try {
			sys.FileSystem.deleteFile(js.node.Path.join(webRoot, "index.html"));
			sys.FileSystem.deleteFile(js.node.Path.join(webRoot, "data.json"));
			sys.FileSystem.deleteDirectory(webRoot);
		} catch (_:Dynamic) {}

		startWebSocketServer();
	}

	// ---- 6. crossbyte.net.WebSocket framing over js.node.net -------------

	private function startWebSocketServer():Void {
		// Checked here because the WebSocket depends on it -- a client masks
		// every frame with a fresh key, and the key comes from here. It threw
		// on Node until Node's own CSPRNG was wired in, which meant a
		// WebSocket could not be constructed at all.
		var first = crossbyte.crypto.SecureRandom.getSecureRandomBytes(32);
		var second = crossbyte.crypto.SecureRandom.getSecureRandomBytes(32);

		// Compared as hex, not through toString(): random bytes are not valid
		// UTF-8, and decoding them as if they were throws on js.
		var firstHex:String = (first : haxe.io.Bytes).toHex();
		var secondHex:String = (second : haxe.io.Bytes).toHex();

		check("SecureRandom returns the length asked for", first.length == 32, "got " + first.length);
		check("SecureRandom does not repeat itself", firstHex != secondHex, "two draws came back identical");

		// An RFC 6455 echo server written straight onto a Node socket rather
		// than pulled from npm, so CI needs nothing installed. It answers the
		// upgrade, unmasks what a client sends -- a client must mask, a server
		// must not -- and sends the same payload back unmasked.
		wsServer = js.node.Net.createServer(function(connection:js.node.net.Socket):Void {
			var handshaken:Bool = false;
			var buffer:js.node.Buffer = js.node.Buffer.alloc(0);

			connection.on("error", function(_):Void {});

			connection.on("data", function(chunk:js.node.Buffer):Void {
				buffer = js.node.Buffer.concat([buffer, chunk]);

				if (!handshaken) {
					var head:Int = buffer.indexOf("\r\n\r\n");

					if (head < 0) {
						return;
					}

					var request:String = buffer.slice(0, head).toString();
					buffer = buffer.slice(head + 4);

					var keyHeader = ~/sec-websocket-key:(.+)/i;
					var key:String = keyHeader.match(request) ? StringTools.trim(keyHeader.matched(1)) : "";
					// The one line of the protocol a server cannot get wrong:
					// the client refuses any accept token it did not derive
					// itself from the key it sent.
					var accept:String = haxe.crypto.Base64.encode(haxe.io.Bytes.ofHex(haxe.crypto.Sha1.encode(key + WS_GUID)));
					connection.write("HTTP/1.1 101 Switching Protocols\r\n" + "Upgrade: websocket\r\n" + "Connection: Upgrade\r\n"
						+ "Sec-WebSocket-Accept: " + accept + "\r\n\r\n");
					handshaken = true;
				}

				buffer = echoFrames(connection, buffer);
			});
		});

		wsServer.listen(0, "127.0.0.1", function():Void {
			wsPort = wsServer.address().port;
			connectWebSocket();
		});
	}

	private static function echoFrames(connection:js.node.net.Socket, buffer:js.node.Buffer):js.node.Buffer {
		while (buffer.length >= 2) {
			var opcode:Int = buffer[0] & 0x0F;
			var masked:Bool = (buffer[1] & 0x80) != 0;
			var length:Int = buffer[1] & 0x7F;
			var offset:Int = 2;

			if (length == 126) {
				length = buffer.readUInt16BE(2);
				offset = 4;
			} else if (length == 127) {
				// Not produced by anything this harness sends; a 64-bit length
				// would need a payload of 64 KB and up.
				return js.node.Buffer.alloc(0);
			}

			var needed:Int = offset + (masked ? 4 : 0) + length;

			if (buffer.length < needed) {
				return buffer;
			}

			var mask:js.node.Buffer = null;

			if (masked) {
				mask = buffer.slice(offset, offset + 4);
				offset += 4;
			}

			var payload:js.node.Buffer = js.node.Buffer.from(buffer.slice(offset, offset + length));

			if (mask != null) {
				for (i in 0...payload.length) {
					payload[i] = payload[i] ^ mask[i % 4];
				}
			}

			buffer = buffer.slice(needed);

			switch (opcode) {
				case 0x8:
					connection.end(null);
					return js.node.Buffer.alloc(0);
				case 0x9:
					connection.write(serverFrame(0x0A, payload));
				case 0x0A:
				default:
					connection.write(serverFrame(opcode, payload));
			}
		}

		return buffer;
	}

	private static function serverFrame(opcode:Int, payload:js.node.Buffer):js.node.Buffer {
		var head:js.node.Buffer;

		if (payload.length < 126) {
			head = js.node.Buffer.from([0x80 | opcode, payload.length]);
		} else {
			head = js.node.Buffer.alloc(4);
			head[0] = 0x80 | opcode;
			head[1] = 126;
			head.writeUInt16BE(payload.length, 2);
		}

		return js.node.Buffer.concat([head, payload]);
	}

	private function connectWebSocket():Void {
		ws = new WebSocket();

		ws.addEventListener(Event.CONNECT, function(_):Void {
			check("WebSocket completed the upgrade handshake", true, "");
			ws.writeUTFBytes(WS_SHORT);
			ws.flush();
		});

		ws.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent):Void {
			check("WebSocket connected", false, "io error: " + e.text);
			stopWebSocket();
		});

		ws.addEventListener(ProgressEvent.SOCKET_DATA, function(_):Void {
			wsReceived += ws.readUTFBytes(ws.bytesAvailable);

			if (wsReceived == WS_SHORT) {
				check("WebSocket echoed a short frame", true, "");
				// Past 125 bytes the length moves into the extended 16-bit
				// field, which is a different encoding path on the way out and
				// a different parse on the way in.
				wsReceived = "";
				ws.writeUTFBytes(longMessage());
				ws.flush();
			} else if (wsReceived == longMessage()) {
				check("WebSocket echoed an extended-length frame", true, "got " + wsReceived.length + " bytes");
				stopWebSocket();
			}
		});

		ws.connect("127.0.0.1", wsPort);
	}

	private static function longMessage():String {
		var buf = new StringBuf();

		for (i in 0...400) {
			buf.add(String.fromCharCode(97 + (i % 26)));
		}

		return buf.toString();
	}

	private function stopWebSocket():Void {
		ws.close();
		wsServer.close();
		startDatagrams();
	}

	// ---- 7. crossbyte.net.DatagramSocket over dgram ----------------------

	private function startDatagrams():Void {
		check("DatagramSocket is supported on Node", DatagramSocket.isSupported, "reported unsupported");

		receiver = new DatagramSocket();
		receiver.addEventListener(DatagramSocketDataEvent.DATA, onDatagram);
		// Asked before binding, which Node cannot act on yet: it is kept, and
		// applied once the socket is bound.
		receiver.receiveBufferSize = 96 * 1024;
		receiver.bind(0, "127.0.0.1");
		receiver.receive();

		check("bind() marked the socket bound", receiver.bound, "not bound");

		// Node binds asynchronously, so the local endpoint is not readable
		// until it has. Sending before then would go to a port nothing holds.
		waitForBind(0);
	}

	private function waitForBind(attempts:Int):Void {
		if (receiver.localPort != 0) {
			udpPort = receiver.localPort;
			check("the bound port is readable back", udpPort != 0, "got " + udpPort);
			check("a buffer size asked for before binding was applied once bound", receiver.receiveBufferSize >= 96 * 1024,
				"read back " + receiver.receiveBufferSize);
			sendDatagrams();
			return;
		}

		if (attempts > 200) {
			check("the bound port is readable back", false, "still " + receiver.localPort + " after " + attempts + " tries");
			stopDatagrams();
			return;
		}

		haxe.Timer.delay(function():Void {
			waitForBind(attempts + 1);
		}, 5);
	}

	private function sendDatagrams():Void {
		sender = new DatagramSocket();

		var first = new crossbyte.io.ByteArray();
		first.writeUTFBytes("datagram-one");
		sender.send(first, 0, first.length, "127.0.0.1", udpPort);

		// Connected: the destination comes from connect() rather than from
		// the call, which is the whole difference between the two modes.
		sender.connect("127.0.0.1", udpPort);
		check("connect() marked the socket connected", sender.connected, "not connected");

		var second = new crossbyte.io.ByteArray();
		second.writeUTFBytes("datagram-two");
		sender.send(second, 0, second.length);
	}

	private function onDatagram(event:DatagramSocketDataEvent):Void {
		datagrams++;
		var text = event.data.readUTFBytes(event.data.bytesAvailable);

		if (datagrams == 1) {
			check("an unconnected send arrived", text == "datagram-one", "got " + text);
			check("the datagram names its source", event.srcPort > 0, "src port " + event.srcPort);
			check("the datagram names its destination", event.dstPort == udpPort, "dst port " + event.dstPort);
		} else if (datagrams == 2) {
			check("a connected send arrived", text == "datagram-two", "got " + text);
			checkStrayIsFiltered();
		}
	}

	private function checkStrayIsFiltered():Void {
		// A connected socket sees only its peer. The receiver is unconnected,
		// so this one is: it is pointed at a port nothing is sending from, and
		// must not be handed the receiver's traffic.
		stray = new DatagramSocket();
		stray.connect("127.0.0.1", udpPort + 1);
		stray.bind(udpPort + 2, "127.0.0.1");

		var seen:Bool = false;
		stray.addEventListener(DatagramSocketDataEvent.DATA, function(_):Void {
			seen = true;
		});
		stray.receive();

		var payload = new crossbyte.io.ByteArray();
		payload.writeUTFBytes("not-for-you");
		sender.send(payload, 0, payload.length);

		haxe.Timer.delay(function():Void {
			check("a connected socket ignores traffic from anywhere else", !seen, "it took a datagram from the wrong peer");
			stopDatagrams();
		}, 120);
	}

	private function stopDatagrams():Void {
		receiver.close();
		sender.close();

		if (stray != null) {
			stray.close();
		}

		check("close() marked the socket closed", !receiver.bound, "still bound");
		startReliableDatagrams();
	}

	// ---- 8. the reliable layer on top of it ------------------------------

	private function startReliableDatagrams():Void {
		// Pure protocol over DatagramSocket -- sequencing, acknowledgement,
		// retransmission -- so nothing about it is platform code. Which is
		// exactly why it is worth running rather than assuming: it came to
		// Node as a gate change and no new lines, and a gate change that
		// compiles is not a gate change that works.
		rdServer = new ReliableDatagramServerSocket();
		// Its sequence starts forty below 2^31, so the burst below crosses
		// it. JavaScript counted on past it where the wire wraps, and the
		// receiver stopped delivering at the crossing.
		rdClient = new CrossingSocket();

		rdServer.addEventListener(ReliableDatagramSocketConnectEvent.CONNECT, function(event:ReliableDatagramSocketConnectEvent):Void {
			rdAccepted = event.socket;
			check("the reliable server accepted a session", rdAccepted != null, "no socket on the event");

			rdAccepted.addEventListener(DatagramSocketDataEvent.DATA, function(dataEvent:DatagramSocketDataEvent):Void {
				dataEvent.data.position = 0;
				var text = dataEvent.data.readUTFBytes(dataEvent.data.length);
				if (rdBurst.length == 0 && text == "reliable-over-node") {
					check("a reliable message arrived intact", true, "");
					rdBurst.push(text);
					sendReliableBurst();
					return;
				}
				rdBurst.push(text);
				if (rdBurst.length == RELIABLE_BURST + 1) {
					var inOrder = true;
					for (i in 0...RELIABLE_BURST) {
						if (rdBurst[i + 1] != "burst " + i) {
							inOrder = false;
						}
					}
					check("a burst of reliable messages arrived whole and in order, across 2^31", inOrder, rdBurst.slice(1, 6).join(", ") + "...");
					stopReliableDatagrams();
				}
			});
		});

		rdServer.bind(0, "127.0.0.1");
		rdServer.listen();

		waitForReliableBind(0);
	}

	// Sent in one go, so on Node, where datagrams arrive between the runtime's
	// passes, the session's frames and the peer's acknowledgements are sent
	// when the platform's turn ends rather than a frame later -- and bundled.
	private static inline var RELIABLE_BURST:Int = 100;

	private function sendReliableBurst():Void {
		for (i in 0...RELIABLE_BURST) {
			var payload = new crossbyte.io.ByteArray();
			payload.writeUTFBytes("burst " + i);
			rdClient.send(payload);
		}
		waitForReliableBurst(0);
	}

	private function waitForReliableBurst(attempts:Int):Void {
		if (rdBurst.length > RELIABLE_BURST) {
			return;
		}
		if (attempts > 400) {
			check("a burst of reliable messages arrived whole and in order, across 2^31", false, rdBurst.length - 1 + " of " + RELIABLE_BURST + " arrived");
			stopReliableDatagrams();
			return;
		}
		haxe.Timer.delay(function():Void {
			waitForReliableBurst(attempts + 1);
		}, 5);
	}

	private function waitForReliableBind(attempts:Int):Void {
		if (rdServer.localPort > 0) {
			rdClient.connect("127.0.0.1", rdServer.localPort);
			waitForReliableHandshake(0);
			return;
		}

		if (attempts > 200) {
			check("the reliable server bound a port", false, "still 0 after " + attempts + " tries");
			stopReliableDatagrams();
			return;
		}

		haxe.Timer.delay(function():Void {
			waitForReliableBind(attempts + 1);
		}, 5);
	}

	private function waitForReliableHandshake(attempts:Int):Void {
		if (rdClient.connected && rdAccepted != null && rdAccepted.connected) {
			check("the reliable handshake completed", true, "");
			// A window's worth of socket buffer, which Windows grants in full;
			// elsewhere the system may cap it, and it is only required to read.
			var windowGranted = Sys.systemName() == "Windows"
				? rdClient.receiveBufferSize >= ReliableDatagramSocket.WINDOW_BUFFER_SIZE
				: rdClient.receiveBufferSize > 0;
			check("a reliable session asked for a window of socket buffer", windowGranted, "read back " + rdClient.receiveBufferSize);
			var payload = new crossbyte.io.ByteArray();
			payload.writeUTFBytes("reliable-over-node");
			rdClient.send(payload);
			return;
		}

		if (attempts > 400) {
			check("the reliable handshake completed", false, "client " + rdClient.connected + ", accepted " + (rdAccepted != null));
			stopReliableDatagrams();
			return;
		}

		haxe.Timer.delay(function():Void {
			waitForReliableHandshake(attempts + 1);
		}, 5);
	}

	private function stopReliableDatagrams():Void {
		try {
			rdClient.close();
		} catch (_:Dynamic) {}

		if (rdAccepted != null) {
			try {
				rdAccepted.close();
			} catch (_:Dynamic) {}
		}

		try {
			rdServer.close();
		} catch (_:Dynamic) {}

		startWebSocketServer2();
	}

	// ---- 9. crossbyte.net.ServerWebSocket accepting on Node --------------

	private function startWebSocketServer2():Void {
		// Both halves of the framing, talking to each other. The client stage
		// above proved the client against an echo server written by hand from
		// the specification; this proves the server, and a bug shared by both
		// would have to be one that the hand-written peer also had.
		wsListener = new ServerWebSocket();

		var secureWs = new ServerWebSocket(true);
		check("a secure ServerWebSocket constructs on Node", true, "");
		// The property, not a private flag. It read false on a secure server
		// until the constructor stopped keeping its own copy of the answer.
		check("a secure ServerWebSocket says it is secure", secureWs.secure, "secure reported false");
		check("a plain ServerWebSocket says it is not", !wsListener.secure, "secure reported true");

		wsListener.addEventListener(ServerSocketConnectEvent.CONNECT, function(event:ServerSocketConnectEvent):Void {
			wsAccepted = cast event.socket;
			check("the server accepted a session", wsAccepted != null, "no socket on the event");
			check("the server counts its sessions", wsListener.clientCount == 1, "clientCount " + wsListener.clientCount);

			wsAccepted.addEventListener(ProgressEvent.SOCKET_DATA, function(_):Void {
				var request = wsAccepted.readUTFBytes(wsAccepted.bytesAvailable);
				check("the server read a masked client frame", request == WS_SHORT, "got " + request);
				wsAccepted.writeUTFBytes(request.toUpperCase());
				wsAccepted.flush();
			});
		});

		wsListener.bind(0, "127.0.0.1");
		wsListener.listen();

		waitForListenerPort(0);
	}

	private function waitForListenerPort(attempts:Int):Void {
		if (wsListener.localPort > 0) {
			connectToOwnServer();
			return;
		}

		if (attempts > 200) {
			check("the server bound a port", false, "still 0 after " + attempts + " tries");
			stopWebSocketServer2();
			return;
		}

		haxe.Timer.delay(function():Void {
			waitForListenerPort(attempts + 1);
		}, 5);
	}

	private function connectToOwnServer():Void {
		wsClient = new WebSocket();

		wsClient.addEventListener(Event.CONNECT, function(_):Void {
			check("the client completed the upgrade against our own server", true, "");
			wsClient.writeUTFBytes(WS_SHORT);
			wsClient.flush();
		});

		wsClient.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent):Void {
			check("the client reached our own server", false, "io error: " + e.text);
			stopWebSocketServer2();
		});

		wsClient.addEventListener(ProgressEvent.SOCKET_DATA, function(_):Void {
			var reply = wsClient.readUTFBytes(wsClient.bytesAvailable);
			// Unmasked on the way back: a server must not mask, and a client
			// that could not tell the difference would read a masked frame as
			// noise.
			check("the client read the server's unmasked reply", reply == WS_SHORT.toUpperCase(), "got " + reply);
			stopWebSocketServer2();
		});

		wsClient.connect("127.0.0.1", wsListener.localPort);
	}

	// ---- 10. a TLS listener on Node --------------------------------------

	private function startTls():Void {
		var fixture = crossbyte.net.TLSTestFixture.selfSigned();

		if (fixture == null) {
			// No certificate toolchain on this machine. Said out loud rather
			// than passed quietly: a skipped TLS test that reports nothing is
			// how a broken listener stays green.
			Sys.println("  SKIP  TLS: no certificate toolchain on this machine");
			runSubprocess();
			return;
		}

		tlsServer = new ServerSocket(true);
		check("a secure ServerSocket constructs on Node", tlsServer.secure, "not secure");
		tlsServer.setCertificate(crossbyte.net.Certificate.fromFile(fixture.certificatePath), crossbyte.net.Key.fromFile(fixture.keyPath));

		tlsServer.addEventListener(ServerSocketConnectEvent.CONNECT, function(event:ServerSocketConnectEvent):Void {
			tlsAccepted = event.socket;
			check("the TLS server accepted a connection", tlsAccepted != null, "no socket on the event");

			tlsAccepted.addEventListener(ProgressEvent.SOCKET_DATA, function(_):Void {
				var text = tlsAccepted.readUTFBytes(tlsAccepted.bytesAvailable);
				check("the TLS server read the encrypted request", text == "over-tls", "got " + text);
				tlsAccepted.writeUTFBytes(text.toUpperCase());
				tlsAccepted.flush();
			});
		});

		tlsServer.bind(0, "127.0.0.1");
		tlsServer.listen();

		waitForTlsPort(0);
	}

	private function waitForTlsPort(attempts:Int):Void {
		if (tlsServer.localPort > 0) {
			connectOverTls();
			return;
		}

		if (attempts > 200) {
			check("the TLS server bound a port", false, "still 0 after " + attempts + " tries");
			stopTls();
			return;
		}

		haxe.Timer.delay(function():Void {
			waitForTlsPort(attempts + 1);
		}, 5);
	}

	private function connectOverTls():Void {
		// Node's own TLS client, not ours. What is under test is whether this
		// server speaks TLS, and two halves of the same codebase agreeing
		// would not answer that. rejectUnauthorized is off only because the
		// certificate is self-signed by the fixture.
		var client = js.node.Tls.connect({port: tlsServer.localPort, host: "127.0.0.1", rejectUnauthorized: false});

		client.on("secureConnect", function():Void {
			check("a standard TLS client completed the handshake", true, "");
			client.write("over-tls");
		});

		client.on("data", function(chunk:js.node.Buffer):Void {
			check("the TLS client got the encrypted reply", chunk.toString() == "OVER-TLS", "got " + chunk.toString());
			client.destroy();
			stopTls();
		});

		client.on("error", function(e:Dynamic):Void {
			check("a standard TLS client completed the handshake", false, Std.string(e));
			stopTls();
		});
	}

	private function stopTls():Void {
		if (tlsAccepted != null) {
			try {
				tlsAccepted.close();
			} catch (_:Dynamic) {}
		}

		try {
			tlsServer.close();
		} catch (_:Dynamic) {}

		runSubprocess();
	}

	private function stopWebSocketServer2():Void {
		try {
			wsClient.close();
		} catch (_:Dynamic) {}

		if (wsAccepted != null) {
			try {
				wsAccepted.close();
			} catch (_:Dynamic) {}
		}

		try {
			wsListener.close();
		} catch (_:Dynamic) {}

		startTls();
	}

	// ---- 11. NativeProcess over child_process ----------------------------

	private function runSubprocess():Void {
		var process = new NativeProcess();
		var out:String = "";
		var err:String = "";
		var outClosed:Bool = false;
		var errClosed:Bool = false;

		process.addEventListener(NativeProcessEvent.STANDARD_OUTPUT_DATA, function(e:NativeProcessEvent):Void {
			out += e.text;
		});

		process.addEventListener(NativeProcessEvent.STANDARD_ERROR_DATA, function(e:NativeProcessEvent):Void {
			err += e.text;
		});

		process.addEventListener(NativeProcessEvent.STANDARD_OUTPUT_CLOSE, function(_):Void {
			outClosed = true;
		});

		process.addEventListener(NativeProcessEvent.STANDARD_ERROR_CLOSE, function(_):Void {
			errClosed = true;
		});

		process.addEventListener(NativeProcessEvent.EXIT, function(e:NativeProcessEvent):Void {
			check("NativeProcess read stdout", out.indexOf("child-stdout") >= 0, "got " + out);
			check("NativeProcess read stderr", err.indexOf("child-stderr") >= 0, "got " + err);
			check("NativeProcess closed both streams", outClosed && errClosed, "stdout " + outClosed + ", stderr " + errClosed);
			check("NativeProcess reported the exit code", e.exitCode == 7, "got " + e.exitCode);
			check("NativeProcess reported a pid", e.pid > 0, "got " + e.pid);
			feedSubprocess();
		});

		process.start(new NativeProcessStartupInfo("node", ["-e", childScript()]));

		check("NativeProcess is supported on Node", NativeProcess.isSupported, "reported unsupported");
	}

	private function feedSubprocess():Void {
		var process = new NativeProcess();
		var out:String = "";

		process.addEventListener(NativeProcessEvent.STANDARD_OUTPUT_DATA, function(e:NativeProcessEvent):Void {
			out += e.text;
		});

		process.addEventListener(NativeProcessEvent.EXIT, function(_):Void {
			check("NativeProcess wrote to stdin", out.indexOf("[through-stdin]") >= 0, "got " + out);
			startPhpBackend();
		});

		process.start(new NativeProcessStartupInfo("node", ["-e", echoStdinScript()]));

		var input = process.standardInput;
		check("NativeProcess handed out an stdin writer", input != null, "standardInput was null");

		if (input != null) {
			input.writeString("through-");
			// Offset and length both non-trivial, so a writeBytes that ignores
			// them would put the wrong text through the pipe rather than none.
			input.writeBytes(haxe.io.Bytes.ofString("xxstdinyy"), 2, 5);
		}

		process.closeInput();
	}

	// Built rather than written out, because a quote inside a -e argument is
	// where a shell, a Haxe string and Node's parser each want a turn.
	private static function childScript():String {
		var q = String.fromCharCode(39);
		return "process.stdout.write(" + q + "child-stdout" + q + ");" + "process.stderr.write(" + q + "child-stderr" + q + ");" + "process.exit(7)";
	}

	private static function echoStdinScript():String {
		var q = String.fromCharCode(39);
		return "let b=" + q + q + ";" + "process.stdin.on(" + q + "data" + q + ",c=>b+=c);" + "process.stdin.on(" + q + "end" + q + ",()=>process.stdout.write("
			+ q + "[" + q + "+b+" + q + "]" + q + "))";
	}

	// ---- 12. the PHP bridge over Node's sockets --------------------------
	//
	// This one could not exist until the bridge stopped reading synchronously.
	// Node has no blocking socket read, so PHP was refused outright at config
	// validation; the refusal is gone and this is what replaces it.
	//
	// The backend is a socket that speaks FastCGI, not php-fpm. What is under
	// test is the bridge, and standing up a real PHP to test it would make this
	// a test of whether CI has PHP installed.

	private function startPhpBackend():Void {
		phpBackend = new ServerSocket();

		phpBackend.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent):Void {
			phpPeer = e.socket;

			phpPeer.addEventListener(ProgressEvent.SOCKET_DATA, function(_):Void {
				// The request arrives as records this test does not need to
				// parse -- any of it means the bridge sent something.
				if (phpAnswered) {
					return;
				}

				phpAnswered = true;
				phpPeer.readUTFBytes(phpPeer.bytesAvailable);

				var payload = "Status: 201 Created\r\nContent-Type: text/plain\r\nX-From: fastcgi\r\n\r\nhello from php";
				var body = ByteArray.fromBytes(haxe.io.Bytes.ofString(payload));
				var stdout = fcgiRecord(6, body);

				// Deliberately torn in half, mid-record. A response does not
				// arrive in one piece and the blocking reader never had to care,
				// because it simply asked the socket for more; an event-driven
				// one is handed whatever turned up and has to carry the
				// remainder. Splitting inside the header is the case that breaks
				// a parser that assumes it can at least read eight bytes.
				var firstHalf = new ByteArray();
				firstHalf.writeBytes(stdout, 0, 3);
				phpPeer.writeBytes(firstHalf, 0, firstHalf.length);
				phpPeer.flush();

				haxe.Timer.delay(function():Void {
					var rest = new ByteArray();
					rest.writeBytes(stdout, 3, stdout.length - 3);
					rest.writeBytes(fcgiRecord(3, endRequestBody()), 0, 8 + 8);
					phpPeer.writeBytes(rest, 0, rest.length);
					phpPeer.flush();
				}, 30);
			});
		});

		phpBackend.bind(0, "127.0.0.1");
		phpBackend.listen();

		crossByte.addEventListener(TickEvent.TICK, waitForPhpPort);
	}

	private function waitForPhpPort(_):Void {
		if (phpBackend.localPort == 0) {
			return;
		}

		crossByte.removeEventListener(TickEvent.TICK, waitForPhpPort);
		runPhp();
	}

	private function runPhp():Void {
		var bridge = new PHPBridge(PHPMode.Connect("127.0.0.1", phpBackend.localPort), "", ["index.php"], 5);

		var started:Float = haxe.Timer.stamp();
		var future = bridge.execute(phpRequest());

		check("PHPBridge.execute returned before the backend answered", !future.completed, "it had already settled");

		future.then(function(response:PHPResponse):Void {
			check("PHP response carried the CGI status", response.status == 201, "got " + response.status);
			check("PHP response carried a header", response.headers.get("x-from") == "fastcgi", "got " + response.headers.get("x-from"));
			check("PHP response carried the body", response.body.toString() == "hello from php", "got " + response.body.toString());
			check("PHP response reassembled a torn record", haxe.Timer.stamp() - started >= 0.02, "answered before the second half was sent");
			phpBackend.close();
			runPhpTimeout();
		}, function(message:String):Void {
			check("PHP exchange succeeded", false, message);
			phpBackend.close();
			runPhpTimeout();
		});
	}

	private function runPhpTimeout():Void {
		// The deadline, on Node. Native drives it from a tick; Node has no tick
		// to read on, so the sweep is the only thing that can end this exchange.
		var silent = new ServerSocket();

		// The accepted socket is held, which is the whole point of this stage.
		// Dropped on the floor it is collectable, Node tears the connection
		// down, and the bridge reports a closed peer -- a real failure, but not
		// the one under test. A backend that accepted and then said nothing is
		// what has to be survived here.
		silent.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent):Void {
			silentPeer = e.socket;
		});

		silent.bind(0, "127.0.0.1");
		silent.listen();

		var armed:Bool = false;

		crossByte.addEventListener(TickEvent.TICK, function await(_):Void {
			if (silent.localPort == 0 || armed) {
				return;
			}

			armed = true;
			crossByte.removeEventListener(TickEvent.TICK, await);

			var bridge = new PHPBridge(PHPMode.Connect("127.0.0.1", silent.localPort), "", ["index.php"], 0.4);
			var started:Float = haxe.Timer.stamp();

			bridge.execute(phpRequest()).then(function(_:PHPResponse):Void {
				check("a silent PHP backend failed instead of hanging", false, "it produced a response");
				silent.close();
				report();
			}, function(message:String):Void {
				var elapsed:Float = haxe.Timer.stamp() - started;
				check("a silent PHP backend failed instead of hanging", message.indexOf("did not respond within") >= 0, "got " + message);
				check("the PHP deadline was honoured on Node", elapsed < 3, "took " + elapsed + "s");
				silent.close();
				report();
			});
		});
	}

	private function phpRequest():PHPRequest {
		return {
			requestMethod: "GET",
			scriptFilename: "/var/www/index.php",
			scriptName: "/index.php",
			requestUri: "/index.php",
			queryString: "",
			contentType: "",
			remoteAddr: "127.0.0.1",
			serverName: "localhost",
			serverPort: "80",
			extraHeaders: new haxe.ds.StringMap(),
			body: haxe.io.Bytes.alloc(0)
		};
	}

	private static function fcgiRecord(type:Int, content:ByteArray):ByteArray {
		var record = new ByteArray();
		record.writeByte(1);
		record.writeByte(type);
		record.writeByte(0);
		record.writeByte(1);
		record.writeByte((content.length >> 8) & 0xFF);
		record.writeByte(content.length & 0xFF);
		record.writeByte(0);
		record.writeByte(0);
		record.writeBytes(content, 0, content.length);
		return record;
	}

	private static function endRequestBody():ByteArray {
		var body = new ByteArray();
		for (_ in 0...8) {
			body.writeByte(0);
		}
		return body;
	}

	// ---- reporting --------------------------------------------------------

	private function report():Void {
		Sys.println(failures == 0 ? "ALL PASS (" + checks + " checks)" : failures + " of " + checks + " FAILED");
		js.Node.process.exitCode = failures == 0 ? 0 : 1;
		// Through the runtime rather than Sys.exit, so that stopping a
		// self-driven loop is itself covered: nothing stays scheduled
		// afterwards, and Node returns on its own.
		crossByte.exit();
	}

	private static function check(what:String, ok:Bool, detail:String):Void {
		checks++;
		Sys.println((ok ? "  PASS  " : "  FAIL  ") + what + (ok ? "" : " -- " + detail));

		if (!ok) {
			failures++;
		}
	}

	public static function main():Void {
		new NodeIntegrationMain();
	}
}

/** A reliable session whose first sequence is forty below 2^31. **/
@:access(crossbyte.net.ReliableDatagramSocket)
private class CrossingSocket extends ReliableDatagramSocket {
	public function new() {
		super();
	}

	override private function __randomSequenceSeed():crossbyte.Seq32 {
		return 0x7FFFFFFF - 40;
	}
}
