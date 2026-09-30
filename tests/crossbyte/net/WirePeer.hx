package crossbyte.net;

import haxe.io.Bytes;
import haxe.io.BytesBuffer;

/**
	A WebSocket peer written by hand, for a test to say exactly what goes on
	the wire and read exactly what comes back -- on every target, Node
	included, which `RawWebSocketClient` cannot reach.

	Nothing here blocks. Natively the socket is read only once `select` says
	it has something, which works where a socket cannot be made non-blocking
	(eval); on Node it arrives by event. Either way `poll()` is called from a
	`NetPump` wait, and what has arrived is in `received`.
**/
class WirePeer {
	public static inline var TEXT:Int = 0x1;
	public static inline var BINARY:Int = 0x2;
	public static inline var CLOSE:Int = 0x8;
	public static inline var PING:Int = 0x9;
	public static inline var PONG:Int = 0xA;

	/** Everything that has arrived, from the first byte. **/
	public var received(default, null):BytesBuffer = new BytesBuffer();

	/** Whether the other end has closed the connection. **/
	public var ended(default, null):Bool = false;

	#if nodejs
	private var __socket:js.node.net.Socket;
	#else
	private var __socket:sys.net.Socket;
	private var __scratch:Bytes = Bytes.alloc(64 * 1024);
	#end

	public function new(port:Int) {
		#if nodejs
		__socket = js.node.Net.connect({port: port, host: "127.0.0.1"});
		__socket.on("data", function(chunk:js.node.Buffer) {
			received.addBytes(Bytes.ofData(chunk.buffer.slice(chunk.byteOffset, chunk.byteOffset + chunk.byteLength)), 0, chunk.byteLength);
		});
		__socket.on("end", function() ended = true);
		__socket.on("close", function(_) ended = true);
		__socket.on("error", function(_) ended = true);
		#else
		__socket = new sys.net.Socket();
		__socket.connect(new sys.net.Host("127.0.0.1"), port);
		__socket.setBlocking(false);
		#end
	}

	/** Sends an upgrade request for `target`, with any headers given. **/
	public function upgrade(target:String = "/", ?headers:Array<String>):Void {
		var lines:Array<String> = [
			'GET $target HTTP/1.1',
			"Host: 127.0.0.1",
			"Upgrade: websocket",
			"Connection: Upgrade",
			"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
			"Sec-WebSocket-Version: 13"
		];
		if (headers != null) {
			for (header in headers) {
				lines.push(header);
			}
		}
		send(Bytes.ofString(lines.join("\r\n") + "\r\n\r\n"));
	}

	/**
		Sends one frame, masked as a client's must be. `rsv1` marks it
		compressed, as permessage-deflate does; `fin` false leaves the
		message open for a continuation.
	**/
	public function sendFrame(opcode:Int, payload:Bytes, rsv1:Bool = false, fin:Bool = true):Void {
		var out = new BytesBuffer();
		var length:Int = payload == null ? 0 : payload.length;
		out.addByte((fin ? 0x80 : 0x00) | (rsv1 ? 0x40 : 0x00) | opcode);
		if (length < 126) {
			out.addByte(0x80 | length);
		} else {
			out.addByte(0x80 | 126);
			out.addByte((length >> 8) & 0xFF);
			out.addByte(length & 0xFF);
		}
		var mask:Array<Int> = [0x37, 0xFA, 0x21, 0x3D];
		for (b in mask) {
			out.addByte(b);
		}
		for (i in 0...length) {
			out.addByte(payload.get(i) ^ mask[i & 3]);
		}
		send(out.getBytes());
	}

	public function send(bytes:Bytes):Void {
		#if nodejs
		__socket.write(js.node.Buffer.hxFromBytes(bytes));
		#else
		var sent:Int = 0;
		while (sent < bytes.length) {
			try {
				sent += __socket.output.writeBytes(bytes, sent, bytes.length - sent);
			} catch (e:Dynamic) {
				if (Std.string(e).indexOf("Block") < 0) {
					ended = true;
					return;
				}
			}
		}
		#end
	}

	/**
		Stops reading, so what is sent here backs up. Natively nothing is read
		except by `poll()` anyway; Node reads on its own until told not to.
	**/
	public function pause():Void {
		#if nodejs
		__socket.pause();
		#end
	}

	/** Takes in whatever has arrived, where arriving is not Node's doing. **/
	public function poll():Void {
		#if !nodejs
		if (ended) {
			return;
		}
		try {
			while (sys.net.Socket.select([__socket], [], [], 0).read.length > 0) {
				var got:Int = __socket.input.readBytes(__scratch, 0, __scratch.length);
				if (got <= 0) {
					ended = true;
					return;
				}
				received.addBytes(__scratch, 0, got);
			}
		} catch (_:haxe.io.Eof) {
			ended = true;
		} catch (e:Dynamic) {
			if (Std.string(e).indexOf("Block") < 0) {
				ended = true;
			}
		}
		#end
	}

	/** The response head, once all of it has arrived; `null` until then. **/
	public function head():Null<String> {
		var bytes:Bytes = __all();
		var end:Int = __headEnd(bytes);
		return end < 0 ? null : bytes.getString(0, end);
	}

	/**
		The frames that have arrived after the response head, whole ones only:
		a server's, so unmasked.
	**/
	public function frames():Array<WireFrame> {
		var bytes:Bytes = __all();
		var at:Int = __headEnd(bytes);
		var out:Array<WireFrame> = [];
		if (at < 0) {
			return out;
		}
		at += 4;

		while (at + 2 <= bytes.length) {
			var opcode:Int = bytes.get(at) & 0x0F;
			var length:Int = bytes.get(at + 1) & 0x7F;
			var start:Int = at + 2;
			if (length == 126) {
				if (at + 4 > bytes.length) {
					break;
				}
				length = (bytes.get(at + 2) << 8) | bytes.get(at + 3);
				start = at + 4;
			} else if (length == 127) {
				if (at + 10 > bytes.length) {
					break;
				}
				length = (bytes.get(at + 6) << 24) | (bytes.get(at + 7) << 16) | (bytes.get(at + 8) << 8) | bytes.get(at + 9);
				start = at + 10;
			}
			if (start + length > bytes.length) {
				break;
			}
			out.push({opcode: opcode, payload: bytes.sub(start, length), rsv1: (bytes.get(at) & 0x40) != 0});
			at = start + length;
		}

		return out;
	}

	/** The frames of one kind. **/
	public function framesOf(opcode:Int):Array<WireFrame> {
		return frames().filter(frame -> frame.opcode == opcode);
	}

	/**
		Hangs up as soon as the connection is up, as a load balancer's health
		check does. Natively the connect has already finished; on Node it
		finishes on a later turn, and closing before then would abort it
		rather than hang up on anyone.
	**/
	public function hangUp():Void {
		#if nodejs
		__socket.on("connect", function() __socket.end());
		#else
		close();
		#end
	}

	/** Sends this side's FIN and goes on reading: a half-close. **/
	public function shutdownWrite():Void {
		try {
			#if nodejs
			__socket.end();
			#else
			__socket.shutdown(false, true);
			#end
		} catch (_:Dynamic) {}
	}

	/** Everything that has arrived, read as text. **/
	public function text():String {
		return __all().toString();
	}

	public function close():Void {
		try {
			#if nodejs
			__socket.destroy();
			#else
			__socket.close();
			#end
		} catch (_:Dynamic) {}
	}

	/** Where the blank line ending the response head starts, or -1. **/
	private static function __headEnd(bytes:Bytes):Int {
		var i:Int = 0;
		while (i + 3 < bytes.length) {
			if (bytes.get(i) == 13 && bytes.get(i + 1) == 10 && bytes.get(i + 2) == 13 && bytes.get(i + 3) == 10) {
				return i;
			}
			i++;
		}
		return -1;
	}

	private function __all():Bytes {
		// A BytesBuffer can be read only once, so it is read into a fresh one
		// that carries on collecting.
		var bytes:Bytes = received.getBytes();
		received = new BytesBuffer();
		received.addBytes(bytes, 0, bytes.length);
		return bytes;
	}
}

typedef WireFrame = {
	var opcode:Int;
	var payload:Bytes;
	/** Set on the first frame of a compressed message. **/
	var rsv1:Bool;
}
