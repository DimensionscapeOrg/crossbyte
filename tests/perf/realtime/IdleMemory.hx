import crossbyte.core.HostApplication;
import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ProgressEvent;
import crossbyte.events.ReliableDatagramSocketConnectEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.events.WebSocketMessageEvent;
import crossbyte.io.ByteArray;
import crossbyte.net.ReliableDatagramServerSocket;
import crossbyte.net.ReliableDatagramSocket;
import crossbyte.net.ServerSocket;
import crossbyte.net.ServerWebSocket;
import crossbyte.net.Socket;
import crossbyte.net.WebSocket;
import haxe.Json;
import haxe.Timer;
import haxe.io.Bytes;

/**
	What a server holds for each idle connection: the heap after a full
	collection with `count` connections open, less the heap before any
	connected, over `count`, in the server's process. The clients run in a
	process of their own (`--bots`, this program unless given, so a JVM server
	can be given native clients), so only the server's side is counted.

	    IdleMemory server --transport tcp|ws|rudp [--count 1000] [--message 0] [--quiet 3] [--encrypt] [--bots <exe>]
	    IdleMemory clients --transport tcp|ws|rudp --port P --count N [--message 0] [--encrypt]

	Each connection the server accepts gets one listener for what arrives, as
	an application's would. With `--message n`, each client sends n bytes once
	connected and the server sends them back, so the figure is what a
	connection holds after a message each way. The heap is read once the last
	connection opened (and, with a message, the last echo went) `quiet`
	seconds before: a TCP connection lets its buffers' storage go at its
	runtime's next sweep (every 5 s), a WebSocket session after a heartbeat
	with nothing heard or sent (30 s), so after a message give it longer than
	that. `--encrypt` seals reliable UDP sessions.

	Natively the heap is `MEM_INFO_USAGE` after two full collections; on the
	JVM the used heap after four `System.gc()` calls. Prints one `IDLE` line
	of JSON.
**/
class IdleMemory extends HostApplication {
	static final opts:Map<String, String> = new Map();
	static final KEY:Bytes = Bytes.ofHex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f");

	static function opt(name:String, fallback:String):String {
		return opts.exists(name) ? opts.get(name) : fallback;
	}

	static function main():Void {
		final args = Sys.args();
		final role = args.length > 0 ? args.shift() : "";
		var i = 0;
		while (i < args.length) {
			final name = args[i].substr(2);
			if (i + 1 < args.length && !StringTools.startsWith(args[i + 1], "--")) {
				opts.set(name, args[i + 1]);
				i += 2;
			} else {
				opts.set(name, "true");
				i++;
			}
		}
		final app = new IdleMemory();
		switch (role) {
			case "server":
				app.server();
			case "clients":
				app.clients();
			default:
				Sys.println("usage: IdleMemory server|clients --transport tcp|ws|rudp ...");
				Sys.exit(2);
		}
	}

	var last:Float = 0;

	function new() {
		super();
		last = Timer.stamp();
	}

	/** Runs the runtime for `seconds`, or until `until` answers true. **/
	function pump(seconds:Float, ?until:Void->Bool):Bool {
		final end = Timer.stamp() + seconds;
		while (Timer.stamp() < end) {
			final now = Timer.stamp();
			advance(now - last, 0);
			last = now;
			if (until != null && until()) {
				return true;
			}
			crossbyte.sys.System.sleep(0.001);
		}
		return until == null;
	}

	static function heap():Float {
		#if cpp
		cpp.vm.Gc.run(true);
		cpp.vm.Gc.run(true);
		return cpp.vm.Gc.memInfo64(cpp.vm.Gc.MEM_INFO_USAGE);
		#elseif jvm
		final runtime = java.lang.Runtime.getRuntime();
		for (_ in 0...4) {
			java.lang.System.gc();
			crossbyte.sys.System.sleep(0.05);
		}
		final used:haxe.Int64 = runtime.totalMemory() - runtime.freeMemory();
		return haxe.Int64.toInt(used) * 1.0;
		#else
		return -1;
		#end
	}

	function server():Void {
		final transport = opt("transport", "tcp");
		final count = Std.parseInt(opt("count", "1000"));
		final message = Std.parseInt(opt("message", "0"));
		final quiet = Std.parseFloat(opt("quiet", "3"));
		final encrypt = opts.exists("encrypt");
		final held:Array<Any> = [];
		var connected = 0;
		var echoed = 0;
		var port = 0;

		switch (transport) {
			case "tcp":
				final server = new ServerSocket();
				server.maxConnections = count + 100;
				server.addEventListener(ServerSocketConnectEvent.CONNECT, (e:ServerSocketConnectEvent) -> {
					final socket:Socket = e.socket;
					held.push(socket);
					connected++;
					socket.addEventListener(ProgressEvent.SOCKET_DATA, (_:ProgressEvent) -> {
						if (message > 0 && socket.bytesAvailable >= message) {
							final bytes = new ByteArray();
							socket.readBytes(bytes, 0, message);
							socket.writeBytes(bytes);
							socket.flush();
							echoed++;
						}
					});
				});
				server.bind(0, "127.0.0.1");
				server.listen(4096);
				held.push(server);
				port = server.localPort;
			case "ws":
				final server = new ServerWebSocket();
				server.maxConnections = count + 100;
				server.addEventListener(ServerSocketConnectEvent.CONNECT, (e:ServerSocketConnectEvent) -> {
					final session:WebSocket = cast e.socket;
					held.push(session);
					connected++;
					session.addEventListener(WebSocketMessageEvent.MESSAGE, (m:WebSocketMessageEvent) -> {
						session.sendBinary(m.data);
						echoed++;
					});
				});
				server.bind(0, "127.0.0.1");
				server.listen(4096);
				held.push(server);
				port = server.localPort;
			case "rudp":
				final server = new ReliableDatagramServerSocket();
				server.maxPendingConnections = count + 256;
				server.joinValidation = NEVER;
				if (encrypt) {
					server.encryptionKeyFor = (_, _, _) -> KEY;
				}
				server.addEventListener(ReliableDatagramSocketConnectEvent.CONNECT, (e:ReliableDatagramSocketConnectEvent) -> {
					final session = e.socket;
					held.push(session);
					connected++;
					session.addEventListener(DatagramSocketDataEvent.DATA, (d:DatagramSocketDataEvent) -> {
						session.send(d.data);
						echoed++;
					});
				});
				server.bind(0, "127.0.0.1");
				server.listen();
				held.push(server);
				port = server.localPort;
			default:
				Sys.println("FAILED unknown transport " + transport);
				Sys.exit(2);
		}

		pump(0.2);
		final before = heap();
		final args = ["clients", "--transport", transport, "--port", Std.string(port), "--count", Std.string(count), "--message",
			Std.string(message)];
		if (encrypt) {
			args.push("--encrypt");
		}
		final bots = new sys.io.Process(opt("bots", Sys.programPath()), args);
		if (!pump(120, () -> connected >= count && (message == 0 || echoed >= count))) {
			Sys.println('FAILED $connected of $count connected, $echoed echoed');
		}
		pump(quiet);
		final after = heap();
		Sys.println("IDLE " + Json.stringify({
			transport: transport,
			target: #if cpp "native" #elseif jvm "jvm" #else "other" #end,
			encrypt: encrypt,
			connections: connected,
			message: message,
			quietSeconds: quiet,
			heapBefore: Math.round(before),
			heapAfter: Math.round(after),
			perConnection: Math.round((after - before) / Math.max(1, connected))
		}));
		Sys.stdout().flush();
		bots.kill();
		bots.close();
		Sys.exit(0);
	}

	function clients():Void {
		final transport = opt("transport", "tcp");
		final port = Std.parseInt(opt("port", "0"));
		final count = Std.parseInt(opt("count", "1000"));
		final message = Std.parseInt(opt("message", "0"));
		final encrypt = opts.exists("encrypt");
		final payload = new ByteArray();
		payload.length = message;
		final held:Array<Any> = [];
		var started = 0;
		while (started < count) {
			for (_ in 0...50) {
				if (started >= count) {
					break;
				}
				started++;
				switch (transport) {
					case "tcp":
						final socket = new Socket();
						held.push(socket);
						socket.addEventListener(Event.CONNECT, _ -> {
							if (message > 0) {
								socket.writeBytes(payload);
								socket.flush();
							}
						});
						socket.addEventListener(ProgressEvent.SOCKET_DATA, (_:ProgressEvent) -> {
							if (socket.bytesAvailable >= message && message > 0) {
								socket.readBytes(new ByteArray(), 0, message);
							}
						});
						socket.addEventListener(IOErrorEvent.IO_ERROR, (_:IOErrorEvent) -> {});
						socket.connect("127.0.0.1", port);
					case "ws":
						final socket = new WebSocket();
						held.push(socket);
						socket.addEventListener(Event.CONNECT, _ -> {
							if (message > 0) {
								socket.sendBinary(payload);
							}
						});
						socket.addEventListener(WebSocketMessageEvent.MESSAGE, (_:WebSocketMessageEvent) -> {});
						socket.addEventListener(IOErrorEvent.IO_ERROR, (_:IOErrorEvent) -> {});
						socket.connect("127.0.0.1", port);
					case "rudp":
						final socket = new ReliableDatagramSocket();
						held.push(socket);
						if (encrypt) {
							socket.encryptionKey = KEY;
						}
						socket.addEventListener(Event.CONNECT, _ -> {
							if (message > 0) {
								socket.send(payload);
							}
						});
						socket.addEventListener(DatagramSocketDataEvent.DATA, (_:DatagramSocketDataEvent) -> {});
						socket.addEventListener(IOErrorEvent.IO_ERROR, (_:IOErrorEvent) -> {});
						socket.bind(0, "127.0.0.1");
						socket.connect("127.0.0.1", port);
				}
			}
			pump(0.05);
		}
		// Until the server's process ends this one.
		pump(600);
		Sys.exit(0);
	}
}
