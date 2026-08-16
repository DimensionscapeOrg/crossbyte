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
 * Writes hard at a WebSocket peer that never reads a byte.
 *
 * Invariant: a session carrying `ServerWebSocket.maxOutputBufferSize`
 * stops growing and is closed, rather than retaining frames until the
 * process runs out of memory.
 *
 * The complement of `WebSocketRetentionStress`: there the peer eventually
 * drained and losing a frame would have been the bug, so retention is
 * unconditional. Retention without a bound is its own outage, and the two
 * cases together pin the boundary between them.
 */
class WebSocketBufferLimitStress implements StressCase {
	private static inline final LIMIT:Int = 256 * 1024;
	private static inline final PAYLOAD:Int = 16384;
	// Far more than the limit plus any receive window, so an unbounded
	// buffer would be unmistakable.
	private static inline final FRAMES:Int = 400;

	private var queued:Int = 0;
	private var peakPending:Int = 0;
	private var closedByPolicy:Bool = false;
	private var appliedLimit:Int = -1;

	public function new() {}

	public function run():StressResult {
		var runtime:CrossByte = CrossByte.current();
		var server:ServerWebSocket = new ServerWebSocket();
		server.maxOutputBufferSize = LIMIT;

		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent):Void {
			var ws:WebSocket = cast e.socket;
			// The server applies the limit before any application listener
			// runs, so an accepted session is never briefly unbounded.
			appliedLimit = ws.maxOutputBufferSize;

			ws.addEventListener(Event.CLOSE, function(_):Void {
				closedByPolicy = true;
			});
			ws.addEventListener(IOErrorEvent.IO_ERROR, function(_):Void {
				closedByPolicy = true;
			});

			for (i in 0...FRAMES) {
				if (closedByPolicy) {
					break;
				}

				var payload:ByteArray = new ByteArray();
				for (_ in 0...PAYLOAD) {
					payload.writeByte(i % 251);
				}

				try {
					ws.writeBytes(payload, 0, payload.length);
					ws.flush();
				} catch (_:Dynamic) {
					// Writing to a session the policy already closed.
					closedByPolicy = true;
					break;
				}
				queued++;

				if (ws.outputBufferLength > peakPending) {
					peakPending = ws.outputBufferLength;
				}
			}
		});

		server.bind(0, "127.0.0.1");
		server.listen(4);
		var port:Int = server.localPort;

		// A peer that completes the handshake and then never reads.
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

		var deadline:Float = Sys.time() + 30;
		while (!closedByPolicy && queued < FRAMES && Sys.time() < deadline) {
			@:privateAccess runtime.pump(0.008);
		}

		// Let the close propagate to listeners.
		var settle:Float = Sys.time() + 2;
		while (Sys.time() < settle) {
			@:privateAccess runtime.pump(0.008);
		}

		try {
			client.close();
		} catch (_:Dynamic) {}
		try {
			server.close();
		} catch (_:Dynamic) {}

		// One frame of overshoot is expected: the limit is checked after
		// the write that crosses it. Unbounded growth is not.
		var bound:Int = LIMIT + PAYLOAD + 64;
		var bounded:Bool = peakPending <= bound;
		var passed:Bool = closedByPolicy && queued < FRAMES && bounded && appliedLimit == LIMIT;

		return {
			name: "WebSocket output buffer limit on an unreading peer",
			passed: passed,
			details: [
				'limit=$LIMIT applied to accepted session=$appliedLimit',
				'frames queued=$queued of $FRAMES ($PAYLOAD bytes each)',
				'peak pending=$peakPending (bound $bound)',
				'closed by policy=$closedByPolicy'
			]
		};
	}
}
