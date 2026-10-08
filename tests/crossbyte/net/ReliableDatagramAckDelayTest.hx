package crossbyte.net;

import crossbyte.core.CrossByte;
import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.events.Event;
import crossbyte.events.ReliableDatagramSocketConnectEvent;
import crossbyte.io.ByteArray;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol.ReliableDatagramFrame;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol.ReliableDatagramFrameType;
import crossbyte.test.Require;
import haxe.io.Bytes;
import utest.Assert;

/**
	`ackDelay`: a session holds the acknowledgement of a reliable frame that
	arrived in order for up to 25 milliseconds, for a frame of its own to
	carry it, as QUIC holds one for its `max_ack_delay`.

	It goes at once (when the pass ends, as an unheld acknowledgement does)
	for a frame out of order, a duplicate or one that fills a gap; for the
	second frame it would otherwise hold; for a peer from before 1.0, which
	cannot be told how long one was held; and with `ackDelay` 0. One that
	goes alone says how long it was held, and the peer takes that off the
	round trip it measures and waits that much longer before sending
	anything again.
**/
@:access(crossbyte.net.ReliableDatagramSocket)
@:access(crossbyte.net.ReliableDatagramServerSocket)
@:access(crossbyte.core.CrossByte)
class ReliableDatagramAckDelayTest extends utest.Test {
	// ------------------------------------------------------------ defaults

	public function testTheDefaultIsQuicsMaxAckDelay():Void {
		Assert.equals(0.025, ReliableDatagramSocket.DEFAULT_ACK_DELAY);
		if (!ReliableDatagramSocket.isSupported) {
			Assert.isFalse(ReliableDatagramSocket.isSupported);
			return;
		}

		var socket = new ReliableDatagramSocket();
		var server = new ReliableDatagramServerSocket();
		Assert.equals(0.025, socket.ackDelay);
		Assert.equals(0.025, server.ackDelay);

		Assert.raises(() -> socket.ackDelay = -0.001, crossbyte.errors.RangeError);
		Assert.raises(() -> socket.ackDelay = ReliableDatagramSocket.MAX_ACK_DELAY + 0.001, crossbyte.errors.RangeError);
		Assert.raises(() -> server.ackDelay = -1, crossbyte.errors.RangeError);
		socket.ackDelay = 0;
		Assert.equals(0.0, socket.ackDelay);
		socket.close();
		server.close();
	}

	public function testAServersSessionsTakeItsDelay():Void {
		if (!ReliableDatagramSocket.isSupported) {
			Assert.isFalse(ReliableDatagramSocket.isSupported);
			return;
		}

		var server = new ReliableDatagramServerSocket();
		var client = new ReliableDatagramSocket();
		var accepted:ReliableDatagramSocket = null;
		try {
			server.ackDelay = 0.04;
			client.ackDelay = 0.01;
			server.addEventListener(ReliableDatagramSocketConnectEvent.CONNECT, e -> accepted = e.socket);
			server.bind(0, "127.0.0.1");
			server.listen();
			client.connect("127.0.0.1", server.localPort);
			pumpUntil(() -> client.connected && accepted != null && accepted.connected, 3.0);
			var session = Require.notNull(accepted, "the pair never connected");

			Assert.equals(0.04, session.ackDelay);
			// Each has said in its HANDSHAKE how long it holds one.
			pumpUntil(() -> client.__peerAckDelay >= 0 && session.__peerAckDelay >= 0, 1.0);
			Assert.floatEquals(0.04, client.__peerAckDelay, 0.00001);
			Assert.floatEquals(0.01, session.__peerAckDelay, 0.00001);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}
		try client.close() catch (_:Dynamic) {}
		try server.close() catch (_:Dynamic) {}
	}

	public function testAChangeIsToldToThePeerAtOnce():Void {
		if (!ReliableDatagramSocket.isSupported) {
			Assert.isFalse(ReliableDatagramSocket.isSupported);
			return;
		}

		var server = new ReliableDatagramServerSocket();
		var client = new ReliableDatagramSocket();
		var accepted:ReliableDatagramSocket = null;
		try {
			// No keepalive to carry it: a busy session sends none either.
			client.keepAliveInterval = 0;
			server.addEventListener(ReliableDatagramSocketConnectEvent.CONNECT, e -> accepted = e.socket);
			server.bind(0, "127.0.0.1");
			server.listen();
			client.connect("127.0.0.1", server.localPort);
			pumpUntil(() -> client.connected && accepted != null && accepted.connected, 3.0);
			var session = Require.notNull(accepted, "the pair never connected");
			pumpUntil(() -> session.__peerAckDelay >= 0, 1.0);
			Assert.floatEquals(0.025, session.__peerAckDelay, 0.00001);

			// The peer waits for acknowledgements by what it was told, so it
			// is told now, not when the session next falls quiet.
			client.ackDelay = 0.2;
			pumpUntil(() -> session.__peerAckDelay > 0.1, 0.5);
			Assert.floatEquals(0.2, session.__peerAckDelay, 0.00001, "the peer was not told of the change");
			Assert.isTrue(client.connected && session.connected);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}
		try client.close() catch (_:Dynamic) {}
		try server.close() catch (_:Dynamic) {}
	}

	// ------------------------------------------------------------- the wire

	public function testAHandshakeSaysHowLongThisSideHoldsAnAcknowledgement():Void {
		var socket = AckWire.make(-1);
		if (socket == null) return;
		socket.ackDelay = 0.04;
		// What the change sent, to tell the peer at once.
		socket.flush();
		socket.datagrams = [];

		socket.__sendHandshake();
		socket.flush();
		var frames = socket.frames();
		Assert.equals(1, frames.length);
		var payload:Bytes = frames[0].payload;
		Assert.equals(ReliableDatagramProtocol.HANDSHAKE_PAYLOAD_SIZE, payload.length);
		Assert.equals(4000, (payload.get(4) << 8) | payload.get(5), "not 0.04 s in units of ten microseconds");
		socket.close();
	}

	public function testAPeerFromBefore1_0IsAcknowledgedEveryPass():Void {
		var receiver = AckWire.make(-1);
		if (receiver == null) return;

		// Its HANDSHAKE carried four bytes, or none: it says nothing about
		// holding acknowledgements, and could not read how long one was held.
		var older = new ByteArray();
		older.length = 4;
		receiver.__acceptFrame(new ReliableDatagramFrame(HANDSHAKE, 1000, older, false, 1));
		CrossByte.current().pump(0, 0);
		receiver.datagrams = [];
		Assert.isTrue(receiver.__peerAckDelay < 0);

		for (i in 0...4) {
			receiver.__acceptFrame(packet(1000 + i, "m" + i));
			CrossByte.current().pump(0, 0);
		}
		var frames = receiver.frames();
		Assert.same(["ACK", "ACK", "ACK", "ACK"], kinds(frames));
		for (frame in frames) {
			Assert.isTrue(frame.ackDelay < 0, "an older peer was sent a delay it cannot read");
		}
		receiver.close();
	}

	// ------------------------------------------------------------- holding

	public function testEverySecondFrameInOrderIsAcknowledged():Void {
		var receiver = AckWire.make(0.025);
		if (receiver == null) return;

		for (i in 0...6) {
			receiver.__acceptFrame(packet(1000 + i, "m" + i));
			CrossByte.current().pump(0, 0);
		}

		// Held for the first of each pair, sent with the second: a pass per
		// frame, and half as many acknowledgements as frames.
		var frames = receiver.frames();
		Assert.same(["ACK", "ACK", "ACK"], kinds(frames));
		if (frames.length == 3) {
			Assert.equals(1002, frames[0].sequence);
			Assert.equals(1006, frames[2].sequence);
			Assert.isTrue(frames[0].ackDelay >= 0, "an acknowledgement to a peer that reads delays did not say one");
		}
		receiver.close();
	}

	public function testZeroAcknowledgesEveryPass():Void {
		var receiver = AckWire.make(0.025);
		if (receiver == null) return;
		receiver.ackDelay = 0;
		// The peer is told it is no longer held for.
		receiver.flush();
		Assert.same(["HANDSHAKE"], kinds(receiver.frames()));
		receiver.datagrams = [];

		for (i in 0...3) {
			receiver.__acceptFrame(packet(1000 + i, "m" + i));
			CrossByte.current().pump(0, 0);
		}
		Assert.same(["ACK", "ACK", "ACK"], kinds(receiver.frames()));
		receiver.close();
	}

	public function testAHeldAcknowledgementRidesOnTheNextFrameSent():Void {
		var receiver = AckWire.make(0.025);
		if (receiver == null) return;

		var arrived:Float = haxe.Timer.stamp();
		receiver.__acceptFrame(packet(1000, "question"));
		CrossByte.current().pump(0, 0);
		Assert.equals(0, receiver.datagrams.length, "an acknowledgement went alone that could have waited");

		crossbyte.sys.System.sleep(0.005);
		receiver.send(text("answer"));
		receiver.flush();
		// As long as it was, which a loaded machine makes longer than asked.
		var held:Float = haxe.Timer.stamp() - arrived;

		// One datagram: an ACK saying how long it waited, ahead of the frame
		// whose header would have carried the value but not the wait.
		Assert.equals(1, receiver.datagrams.length);
		var frames = receiver.frames();
		Assert.same(["ACK", "PACKET"], kinds(frames));
		if (frames.length == 2) {
			Assert.equals(1001, frames[0].sequence);
			Assert.isTrue(frames[0].ackDelay >= 0.004, "the ACK did not say how long it was held: " + frames[0].ackDelay);
			Assert.isTrue(frames[0].ackDelay <= held + 0.00001, "it said longer than it was held: " + frames[0].ackDelay + " against " + held);
		}
		receiver.close();
	}

	public function testAnAnswerInTheSamePassCarriesItInItsHeader():Void {
		var receiver = AckWire.make(0.025);
		if (receiver == null) return;

		receiver.__acceptFrame(packet(1000, "question"));
		receiver.send(text("answer"));
		receiver.flush();

		// Answered at once: one datagram, its frame's header carrying the
		// acknowledgement, and an ACK ahead of it only on a target slow enough
		// that a millisecond passed in between.
		Assert.equals(1, receiver.datagrams.length);
		var frames = receiver.frames();
		var answer = frames[frames.length - 1];
		Assert.equals(ReliableDatagramFrameType.PACKET, answer.type);
		Assert.equals(1001, (answer.ack : Int));
		CrossByte.current().pump(0, 0);
		Assert.equals(1, receiver.datagrams.length, "the acknowledgement went again on its own");
		receiver.close();
	}

	public function testAHeldAcknowledgementGoesWhenItsTimeIsUp():Void {
		var receiver = AckWire.make(0.025);
		if (receiver == null) return;

		receiver.__acceptFrame(packet(1000, "alone"));
		CrossByte.current().pump(0, 0);
		Assert.equals(0, receiver.datagrams.length);

		crossbyte.sys.System.sleep(0.03);
		CrossByte.current().pump(0.03, 0);
		var frames = receiver.frames();
		Assert.same(["ACK"], kinds(frames));
		if (frames.length == 1) {
			Assert.equals(1001, frames[0].sequence);
			Assert.isTrue(frames[0].ackDelay >= 0.025, "the ACK said it was held less than it was: " + frames[0].ackDelay);
		}
		receiver.close();
	}

	// -------------------------------------------------------- not holding

	public function testAGapIsAcknowledgedAtOnceAndSoIsWhatFillsIt():Void {
		var receiver = AckWire.make(0.025);
		if (receiver == null) return;

		receiver.__acceptFrame(packet(1000, "first"));
		receiver.__acceptFrame(packet(1002, "past the gap"));
		CrossByte.current().pump(0, 0);
		var frames = receiver.frames();
		Assert.same(["ACK"], kinds(frames), "a gap waited to be told");
		if (frames.length == 1) {
			Assert.equals(1001, frames[0].sequence);
			Assert.equals(0x01, (frames[0].payload : Bytes).get(0), "the map did not name the frame held");
		}

		receiver.datagrams = [];
		receiver.__acceptFrame(packet(1001, "the gap"));
		CrossByte.current().pump(0, 0);
		frames = receiver.frames();
		Assert.same(["ACK"], kinds(frames), "the frame that filled the gap waited to be told");
		if (frames.length == 1) {
			Assert.equals(1003, frames[0].sequence);
		}
		receiver.close();
	}

	public function testADuplicateIsAcknowledgedAtOnce():Void {
		var receiver = AckWire.make(0.025);
		if (receiver == null) return;

		receiver.__acceptFrame(packet(1000, "once"));
		CrossByte.current().pump(0, 0);
		Assert.equals(0, receiver.datagrams.length);

		// Sent again: the peer did not hear, and is waiting to.
		receiver.__acceptFrame(packet(1000, "once"));
		CrossByte.current().pump(0, 0);
		Assert.same(["ACK"], kinds(receiver.frames()));
		receiver.close();
	}

	// ------------------------------------------------------------ the sender

	public function testTheSenderTakesTheHoldOffItsRoundTrip():Void {
		var sender = AckWire.make(0.025);
		if (sender == null) return;

		sender.send(text("one"));
		sender.flush();
		// Sent 50 ms ago, as far as the session knows.
		Require.notNull(sender.__outFrameCache.get(1000)).sentAt -= 0.05;

		// The peer says it held the acknowledgement 45 ms: the round trip is
		// what is left, not the 50 ms the sender waited.
		sender.__acceptFrame(delayedAck(1001, 0.045));
		Assert.isTrue(sender.roundTripTime >= 0, "no round trip was measured");
		Assert.isTrue(sender.roundTripTime < 0.015, "the hold was counted as round trip: " + sender.roundTripTime);
		// The timers keep the answer's time as it came, hold and all.
		Assert.isTrue(sender.__answerRtt >= 0.05, "the timers were told the round trip without the hold: " + sender.__answerRtt);
		sender.close();
	}

	public function testTheSendersTimeoutsAllowForTheHold():Void {
		var sender = AckWire.make(0.1);
		if (sender == null) return;

		sender.send(text("one"));
		sender.flush();
		sender.__acceptFrame(delayedAck(1001, 0));
		Assert.isTrue(sender.__baseRto() >= 0.1, "the retransmission timeout did not count the peer's hold: " + sender.__baseRto());

		// A tail waits out the peer's hold, twice over (the peer answers on
		// the first pass of its loop after it), before it is probed.
		sender.send(text("two"));
		sender.flush();
		sender.datagrams = [];
		var sentAt:Float = sender.__clock();
		var answer:Float = 2 * sender.__answerRtt;
		sender.__probeTail(sentAt + answer + 0.15);
		Assert.equals(0, sender.__probes, "the tail was probed while the peer could still be holding its answer");
		sender.__probeTail(sentAt + answer + 0.25);
		Assert.equals(1, sender.__probes);
		sender.close();
	}

	public function testARealPairMeasuresTheNetworkAndSendsNothingTwice():Void {
		if (!ReliableDatagramSocket.isSupported) {
			Assert.isFalse(ReliableDatagramSocket.isSupported);
			return;
		}

		var server = new ReliableDatagramServerSocket();
		var client = new ReliableDatagramSocket();
		var accepted:ReliableDatagramSocket = null;
		var delivered = 0;
		try {
			// The server's sessions hold every acknowledgement its full 100 ms:
			// they send nothing that could carry one.
			server.ackDelay = 0.1;
			server.addEventListener(ReliableDatagramSocketConnectEvent.CONNECT, e -> {
				accepted = e.socket;
				accepted.addEventListener(DatagramSocketDataEvent.DATA, _ -> delivered++);
			});
			server.bind(0, "127.0.0.1");
			server.listen();
			client.connect("127.0.0.1", server.localPort);
			pumpUntil(() -> client.connected && accepted != null && accepted.connected, 3.0);
			Require.notNull(accepted, "the pair never connected");
			pumpUntil(() -> client.__peerAckDelay > 0, 1.0);

			for (i in 0...5) {
				client.send(text("m" + i));
				var sentAt = haxe.Timer.stamp();
				pumpUntil(() -> haxe.Timer.stamp() - sentAt > 0.25, 1.0);
			}
			pumpUntil(() -> delivered >= 5 && client.framesDelivered >= 5, 2.0);

			Assert.equals(5, delivered);
			Assert.equals(5.0, client.framesDelivered, "not every message was acknowledged");
			Assert.isTrue(client.roundTripTime >= 0 && client.roundTripTime < 0.05,
				"the round trip counted the peer's hold: " + client.roundTripTime);
			Assert.equals(0, client.__probes, "a held acknowledgement was taken for a lost tail");
			Assert.equals(0, client.__timeoutResends, "a held acknowledgement was taken for a loss");
			Assert.equals(0, client.__fastResends);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}
		try client.close() catch (_:Dynamic) {}
		try server.close() catch (_:Dynamic) {}
	}

	// ------------------------------------------------------------- helpers

	private static function packet(sequence:Int, value:String):ReliableDatagramFrame {
		return new ReliableDatagramFrame(PACKET, sequence, text(value), false, 1);
	}

	/** An ACK of `value` from a peer that says it held it `seconds`. **/
	private static function delayedAck(value:Int, seconds:Float):ReliableDatagramFrame {
		var payload = new ByteArray();
		var units = ReliableDatagramProtocol.delayUnits(seconds);
		payload.writeByte(units >> 8);
		payload.writeByte(units & 0xFF);
		var scratch = new ByteArray();
		scratch.length = ReliableDatagramProtocol.MAX_FRAME_SIZE;
		var length = ReliableDatagramProtocol.encodeInto(scratch, ACK, value, payload, 0, 2, false, 0, false, false, 0, true);
		scratch.length = length;
		return ReliableDatagramProtocol.decode(scratch);
	}

	private static function kinds(frames:Array<ReliableDatagramFrame>):Array<String> {
		return [
			for (frame in frames)
				switch (frame.type) {
					case ACK: "ACK";
					case PACKET: "PACKET";
					case HANDSHAKE: "HANDSHAKE";
					case FIN: "FIN";
					case _: "?";
				}
		];
	}

	private static function pumpUntil(done:Void->Bool, timeout:Float):Void {
		var runtime = CrossByte.current();
		var deadline = haxe.Timer.stamp() + timeout;
		var last = haxe.Timer.stamp();
		while (!done() && haxe.Timer.stamp() < deadline) {
			crossbyte.sys.System.sleep(0.001);
			var now = haxe.Timer.stamp();
			// The runtime's clock kept with the wall, which the holds are timed by.
			runtime.pump(now - last, 0);
			last = now;
		}
	}

	private static function text(value:String):ByteArray {
		var bytes = new ByteArray();
		bytes.writeUTFBytes(value);
		bytes.position = 0;
		return bytes;
	}
}

/** A connected session whose datagrams are kept instead of sent. **/
@:access(crossbyte.net.ReliableDatagramSocket)
private class AckWire extends ReliableDatagramSocket {
	public var datagrams:Array<ByteArray> = [];

	/**
		One ready to send, its peer expecting frames from 1000, and saying it
		holds acknowledgements `peerAckDelay` seconds (-1: a peer from before
		1.0); or null where this target has no datagrams.
	**/
	public static function make(peerAckDelay:Float):AckWire {
		if (!DatagramSocket.isSupported) {
			Assert.isFalse(DatagramSocket.isSupported);
			return null;
		}
		var socket = new AckWire();
		socket.__connected = true;
		socket.__peerConfirmed = true;
		socket.__remoteAddress = "127.0.0.1";
		socket.__remotePort = 9;
		socket.__peerTakesBundles = true;
		socket.__peerAckDelay = peerAckDelay;
		socket.__inSequence = 1000;
		socket.__outSequence = 1000;
		socket.__windowBase = 1000;
		socket.__firstSequence = 1000;
		return socket;
	}

	public function new() {
		super();
	}

	/** Every frame sent, in order, across however many datagrams. **/
	public function frames():Array<ReliableDatagramFrame> {
		var frames:Array<ReliableDatagramFrame> = [];
		for (datagram in datagrams) {
			if (!ReliableDatagramProtocol.isBundle(datagram)) {
				frames.push(ReliableDatagramProtocol.decode(datagram));
				continue;
			}
			var at = ReliableDatagramProtocol.BUNDLE_HEADER_SIZE;
			while (true) {
				var length = ReliableDatagramProtocol.bundleEntryLength(datagram, at);
				if (length < 0) {
					break;
				}
				frames.push(ReliableDatagramProtocol.decodeRange(datagram, at + ReliableDatagramProtocol.BUNDLE_ENTRY_SIZE, length));
				at += ReliableDatagramProtocol.BUNDLE_ENTRY_SIZE + length;
			}
		}
		return frames;
	}

	override private function __sendDatagram(offset:Int, length:Int):Bool {
		var copy = new ByteArray();
		copy.length = length;
		(copy : Bytes).blit(0, __scratch, offset, length);
		datagrams.push(copy);
		return true;
	}
}
