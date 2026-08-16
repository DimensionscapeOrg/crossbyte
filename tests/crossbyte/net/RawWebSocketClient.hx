package crossbyte.net;

import crossbyte.core.CrossByte;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;

/**
 * One frame read off the wire.
 */
typedef RawFrame = {
	var fin:Bool;
	var opcode:Int;
	var payload:Bytes;
}

/**
 * A WebSocket client built out of a plain socket and hand-written bytes.
 *
 * Everything else that exercises `ServerWebSocket` end to end drives it
 * with CrossByte's own client, which means the two sides agree by
 * construction and a fault only a foreign peer reaches stays invisible.
 * That is not a hypothetical: a server that could not receive a single
 * client message shipped behind exactly that blind spot, because
 * CrossByte's client happened to leave the handshake buffer in a state
 * the parser tolerated.
 *
 * This client therefore composes frames by hand, so a test can send what
 * a browser would send — and, more usefully, what a browser must never
 * send.
 *
 * The runtime is pumped while waiting on the socket, so the server under
 * test makes progress on the same thread.
 */
@:access(crossbyte.core.CrossByte)
class RawWebSocketClient {
	public var handshakeStatus(default, null):String;

	private var __runtime:CrossByte;
	private var __socket:sys.net.Socket;
	private var __maskCounter:Int = 0;
	private var __closed:Bool = false;

	/**
	 * Connects and completes the HTTP upgrade, leaving the session open.
	 */
	public function new(runtime:CrossByte, host:String, port:Int) {
		__runtime = runtime;
		__socket = new sys.net.Socket();
		__socket.connect(new sys.net.Host(host), port);
		__socket.setBlocking(false);

		var key:String = haxe.crypto.Base64.encode(Bytes.ofString("0123456789abcdef"));
		__writeAll(Bytes.ofString("GET / HTTP/1.1\r\n"
			+ 'Host: $host:$port\r\n'
			+ "Upgrade: websocket\r\n"
			+ "Connection: Upgrade\r\n"
			+ 'Sec-WebSocket-Key: $key\r\n'
			+ "Sec-WebSocket-Version: 13\r\n\r\n"));

		handshakeStatus = __readLine();
		// Drain the remaining response headers up to the blank line.
		while (__readLine() != "") {}
	}

	/**
	 * Builds a client frame.
	 *
	 * Every parameter that RFC 6455 constrains is left adjustable, because
	 * the interesting cases are the illegal ones: `masked` false, a
	 * non-zero `rsv`, a control opcode with `fin` false.
	 *
	 * @param rsv Reserved bits, already shifted into their header position.
	 */
	public function frame(opcode:Int, payload:Bytes, fin:Bool = true, masked:Bool = true, rsv:Int = 0):Bytes {
		var out:BytesBuffer = new BytesBuffer();
		out.addByte((fin ? 0x80 : 0x00) | rsv | (opcode & 0x0F));

		var length:Int = payload == null ? 0 : payload.length;
		var maskFlag:Int = masked ? 0x80 : 0x00;

		if (length < 126) {
			out.addByte(maskFlag | length);
		} else if (length < 65536) {
			out.addByte(maskFlag | 126);
			out.addByte((length >> 8) & 0xFF);
			out.addByte(length & 0xFF);
		} else {
			out.addByte(maskFlag | 127);
			// 64-bit length; the high word is always zero at these sizes.
			for (_ in 0...4) {
				out.addByte(0);
			}
			out.addByte((length >>> 24) & 0xFF);
			out.addByte((length >> 16) & 0xFF);
			out.addByte((length >> 8) & 0xFF);
			out.addByte(length & 0xFF);
		}

		if (!masked) {
			if (length > 0) {
				out.addBytes(payload, 0, length);
			}
			return out.getBytes();
		}

		// A fresh mask per frame rather than a fixed one, so a server that
		// unmasks with a stale or hard-coded key fails here.
		var mask:Bytes = Bytes.alloc(4);
		for (i in 0...4) {
			mask.set(i, (__maskCounter * 37 + i * 91 + 13) & 0xFF);
		}
		__maskCounter++;

		out.addBytes(mask, 0, 4);
		for (i in 0...length) {
			out.addByte(payload.get(i) ^ mask.get(i & 0x03));
		}

		return out.getBytes();
	}

	/**
	 * Sends a single frame.
	 */
	public function send(opcode:Int, payload:Bytes, fin:Bool = true, masked:Bool = true, rsv:Int = 0):Void {
		__writeAll(frame(opcode, payload, fin, masked, rsv));
	}

	/**
	 * Sends bytes exactly as given, for cases that need several frames in
	 * one write or a frame deliberately split across writes.
	 */
	public function sendRaw(bytes:Bytes):Void {
		__writeAll(bytes);
	}

	/**
	 * Reads the next frame, or `null` if the peer closed or nothing arrived
	 * before the deadline.
	 */
	public function readFrame(timeoutSeconds:Float = 5.0):Null<RawFrame> {
		var deadline:Float = Sys.time() + timeoutSeconds;

		var header:Bytes = __readExactly(2, deadline);
		if (header == null) {
			return null;
		}

		var first:Int = header.get(0);
		var second:Int = header.get(1);
		var length:Int = second & 0x7F;

		if (length == 126) {
			var ext:Bytes = __readExactly(2, deadline);
			if (ext == null) {
				return null;
			}
			length = (ext.get(0) << 8) | ext.get(1);
		} else if (length == 127) {
			var ext:Bytes = __readExactly(8, deadline);
			if (ext == null) {
				return null;
			}
			length = 0;
			for (i in 4...8) {
				length = (length << 8) | ext.get(i);
			}
		}

		// A server must not mask, so any payload here is read verbatim.
		var payload:Bytes = length > 0 ? __readExactly(length, deadline) : Bytes.alloc(0);
		if (payload == null) {
			return null;
		}

		return {
			fin: (first & 0x80) != 0,
			opcode: first & 0x0F,
			payload: payload
		};
	}

	/**
	 * Waits for the server to drop the connection.
	 *
	 * A protocol error closes the socket without a close frame, so this is
	 * how a rejection is observed from the wire.
	 */
	public function waitForClose(timeoutSeconds:Float = 5.0):Bool {
		var deadline:Float = Sys.time() + timeoutSeconds;
		var scratch:Bytes = Bytes.alloc(256);

		while (Sys.time() < deadline) {
			try {
				if (__socket.input.readBytes(scratch, 0, scratch.length) <= 0) {
					return true;
				}
			} catch (_:haxe.io.Eof) {
				return true;
			} catch (e:Dynamic) {
				if (Std.string(e).indexOf("Block") < 0) {
					// Any other error means the socket is gone too.
					return true;
				}
			}
			__pump();
		}

		return false;
	}

	/**
	 * Runs the server's loop without reading, for cases where the point is
	 * what the server does on its own.
	 */
	public function pumpFor(seconds:Float):Void {
		var until:Float = Sys.time() + seconds;
		while (Sys.time() < until) {
			__pump();
		}
	}

	public function close():Void {
		if (__closed) {
			return;
		}
		__closed = true;
		try {
			__socket.close();
		} catch (_:Dynamic) {}
	}

	private function __pump():Void {
		__runtime.pump(1 / 240, 0);
	}

	private function __writeAll(bytes:Bytes):Void {
		var sent:Int = 0;
		var deadline:Float = Sys.time() + 15;

		while (sent < bytes.length && Sys.time() < deadline) {
			try {
				sent += __socket.output.writeBytes(bytes, sent, bytes.length - sent);
			} catch (e:Dynamic) {
				if (Std.string(e).indexOf("Block") < 0) {
					throw e;
				}
				// The server has to drain before there is room for the rest.
				__pump();
			}
		}

		try {
			__socket.output.flush();
		} catch (_:Dynamic) {}
	}

	private function __readExactly(count:Int, deadline:Float):Null<Bytes> {
		var out:Bytes = Bytes.alloc(count);
		var got:Int = 0;

		while (got < count && Sys.time() < deadline) {
			try {
				var read:Int = __socket.input.readBytes(out, got, count - got);
				if (read <= 0) {
					return null;
				}
				got += read;
			} catch (_:haxe.io.Eof) {
				return null;
			} catch (e:Dynamic) {
				// haxe.io.Error.Blocked stringifies as "Blocked"; the ssl layer
				// reports "Blocking" before it is mapped to a type.
				if (Std.string(e).indexOf("Block") < 0) {
					return null;
				}
				__pump();
			}
		}

		return got == count ? out : null;
	}

	private function __readLine():String {
		var buf:StringBuf = new StringBuf();
		var deadline:Float = Sys.time() + 15;

		while (Sys.time() < deadline) {
			try {
				var c:Int = __socket.input.readByte();
				if (c == 10) {
					var line:String = buf.toString();
					return line.charAt(line.length - 1) == "\r" ? line.substr(0, line.length - 1) : line;
				}
				buf.addChar(c);
			} catch (e:Dynamic) {
				if (Std.string(e).indexOf("Block") < 0) {
					return buf.toString();
				}
				__pump();
			}
		}

		return buf.toString();
	}
}
