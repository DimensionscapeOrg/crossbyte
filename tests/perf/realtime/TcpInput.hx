import crossbyte.core.CrossByte;
import crossbyte.core.HostApplication;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.events.WebSocketMessageEvent;
import crossbyte.io.ByteArray;
import crossbyte.io.ByteArray.ByteArrayData;
import crossbyte.net.ServerSocket;
import crossbyte.net.Socket;
import haxe.Timer;
import haxe.io.Bytes;

/**
	What a TCP connection's input buffer costs, natively or on the jvm,
	receiving large bursts from a plain socket in the same process:

	- `mode=bulk`: the writer sends `burst` bytes (1 MB), the receiver
	  reads everything it is given, and the next burst goes once it has,
	  until `total` bytes have arrived.
	- `mode=slow`: the application reads `read` bytes a pass (64 KB) while
	  the writer keeps `backlog` bytes (8 MB) waiting for it, then stops
	  until the application has read everything, and fills it again: a
	  receiver behind a slow handler, its backlog drained now and then.
	  `drain=0` never lets it drain: the backlog stays.
	- `mode=ws`: a ServerWebSocket session receives `size`-byte binary
	  messages (1 MB) from a client that upgraded by hand, one a pass, a
	  MESSAGE listener taking each.

	Reports the input storage at its largest, the bytes the process
	allocated per megabyte received (collection off, the growth of what
	the collector reserved), CPU and wall per megabyte, and what the
	runtime's storage pool holds after `quiet` seconds (0: not measured).

	Arguments: mode (bulk), burst, backlog, read, size, total (128 MB),
	rcvbuf (4 MB, the receiving socket's system buffer), quiet, label.
**/
@:access(crossbyte.net.Socket)
class TcpInput extends HostApplication {
	static var opts:Map<String, String> = new Map();

	static function opt(name:String, value:String):String {
		return opts.exists(name) ? opts.get(name) : value;
	}

	static function optInt(name:String, value:Int):Int {
		return Std.parseInt(opt(name, Std.string(value)));
	}

	static function main():Void {
		for (arg in Sys.args()) {
			var at = arg.indexOf("=");
			if (at > 0) {
				opts.set(arg.substr(0, at), arg.substr(at + 1));
			}
		}
		new TcpInput().run();
	}

	var last:Float = 0;
	var accepted:Array<Socket> = [];

	function new() {
		super();
	}

	function pump():Void {
		var now = Timer.stamp();
		advance(now - last, 0);
		last = now;
	}

	/** Natively what the collector reserved (collection off); on the jvm what this thread allocated. **/
	static function reserved():Float {
		#if cpp
		return cpp.vm.Gc.memInfo64(cpp.vm.Gc.MEM_INFO_RESERVED);
		#elseif jvm
		var bean = java.lang.management.ManagementFactory.getThreadMXBean();
		var method = java.lang.Class.forName("com.sun.management.ThreadMXBean").getMethod("getThreadAllocatedBytes", java.lang.Long.TYPE);
		var bytes:Dynamic = method.invoke(bean, java.lang.Long.valueOf(java.lang.Thread.currentThread().getId()));
		return (bytes : Float);
		#else
		return 0;
		#end
	}

	/** This thread's CPU time: on the jvm `Sys.cpuTime` is wall time. **/
	static function cpu():Float {
		#if jvm
		return haxe.Int64.toInt(haxe.Int64.div(java.lang.management.ManagementFactory.getThreadMXBean().getCurrentThreadCpuTime(), 1000)) / 1e6;
		#else
		return Sys.cpuTime();
		#end
	}

	static function gcOff(off:Bool):Void {
		#if cpp
		if (!off) {
			cpp.vm.Gc.enable(true);
		} else {
			cpp.vm.Gc.run(true);
			cpp.vm.Gc.enable(false);
		}
		#end
	}

	static function storage(buffer:Null<ByteArray>):Float {
		return buffer == null ? 0 : @:privateAccess (buffer : ByteArrayData).__length;
	}

	static function poolHeld():Float {
		#if ((cpp || jvm) && !macro)
		var pool = @:privateAccess CrossByte.current().__storage;
		return pool == null ? 0 : pool.held();
		#else
		return 0;
		#end
	}

	function run():Void {
		var mode = opt("mode", "bulk");
		if (mode == "ws") {
			webSocket();
		} else {
			tcp(mode);
		}
		Sys.exit(0);
	}

	/** Writes what it can of `data` from `at` to `end` without blocking: the new `at`. **/
	static function offer(writer:sys.net.Socket, data:Bytes, at:Int, end:Int):Int {
		while (at < end) {
			var n = try writer.output.writeBytes(data, at, end - at) catch (_:Dynamic) -1;
			if (n <= 0) {
				break;
			}
			at += n;
		}
		return at;
	}

	function tcp(mode:String):Void {
		var burst = optInt("burst", 1024 * 1024);
		var backlog = optInt("backlog", 8 * 1024 * 1024);
		var read = optInt("read", 65536);
		var drain = optInt("drain", 1) != 0;
		var total = Std.parseFloat(opt("total", "134217728"));

		var server = new ServerSocket();
		server.receiveBufferSize = optInt("rcvbuf", 4 * 1024 * 1024);
		server.addEventListener(ServerSocketConnectEvent.CONNECT, (e:ServerSocketConnectEvent) -> accepted.push(e.socket));
		server.bind(0, "127.0.0.1");
		server.listen(16);
		last = Timer.stamp();

		var writer = new sys.net.Socket();
		writer.setFastSend(true);
		writer.connect(new sys.net.Host("127.0.0.1"), server.localPort);
		writer.setBlocking(false);
		var deadline = Timer.stamp() + 10;
		while (accepted.length < 1 && Timer.stamp() < deadline) {
			pump();
		}
		var s = accepted[0];
		if (s == null) {
			Sys.println("never connected");
			Sys.exit(1);
		}
		s.maxInputBufferSize = 0;

		// What the writer sends from: one block, sent over and over.
		var chunk = Bytes.alloc(1024 * 1024);
		var sink = new ByteArray();
		sink.length = 32 * 1024 * 1024;
		var got = 0.0;
		var sent = 0.0;
		var peak = 0.0;
		var events = 0;
		var cycles = 0;
		var grown = 0;
		var lastData:Dynamic = null;
		if (mode == "bulk") {
			s.addEventListener(crossbyte.events.ProgressEvent.SOCKET_DATA, function(_) {
				var n = s.bytesAvailable;
				events++;
				s.readBytes(sink, 0, n);
				got += n;
			});
		}

		gcOff(true);
		var m0 = reserved();
		var c0 = cpu();
		var t0 = Timer.stamp();
		var filling = true;
		var at = 0;
		while (got < total) {
			if (mode == "bulk") {
				if (sent - got <= 0 && sent < total) {
					// The next burst, once the last has all been read.
					var left = burst;
					while (left > 0) {
						var n = left < chunk.length ? left : chunk.length;
						var end = offer(writer, chunk, 0, n);
						sent += end;
						left -= end;
						if (end < n) {
							// The system's buffer is full: what is left goes
							// as the receiver reads.
							pump();
						}
					}
				}
			} else {
				if (!filling && sent - got <= 0) {
					filling = true;
					cycles++;
				}
				if (filling && sent < total) {
					var want = backlog - (sent - got);
					if (want > chunk.length - at) {
						want = chunk.length - at;
					}
					if (want > 0) {
						var end = offer(writer, chunk, at, at + Std.int(want));
						sent += end - at;
						at = end >= chunk.length ? 0 : end;
					}
					if (sent - got >= backlog) {
						// Full: from here the application drains it.
						filling = !drain;
					}
				}
			}
			pump();
			var held = storage(s.__input);
			if (held > peak) {
				peak = held;
			}
			var data:Dynamic = s.__input == null ? null : (s.__input : Bytes).getData();
			if (data != lastData) {
				grown++;
				lastData = data;
			}
			if (mode != "bulk") {
				// The application takes what it can this pass.
				var n = s.bytesAvailable;
				if (n > read) {
					n = read;
				}
				if (n > 0) {
					events++;
					s.readBytes(sink, 0, n);
					got += n;
				}
			}
		}
		var t1 = Timer.stamp();
		var c1 = cpu();
		var m1 = reserved();
		gcOff(false);
		var mb = total / 1048576;
		var quiet = quietHeld();
		Sys.println('TCPIN label=${opt("label", "")} mode=$mode burst=$burst backlog=$backlog read=$read drain=$drain total=${Math.round(mb)}MB '
			+ 'peak=${kb(peak)}KB events=$events cycles=$cycles storages=$grown alloc/MB=${kb((m1 - m0) / mb)}KB cpu/MB=${ms((c1 - c0) / mb)}ms wall/MB=${ms((t1 - t0) / mb)}ms '
			+ 'pool=${kb(poolHeld())}KB quiet=${kb(quiet)}KB');
		writer.close();
	}

	/** What the pool holds after `quiet` seconds of pumping, or -1. **/
	function quietHeld():Float {
		var quiet = Std.parseFloat(opt("quiet", "0"));
		if (quiet <= 0) {
			return -1024;
		}
		var until = Timer.stamp() + quiet;
		while (Timer.stamp() < until) {
			pump();
			crossbyte.sys.System.sleep(1 / 60);
		}
		return poolHeld();
	}

	function webSocket():Void {
		var size = optInt("size", 1024 * 1024);
		var total = Std.parseFloat(opt("total", "134217728"));
		var server = new crossbyte.net.ServerWebSocket();
		server.maxMessageSize = 64 * 1024 * 1024;
		server.receiveBufferSize = optInt("rcvbuf", 4 * 1024 * 1024);
		var session:crossbyte.net.WebSocket = null;
		server.addEventListener(ServerSocketConnectEvent.CONNECT, (e:ServerSocketConnectEvent) -> session = cast e.socket);
		server.bind(0, "127.0.0.1");
		server.listen();
		last = Timer.stamp();

		var writer = new sys.net.Socket();
		writer.connect(new sys.net.Host("127.0.0.1"), server.localPort);
		writer.output.writeString("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
			+ "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n");
		writer.setBlocking(false);
		var deadline = Timer.stamp() + 10;
		while (session == null && Timer.stamp() < deadline) {
			pump();
		}
		if (session == null) {
			Sys.println("the session never opened");
			Sys.exit(1);
		}
		var answer = Bytes.alloc(4096);
		try writer.input.readBytes(answer, 0, answer.length) catch (_:Dynamic) {}

		// One masked binary frame, sent over and over.
		var head = size < 126 ? 6 : (size < 65536 ? 8 : 14);
		var frame = Bytes.alloc(head + size);
		frame.set(0, 0x82);
		if (size < 126) {
			frame.set(1, 0x80 | size);
		} else if (size < 65536) {
			frame.set(1, 0x80 | 126);
			frame.set(2, size >> 8);
			frame.set(3, size & 0xFF);
		} else {
			frame.set(1, 0x80 | 127);
			for (i in 0...8) {
				frame.set(2 + i, i < 4 ? 0 : (size >> ((7 - i) * 8)) & 0xFF);
			}
		}
		var mask = [0x12, 0x34, 0x56, 0x78];
		for (i in 0...4) {
			frame.set(head - 4 + i, mask[i]);
		}
		for (i in 0...size) {
			frame.set(head + i, (i & 0xFF) ^ mask[i & 3]);
		}

		var got = 0.0;
		var messages = 0;
		var peak = 0.0;
		session.addEventListener(WebSocketMessageEvent.MESSAGE, function(e:WebSocketMessageEvent) {
			got += e.data.length;
			messages++;
		});
		var sent = 0.0;
		gcOff(true);
		var m0 = reserved();
		var c0 = cpu();
		var t0 = Timer.stamp();
		while (got < total) {
			if (sent <= got) {
				var at = 0;
				while (at < frame.length) {
					at = offer(writer, frame, at, frame.length);
					if (at < frame.length) {
						pump();
					}
				}
				sent += size;
			}
			pump();
			var internal = @:privateAccess session.__webSocket;
			if (internal != null) {
				var held = storage(@:privateAccess internal.__input);
				if (held > peak) {
					peak = held;
				}
			}
		}
		var t1 = Timer.stamp();
		var c1 = cpu();
		var m1 = reserved();
		gcOff(false);
		var mb = total / 1048576;
		var quiet = quietHeld();
		Sys.println('TCPIN label=${opt("label", "")} mode=ws size=$size total=${Math.round(mb)}MB messages=$messages '
			+ 'peak=${kb(peak)}KB alloc/MB=${kb((m1 - m0) / mb)}KB cpu/MB=${ms((c1 - c0) / mb)}ms wall/MB=${ms((t1 - t0) / mb)}ms '
			+ 'pool=${kb(poolHeld())}KB quiet=${kb(quiet)}KB');
		writer.close();
	}

	static function ms(x:Float):Float {
		return Math.round(x * 100000) / 100;
	}

	static function kb(x:Float):Float {
		return Math.round(x / 102.4) / 10;
	}
}
