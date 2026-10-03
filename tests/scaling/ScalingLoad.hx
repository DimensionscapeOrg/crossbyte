import haxe.io.Bytes;
import sys.net.Host;
import sys.net.Socket;
import sys.thread.Deque;
import sys.thread.Mutex;
import sys.thread.Thread;

/**
	The client half of the scaling measurement: small GETs over kept-alive
	connections, from threads of plain blocking sockets in a process of its
	own, so it can be pinned to CPUs the server is not on.

	    ScalingLoad <port> <connections> <seconds> <h1|h2> [depth]

	Each connection keeps `depth` requests in flight -- pipelined over
	HTTP/1.1, concurrent streams over HTTP/2 (prior knowledge, cleartext) --
	and counts the responses that arrive after a second's warm-up, for
	`seconds`. Prints `RPS <requests per second> requests=<n> errors=<n>`.
**/
class ScalingLoad {
	private static final __lock:Mutex = new Mutex();
	private static var __done:Int = 0;
	private static var __errors:Int = 0;
	private static final __finished:Deque<Bool> = new Deque();

	public static function main():Void {
		var args:Array<String> = Sys.args();
		var port:Int = Std.parseInt(args[0]);
		var connections:Int = Std.parseInt(args[1]);
		var seconds:Float = Std.parseFloat(args[2]);
		var http2:Bool = args[3] == "h2";
		var depth:Int = args.length > 4 ? Std.parseInt(args[4]) : 1;

		var start:Float = haxe.Timer.stamp() + 1.0;
		var end:Float = start + seconds;
		for (_ in 0...connections) {
			Thread.create(() -> {
				var counted:Int = 0;
				var failed:Bool = false;
				try {
					counted = http2 ? __runHttp2(port, depth, start, end) : __runHttp1(port, depth, start, end);
				} catch (_:Dynamic) {
					failed = true;
				}
				__lock.acquire();
				__done += counted;
				if (failed) {
					__errors++;
				}
				__lock.release();
				__finished.add(true);
			});
		}

		for (_ in 0...connections) {
			__finished.pop(true);
		}
		Sys.println('RPS ${Math.round(__done / seconds)} requests=$__done errors=$__errors');
	}

	private static function __connect(port:Int):Socket {
		var socket:Socket = new Socket();
		socket.connect(new Host("127.0.0.1"), port);
		socket.setFastSend(true);
		socket.setTimeout(10);
		return socket;
	}

	/** Responses counted between `start` and `end`, `depth` pipelined at a time. **/
	private static function __runHttp1(port:Int, depth:Int, start:Float, end:Float):Int {
		var socket:Socket = __connect(port);
		var request:Bytes = Bytes.ofString("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n");
		var batch:Bytes = Bytes.alloc(request.length * depth);
		for (i in 0...depth) {
			batch.blit(i * request.length, request, 0, request.length);
		}
		var reader:ResponseReader = new ResponseReader(socket);
		var counted:Int = 0;
		while (true) {
			var now:Float = haxe.Timer.stamp();
			if (now >= end) {
				break;
			}
			socket.output.writeFullBytes(batch, 0, batch.length);
			for (_ in 0...depth) {
				reader.next();
			}
			if (now >= start) {
				counted += depth;
			}
		}
		socket.close();
		return counted;
	}

	/** Responses counted between `start` and `end`, `depth` streams at a time. **/
	private static function __runHttp2(port:Int, depth:Int, start:Float, end:Float):Int {
		var socket:Socket = __connect(port);
		var out = new haxe.io.BytesBuffer();
		out.addString("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n");
		__frame(out, 4, 0, 0, Bytes.alloc(0));
		socket.output.write(out.getBytes());

		// :method GET, :scheme http, :path /, :authority by its literal.
		var block:haxe.io.BytesBuffer = new haxe.io.BytesBuffer();
		block.addByte(0x82);
		block.addByte(0x86);
		block.addByte(0x84);
		block.addByte(0x01);
		block.addByte(9);
		block.addString("127.0.0.1");
		var headers:Bytes = block.getBytes();

		var frames:FrameReader = new FrameReader(socket);
		var stream:Int = 1;
		var counted:Int = 0;
		var unacknowledged:Int = 0;
		while (true) {
			var now:Float = haxe.Timer.stamp();
			if (now >= end) {
				break;
			}
			var send = new haxe.io.BytesBuffer();
			for (_ in 0...depth) {
				__frame(send, 1, 0x05, stream, headers);
				stream += 2;
			}
			socket.output.write(send.getBytes());

			var open:Int = depth;
			while (open > 0) {
				frames.next();
				if (frames.type == 4 && (frames.flags & 1) == 0) {
					var ack = new haxe.io.BytesBuffer();
					__frame(ack, 4, 1, 0, Bytes.alloc(0));
					socket.output.write(ack.getBytes());
				} else if (frames.type == 0) {
					unacknowledged += frames.length;
					if ((frames.flags & 1) != 0) {
						open--;
					}
				} else if (frames.type == 1 && (frames.flags & 1) != 0) {
					open--;
				} else if (frames.type == 7) {
					throw "GOAWAY";
				}
			}
			if (unacknowledged > 32768) {
				// The connection's window back, in one frame for many responses.
				var update = new haxe.io.BytesBuffer();
				var increment:Bytes = Bytes.alloc(4);
				increment.set(0, (unacknowledged >> 24) & 0x7F);
				increment.set(1, (unacknowledged >> 16) & 0xFF);
				increment.set(2, (unacknowledged >> 8) & 0xFF);
				increment.set(3, unacknowledged & 0xFF);
				__frame(update, 8, 0, 0, increment);
				socket.output.write(update.getBytes());
				unacknowledged = 0;
			}
			if (now >= start) {
				counted += depth;
			}
		}
		socket.close();
		return counted;
	}

	private static function __frame(into:haxe.io.BytesBuffer, type:Int, flags:Int, stream:Int, payload:Bytes):Void {
		into.addByte((payload.length >> 16) & 0xFF);
		into.addByte((payload.length >> 8) & 0xFF);
		into.addByte(payload.length & 0xFF);
		into.addByte(type);
		into.addByte(flags);
		into.addByte((stream >> 24) & 0x7F);
		into.addByte((stream >> 16) & 0xFF);
		into.addByte((stream >> 8) & 0xFF);
		into.addByte(stream & 0xFF);
		into.add(payload);
	}
}

/** Buffered reads off a blocking socket. **/
class Buffered {
	private var __socket:Socket;
	private var __buffer:Bytes = Bytes.alloc(65536);
	private var __start:Int = 0;
	private var __end:Int = 0;

	public function new(socket:Socket) {
		__socket = socket;
	}

	/** At least `count` bytes available from __start, reading as needed. **/
	private function __need(count:Int):Void {
		if (__end - __start >= count) {
			return;
		}
		if (__start > 0) {
			__buffer.blit(0, __buffer, __start, __end - __start);
			__end -= __start;
			__start = 0;
		}
		while (__end < count) {
			var got:Int = __socket.input.readBytes(__buffer, __end, __buffer.length - __end);
			if (got <= 0) {
				throw "closed";
			}
			__end += got;
		}
	}
}

/** One HTTP/1.1 response at a time: its head, then its Content-Length of body. **/
class ResponseReader extends Buffered {
	public function next():Void {
		var scanned:Int = 0;
		while (true) {
			__need(scanned + 4);
			var found:Int = -1;
			var i:Int = __start + scanned;
			while (i + 3 < __end) {
				if (__buffer.get(i) == 13 && __buffer.get(i + 1) == 10 && __buffer.get(i + 2) == 13 && __buffer.get(i + 3) == 10) {
					found = i;
					break;
				}
				i++;
			}
			if (found >= 0) {
				var head:String = __buffer.getString(__start, found - __start);
				var length:Int = 0;
				var at:Int = head.toLowerCase().indexOf("content-length:");
				if (at >= 0) {
					var tail:String = head.substr(at + 15);
					var stop:Int = tail.indexOf("\r");
					length = Std.parseInt(StringTools.trim(stop >= 0 ? tail.substr(0, stop) : tail));
				}
				var total:Int = found + 4 - __start + length;
				__need(total);
				__start += total;
				return;
			}
			scanned = __end - __start - 3;
			if (scanned < 0) {
				scanned = 0;
			}
			__need(__end - __start + 1);
		}
	}
}

/** One HTTP/2 frame at a time. **/
class FrameReader extends Buffered {
	public var type:Int = 0;
	public var flags:Int = 0;
	public var length:Int = 0;

	public function next():Void {
		__need(9);
		length = (__buffer.get(__start) << 16) | (__buffer.get(__start + 1) << 8) | __buffer.get(__start + 2);
		type = __buffer.get(__start + 3);
		flags = __buffer.get(__start + 4);
		__need(9 + length);
		__start += 9 + length;
	}
}
