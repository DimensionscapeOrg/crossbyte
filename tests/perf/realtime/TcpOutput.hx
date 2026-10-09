import crossbyte.core.HostApplication;
import crossbyte.events.ProgressEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.io.ByteArray;
import crossbyte.net.ServerSocket;
import crossbyte.net.Socket;
import haxe.Timer;

/**
	What a TCP connection's output buffer costs, natively, in the cases a
	pool of chunks would change:

	- `mode=broadcast`: `connections` accepted connections, each sent a
	  `size`-byte message in one pass, the clients (in this process) reading
	  everything; `bursts` broadcasts with `quiet` seconds after each, then
	  `steady` broadcasts at 30 a second. Reports the sends' and the pass's
	  time, what the server's connections hold in output storage after a
	  broadcast and after the quiet, and the bytes the process allocated per
	  broadcast (collection off, the growth of what the collector reserved,
	  over the steady run).
	- `mode=slow`: one connection whose reader takes `read` bytes a pass
	  through a plain socket with a 64 KB receive buffer, while the server
	  keeps `backlog` bytes waiting, writing `size` at a time, until `total`
	  bytes have gone. Reports the output storage at its largest, the bytes
	  allocated per megabyte delivered, and CPU and wall per megabyte.

	Arguments: mode (broadcast), connections (2000), size (1024), bursts (3),
	quiet (12), steady (60); for slow: backlog (8388608), size (65536), read
	(16384), total (268435456); label.
**/
@:access(crossbyte.net.Socket)
class TcpOutput extends HostApplication {
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
		new TcpOutput().run();
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

	static function reserved():Float {
		#if cpp
		return cpp.vm.Gc.memInfo64(cpp.vm.Gc.MEM_INFO_RESERVED);
		#else
		return 0;
		#end
	}

	static function large():Float {
		#if cpp
		return cpp.vm.Gc.memInfo64(cpp.vm.Gc.MEM_INFO_LARGE);
		#else
		return 0;
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

	/** Output storage the server's connections hold. **/
	function outputStorage():Float {
		var total = 0.0;
		for (s in accepted) {
			if (s.__output != null) {
				total += @:privateAccess (s.__output : crossbyte.io.ByteArray.ByteArrayData).__length;
			}
		}
		return total;
	}

	function run():Void {
		var server = new ServerSocket();
		server.addEventListener(ServerSocketConnectEvent.CONNECT, (e:ServerSocketConnectEvent) -> accepted.push(e.socket));
		server.bind(0, "127.0.0.1");
		server.listen(1024);
		last = Timer.stamp();
		if (opt("mode", "broadcast") == "ws") {
			server.close();
			webSocket();
		} else if (opt("mode", "broadcast") == "slow") {
			slow(server);
		} else {
			broadcast(server);
		}
		Sys.exit(0);
	}

	function broadcast(server:ServerSocket):Void {
		var count = optInt("connections", 2000);
		var size = optInt("size", 1024);
		var message = new ByteArray();
		message.length = size;
		var clients:Array<Socket> = [];
		var got = 0.0;
		var sink = new ByteArray();
		for (i in 0...count) {
			var c = new Socket();
			c.addEventListener(ProgressEvent.SOCKET_DATA, function(_) {
				var n = c.bytesAvailable;
				got += n;
				c.readBytes(sink, 0, n);
				sink.length = 0;
			});
			c.connect("127.0.0.1", server.localPort);
			clients.push(c);
			if (i % 100 == 99) {
				pump();
			}
		}
		var deadline = Timer.stamp() + 60;
		while (accepted.length < count && Timer.stamp() < deadline) {
			pump();
			crossbyte.sys.System.sleep(0.001);
		}
		if (accepted.length < count) {
			Sys.println('only ${accepted.length} of $count connected');
			Sys.exit(1);
		}

		var writes:Array<Float> = [];
		var flushes:Array<Float> = [];
		function once():Void {
			var want = got + count * size;
			var t0 = Timer.stamp();
			for (s in accepted) {
				s.writeBytes(message, 0, size);
			}
			var t1 = Timer.stamp();
			@:privateAccess crossbyte.core.CrossByte.current().__flushHeld();
			var t2 = Timer.stamp();
			writes.push(t1 - t0);
			flushes.push(t2 - t1);
			var limit = Timer.stamp() + 10;
			while (got < want && Timer.stamp() < limit) {
				pump();
			}
		}

		var line = 'TCPOUT label=${opt("label", "")} mode=broadcast connections=$count size=$size';
		var quiet = Std.parseFloat(opt("quiet", "12"));
		for (b in 0...optInt("bursts", 3)) {
			once();
			var held = outputStorage();
			var until = Timer.stamp() + quiet;
			while (Timer.stamp() < until) {
				pump();
				crossbyte.sys.System.sleep(1 / 60);
			}
			line += ' b$b:write=${ms(writes[b])}ms,flush=${ms(flushes[b])}ms,held=${kb(held)}KB,heldQuiet=${kb(outputStorage())}KB';
		}
		writes = [];
		flushes = [];
		var steady = optInt("steady", 60);
		once();
		gcOff(true);
		var m0 = reserved();
		for (_ in 0...steady) {
			once();
			var until = Timer.stamp() + 1 / 30;
			while (Timer.stamp() < until) {
				pump();
			}
		}
		var m1 = reserved();
		gcOff(false);
		line += ' steady:write=${ms(median(writes))}ms,flush=${ms(median(flushes))}ms,held=${kb(outputStorage())}KB,alloc=${kb((m1 - m0) / steady)}KB';
		Sys.println(line);
	}

	function slow(server:ServerSocket):Void {
		var backlog = optInt("backlog", 8 * 1024 * 1024);
		var size = optInt("size", 65536);
		var read = optInt("read", 16384);
		var total = Std.parseFloat(opt("total", "268435456"));
		var message = new ByteArray();
		message.length = size;

		var reader = new sys.net.Socket();
		reader.setFastSend(true);
		reader.connect(new sys.net.Host("127.0.0.1"), server.localPort);
		reader.setBlocking(false);
		var deadline = Timer.stamp() + 10;
		while (accepted.length < 1 && Timer.stamp() < deadline) {
			pump();
		}
		var s = accepted[0];
		// The system's own buffer kept small, so the backlog waits in the
		// socket's output rather than in the kernel.
		var sndbuf = optInt("sndbuf", 0);
		if (sndbuf > 0) {
			s.sendBufferSize = sndbuf;
		}
		var buffer = haxe.io.Bytes.alloc(read);
		var sent = 0.0;
		var got = 0.0;
		var peak = 0.0;
		var replaced = 0;
		var lastOutput = s.__output;
		gcOff(true);
		var m0 = reserved();
		var l0 = large();
		var c0 = Sys.cpuTime();
		var t0 = Timer.stamp();
		while (got < total) {
			while (sent < total && s.outputBufferLength < backlog) {
				s.writeBytes(message, 0, size);
				sent += size;
			}
			pump();
			if (s.__output != lastOutput) {
				replaced++;
				lastOutput = s.__output;
			}
			var storage = outputStorage();
			if (storage > peak) {
				peak = storage;
			}
			try {
				var n = reader.input.readBytes(buffer, 0, read);
				got += n;
			} catch (_:Dynamic) {}
		}
		var t1 = Timer.stamp();
		var c1 = Sys.cpuTime();
		var m1 = reserved();
		var l1 = large();
		gcOff(false);
		var mb = total / 1048576;
		Sys.println('TCPOUT label=${opt("label", "")} mode=slow backlog=$backlog size=$size read=$read total=${Math.round(mb)}MB '
			+ 'peak=${kb(peak)}KB replaced=$replaced alloc/MB=${kb((m1 - m0) / mb)}KB large/MB=${kb((l1 - l0) / mb)}KB cpu/MB=${ms((c1 - c0) / mb)}ms wall/MB=${ms((t1 - t0) / mb)}ms');
		reader.close();
	}

	/**
		`mode=ws`: a ServerWebSocket session sends `size`-byte binary
		messages (16 KB unless given), `burst` bytes of them a pass (1 MB),
		to a plain socket that upgraded by hand and reads whatever arrives,
		until `total` bytes have gone. Reports as `mode=slow` does.
	**/
	function webSocket():Void {
		var size = optInt("size", 16384);
		var burst = optInt("burst", 1024 * 1024);
		var total = Std.parseFloat(opt("total", "268435456"));
		var server = new crossbyte.net.ServerWebSocket();
		var session:crossbyte.net.WebSocket = null;
		server.addEventListener(ServerSocketConnectEvent.CONNECT, (e:ServerSocketConnectEvent) -> session = cast e.socket);
		server.bind(0, "127.0.0.1");
		server.listen();

		var reader = new sys.net.Socket();
		reader.connect(new sys.net.Host("127.0.0.1"), server.localPort);
		reader.output.writeString("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
			+ "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n");
		reader.setBlocking(false);
		var deadline = Timer.stamp() + 10;
		while (session == null && Timer.stamp() < deadline) {
			pump();
		}
		if (session == null) {
			Sys.println("the session never opened");
			Sys.exit(1);
		}
		var message = new ByteArray();
		message.length = size;
		var buffer = haxe.io.Bytes.alloc(65536);
		var sent = 0.0;
		var got = 0.0;
		gcOff(true);
		var m0 = reserved();
		var l0 = large();
		var c0 = Sys.cpuTime();
		var t0 = Timer.stamp();
		while (got < total) {
			var thisPass = 0;
			while (sent < total && thisPass < burst && session.outputBufferLength < burst) {
				session.sendBinary(message);
				sent += size;
				thisPass += size;
			}
			pump();
			while (true) {
				var n = try reader.input.readBytes(buffer, 0, buffer.length) catch (_:Dynamic) -1;
				if (n <= 0) {
					break;
				}
				got += n;
			}
		}
		var t1 = Timer.stamp();
		var c1 = Sys.cpuTime();
		var m1 = reserved();
		var l1 = large();
		gcOff(false);
		var mb = total / 1048576;
		Sys.println('TCPOUT label=${opt("label", "")} mode=ws size=$size burst=$burst total=${Math.round(mb)}MB '
			+ 'alloc/MB=${kb((m1 - m0) / mb)}KB large/MB=${kb((l1 - l0) / mb)}KB cpu/MB=${ms((c1 - c0) / mb)}ms wall/MB=${ms((t1 - t0) / mb)}ms');
		reader.close();
	}

	static function median(values:Array<Float>):Float {
		var sorted = values.copy();
		sorted.sort((a, b) -> a < b ? -1 : (a > b ? 1 : 0));
		return sorted[sorted.length >> 1];
	}

	static function ms(x:Float):Float {
		return Math.round(x * 100000) / 100;
	}

	static function kb(x:Float):Float {
		return Math.round(x / 102.4) / 10;
	}
}
