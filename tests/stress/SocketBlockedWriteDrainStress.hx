package stress;

import crossbyte.core.CrossByte;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.io.ByteArray;
import crossbyte.net.ServerSocket;
import crossbyte.net.Socket;

/**
 * Writes more than the send buffer holds to a peer that drains slowly,
 * and requires every byte to arrive.
 *
 * Invariant: a socket that blocks, recovers, and blocks again keeps being
 * retried until it has drained.
 *
 * The retry runs off the registry's writable queue. That queue is guarded
 * by a "retry pending" flag, so the failure mode this guards is a socket
 * that blocks twice in a row, believes a retry is already queued when it
 * is not, and strands whatever it was holding — silently, with no error
 * and no close, which is indistinguishable from the peer never having
 * been sent anything.
 */
class SocketBlockedWriteDrainStress implements StressCase {
	private static inline final CHUNK:Int = 64 * 1024;
	// Far more than any loopback send buffer, so the write blocks many
	// times over rather than once.
	private static inline final CHUNKS:Int = 64;
	private static inline final TOTAL:Int = CHUNK * CHUNKS;

	private var served:Socket;

	public function new() {}

	public function run():StressResult {
		var runtime:CrossByte = CrossByte.current();
		var server:ServerSocket = new ServerSocket();

		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent):Void {
			served = e.socket;
		});

		server.bind(0, "127.0.0.1");
		server.listen();
		var port:Int = server.localPort;

		var client:sys.net.Socket = new sys.net.Socket();
		client.connect(new sys.net.Host("127.0.0.1"), port);
		client.setBlocking(false);

		var payload:ByteArray = new ByteArray();
		for (i in 0...CHUNK) {
			payload.writeByte(i & 0xFF);
		}

		// Hand the whole payload over up front, so everything past the
		// first blocked write depends on the retry path.
		var deadline:Float = Sys.time() + 30;
		while (served == null && Sys.time() < deadline) {
			@:privateAccess runtime.pump(0.008);
		}

		var queued:Int = 0;
		if (served != null) {
			for (_ in 0...CHUNKS) {
				served.writeBytes(payload, 0, payload.length);
				try {
					served.flush();
				} catch (_:Dynamic) {}
				queued++;
			}
		}

		// Now drain from the client while pumping, so each recovery has to
		// come from the writable queue rather than one lucky flush.
		var received:Int = 0;
		var scratch:haxe.io.Bytes = haxe.io.Bytes.alloc(CHUNK);
		var readDeadline:Float = Sys.time() + 60;

		while (received < TOTAL && Sys.time() < readDeadline) {
			@:privateAccess runtime.pump(0.004);

			try {
				var read:Int = client.input.readBytes(scratch, 0, scratch.length);
				if (read > 0) {
					received += read;
				}
			} catch (_:haxe.io.Eof) {
				break;
			} catch (e:Dynamic) {
				if (Std.string(e).indexOf("Block") < 0) {
					break;
				}
			}
		}

		var pending:Int = served == null ? -1 : served.outputBufferLength;

		try {
			client.close();
		} catch (_:Dynamic) {}
		try {
			server.close();
		} catch (_:Dynamic) {}

		var passed:Bool = received == TOTAL && pending == 0;

		return {
			name: "Socket drains a repeatedly blocked write",
			passed: passed,
			details: [
				'queued=$queued chunk(s) of $CHUNK, $TOTAL bytes total',
				'received=$received of $TOTAL',
				'still buffered=$pending (expected 0)'
			]
		};
	}
}
