package stress;

import crossbyte.core.CrossByte;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.io.ByteArray;
import crossbyte.net.ServerSocket;
import crossbyte.net.Socket;

/**
 * Closes a socket that has a deferred flush pending, then keeps pumping.
 *
 * Invariant: the runtime keeps running. A blocked write schedules a retry
 * on a timer; if the socket is closed before that timer fires, the retry
 * must find nothing to do rather than raising.
 *
 * The failure this guards is disproportionate: the retry runs inside the
 * runtime's tick dispatch, so an exception there does not fail one
 * connection, it propagates out of `pump()` and stops the loop serving
 * every other connection in the process. It is reachable whenever a peer
 * disconnects, or the overflow policy fires, while a write is still
 * blocked — routine events on a busy server.
 */
class SocketDeferredFlushStress implements StressCase {
	private static inline final LIMIT:Int = 256 * 1024;
	private static inline final CHUNK:Int = 64 * 1024;
	private static inline final CHUNKS:Int = 400;

	private var served:Socket;

	public function new() {}

	public function run():StressResult {
		var runtime:CrossByte = CrossByte.current();
		var server:ServerSocket = new ServerSocket();

		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent):Void {
			served = e.socket;
			// Guarantees the close happens while a write is blocked, which
			// is precisely when a retry is outstanding.
			served.maxOutputBufferSize = LIMIT;
			served.outputOverflowPolicy = CLOSE;
		});

		server.bind(0, "127.0.0.1");
		server.listen();
		var port:Int = server.localPort;

		// A peer that connects and never reads.
		var client:sys.net.Socket = new sys.net.Socket();
		client.connect(new sys.net.Host("127.0.0.1"), port);

		var payload:ByteArray = new ByteArray();
		for (i in 0...CHUNK) {
			payload.writeByte(i & 0xFF);
		}

		var writes:Int = 0;
		var policyClosed:Bool = false;
		var deadline:Float = Sys.time() + 20;

		while (!policyClosed && writes < CHUNKS && Sys.time() < deadline) {
			@:privateAccess runtime.pump(0.016);

			if (served != null) {
				try {
					served.writeBytes(payload, 0, payload.length);
					served.flush();
					writes++;
				} catch (_:Dynamic) {
					policyClosed = true;
				}

				if (!served.connected) {
					policyClosed = true;
				}
			}
		}

		try {
			server.close();
		} catch (_:Dynamic) {}

		// The socket is now closed with its retry timer still queued. Every
		// one of these pumps must complete.
		var pumps:Int = 0;
		var pumpError:String = "none";
		try {
			for (_ in 0...30) {
				@:privateAccess runtime.pump(0.016);
				pumps++;
			}
		} catch (e:Dynamic) {
			pumpError = Std.string(e);
		}

		try {
			client.close();
		} catch (_:Dynamic) {}

		var passed:Bool = policyClosed && pumps == 30 && pumpError == "none";

		return {
			name: "Socket deferred flush survives close",
			passed: passed,
			details: [
				'writes=$writes closed by policy=$policyClosed',
				'pumps after close=$pumps of 30',
				'pump error=$pumpError'
			]
		};
	}
}
