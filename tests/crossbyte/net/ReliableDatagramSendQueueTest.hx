package crossbyte.net;

import crossbyte.core.CrossByte;
import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ReliableDatagramSocketConnectEvent;
import crossbyte.io.ByteArray;
import crossbyte.test.Require;
import haxe.io.Bytes;
import utest.Assert;

/**
	What a session holds for a peer that is not taking what it is sent:
	`maxOutputBufferSize`, 256 KB unless changed, and past it the session is
	ended with an `ioError` saying why, as a TCP connection to a peer that
	stopped reading would be, rather than held without bound by an
	overloaded server.
**/
@:access(crossbyte.net.ReliableDatagramSocket)
@:access(crossbyte.net.CongestionControl)
class ReliableDatagramSendQueueTest extends utest.Test {
	public function testTheQueueIsCappedByDefault():Void {
		Assert.equals(256 * 1024, ReliableDatagramSocket.DEFAULT_MAX_OUTPUT_BUFFER_SIZE);
		if (!ReliableDatagramSocket.isSupported) {
			Assert.isFalse(ReliableDatagramSocket.isSupported);
			return;
		}
		var socket = new ReliableDatagramSocket();
		Assert.equals(ReliableDatagramSocket.DEFAULT_MAX_OUTPUT_BUFFER_SIZE, socket.maxOutputBufferSize);
		Assert.equals(OutputOverflowPolicy.CLOSE, socket.outputOverflowPolicy);
		socket.close();
	}

	public function testASessionWhosePeerTakesNothingIsEndedAndHoldsNoMore():Void {
		var socket = QueueWire.make();
		if (socket == null) return;

		var errors:Array<String> = [];
		var closed:Bool = false;
		socket.addEventListener(IOErrorEvent.IO_ERROR, e -> errors.push(e.text));
		socket.addEventListener(Event.CLOSE, _ -> closed = true);

		// A megabyte to a peer that acknowledges nothing: the window lets the
		// first frames out and everything else waits.
		var message = new ByteArray();
		message.length = 1000;
		var most:Int = 0;
		var sent:Int = 0;
		for (_ in 0...1000) {
			if (!socket.connected) {
				break;
			}
			socket.send(message);
			sent++;
			if (socket.bufferedAmount > most) {
				most = socket.bufferedAmount;
			}
		}

		Assert.isTrue(closed, "a session holding a megabyte for a silent peer was never ended");
		Assert.isFalse(socket.connected);
		Assert.isTrue(errors.length == 1 && errors[0].indexOf("limit") >= 0, "it was not said why: " + errors.join("; "));
		Assert.isTrue(sent < 1000, "every send was taken");
		Assert.isTrue(most <= ReliableDatagramSocket.DEFAULT_MAX_OUTPUT_BUFFER_SIZE + message.length,
			"it held " + most + " bytes, past the limit by more than one message");
		Assert.equals(0, socket.bufferedAmount, "what it held was kept after it ended");
	}

	public function testZeroStillMeansNoLimit():Void {
		var socket = QueueWire.make();
		if (socket == null) return;
		socket.maxOutputBufferSize = 0;

		var message = new ByteArray();
		message.length = 1000;
		for (_ in 0...400) {
			socket.send(message);
		}
		Assert.isTrue(socket.connected);
		Assert.isTrue(socket.bufferedAmount > ReliableDatagramSocket.DEFAULT_MAX_OUTPUT_BUFFER_SIZE);
		socket.abort();
	}

	/**
		Under `THROW` the limit is applied once the whole message is queued,
		not after each frame, which would throw part way through a message
		larger than a frame: what was queued would say more followed, nothing
		would follow, and the peer would put the next message sent onto it.
	**/
	public function testAMessageLargerThanAFrameIsQueuedWholeBeforeTheLimitThrows():Void {
		var socket = QueueWire.make();
		if (socket == null) return;
		// Nothing may go out: everything sent waits for the window.
		socket.__congestion.window = 0;
		socket.maxOutputBufferSize = 2000;
		socket.outputOverflowPolicy = THROW;

		var message = new ByteArray();
		message.length = 3000;
		Assert.raises(() -> socket.send(message), crossbyte.errors.IOError);
		var queued:Int = socket.__outgoingQueue.length - socket.__queueAt;
		Assert.equals(3, queued, "the message was not queued whole");
		if (queued > 0) {
			Assert.isFalse(socket.__outgoingQueue[socket.__outgoingQueue.length - 1].more,
				"the message was left half queued, its last frame saying more follows");
		}
		Assert.equals(3000, socket.bufferedAmount);
		Assert.isTrue(socket.connected, "THROW ended the session");
		socket.abort();
	}

	/**
		And a stream's bytes flushed past the limit under `THROW` are queued
		once: not left in the output buffer when the limit throws, to be queued
		again by the next flush.
	**/
	public function testStreamBytesFlushedPastTheLimitAreQueuedOnce():Void {
		var socket = QueueWire.make();
		if (socket == null) return;
		socket.__mode = STREAM;
		socket.__congestion.window = 0;
		socket.maxOutputBufferSize = 2000;
		socket.outputOverflowPolicy = THROW;

		var bytes = new ByteArray();
		bytes.length = 3000;
		socket.writeBytes(bytes);
		Assert.raises(() -> socket.flush(), crossbyte.errors.IOError);
		Assert.equals(0, socket.bytesPending, "the bytes queued were kept to be queued again");
		try {
			socket.flush();
		} catch (_:Dynamic) {}
		Assert.equals(3000, socket.bufferedAmount, "the bytes were queued twice");
		socket.abort();
	}

	public function testAHealthySessionNeverComesNearIt():Void {
		if (!ReliableDatagramSocket.isSupported) {
			Assert.isFalse(ReliableDatagramSocket.isSupported);
			return;
		}

		var server = new ReliableDatagramServerSocket();
		var client = new ReliableDatagramSocket();
		var accepted:ReliableDatagramSocket = null;
		var delivered:Int = 0;
		var errors:Array<String> = [];
		try {
			server.addEventListener(ReliableDatagramSocketConnectEvent.CONNECT, e -> {
				accepted = e.socket;
				accepted.addEventListener(IOErrorEvent.IO_ERROR, e -> errors.push(e.text));
			});
			server.bind(0, "127.0.0.1");
			server.listen();
			client.addEventListener(DatagramSocketDataEvent.DATA, _ -> delivered++);
			client.addEventListener(IOErrorEvent.IO_ERROR, e -> errors.push(e.text));
			client.connect("127.0.0.1", server.localPort);
			pumpUntil(() -> client.connected && accepted != null && accepted.connected, 3.0);
			var session = Require.notNull(accepted, "the pair never connected");

			// A game's server: a few hundred bytes a client, reliably, every
			// pass, for two hundred passes.
			var snapshot = new ByteArray();
			snapshot.length = 400;
			var most:Int = 0;
			for (_ in 0...200) {
				session.send(snapshot);
				session.send(snapshot);
				if (session.bufferedAmount > most) {
					most = session.bufferedAmount;
				}
				pumpOnce();
			}
			pumpUntil(() -> delivered >= 400, 5.0);

			Assert.equals(400, delivered);
			Assert.same([], errors);
			Assert.isTrue(session.connected, "a healthy session was ended");
			Assert.isTrue(most < ReliableDatagramSocket.DEFAULT_MAX_OUTPUT_BUFFER_SIZE / 16, "a healthy session held " + most + " bytes");
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}
		try client.close() catch (_:Dynamic) {}
		try server.close() catch (_:Dynamic) {}
	}

	private static var __last:Float = -1;

	private static function pumpOnce():Void {
		var now = haxe.Timer.stamp();
		if (__last < 0) {
			__last = now;
		}
		crossbyte.sys.System.sleep(0.001);
		CrossByte.current().pump(now - __last, 0);
		__last = now;
	}

	private static function pumpUntil(done:Void->Bool, timeout:Float):Void {
		var deadline = haxe.Timer.stamp() + timeout;
		while (!done() && haxe.Timer.stamp() < deadline) {
			pumpOnce();
		}
	}
}

/** A connected session whose datagrams go nowhere, to a peer that answers nothing. **/
@:access(crossbyte.net.ReliableDatagramSocket)
private class QueueWire extends ReliableDatagramSocket {
	public static function make():QueueWire {
		if (!DatagramSocket.isSupported) {
			Assert.isFalse(DatagramSocket.isSupported);
			return null;
		}
		var socket = new QueueWire();
		socket.__connected = true;
		socket.__peerConfirmed = true;
		socket.__remoteAddress = "127.0.0.1";
		socket.__remotePort = 9;
		socket.__peerTakesBundles = true;
		return socket;
	}

	public function new() {
		super();
	}

	override private function __sendDatagram(offset:Int, length:Int):Bool {
		return true;
	}
}
