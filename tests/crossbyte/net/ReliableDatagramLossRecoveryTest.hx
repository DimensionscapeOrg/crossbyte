package crossbyte.net;

import crossbyte.Seq32;
import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.io.ByteArray;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol.ReliableDatagramFrame;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol.ReliableDatagramFrameType;
import haxe.Timer;
import utest.Assert;

/**
	How a reliable session finds out what was lost, and what it does then.

	A receiver holding frames past a gap says which, in a map on its
	acknowledgement. A sender takes a frame as lost once one sent after it has
	arrived and it has had that one's round trip to arrive in, sends it again
	then, and halves its window once for the burst. When nothing comes back at
	all, it probes the tail before it waits out a timeout.

	Frames are handed across by hand, so what was dropped is what a case
	leaves out; the sockets are real, and only the datagram leaving is
	replaced.
**/
@:access(crossbyte.net.ReliableDatagramSocket)
class ReliableDatagramLossRecoveryTest extends utest.Test {
	// ----------------------------------------------------------- receiving

	public function testAReceiverHoldingFramesPastAGapNamesThem():Void {
		var receiver = RecordingSocket.make();
		if (receiver == null) return;

		// 1000 is missing, and 1002: 1001 and 1003 are held past the gap.
		receiver.__acceptFrame(packet(1001, "b"));
		receiver.__acceptFrame(packet(1003, "d"));
		var frames = receiver.take();

		var ack = frames[frames.length - 1];
		Assert.equals(ReliableDatagramFrameType.ACK, ack.type);
		Assert.equals(1000, (ack.sequence : Int), "the cumulative value moved past a gap");
		// Bit i is frame ack + 1 + i: bits 0 and 2.
		Assert.same([0x05], bytesOf(ack.payload));
		Assert.equals(0, receiver.delivered.length, "a frame past the gap was delivered");
		receiver.close();
	}

	public function testTheMapEndsAtItsLastHeldByte():Void {
		var receiver = RecordingSocket.make();
		if (receiver == null) return;

		// Twenty past the gap is bit 19: the third byte's fourth bit, and
		// nothing after that byte is sent.
		receiver.__acceptFrame(packet(1020, "far"));
		var frames = receiver.take();

		Assert.same([0, 0, 0x08], bytesOf(frames[frames.length - 1].payload));
		receiver.close();
	}

	public function testAnAcknowledgementWithNothingHeldCarriesNoMap():Void {
		var receiver = RecordingSocket.make();
		if (receiver == null) return;

		receiver.__acceptFrame(packet(1000, "a"));
		var frames = receiver.take();

		var ack = frames[frames.length - 1];
		Assert.equals(ReliableDatagramFrameType.ACK, ack.type);
		Assert.equals(1001, (ack.sequence : Int));
		Assert.equals(0, ack.payload.length, "an acknowledgement with no gap carried a map");
		receiver.close();
	}

	// ------------------------------------------------------------- sending

	public function testAFrameSentBeforeOnesThePeerHoldsIsSentAgainAtOnce():Void {
		var sender = RecordingSocket.make();
		if (sender == null) return;

		sendMessages(sender, 5);
		sender.take();

		// 1000 lost, 1001 to 1004 held.
		sender.__acceptFrame(ack(1000, [0, 1, 2, 3]));
		var frames = sender.take();

		Assert.same(["PACKET 1000 resend"], described(frames));
		Assert.equals(1, sender.__fastResends);
		Assert.equals(0, sender.__timeoutResends, "a loss the map showed waited for a timeout");
		Assert.isTrue(sender.__inRecovery);
		Assert.equals(5.0, sender.congestionControl.window, "the window was not halved for the loss");
		sender.close();
	}

	public function testOneFrameHeldPastAGapIsEnoughGivenTime():Void {
		var sender = RecordingSocket.make();
		if (sender == null) return;

		// A window of two, which is what a lossy path leaves: counting held
		// frames needs three past the gap, and there is only ever one.
		sendMessages(sender, 2);
		sender.take();
		sender.__acceptFrame(ack(1000, [0]));

		// Past its allowance -- the round trip of the frame that arrived,
		// and a quarter of the fastest round trip -- by the time the clock
		// next looks, if not already when the map arrived. The timeout, a
		// second on a session this new, is not what sends it.
		waitFor(0.005);
		sender.__checkRetransmits();

		Assert.same(["PACKET 1000 resend"], described(sender.take()));
		Assert.equals(0, sender.__timeoutResends);
		sender.close();
	}

	public function testAResendIsNotRepeatedUntilSomethingSentAfterItArrives():Void {
		var sender = RecordingSocket.make();
		if (sender == null) return;

		sendMessages(sender, 5);
		sender.take();
		sender.__acceptFrame(ack(1000, [0, 1, 2, 3]));
		Assert.same(["PACKET 1000 resend"], described(sender.take()));

		// The same map again, later: nothing the peer holds was sent after
		// the resend, so nothing says the resend was lost. It was sent once
		// per acknowledgement before, which a burst of them made a flood.
		waitFor(0.005);
		sender.__acceptFrame(ack(1000, [0, 1, 2, 3]));
		sender.__checkRetransmits();
		Assert.same([], described(sender.take()), "a resend went again with nothing to say it was lost");

		// A frame sent after it arrives, and it still has not: now it was.
		sendMessages(sender, 1);
		Assert.same(["PACKET 1005"], described(sender.take()));
		waitFor(0.002);
		sender.__acceptFrame(ack(1000, [0, 1, 2, 3, 4]));
		Assert.same(["PACKET 1000 resend"], described(sender.take()));
		sender.close();
	}

	public function testAResendAnsweredFasterThanAnyRoundTripIsTheFirstCopyArriving():Void {
		var sender = RecordingSocket.make();
		if (sender == null) return;

		// Five out, then a round trip of twenty milliseconds, and a sixth.
		sendMessages(sender, 5);
		sender.take();
		waitFor(0.02);
		sendMessages(sender, 1);
		sender.take();

		// 1000 is taken for lost and sent again, after the sixth.
		sender.__acceptFrame(ack(1000, [0, 1, 2, 3]));
		Assert.same(["PACKET 1000 resend"], described(sender.take()));

		// And acknowledged at once, far sooner than any round trip: the first
		// copy was late, not lost. Taken as the resend arriving, it would be
		// the last frame known delivered, and the sixth, sent before it and
		// still on its way, would be sent again for nothing.
		sender.__acceptFrame(ack(1005, []));
		Assert.same([], described(sender.take()), "a frame still on its way was sent again");
		sender.close();
	}

	public function testAHeldFrameIsTimedWhenHeldNotWhenReleased():Void {
		var sender = RecordingSocket.make();
		if (sender == null) return;

		sendMessages(sender, 5);
		sender.take();
		sender.__acceptFrame(ack(1000, [0, 1, 2, 3]));
		sender.take();
		Assert.isTrue(sender.__smoothedRtt >= 0, "holding frames measured nothing");

		// The gap fills a tenth of a second later. The four held frames
		// arrived when the map said so; timed at their release, they made
		// the wait for the gap a round trip.
		waitFor(0.1);
		sender.__acceptFrame(ack(1005, []));

		Assert.isTrue(sender.__smoothedRtt < 0.02, 'the round trip became ${sender.__smoothedRtt}');
		sender.close();
	}

	public function testOneBurstOfLossesHalvesTheWindowOnce():Void {
		var sender = RecordingSocket.make();
		if (sender == null) return;

		sendMessages(sender, 8);
		sender.take();

		// 1000 and 1001 lost, 1002 to 1007 held.
		sender.__acceptFrame(ack(1000, [1, 2, 3, 4, 5, 6]));

		Assert.same(["PACKET 1000 resend", "PACKET 1001 resend"], described(sender.take()));
		Assert.equals(5.0, sender.congestionControl.window);
		sender.close();
	}

	public function testFramesThePeerHoldsLeaveRoomForMore():Void {
		var sender = RecordingSocket.make();
		if (sender == null) return;

		// Ten fill the window; five wait behind it.
		sendMessages(sender, 15);
		Assert.equals(10, sender.take().length);

		// Eight held, two lost: two in the network, and the halved window of
		// five has room for three. Counted as ten outstanding, it had none,
		// and the session sat on its queue until the gap filled.
		sender.__acceptFrame(ack(1000, [1, 2, 3, 4, 5, 6, 7, 8]));

		Assert.same(["PACKET 1000 resend", "PACKET 1001 resend", "PACKET 1010", "PACKET 1011", "PACKET 1012"], described(sender.take()));
		sender.close();
	}

	public function testThreeDuplicatesFromAnOlderPeerResendTheOldest():Void {
		var sender = RecordingSocket.make();
		if (sender == null) return;

		sendMessages(sender, 5);
		sender.take();

		// A peer that sends no map, only the value it is stuck at.
		sender.__acceptFrame(ack(1000, []));
		sender.__acceptFrame(ack(1000, []));
		Assert.same([], described(sender.take()), "two duplicates were taken for a loss");
		sender.__acceptFrame(ack(1000, []));

		Assert.same(["PACKET 1000 resend"], described(sender.take()));
		Assert.equals(5.0, sender.congestionControl.window);
		sender.close();
	}

	public function testDuplicatesFromAPeerThatSendsMapsAreNotLoss():Void {
		var sender = RecordingSocket.make();
		if (sender == null) return;

		sendMessages(sender, 5);
		sender.take();
		sender.__acceptFrame(ack(1000, [0, 1, 2, 3]));
		sender.__acceptFrame(ack(1005, []));
		sendMessages(sender, 3);
		sender.take();

		// This peer says what it holds whenever there is a gap, so an
		// acknowledgement without a map is no gap: a duplicate arrived.
		for (_ in 0...3) {
			sender.__acceptFrame(ack(1005, []));
		}
		Assert.same([], described(sender.take()), "duplicates from a peer that sends maps were taken for loss");
		sender.close();
	}

	public function testTheTailIsProbedWhenNothingComesBack():Void {
		var sender = RecordingSocket.make();
		if (sender == null) return;

		// One round trip measured, and short.
		sendMessages(sender, 1);
		sender.take();
		sender.__acceptFrame(ack(1001, []));

		sendMessages(sender, 3);
		sender.take();
		waitFor(0.02);
		sender.__checkRetransmits();

		// The last frame, not the first: whatever arrives of it says what
		// the peer holds, and what it lacks is then found the ordinary way.
		// No timeout, and the window is as it was.
		Assert.same(["PACKET 1003 resend"], described(sender.take()));
		Assert.equals(1, sender.__probes);
		Assert.equals(0, sender.__timeoutResends);
		Assert.isFalse(sender.__inRecovery, "a probe was treated as a loss");

		// Once a silence: a second is the timeout's to send.
		waitFor(0.02);
		sender.__checkRetransmits();
		Assert.same([], described(sender.take()), "the tail was probed twice in one silence");

		// The probe arrived; the two before it did not.
		waitFor(0.002);
		sender.__acceptFrame(ack(1001, [1]));
		Assert.same(["PACKET 1001 resend", "PACKET 1002 resend"], described(sender.take()));
		sender.close();
	}

	// ---------------------------------------------------------- the policy

	public function testTheSessionTellsItsPolicyWhatHappened():Void {
		var sender = RecordingSocket.make();
		if (sender == null) return;
		var policy = new RecordingPolicy();
		sender.congestionControl = policy;

		sendMessages(sender, 5);
		sender.take();
		sender.__acceptFrame(ack(1005, []));

		// A burst with one frame lost: one loss, however many frames the
		// burst holds, and the lost frame counts when the gap fills.
		sendMessages(sender, 5);
		sender.take();
		sender.__acceptFrame(ack(1005, [0, 1, 2, 3]));
		sender.take();
		sender.__acceptFrame(ack(1010, []));

		// A frame nothing ever answers.
		sendMessages(sender, 1);
		sender.take();
		var timeout = sender.__rto;
		sender.__outFrameCache.get(1010).deadline = 0;
		sender.__checkRetransmits();

		Assert.same(["acknowledged 5", "loss", "acknowledged 5", "timeout"], policy.events);
		Assert.equals(timeout * 2, sender.__rto, "the session did not back its own timeout off");
		sender.close();
	}

	public function testFramesDeliveredCountsEachFrameOnceWhenFirstKnown():Void {
		var sender = RecordingSocket.make();
		if (sender == null) return;

		sendMessages(sender, 5);
		sender.take();

		// Four held past a gap count as they are reported, not when the gap
		// fills; the fifth counts when it arrives, and the four not again.
		sender.__acceptFrame(ack(1000, [0, 1, 2, 3]));
		Assert.equals(4.0, sender.framesDelivered);
		sender.__acceptFrame(ack(1005, []));
		Assert.equals(5.0, sender.framesDelivered);

		sender.close();
		Assert.equals(0.0, sender.framesDelivered, "a closed session kept its count");
	}

	public function testThePolicysWindowIsWhatLimitsSending():Void {
		var sender = RecordingSocket.make();
		if (sender == null) return;
		sender.congestionControl = new FixedWindow(3);

		sendMessages(sender, 10);
		Assert.same(["PACKET 1000", "PACKET 1001", "PACKET 1002"], described(sender.take()));
		sender.close();
	}

	public function testASessionCannotBeLeftWithoutAPolicy():Void {
		var sender = RecordingSocket.make();
		if (sender == null) return;

		Assert.raises(() -> sender.congestionControl = null, crossbyte.errors.ArgumentError);
		Assert.notNull(sender.congestionControl);
		sender.close();
	}

	public function testClosingStartsThePolicyOver():Void {
		var sender = RecordingSocket.make();
		if (sender == null) return;
		var policy = new LossTolerantCongestionControl();
		sender.congestionControl = policy;

		sendMessages(sender, 5);
		sender.take();
		sender.__acceptFrame(ack(1000, [0, 1, 2, 3]));
		Assert.equals(5.0, policy.window);

		// Connected again, the socket is a new session, and so is its policy.
		sender.close();
		Assert.equals(10.0, policy.window);
		Assert.equals(500.0, policy.slowStartThreshold);
	}

	// ----------------------------------------------------------- handshake

	public function testARepeatedHandshakeLeavesWhereFramesAreExpected():Void {
		var session = RecordingSocket.make();
		if (session == null) return;

		// Connected, expecting 1000 from the peer. A repeat naming somewhere
		// else is not taken: that was how frames still on their way were
		// skipped, never delivered and all acknowledged.
		session.__acceptFrame(new ReliableDatagramFrame(HANDSHAKE, 1100, new ByteArray(), false, 7000));
		Assert.equals(1000, (session.__inSequence : Int));
		// The sender has this side's sequence -- it acknowledges it -- so the
		// answer is an acknowledgement, which draws nothing back.
		Assert.same(["ACK 1000"], described(session.take()));

		// Without an acknowledgement the sender still lacks it, and is sent it.
		session.__acceptFrame(new ReliableDatagramFrame(HANDSHAKE, 1100, new ByteArray(), false));
		Assert.equals(1000, (session.__inSequence : Int));
		var frames = session.take();
		Assert.same(["HANDSHAKE 1000"], described(frames));
		Assert.equals(1000, (frames[0].ack : Int), "an answer from a connected session carried no acknowledgement");
		session.close();
	}

	public function testAPeerAskingAgainBeforeAcknowledgingAnythingIsSentEverything():Void {
		var session = RecordingSocket.make();
		if (session == null) return;

		sendMessages(session, 3);
		session.take();

		// The peer never took this side's HANDSHAKE, so it dropped these as
		// they came. The answer names where they start, not where sending has
		// got to, and they all go again now rather than at the timeout.
		session.__acceptFrame(new ReliableDatagramFrame(HANDSHAKE, 1000, new ByteArray(), false));
		Assert.same(["HANDSHAKE 1000", "PACKET 1000 resend", "PACKET 1001 resend", "PACKET 1002 resend"], described(session.take()));
		Assert.equals(10.0, session.congestionControl.window, "a lost handshake was taken for congestion");
		session.close();
	}

	public function testASessionNotYetConnectedAnswersFramesWithItsHandshake():Void {
		var session = RecordingSocket.make();
		if (session == null) return;
		session.__connected = false;
		session.__incoming = true;

		// Frames only a connected peer sends: its answer to this side's
		// HANDSHAKE was lost. Nothing is delivered, and it is asked again --
		// once for the pass, however many arrive.
		session.__acceptFrame(packet(5000, "a"));
		session.__acceptFrame(packet(5001, "b"));
		session.__acceptFrame(packet(5002, "c"));

		var frames = session.take();
		Assert.same(["HANDSHAKE 1000"], described(frames));
		Assert.isNull(frames[0].ack, "an unconnected session acknowledged something");
		Assert.equals(0, session.delivered.length);
		session.close();
	}

	// ------------------------------------------------------------- helpers

	private static function packet(sequence:Int, value:String):ReliableDatagramFrame {
		return new ReliableDatagramFrame(PACKET, sequence, text(value), false, 7000);
	}

	/** An acknowledgement of `value`, holding `ack + 1 + i` for each offset. **/
	private static function ack(value:Int, held:Array<Int>):ReliableDatagramFrame {
		var map = new ByteArray();
		for (offset in held) {
			var index = offset >> 3;
			while (map.length <= index) {
				map.length = map.length + 1;
			}
			(map : haxe.io.Bytes).set(index, (map : haxe.io.Bytes).get(index) | (1 << (offset & 7)));
		}
		return new ReliableDatagramFrame(ACK, value, map, false);
	}

	private static function sendMessages(socket:ReliableDatagramSocket, count:Int):Void {
		for (i in 0...count) {
			socket.send(text("m" + i));
		}
	}

	private static function described(frames:Array<ReliableDatagramFrame>):Array<String> {
		return [
			for (frame in frames)
				RecordingSocket.typeName(frame.type) + " " + (frame.sequence : Int) + (frame.resend ? " resend" : "")
		];
	}

	private static function bytesOf(bytes:ByteArray):Array<Int> {
		return [for (i in 0...bytes.length) (bytes : haxe.io.Bytes).get(i)];
	}

	private static function waitFor(seconds:Float):Void {
		var until = Timer.stamp() + seconds;
		while (Timer.stamp() < until) {}
	}

	private static function text(value:String):ByteArray {
		var bytes = new ByteArray();
		bytes.writeUTFBytes(value);
		bytes.position = 0;
		return bytes;
	}
}

/**
	A connected session whose frames are recorded instead of sent, with every
	sequence pinned: its own start at 1000, and the peer's at 1000 too.
**/
@:access(crossbyte.net.ReliableDatagramSocket)
private class RecordingSocket extends ReliableDatagramSocket {
	public var delivered:Array<ByteArray> = [];

	private var __recorded:Array<ByteArray> = [];

	/** One ready to send, or null where this target has no datagrams. **/
	public static function make():RecordingSocket {
		if (!DatagramSocket.isSupported) {
			Assert.isFalse(DatagramSocket.isSupported);
			return null;
		}
		var socket = new RecordingSocket();
		socket.__connected = true;
		socket.__remoteAddress = "127.0.0.1";
		socket.__remotePort = 9;
		// Pinned, where a session starts somewhere random: far from where
		// 32 bits wrap, and the same every run.
		socket.__outSequence = 1000;
		socket.__windowBase = 1000;
		socket.__firstSequence = 1000;
		socket.__inSequence = 1000;
		socket.addEventListener(DatagramSocketDataEvent.DATA, e -> socket.delivered.push(e.data));
		return socket;
	}

	public function new() {
		super();
	}

	/** Every frame recorded since the last call, and what the pass owes. **/
	public function take():Array<ReliableDatagramFrame> {
		__sendBundle();
		var frames = [for (bytes in __recorded) ReliableDatagramProtocol.decode(bytes)];
		__recorded = [];
		return frames;
	}

	override private function __sendFrame(type:ReliableDatagramFrameType, sequence:Seq32, payload:ByteArray, offset:Int, length:Int, resend:Bool,
			ack:Null<Seq32>, more:Bool):Void {
		var frame = new ByteArray();
		frame.length = ReliableDatagramProtocol.MAX_FRAME_SIZE;
		frame.length = ReliableDatagramProtocol.encodeInto(frame, type, sequence, payload, offset, length, resend, ack, more);
		__recorded.push(frame);
	}

	public static function typeName(type:ReliableDatagramFrameType):String {
		return switch (type) {
			case CONNECT: "CONNECT";
			case HANDSHAKE: "HANDSHAKE";
			case PACKET: "PACKET";
			case ACK: "ACK";
			case FIN: "FIN";
			case UNRELIABLE: "UNRELIABLE";
			case SEQUENCED: "SEQUENCED";
			case _: "?";
		}
	}
}

/** A policy that keeps the default's decisions and writes down each event. **/
private class RecordingPolicy extends CongestionControl {
	public var events:Array<String> = [];

	public function new() {
		super();
	}

	override public function onAcknowledged(session:ReliableDatagramSocket, frames:Int, now:Float):Void {
		events.push("acknowledged " + frames);
		super.onAcknowledged(session, frames, now);
	}

	override public function onLoss(session:ReliableDatagramSocket, now:Float):Void {
		events.push("loss");
		super.onLoss(session, now);
	}

	override public function onTimeout(session:ReliableDatagramSocket, now:Float):Void {
		events.push("timeout");
		super.onTimeout(session, now);
	}
}

/** A policy that never moves its window. **/
private class FixedWindow extends CongestionControl {
	public function new(frames:Int) {
		super();
		window = frames;
	}

	override public function onAcknowledged(session:ReliableDatagramSocket, frames:Int, now:Float):Void {}

	override public function onLoss(session:ReliableDatagramSocket, now:Float):Void {}

	override public function onTimeout(session:ReliableDatagramSocket, now:Float):Void {}
}
