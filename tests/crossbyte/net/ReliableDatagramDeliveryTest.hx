package crossbyte.net;

import crossbyte.errors.ArgumentError;
import crossbyte.errors.IllegalOperationError;
import crossbyte.errors.RangeError;
import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.events.IOErrorEvent;
import crossbyte.io.ByteArray;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol.ReliableDatagramFrame;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol.ReliableDatagramFrameType;
import utest.Assert;

/**
	What each delivery mode promises, checked between two sockets whose frames
	go through memory rather than a network: every frame one sends is recorded,
	and handed to the other in whatever order a case chooses -- reordered,
	dropped or duplicated on purpose, which a network does only when it likes.

	The sockets are real, so what is exercised is the code a session runs; only
	the last step, the datagram leaving, is replaced.
**/
@:access(crossbyte.net.ReliableDatagramSocket)
class ReliableDatagramDeliveryTest extends utest.Test {
	// --------------------------------------------------------------- modes

	public function testADeliveryModeSaysWhatItIs():Void {
		Assert.isTrue(DeliveryMode.RELIABLE.reliable);
		Assert.isFalse(DeliveryMode.RELIABLE.isSequenced);
		Assert.equals(-1, DeliveryMode.RELIABLE.channel);

		Assert.isFalse(DeliveryMode.UNRELIABLE.reliable);
		Assert.isFalse(DeliveryMode.UNRELIABLE.isSequenced);

		var seven = DeliveryMode.sequenced(7);
		Assert.isFalse(seven.reliable);
		Assert.isTrue(seven.isSequenced);
		Assert.equals(7, seven.channel);
		Assert.equals(0, DeliveryMode.sequenced(0).channel);
		Assert.equals(255, DeliveryMode.sequenced(255).channel);
	}

	public function testAChannelOutsideItsRangeIsRefused():Void {
		Assert.raises(() -> DeliveryMode.sequenced(-1), ArgumentError);
		Assert.raises(() -> DeliveryMode.sequenced(256), ArgumentError);
	}

	// ------------------------------------------------------------ reliable

	public function testAMessageIsSplitIntoFramesThatSayWhetherMoreFollows():Void {
		var sender = RecordingSocket.make();
		if (sender == null) return;

		sender.send(filled(3000));
		var frames = sender.take();

		Assert.equals(3, frames.length);
		Assert.same([1200, 1200, 600], [for (f in frames) f.payload.length]);
		Assert.same([true, true, false], [for (f in frames) f.more]);
		for (f in frames) {
			Assert.equals(ReliableDatagramFrameType.PACKET, f.type);
		}

		// Exactly one frame's worth is one frame, and one byte more is two.
		sender.send(filled(1200));
		Assert.same([false], [for (f in sender.take()) f.more]);
		sender.send(filled(1201));
		Assert.same([true, false], [for (f in sender.take()) f.more]);
		sender.close();
	}

	public function testFragmentsAreJoinedIntoTheMessageThatWasSent():Void {
		var pair = Pair.make();
		if (pair == null) return;

		pair.sender.send(filled(3000));
		pair.sender.send(filled(10));
		pair.carry(pair.sender.take());

		Assert.same([3000, 10], [for (m in pair.received) m.length]);
		Assert.equals(-1, firstWrongByte(pair.received[0]));
		pair.close();
	}

	public function testFragmentsArrivingOutOfOrderAreJoinedInOrder():Void {
		var pair = Pair.make();
		if (pair == null) return;

		pair.sender.send(filled(3000));
		var frames = pair.sender.take();
		// Reversed, so a middle fragment waits in the out-of-order cache and
		// has to remember there that more follows it.
		pair.carry([frames[2], frames[1], frames[0]]);

		Assert.same([3000], [for (m in pair.received) m.length]);
		Assert.equals(-1, firstWrongByte(pair.received[0]));
		pair.close();
	}

	public function testAFragmentSentAgainStillSaysMoreFollows():Void {
		var pair = Pair.make();
		if (pair == null) return;

		pair.sender.send(filled(3000));
		var frames = pair.sender.take();
		// The first fragment is lost; the other two wait for it.
		pair.carry([frames[1], frames[2]]);
		Assert.equals(0, pair.received.length, "delivered with its first fragment missing");

		// Its deadline passes, and the retransmission clock sends it again.
		pair.sender.__outFrameCache.get(pair.sender.__windowBase).deadline = 0;
		pair.sender.__checkRetransmits();
		var resent = pair.sender.take();

		Assert.equals(1, resent.length);
		Assert.isTrue(resent.length == 1 && resent[0].resend);
		Assert.isTrue(resent.length == 1 && resent[0].more, "a fragment sent again forgot that more follows");
		pair.carry(resent);
		Assert.same([3000], [for (m in pair.received) m.length]);
		Assert.isTrue(pair.received.length == 1 && firstWrongByte(pair.received[0]) == -1);
		pair.close();
	}

	public function testAnUnreliableMessageBetweenFragmentsIsNotPartOfTheMessage():Void {
		var pair = Pair.make();
		if (pair == null) return;

		pair.sender.send(filled(2500));
		var fragments = pair.sender.take();
		pair.sender.send(text("between"), 0, 0, DeliveryMode.UNRELIABLE);
		var between = pair.sender.take();
		pair.carry([fragments[0], between[0], fragments[1], fragments[2]]);

		Assert.same([7, 2500], [for (m in pair.received) m.length]);
		Assert.equals("between", pair.received[0].toString());
		Assert.equals(-1, firstWrongByte(pair.received[1]));
		pair.close();
	}

	public function testAMessageLargerThanMaxMessageSizeClosesTheSession():Void {
		var pair = Pair.make();
		if (pair == null) return;

		var errors:Array<String> = [];
		pair.receiver.addEventListener(IOErrorEvent.IO_ERROR, e -> errors.push(e.text));
		pair.receiver.maxMessageSize = 2000;
		pair.sender.send(filled(3000));
		pair.carry(pair.sender.take());

		Assert.same([], [for (m in pair.received) m.length], "no part of it was delivered");
		Assert.equals(1, errors.length);
		Assert.isTrue(errors.length == 1 && errors[0].indexOf("maxMessageSize") >= 0, errors.join("; "));
		Assert.isFalse(pair.receiver.connected);
		pair.close();
	}

	public function testMaxMessageSizeIsInclusiveAndCoversASingleFrame():Void {
		var exact = Pair.make();
		if (exact == null) return;
		exact.receiver.maxMessageSize = 3000;
		exact.sender.send(filled(3000));
		exact.carry(exact.sender.take());
		Assert.same([3000], [for (m in exact.received) m.length], "a message exactly the limit");
		exact.close();

		var single = Pair.make();
		single.receiver.maxMessageSize = 500;
		single.sender.send(filled(501));
		single.carry(single.sender.take());
		Assert.same([], [for (m in single.received) m.length], "one frame past the limit");
		Assert.isFalse(single.receiver.connected);
		single.close();

		var none = Pair.make();
		none.receiver.maxMessageSize = 0;
		none.sender.send(filled(9000));
		none.carry(none.sender.take());
		Assert.same([9000], [for (m in none.received) m.length], "zero is no limit");
		none.close();
	}

	// ---------------------------------------------------------- unreliable

	public function testAnUnreliableMessageGoesOutOnceAndIsNotKept():Void {
		var sender = RecordingSocket.make();
		if (sender == null) return;

		var sequenceBefore = sender.__outSequence;
		sender.send(text("once"), 0, 0, DeliveryMode.UNRELIABLE);
		var frames = sender.take();

		Assert.equals(1, frames.length);
		Assert.equals(ReliableDatagramFrameType.UNRELIABLE, frames[0].type);
		Assert.equals("once", frames[0].payload.toString());
		Assert.isFalse(sender.__outFrameCache.keys().hasNext(), "kept for resending");
		Assert.equals(sequenceBefore, sender.__outSequence, "it took a reliable sequence number");
		Assert.equals(0, sender.bufferedAmount);
		sender.close();
	}

	public function testUnreliableMessagesAreDeliveredInWhateverOrderTheyArrive():Void {
		var pair = Pair.make();
		if (pair == null) return;

		for (word in ["a", "b", "c"]) {
			pair.sender.send(text(word), 0, 0, DeliveryMode.UNRELIABLE);
		}
		var frames = pair.sender.take();
		pair.carry([frames[2], frames[0], frames[0], frames[1]]);

		// Unreliable promises nothing about order or duplicates: all four
		// arrivals are delivered, as they came.
		Assert.same(["c", "a", "a", "b"], [for (m in pair.received) m.toString()]);
		pair.close();
	}

	public function testAnUnreliableMessageMustFitOneFrame():Void {
		var sender = RecordingSocket.make();
		if (sender == null) return;

		sender.send(filled(1200), 0, 0, DeliveryMode.UNRELIABLE);
		sender.send(filled(1200), 0, 0, DeliveryMode.sequenced(3));
		Assert.equals(2, sender.take().length);

		Assert.raises(() -> sender.send(filled(1201), 0, 0, DeliveryMode.UNRELIABLE), RangeError);
		Assert.raises(() -> sender.send(filled(1201), 0, 0, DeliveryMode.sequenced(3)), RangeError);
		Assert.raises(() -> sender.send(filled(10), 5, 6, DeliveryMode.UNRELIABLE), RangeError);
		Assert.equals(0, sender.take().length, "a refused message was sent anyway");

		// An offset and length are honoured, and nothing is copied that is
		// not sent.
		sender.send(text("0123456789"), 3, 4, DeliveryMode.UNRELIABLE);
		Assert.equals("3456", sender.take()[0].payload.toString());
		sender.close();
	}

	public function testAStreamHasNoMessagesToSendUnreliably():Void {
		var sender = RecordingSocket.make();
		if (sender == null) return;

		sender.__mode = STREAM;
		Assert.raises(() -> sender.send(text("x"), 0, 0, DeliveryMode.UNRELIABLE), IllegalOperationError);
		sender.close();
	}

	public function testNothingUnreliableIsDeliveredBeforeTheHandshake():Void {
		var pair = Pair.make();
		if (pair == null) return;

		pair.sender.send(text("early"), 0, 0, DeliveryMode.UNRELIABLE);
		pair.sender.send(text("early"), 0, 0, DeliveryMode.sequenced(0));
		var frames = pair.sender.take();
		pair.receiver.__connected = false;
		pair.carry(frames);

		Assert.equals(0, pair.received.length);
		pair.close();
	}

	// ----------------------------------------------------------- sequenced

	public function testASequencedChannelDeliversOnlyWhatIsNewer():Void {
		var pair = Pair.make();
		if (pair == null) return;

		for (i in 0...4) {
			pair.sender.send(text('s$i'), 0, 0, DeliveryMode.sequenced(0));
		}
		var frames = pair.sender.take();
		// Late, early, a duplicate, and one from before the newest.
		pair.carry([frames[1], frames[0], frames[3], frames[3], frames[2]]);

		Assert.same(["s1", "s3"], [for (m in pair.received) m.toString()]);
		pair.close();
	}

	public function testSequencedChannelsDoNotHoldEachOtherBack():Void {
		var pair = Pair.make();
		if (pair == null) return;

		pair.sender.send(text("snapshot 0"), 0, 0, DeliveryMode.sequenced(0));
		pair.sender.send(text("snapshot 1"), 0, 0, DeliveryMode.sequenced(0));
		pair.sender.send(text("input 0"), 0, 0, DeliveryMode.sequenced(1));
		var frames = pair.sender.take();
		pair.carry([frames[1], frames[2], frames[0]]);

		// The newer snapshot drops the older one, and has no say over the
		// input, which has its own channel and its own count.
		Assert.same(["snapshot 1", "input 0"], [for (m in pair.received) m.toString()]);
		pair.close();
	}

	public function testASequencedChannelKeepsItsOrderAcrossTheWrap():Void {
		var pair = Pair.make();
		if (pair == null) return;

		pair.sender.send(text("first"), 0, 0, DeliveryMode.sequenced(5));
		pair.sender.__sequencedOut[5] = ReliableDatagramProtocol.SEQUENCED_COUNTER_MASK - 1;
		pair.sender.send(text("before"), 0, 0, DeliveryMode.sequenced(5));
		pair.sender.send(text("last"), 0, 0, DeliveryMode.sequenced(5));
		pair.sender.send(text("wrapped"), 0, 0, DeliveryMode.sequenced(5));
		var frames = pair.sender.take();

		Assert.equals(0, ReliableDatagramProtocol.counterOf(frames[3].sequence), "the counter did not wrap to zero");
		pair.carry([frames[1], frames[3], frames[2]]);

		// Zero is newer than 2^24 - 1, so what was sent before the wrap is
		// the stale one.
		Assert.same(["before", "wrapped"], [for (m in pair.received) m.toString()]);
		pair.close();
	}

	// ----------------------------------------------------------- round trip

	public function testTheRoundTripIsUnknownUntilMeasured():Void {
		var socket = RecordingSocket.make();
		if (socket == null) return;

		Assert.equals(-1.0, socket.roundTripTime);
		Assert.equals(0.0, socket.roundTripVariation);
		Assert.equals(1.0, socket.retransmitTimeout);
		socket.close();
	}

	public function testTheRoundTripIsSmoothedAsRfc6298Says():Void {
		var socket = RecordingSocket.make();
		if (socket == null) return;

		// The first measurement is taken whole, with half of it as variation.
		socket.__sampleRoundTrip(0.1);
		Assert.floatEquals(0.1, socket.roundTripTime);
		Assert.floatEquals(0.05, socket.roundTripVariation);
		Assert.floatEquals(0.3, socket.retransmitTimeout);

		// Each after that moves them an eighth and a quarter of the way.
		socket.__sampleRoundTrip(0.2);
		Assert.floatEquals(0.1125, socket.roundTripTime);
		Assert.floatEquals(0.0625, socket.roundTripVariation);
		Assert.floatEquals(0.3625, socket.retransmitTimeout);
		socket.close();

		// And the timeout is held between its floor and its ceiling.
		var fast = RecordingSocket.make();
		fast.__sampleRoundTrip(0.001);
		Assert.floatEquals(0.001, fast.roundTripTime);
		Assert.floatEquals(0.2, fast.retransmitTimeout);
		fast.close();

		var slow = RecordingSocket.make();
		slow.__sampleRoundTrip(20);
		Assert.floatEquals(10, slow.retransmitTimeout);
		slow.close();
	}

	public function testAnAcknowledgementMeasuresOnlyAFrameSentOnce():Void {
		var pair = Pair.make();
		if (pair == null) return;

		pair.sender.send(text("measured"));
		pair.carry(pair.sender.take());
		for (ack in pair.receiver.take()) {
			pair.sender.__acceptFrame(ack);
		}
		var measured = pair.sender.roundTripTime;
		Assert.isTrue(measured >= 0 && measured < 1, "an acknowledged frame measured " + measured);

		// Karn's algorithm: a frame sent twice cannot say which copy its
		// acknowledgement answers, so it measures nothing.
		pair.sender.send(text("resent"));
		pair.sender.__outFrameCache.get(pair.sender.__windowBase).attempts = 2;
		pair.carry(pair.sender.take());
		var acks = pair.receiver.take();
		Assert.isTrue(acks.length > 0, "the receiver acknowledged nothing");
		for (ack in acks) {
			pair.sender.__acceptFrame(ack);
		}
		Assert.isFalse(pair.sender.__outFrameCache.keys().hasNext(), "the resent frame was not acknowledged");
		Assert.equals(measured, pair.sender.roundTripTime, "a frame sent twice was measured");
		pair.close();
	}

	// ------------------------------------------------------------- helpers

	private static function filled(length:Int):ByteArray {
		var bytes = new ByteArray();
		for (i in 0...length) {
			bytes.writeByte((i * 7) & 0xFF);
		}
		bytes.position = 0;
		return bytes;
	}

	private static function firstWrongByte(bytes:ByteArray):Int {
		bytes.position = 0;
		for (i in 0...bytes.length) {
			if (bytes.readUnsignedByte() != ((i * 7) & 0xFF)) {
				return i;
			}
		}
		return -1;
	}

	private static function text(value:String):ByteArray {
		var bytes = new ByteArray();
		bytes.writeUTFBytes(value);
		bytes.position = 0;
		return bytes;
	}
}

/** A connected socket whose frames are recorded instead of sent. **/
@:access(crossbyte.net.ReliableDatagramSocket)
private class RecordingSocket extends ReliableDatagramSocket {
	private var __recorded:Array<ByteArray> = [];

	/**
		One ready to send, or null where this target cannot make a
		`DatagramSocket` at all -- which is asserted rather than skipped.
	**/
	public static function make():RecordingSocket {
		if (!DatagramSocket.isSupported) {
			Assert.isFalse(DatagramSocket.isSupported);
			return null;
		}
		var socket = new RecordingSocket();
		socket.__connected = true;
		socket.__remoteAddress = "127.0.0.1";
		socket.__remotePort = 9;
		return socket;
	}

	public function new() {
		super();
	}

	/** Every frame recorded since the last call, decoded. **/
	public function take():Array<ReliableDatagramFrame> {
		var frames = [for (bytes in __recorded) ReliableDatagramProtocol.decode(bytes)];
		__recorded = [];
		return frames;
	}

	override private function __sendFrame(type:ReliableDatagramFrameType, sequence:crossbyte.Seq32, payload:ByteArray, offset:Int, length:Int,
			resend:Bool, ack:Null<crossbyte.Seq32>, more:Bool):Void {
		var frame = new ByteArray();
		frame.length = ReliableDatagramProtocol.MAX_FRAME_SIZE;
		frame.length = ReliableDatagramProtocol.encodeInto(frame, type, sequence, payload, offset, length, resend, ack, more);
		__recorded.push(frame);
	}
}

/** Two recording sockets, and what the second has delivered. **/
@:access(crossbyte.net.ReliableDatagramSocket)
private class Pair {
	public var sender:RecordingSocket;
	public var receiver:RecordingSocket;
	public var received:Array<ByteArray> = [];

	public static function make():Pair {
		var sender = RecordingSocket.make();
		if (sender == null) {
			return null;
		}
		var pair = new Pair(sender, RecordingSocket.make());
		return pair;
	}

	private function new(sender:RecordingSocket, receiver:RecordingSocket) {
		this.sender = sender;
		this.receiver = receiver;
		// Where the handshake would have left them: the receiver expecting the
		// sender's first sequence number.
		receiver.__inSequence = sender.__outSequence;
		receiver.addEventListener(DatagramSocketDataEvent.DATA, e -> received.push(e.data));
	}

	/** Hands the receiver each frame, in the order given. **/
	public function carry(frames:Array<ReliableDatagramFrame>):Void {
		for (frame in frames) {
			receiver.__acceptFrame(frame);
		}
	}

	public function close():Void {
		sender.close();
		receiver.close();
	}
}
