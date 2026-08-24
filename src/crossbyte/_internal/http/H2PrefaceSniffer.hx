package crossbyte._internal.http;

// Server-side, so not the browser, for the same reason as the rest of it.
#if !(js && !nodejs)
import crossbyte.events.Event;
import crossbyte.events.ProgressEvent;
import crossbyte.io.ByteArray;
import crossbyte.net.Socket;

/**
 * Decides whether a cleartext connection is HTTP/1.1 or HTTP/2, by looking.
 *
 * RFC 9113 §3.1 retired the `Upgrade: h2c` handshake, which leaves prior
 * knowledge as the only cleartext mode -- and prior knowledge means the client
 * simply starts speaking HTTP/2. So a port that serves both has to tell them
 * apart from the first bytes on the wire, because nothing announces which one
 * is coming.
 *
 * That is workable precisely because the HTTP/2 connection preface opens with
 * `PRI * HTTP/2.0`, a request line chosen to be one no HTTP/1.1 client would
 * ever send. The comparison runs against however many bytes have arrived, so
 * the decision is made on the first read that can settle it rather than
 * waiting for all 24.
 *
 * Whatever was read is handed to the winner. Consuming bytes and then dropping
 * them would corrupt the very first request on every connection.
 */
class H2PrefaceSniffer {
	private final __socket:Socket;
	private final __buffer:ByteArray = new ByteArray();
	private final __onDecided:(Socket, ByteArray, Bool) -> Void;

	private var __settled:Bool = false;

	/**
	 * @param onDecided Receives the socket, the bytes already read, and
	 *        whether the peer is speaking HTTP/2.
	 */
	public function new(socket:Socket, onDecided:(Socket, ByteArray, Bool) -> Void) {
		__socket = socket;
		__onDecided = onDecided;

		__socket.addEventListener(ProgressEvent.SOCKET_DATA, __onData);
		__socket.addEventListener(Event.CLOSE, __onClosed);
	}

	private function __onData(_:ProgressEvent):Void {
		if (__settled) {
			return;
		}

		var chunk:ByteArray = new ByteArray();
		__socket.readBytes(chunk, 0);
		if (chunk.length == 0) {
			return;
		}

		__buffer.writeBytes(chunk, 0, chunk.length);

		var preface:String = crossbyte._internal.http.h2.H2Connection.PREFACE;
		var comparable:Int = __buffer.length < preface.length ? __buffer.length : preface.length;

		for (i in 0...comparable) {
			if (__buffer[i] != preface.charCodeAt(i)) {
				// Diverged, so it is not the preface and no further byte can
				// make it one.
				__settle(false);
				return;
			}
		}

		if (__buffer.length >= preface.length) {
			__settle(true);
		}

		// Still a prefix of the preface and shorter than it: undecided, and
		// the next read continues from where this left off.
	}

	private function __onClosed(_:Event):Void {
		// Gone before it said anything. Nothing to hand over, and no handler to
		// hand it to.
		__detach();
		__settled = true;
	}

	private function __settle(isHttp2:Bool):Void {
		__settled = true;
		__detach();

		__buffer.position = 0;
		__onDecided(__socket, __buffer, isHttp2);
	}

	private function __detach():Void {
		__socket.removeEventListener(ProgressEvent.SOCKET_DATA, __onData);
		__socket.removeEventListener(Event.CLOSE, __onClosed);
	}
}
#end
