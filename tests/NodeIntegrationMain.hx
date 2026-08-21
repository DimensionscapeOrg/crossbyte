import crossbyte.core.Application;
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
	private static inline var HTTP_PORT:Int = 50561;
	private static inline var ECHO_PORT:Int = 50562;
	private static inline var WEB_PORT:Int = 50563;
	private static inline var WS_PORT:Int = 50564;
	private static inline var UDP_PORT:Int = 50565;
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

		httpServer.listen(HTTP_PORT, "127.0.0.1", function():Void {
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

		loader.load(new URLRequest("http://127.0.0.1:" + HTTP_PORT + "/hello"));
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

		var request = new URLRequest("http://127.0.0.1:" + HTTP_PORT + "/echo");
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

		echoServer.listen(ECHO_PORT, "127.0.0.1", function():Void {
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
			check("Socket knows its remote port", socket.remotePort == ECHO_PORT, "got " + socket.remotePort);
			check("Socket knows its local port", socket.localPort > 0, "got " + socket.localPort);
			socket.close();
			echoServer.close();
			startListener();
		});

		socket.connect("127.0.0.1", ECHO_PORT);
	}

	// ---- 4. crossbyte.net.ServerSocket over js.node.net.Server -----------

	private function startListener():Void {
		listener = new ServerSocket();

		check("ServerSocket is supported on Node", ServerSocket.isSupported, "reported unsupported");

		var refusedSecure:String = null;

		try {
			new ServerSocket(true);
		} catch (e:Dynamic) {
			refusedSecure = Std.string(e);
		}

		check("a secure ServerSocket refuses on Node", refusedSecure != null && refusedSecure.indexOf("sys.ssl") >= 0,
			refusedSecure == null ? "it did not refuse" : refusedSecure);

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
		config.port = WEB_PORT;
		config.rootDirectory = new File(webRoot);
		config.directoryIndex = ["index.html"];

		var refusedPhp:String = null;

		try {
			config.phpEnabled = true;
			config.validate();
		} catch (e:Dynamic) {
			refusedPhp = Std.string(e);
		}

		config.phpEnabled = false;
		check("a PHP-enabled config refuses on Node", refusedPhp != null && refusedPhp.indexOf("PHP") >= 0,
			refusedPhp == null ? "it did not refuse" : refusedPhp);

		// Binds and listens in its constructor; calling bind() again here is
		// a second bind on the same socket, which a native target refuses
		// outright.
		webServer = new HTTPServer(config);

		check("HTTPServer is listening", webServer.listening, "not listening");

		requestIndex();
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

		loader.load(new URLRequest("http://127.0.0.1:" + WEB_PORT + "/"));
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

		loader.load(new URLRequest("http://127.0.0.1:" + WEB_PORT + "/data.json"));
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

		wsServer.listen(WS_PORT, "127.0.0.1", function():Void {
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

		ws.connect("127.0.0.1", WS_PORT);
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
		receiver.bind(UDP_PORT, "127.0.0.1");
		receiver.receive();

		check("bind() marked the socket bound", receiver.bound, "not bound");

		// Node binds asynchronously, so the local endpoint is not readable
		// until it has. Sending before then would go to a port nothing holds.
		waitForBind(0);
	}

	private function waitForBind(attempts:Int):Void {
		if (receiver.localPort == UDP_PORT) {
			check("the bound port is readable back", receiver.localPort == UDP_PORT, "got " + receiver.localPort);
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
		sender.send(first, 0, first.length, "127.0.0.1", UDP_PORT);

		// Connected: the destination comes from connect() rather than from
		// the call, which is the whole difference between the two modes.
		sender.connect("127.0.0.1", UDP_PORT);
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
			check("the datagram names its destination", event.dstPort == UDP_PORT, "dst port " + event.dstPort);
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
		stray.connect("127.0.0.1", UDP_PORT + 1);
		stray.bind(UDP_PORT + 2, "127.0.0.1");

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
		rdClient = new ReliableDatagramSocket();

		rdServer.addEventListener(ReliableDatagramSocketConnectEvent.CONNECT, function(event:ReliableDatagramSocketConnectEvent):Void {
			rdAccepted = event.socket;
			check("the reliable server accepted a session", rdAccepted != null, "no socket on the event");

			rdAccepted.addEventListener(DatagramSocketDataEvent.DATA, function(dataEvent:DatagramSocketDataEvent):Void {
				dataEvent.data.position = 0;
				var text = dataEvent.data.readUTFBytes(dataEvent.data.length);
				check("a reliable message arrived intact", text == "reliable-over-node", "got " + text);
				stopReliableDatagrams();
			});
		});

		rdServer.bind(0, "127.0.0.1");
		rdServer.listen();

		waitForReliableBind(0);
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

		runSubprocess();
	}

	// ---- 9. NativeProcess over child_process -----------------------------

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
			report();
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
