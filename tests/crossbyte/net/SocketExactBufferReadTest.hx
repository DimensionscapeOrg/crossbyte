package crossbyte.net;

import crossbyte.core.CrossByte;
import crossbyte.events.ProgressEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.io.ByteArray;
import utest.Assert;

/**
 * Byte-exact receipt of inbound bursts sized around the socket's internal
 * read buffer.
 *
 * Every size here is derived from `Socket.READ_CHUNK` rather than written
 * out, because the case being tested is the boundary itself. Hardcoding the
 * number meant that raising the buffer left these cases passing while
 * probing a size that no longer fills it — protection in name only.
 *
 * The read loop in crossbyte.net.Socket re-reads whenever a read fills its
 * buffer, and stops on a short read or a Blocked error. On eval/interp the
 * descriptor is blocking — setBlocking is a no-op there (see the vendored
 * sys.net.Socket) — so a burst of exactly one buffer, or a whole multiple of
 * one, gives the loop no way out: no short read, no Blocked, and the
 * follow-up read parks the whole runtime thread until the peer sends more or
 * closes. The loop is therefore gated on a zero-timeout select on eval, and
 * these cases exist to keep it that way.
 *
 * A regression here fails by TIMEOUT, not by assertion: the interpreter
 * hangs inside pump(), the deadline loop never regains control, and the run
 * is bounded only by the CI job limit. A suite that suddenly takes minutes
 * instead of seconds is this test failing.
 *
 * One byte under and one byte over the buffer are the controls: both end on
 * a short read, so they exit through that path on every target and pass with
 * or without the eval gate.
 */
@:access(crossbyte.net.Socket)
class SocketExactBufferReadTest extends utest.Test {
	public function testExactSingleBufferBurstIsFullyReceived():Void {
		__assertLoopbackRoundTrip(Socket.READ_CHUNK);
	}

	public function testExactDoubleBufferBurstIsFullyReceived():Void {
		__assertLoopbackRoundTrip(Socket.READ_CHUNK * 2);
	}

	public function testOneByteUnderBufferBurstIsFullyReceived():Void {
		__assertLoopbackRoundTrip(Socket.READ_CHUNK - 1);
	}

	public function testOneByteOverBufferBurstIsFullyReceived():Void {
		__assertLoopbackRoundTrip(Socket.READ_CHUNK + 1);
	}

	/**
	 * A full buffer immediately followed by the peer's FIN — the two arrive
	 * in the same tick, so the read loop fills once and then hits Eof (or,
	 * on eval, a select that reports the closed descriptor readable).
	 *
	 * Both halves of that tick have to survive: the 4096 bytes must be
	 * delivered, and they must be delivered BEFORE the close is announced.
	 * Announcing first is what lost them — a listener that tears down on
	 * CLOSE never saw the payload, and one that read it from the CLOSE
	 * handler found the socket already nulled and threw out of the tick
	 * dispatch. Asserting the payload alone would miss the ordering, so the
	 * bytes-at-close-time are captured and asserted too.
	 */
	public function testFullBufferFollowedByCloseDeliversDataBeforeClose():Void {
		var server = new ServerSocket();
		var client = new Socket();
		var serverPeer:Socket = null;
		var received = new ByteArray();
		var closed = false;
		var bytesWhenClosed = -1;

		server.addEventListener(ServerSocketConnectEvent.CONNECT, event -> {
			serverPeer = event.socket;
			var payload = new ByteArray();
			for (i in 0...Socket.READ_CHUNK) {
				payload.writeByte(__expectedByte(i));
			}
			serverPeer.writeBytes(payload);
			serverPeer.flush();
			// Closed straight after the write so the FIN follows the payload
			// closely enough to land in the same client tick.
			serverPeer.close();
		});

		client.addEventListener(ProgressEvent.SOCKET_DATA, _ -> {
			client.readBytes(received, received.length, client.bytesAvailable);
		});
		client.addEventListener(crossbyte.events.Event.CLOSE, _ -> {
			closed = true;
			bytesWhenClosed = received.length;
		});

		try {
			server.bind(0, "127.0.0.1");
			server.listen();
			client.connect("127.0.0.1", server.localPort);

			__pumpUntil(() -> closed && received.length >= Socket.READ_CHUNK, 5.0);

			Assert.equals(Socket.READ_CHUNK, received.length);
			Assert.equals(-1, __firstMismatch(received, Socket.READ_CHUNK));
			Assert.isTrue(closed);
			// The whole point of the ordering: every byte was already
			// delivered by the time CLOSE was dispatched.
			Assert.equals(Socket.READ_CHUNK, bytesWhenClosed);
		} catch (e:Dynamic) {
			__closeQuietly(client);
			__closeQuietly(serverPeer);
			__closeServerQuietly(server);
			throw e;
		}

		__closeQuietly(client);
		__closeQuietly(serverPeer);
		__closeServerQuietly(server);
	}

	/**
	 * Serves exactly `size` patterned bytes over loopback and asserts the
	 * client receives all of them, byte for byte. The burst is written in one
	 * flush so it reaches the client's socket buffer as a single pending
	 * block — the shape that trips the exact-multiple read loop.
	 */
	private function __assertLoopbackRoundTrip(size:Int):Void {
		var server = new ServerSocket();
		var client = new Socket();
		var serverPeer:Socket = null;
		var received = new ByteArray();

		server.addEventListener(ServerSocketConnectEvent.CONNECT, event -> {
			serverPeer = event.socket;
			var payload = new ByteArray();
			for (i in 0...size) {
				payload.writeByte(__expectedByte(i));
			}
			serverPeer.writeBytes(payload);
			serverPeer.flush();
		});

		client.addEventListener(ProgressEvent.SOCKET_DATA, _ -> {
			// Appended at the current end rather than replacing: TCP owes no
			// delivery boundaries, so the burst may arrive across several
			// data events even on loopback.
			client.readBytes(received, received.length, client.bytesAvailable);
		});

		try {
			server.bind(0, "127.0.0.1");
			server.listen();
			client.connect("127.0.0.1", server.localPort);

			__pumpUntil(() -> received.length >= size, 5.0);

			Assert.equals(size, received.length);
			Assert.equals(-1, __firstMismatch(received, size));
		} catch (e:Dynamic) {
			__closeQuietly(client);
			__closeQuietly(serverPeer);
			__closeServerQuietly(server);
			throw e;
		}

		__closeQuietly(client);
		__closeQuietly(serverPeer);
		__closeServerQuietly(server);
	}

	/**
	 * The byte expected at `index`. Period 251 — prime, and not a divisor of
	 * 4096 — so a stream that drops or repeats a buffer-sized chunk cannot
	 * alias back onto the pattern the way a 256-period generator would
	 * (4096 is 16 * 256).
	 */
	private static inline function __expectedByte(index:Int):Int {
		return index % 251;
	}

	/**
	 * Index of the first byte that differs from the generator pattern, or -1
	 * when all `size` bytes match. An index rather than a Bool so a failure
	 * says where the stream diverged, not merely that it did.
	 */
	private static function __firstMismatch(received:ByteArray, size:Int):Int {
		// Bounded by what actually arrived, not by what was expected: on a
		// short receive the length assertion is the one that should report
		// the failure, and reading past the end here would raise EOF and bury
		// it under an exception instead.
		var limit:Int = size < received.length ? size : received.length;
		received.position = 0;
		for (i in 0...limit) {
			if (received.readUnsignedByte() != __expectedByte(i)) {
				return i;
			}
		}
		return -1;
	}

	private static function __pumpUntil(done:Void->Bool, timeout:Float):Void {
		var runtime = CrossByte.current();
		var deadline = Sys.time() + timeout;
		while (!done() && Sys.time() < deadline) {
			runtime.pump(1 / 60, 0);
			Sys.sleep(0.001);
		}
	}

	private static function __closeQuietly(socket:Socket):Void {
		try {
			if (socket != null && socket.__socket != null) {
				socket.close();
			}
		} catch (_:Dynamic) {}
	}

	private static function __closeServerQuietly(server:ServerSocket):Void {
		try {
			if (server != null && server.listening) {
				server.close();
			}
		} catch (_:Dynamic) {}
	}
}
