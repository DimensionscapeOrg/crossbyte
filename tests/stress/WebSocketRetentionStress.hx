package stress;

import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.io.ByteArray;
import crossbyte.net.ServerWebSocket;
import crossbyte.net.WebSocket;
import haxe.io.Bytes;

/**
 * Sends far more than a socket send buffer holds to a peer that stalls
 * before draining.
 *
 * Invariant: every frame arrives, intact and in order, and the session
 * survives.
 *
 * This guards a bug that shipped in both directions at once. A full send
 * buffer is routine on a non-blocking socket, but the two write sites
 * disagreed about what it meant: one caught the blocked write and only
 * traced it, silently discarding the bytes, while the other treated the
 * same condition as fatal and closed the session with 1006. So a peer
 * that paused for a moment either lost messages or lost the connection.
 */
class WebSocketRetentionStress implements StressCase {
	private static inline final FRAMES:Int = 200;
	// Comfortably past any loopback send buffer, so a run that never
	// blocks — and therefore never exercises the retry — cannot pass by
	// accident.
	private static inline final PAYLOAD:Int = 16384;

	private var queued:Int = 0;
	private var closedEarly:Bool = false;

	public function new() {}

	public function run():StressResult {
		var runtime:CrossByte = CrossByte.current();
		var server:ServerWebSocket = new ServerWebSocket();

		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent):Void {
			var ws:WebSocket = cast e.socket;
			ws.addEventListener(Event.CLOSE, function(_):Void {
				closedEarly = true;
			});
			ws.addEventListener(IOErrorEvent.IO_ERROR, function(_):Void {
				closedEarly = true;
			});

			for (i in 0...FRAMES) {
				var payload:ByteArray = new ByteArray();
				for (_ in 0...PAYLOAD) {
					payload.writeByte(i % 251);
				}

				ws.writeBytes(payload, 0, payload.length);
				ws.flush();
				queued++;
			}
		});

		server.bind(0, "127.0.0.1");
		server.listen(4);
		var port:Int = server.localPort;

		var client:sys.net.Socket = new sys.net.Socket();
		client.connect(new sys.net.Host("127.0.0.1"), port);
		client.setBlocking(false);

		var key:String = haxe.crypto.Base64.encode(Bytes.ofString("0123456789abcdef"));
		client.output.writeString("GET / HTTP/1.1\r\n"
			+ 'Host: 127.0.0.1:$port\r\n'
			+ "Upgrade: websocket\r\n"
			+ "Connection: Upgrade\r\n"
			+ 'Sec-WebSocket-Key: $key\r\n'
			+ "Sec-WebSocket-Version: 13\r\n\r\n");
		client.output.flush();

		var status:String = __readLine(runtime, client);
		while (__readLine(runtime, client) != "") {}

		// Stall: let the server fill the socket and block on the rest.
		var stallUntil:Float = Sys.time() + 10;
		while (queued < FRAMES && Sys.time() < stallUntil) {
			@:privateAccess runtime.pump(0.016);
		}

		var received:Int = 0;
		var corrupt:Int = 0;
		var deadline:Float = Sys.time() + 40;

		while (received < FRAMES && Sys.time() < deadline) {
			var header:Bytes = __readExactly(runtime, client, 2, deadline);
			if (header == null) {
				break;
			}

			var lenByte:Int = header.get(1) & 0x7F;
			var len:Int = lenByte;
			if (lenByte == 126) {
				var ext:Bytes = __readExactly(runtime, client, 2, deadline);
				if (ext == null) {
					break;
				}
				len = (ext.get(0) << 8) | ext.get(1);
			} else if (lenByte == 127) {
				var ext:Bytes = __readExactly(runtime, client, 8, deadline);
				if (ext == null) {
					break;
				}
				len = 0;
				for (i in 4...8) {
					len = (len << 8) | ext.get(i);
				}
			}

			var body:Bytes = len > 0 ? __readExactly(runtime, client, len, deadline) : Bytes.alloc(0);
			if (body == null) {
				break;
			}

			// Frame N carries the byte value N % 251 throughout, so a
			// dropped frame shows up as the wrong value here rather than
			// merely a short count.
			var want:Int = received % 251;
			if (len != PAYLOAD || body.get(0) != want || body.get(len - 1) != want) {
				corrupt++;
			}
			received++;
		}

		try {
			client.close();
		} catch (_:Dynamic) {}
		try {
			server.close();
		} catch (_:Dynamic) {}

		var passed:Bool = received == FRAMES && corrupt == 0 && !closedEarly;

		return {
			name: "WebSocket write retention under a stalled peer",
			passed: passed,
			details: [
				'handshake=$status',
				'frames queued=$queued of $FRAMES ($PAYLOAD bytes each)',
				'frames received=$received corrupt/out-of-order=$corrupt',
				'session closed early=$closedEarly'
			]
		};
	}

	/**
	 * Reads exactly `n` bytes, pumping the runtime whenever the socket has
	 * nothing yet, so the server keeps retrying its blocked writes.
	 */
	private function __readExactly(runtime:CrossByte, sock:sys.net.Socket, n:Int, deadline:Float):Bytes {
		var out:Bytes = Bytes.alloc(n);
		var got:Int = 0;

		while (got < n && Sys.time() < deadline) {
			try {
				var read:Int = sock.input.readBytes(out, got, n - got);
				if (read <= 0) {
					@:privateAccess runtime.pump(0.004);
				} else {
					got += read;
				}
			} catch (_:haxe.io.Eof) {
				return null;
			} catch (e:Dynamic) {
				// `haxe.io.Error.Blocked` stringifies as "Blocked"; the ssl
				// layer reports "Blocking" before it is mapped to a type.
				if (Std.string(e).indexOf("Block") < 0) {
					return null;
				}
				@:privateAccess runtime.pump(0.004);
			}
		}

		return got == n ? out : null;
	}

	private function __readLine(runtime:CrossByte, sock:sys.net.Socket):String {
		var buf:StringBuf = new StringBuf();
		var deadline:Float = Sys.time() + 15;

		while (Sys.time() < deadline) {
			try {
				var c:Int = sock.input.readByte();
				if (c == 10) {
					var line:String = buf.toString();
					return line.charAt(line.length - 1) == "\r" ? line.substr(0, line.length - 1) : line;
				}
				buf.addChar(c);
			} catch (e:Dynamic) {
				if (Std.string(e).indexOf("Block") < 0) {
					return buf.toString();
				}
				@:privateAccess runtime.pump(0.004);
			}
		}

		return buf.toString();
	}
}
