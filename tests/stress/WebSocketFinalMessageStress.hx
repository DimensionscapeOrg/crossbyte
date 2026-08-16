package stress;

import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.ProgressEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.io.ByteArray;
import crossbyte.net.ServerWebSocket;
import crossbyte.net.WebSocket;
import haxe.io.Bytes;

/**
 * A peer sends a complete message and immediately disconnects.
 *
 * Invariant: the message is delivered. A disconnect does not entitle the
 * read loop to discard bytes it already read.
 *
 * The read loop treated "we have data" and "the peer went away" as
 * alternatives, so when a single pass read a whole frame and then hit the
 * peer's FIN, it closed the session and dropped the frame. The last
 * message before a disconnect is precisely the one worth keeping — a
 * goodbye, a final ack, an unsent edit — and losing it looks to the
 * application exactly like the peer never sent it.
 *
 * Writing the frame and closing before the server ever ticks is what
 * makes this deterministic: the socket then holds the frame and the FIN
 * together, so one read returns data and the next raises `Eof`, which is
 * the ordering that lost the message.
 */
class WebSocketFinalMessageStress implements StressCase {
	private static inline final MESSAGE:String = "the last thing said before hanging up";

	private var received:String = null;
	private var sessionClosed:Bool = false;

	public function new() {}

	public function run():StressResult {
		var runtime:CrossByte = CrossByte.current();
		var server:ServerWebSocket = new ServerWebSocket();

		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent):Void {
			var ws:WebSocket = cast e.socket;

			ws.addEventListener(ProgressEvent.SOCKET_DATA, function(_):Void {
				received = ws.readUTFBytes(ws.bytesAvailable);
			});
			ws.addEventListener(Event.CLOSE, function(_):Void {
				sessionClosed = true;
			});
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

		// Send the frame and hang up without pumping in between, so the
		// server sees payload and disconnect in the same read pass.
		var frame:Bytes = __maskedTextFrame(MESSAGE);
		client.output.writeBytes(frame, 0, frame.length);
		client.output.flush();
		client.close();

		var deadline:Float = Sys.time() + 10;
		while (!sessionClosed && Sys.time() < deadline) {
			@:privateAccess runtime.pump(0.008);
		}

		// Let any delivery that trails the close land.
		var settle:Float = Sys.time() + 1;
		while (Sys.time() < settle) {
			@:privateAccess runtime.pump(0.008);
		}

		try {
			server.close();
		} catch (_:Dynamic) {}

		var passed:Bool = received == MESSAGE && sessionClosed;

		return {
			name: "WebSocket delivers the final message before a disconnect",
			passed: passed,
			details: [
				'handshake=$status',
				'expected="$MESSAGE"',
				'received=' + (received == null ? "<nothing>" : '"$received"'),
				'session closed=$sessionClosed'
			]
		};
	}

	/** Builds a client-masked text frame, as RFC 6455 requires of clients. */
	private function __maskedTextFrame(text:String):Bytes {
		var payload:Bytes = Bytes.ofString(text);
		var mask:Array<Int> = [0x37, 0xfa, 0x21, 0x3d];
		var frame:ByteArray = new ByteArray();
		frame.endian = BIG_ENDIAN;

		frame.writeByte(0x81); // FIN + text opcode
		frame.writeByte(0x80 | payload.length); // mask bit + length (< 126)
		for (b in mask) {
			frame.writeByte(b);
		}
		for (i in 0...payload.length) {
			frame.writeByte(payload.get(i) ^ mask[i & 0x03]);
		}

		var out:Bytes = Bytes.alloc(frame.length);
		out.blit(0, frame, 0, frame.length);
		return out;
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
