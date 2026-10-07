package crossbyte.net.rtc;

import crossbyte.errors.ArgumentError;
import crossbyte.io.ByteArray;
import crossbyte.net.rtc._internal.sctp.DcepMessage;
import crossbyte.net.rtc._internal.sctp.SctpAssociation;
import crossbyte.net.rtc._internal.sctp.SctpAssociationState;
import crossbyte.net.rtc._internal.sctp.SctpDataTransfer;
import utest.Assert;

/**
	Channels over an association: opening them, naming them, carrying messages.

	The top of the stack, tested the way everything under it is, two peers
	handed each other's packets with no network between them. What that reaches
	is everything except the wire itself: DCEP over SCTP over the framing, all
	of it running for real.
**/
class DataChannelTest extends utest.Test {
	private function unsupported():Bool {
		if (!SctpAssociation.isSupported) {
			Assert.isFalse(SctpAssociation.isSupported);
			return true;
		}

		return false;
	}

	/**
		A channel opened at one end appears at the other, named.
	**/
	public function testAChannelOpensAtBothEnds():Void {
		if (unsupported()) return;

		var pair = Pair.open();
		var accepted:DataChannel = null;
		pair.serverChannels.onChannel = channel -> accepted = channel;

		var chat = pair.clientChannels.create("chat");

		Assert.isTrue(pair.run(() -> chat.open && accepted != null), "the channel was never acknowledged");

		Assert.notNull(accepted, "the peer never saw the channel");

		if (accepted == null) {
			return;
		}

		Assert.equals("chat", accepted.label, "the label did not survive the exchange");
		Assert.equals(chat.id, accepted.id, "the two ends disagree about which stream the channel is on");
		Assert.isTrue(accepted.open);
	}

	/**
		Closing before the peer acknowledges tells whoever was waiting.

		`opened` resolves only from __acknowledge, which a closed channel can
		never reach. The class doc tells a caller to wait on it before sending,
		and a channel closed in between left them waiting forever.
	**/
	public function testClosingBeforeTheAcknowledgementTellsWhoeverWaited():Void {
		if (unsupported()) return;

		var pair = Pair.open();
		var chat = pair.clientChannels.create("chat");

		var acknowledged:Bool = false;
		var failure:String = null;
		chat.opened.then(_ -> acknowledged = true, error -> failure = error);

		// Closed before the peer's acknowledgement has been delivered.
		chat.close();

		Assert.isFalse(acknowledged, "a closed channel reported itself opened");
		Assert.notNull(failure, "closing before the acknowledgement left `opened` pending forever");
	}

	/**
		Closing a channel closes the peer's end of it.

		RFC 8831 section 6.7 closes a data channel by resetting its streams,
		RFC 6525, and there was no stream reset here: `close()` was local
		state, the peer was never told, and went on sending into a channel
		nothing read. A browser's channel stayed open for good.
	**/
	public function testClosingAChannelClosesThePeersEnd():Void {
		if (unsupported()) return;

		var pair = Pair.open();
		var accepted:DataChannel = null;
		pair.serverChannels.onChannel = channel -> accepted = channel;

		var chat = pair.clientChannels.create("chat");
		Assert.isTrue(pair.run(() -> chat.open && accepted != null), "the channel never opened");

		var peerCloses:Int = 0;
		accepted.onClose = () -> peerCloses++;

		chat.close();

		Assert.isTrue(pair.run(() -> peerCloses > 0), "the peer's end of the channel never closed");
		Assert.equals(1, peerCloses);
		Assert.isFalse(accepted.open, "the peer's channel still reports itself open");
		Assert.isNull(pair.serverChannels.channel(accepted.id), "the peer's set still holds the channel");

		// And its answering reset is done, so neither end has anything in flight.
		Assert.isTrue(pair.run(() -> pair.settled()), "a stream reset was left unanswered");
	}

	/**
		And the peer closing its end is heard here.

		The other half: a browser's `channel.close()` resets the stream it
		sends on, and with nothing reading RE-CONFIG, `onClose` never ran.
	**/
	public function testThePeerClosingAChannelIsHeard():Void {
		if (unsupported()) return;

		var pair = Pair.open();
		var accepted:DataChannel = null;
		pair.serverChannels.onChannel = channel -> accepted = channel;

		var chat = pair.clientChannels.create("chat");
		Assert.isTrue(pair.run(() -> chat.open && accepted != null), "the channel never opened");

		var closes:Int = 0;
		chat.onClose = () -> closes++;

		accepted.close();

		Assert.isTrue(pair.run(() -> closes > 0), "the peer closed the channel and nothing here heard it");
		Assert.equals(1, closes);
		Assert.isFalse(chat.open);
		Assert.raises(() -> chat.send("after the peer closed"), ArgumentError);
		Assert.isTrue(pair.run(() -> pair.settled()), "a stream reset was left unanswered");
	}

	/**
		What was sent before a close arrives before it, all of it.

		Most of it is still queued when `close()` is called, far more than
		the congestion window lets out at once, and the reset waits behind
		it: the peer hears every message, in order, and then the close.
	**/
	public function testWhatWasSentBeforeACloseArrivesFirst():Void {
		if (unsupported()) return;

		var pair = Pair.open();
		var accepted:DataChannel = null;
		pair.serverChannels.onChannel = channel -> accepted = channel;

		var chat = pair.clientChannels.create("chat");
		Assert.isTrue(pair.run(() -> chat.open && accepted != null), "the channel never opened");

		var heard:Array<String> = [];
		accepted.onMessage = text -> heard.push(text);
		accepted.onClose = () -> heard.push("closed");

		var filler = StringTools.lpad("", "x", 900);

		for (i in 0...40) {
			chat.send(i + filler);
		}

		Assert.isTrue(chat.bufferedAmount > 0, "everything went at once, so nothing was waiting when the channel closed");
		chat.close();

		Assert.isTrue(pair.run(() -> heard.length > 0 && heard[heard.length - 1] == "closed"), "the peer never heard the close");
		Assert.equals(41, heard.length, "the peer heard " + (heard.length - 1) + " of 40 messages before the close");

		var inOrder:Bool = true;

		for (i in 0...(heard.length - 1)) {
			if (heard[i] != i + filler) {
				inOrder = false;
			}
		}

		Assert.isTrue(inOrder, "the messages before the close arrived out of order");
	}

	/**
		When the association goes, every channel on it goes too, and says so.

		This is what `PeerConnection` does with an ABORT, a close_notify, lost
		consent or its own `close()`. Before it, a channel outlived the
		association under it: `open` stayed true, `onClose` never ran, a channel
		still waiting for its acknowledgement left `opened` pending forever, and
		the first sign of any of it was a `send` that threw.
	**/
	public function testEveryChannelClosesWhenTheSetIsClosed():Void {
		if (unsupported()) return;

		var pair = Pair.open();
		var accepted:DataChannel = null;
		pair.serverChannels.onChannel = channel -> accepted = channel;

		var chat = pair.clientChannels.create("chat");
		Assert.isTrue(pair.run(() -> chat.open && accepted != null), "the channel never opened");

		// And one whose acknowledgement has not come back, since that is the
		// case where a caller is waiting on a future.
		var waiting = pair.clientChannels.create("waiting");
		var waitingSettled:String = null;
		waiting.opened.then(_ -> waitingSettled = "resolved", error -> waitingSettled = error);

		var closes:Array<String> = [];
		chat.onClose = () -> closes.push("chat");
		waiting.onClose = () -> closes.push("waiting");

		pair.clientChannels.closeAll();

		Assert.isFalse(chat.open, "a channel whose association ended still reports itself open");
		Assert.isFalse(waiting.open);
		Assert.equals(2, closes.length, "onClose ran for " + closes.join(",") + " rather than for both channels");
		Assert.notNull(waitingSettled, "a channel still waiting for its acknowledgement left `opened` pending");
		Assert.notEquals("resolved", waitingSettled, "a channel that closed before it was acknowledged reported itself opened");
		Assert.isNull(pair.clientChannels.channel(chat.id), "a closed channel is still held by the set");
		Assert.raises(() -> chat.send("after the end"), ArgumentError);

		// Once each, however many times the association's end is reported.
		pair.clientChannels.closeAll();
		Assert.equals(2, closes.length, "closing again reported the channels again");
	}

	/**
		A channel's reliability crosses to the peer, both ways.

		`createDataChannel` had no way to ask for it, and a browser's
		`{ordered: false, maxRetransmits: 0}` arrived as a channel type and a
		reliability parameter that DCEP read and dropped, the accepting end
		made it reliable, and retransmitted what it sent on it like everything
		else. The main reason a game picks a data channel was not available.
	**/
	public function testAChannelsReliabilityCrossesToThePeer():Void {
		if (unsupported()) return;

		var pair = Pair.open();
		var accepted:Array<DataChannel> = [];
		pair.serverChannels.onChannel = channel -> accepted.push(channel);

		var state = pair.clientChannels.create("state", false, "", 0);
		var timed = pair.clientChannels.create("timed", true, "", -1, 250);
		var reliable = pair.clientChannels.create("chat");

		Assert.isTrue(pair.run(() -> accepted.length == 3), "the channels never arrived");
		Assert.equals(0, state.maxRetransmits);
		Assert.equals(-1, state.maxPacketLifeTime);

		for (channel in accepted) {
			switch (channel.label) {
				case "state":
					Assert.equals(0, channel.maxRetransmits, "the peer's maxRetransmits was dropped");
					Assert.equals(-1, channel.maxPacketLifeTime);
					Assert.isFalse(channel.ordered);
				case "timed":
					Assert.equals(250, channel.maxPacketLifeTime, "the peer's maxPacketLifeTime was dropped");
					Assert.equals(-1, channel.maxRetransmits);
					Assert.isTrue(channel.ordered);
				default:
					Assert.equals(-1, channel.maxRetransmits, "a reliable channel arrived with a limit");
					Assert.equals(-1, channel.maxPacketLifeTime);
			}
		}

		// The WebRTC API's rules on what may be asked.
		Assert.raises(() -> pair.clientChannels.create("both", false, "", 1, 100), ArgumentError);
		Assert.raises(() -> pair.clientChannels.create("negative", false, "", -2), ArgumentError);
		Assert.raises(() -> pair.clientChannels.create("huge", false, "", -1, 70000), ArgumentError);
	}

	/**
		No limit is -1, an `Int`, where it was the WebRTC API's null: a
		`Null<Int>`, which a native build holds as an object, made and unboxed
		to read. -1 may be passed for no limit; nothing below it may.
	**/
	public function testNoLimitIsMinusOne():Void {
		var reliable = DcepMessage.decode(DcepMessage.open("chat", true, "", -1, -1).encode());
		Assert.equals(DcepMessage.RELIABLE, reliable.channelType);
		var retransmits:Int = reliable.maxRetransmits;
		var lifetime:Int = reliable.maxPacketLifeTime;
		Assert.equals(-1, retransmits);
		Assert.equals(-1, lifetime);
		if (unsupported()) return;

		var pair = Pair.open();
		var channel = pair.clientChannels.create("chat", true, "", -1, -1);
		var limit:Int = channel.maxRetransmits;
		Assert.equals(-1, limit);
		Assert.equals(-1, channel.maxPacketLifeTime);
		Assert.raises(() -> pair.clientChannels.create("below", true, "", -1, -2), ArgumentError);
	}

	/**
		The transfer a `DataChannelSet` runs over is its connection's own, and
		not part of what it offers: it was a public field, through which an
		application could send on a stream behind its channel's back.
	**/
	public function testTheSetsTransferIsNotOffered():Void {
		Assert.equals(-1, Type.getInstanceFields(DataChannelSet).indexOf("transfer"), "DataChannelSet.transfer is public");
	}

	/**
		The DCEP OPEN carries the partially reliable types a browser uses.
	**/
	public function testThePartiallyReliableTypesSurviveTheRoundTrip():Void {
		var rexmit = DcepMessage.decode(DcepMessage.open("state", false, "", 3).encode());
		Assert.equals(DcepMessage.PARTIAL_RETRANSMIT_UNORDERED, rexmit.channelType);
		Assert.equals(3, rexmit.maxRetransmits);
		Assert.equals(-1, rexmit.maxPacketLifeTime);
		Assert.isTrue(rexmit.unordered);

		var timed = DcepMessage.decode(DcepMessage.open("timed", true, "", -1, 1500).encode());
		Assert.equals(DcepMessage.PARTIAL_TIMED, timed.channelType);
		Assert.equals(1500, timed.maxPacketLifeTime);
		Assert.equals(-1, timed.maxRetransmits);

		var reliable = DcepMessage.decode(DcepMessage.open("chat").encode());
		Assert.equals(DcepMessage.RELIABLE, reliable.channelType);
		Assert.equals(-1, reliable.maxRetransmits);
		Assert.equals(-1, reliable.maxPacketLifeTime);

		// What a browser sends for {ordered: false, maxRetransmits: 0}.
		var browser = DcepMessage.decode(new DcepMessage(DcepMessage.OPEN, 0x81, 0, 0, "state", "").encode());
		Assert.equals(0, browser.maxRetransmits);
	}

	/**
		The parity rule, which is the whole of the collision avoidance.

		The peer that was the DTLS client takes even stream numbers and the
		other odd. Negotiating a number instead would cost a round trip before
		every channel and could still race; this cannot.
	**/
	public function testEachPeerTakesItsOwnStreamNumbers():Void {
		if (unsupported()) return;

		var pair = Pair.open();
		var fromServer:DataChannel = null;
		pair.clientChannels.onChannel = channel -> fromServer = channel;

		var first = pair.clientChannels.create("one");
		var second = pair.clientChannels.create("two");
		var theirs = pair.serverChannels.create("theirs");

		pair.run(() -> first.open && second.open && fromServer != null);

		Assert.equals(0, first.id % 2, "the client should take even stream numbers");
		Assert.equals(0, second.id % 2);
		Assert.notEquals(first.id, second.id, "two channels were given the same stream");
		Assert.equals(1, theirs.id % 2, "the server should take odd stream numbers");
	}

	/**
		A peer may open a channel on a stream whose last channel closed.

		Nothing removed a closed channel from the set, so the collision guard in
		__onControl went on seeing the stream as taken and refused the peer's
		OPEN, silently, because a DCEP OPEN that is ignored looks exactly like
		one that was lost.

		Asserted as the peer's channel arriving, not as the map shrinking: a set
		that merely forgot the channel would satisfy the latter just as well.
	**/
	public function testAPeerMayReopenAStreamWhoseChannelClosed():Void {
		if (unsupported()) return;

		var pair = Pair.open();
		var accepted:Array<DataChannel> = [];
		pair.clientChannels.onChannel = channel -> accepted.push(channel);

		var theirs = pair.serverChannels.create("first");
		Assert.isTrue(pair.run(() -> accepted.length == 1), "the first channel never arrived");

		var stream:Int = theirs.id;

		// Observed because this case closes both ends before the
		// acknowledgement has finished crossing, and an unobserved failure is
		// reported on the next tick. This test is about stream numbers, not
		// about `opened`; saying so keeps the suite's warning count meaningful.
		theirs.opened.then(_ -> {}, _ -> {});
		accepted[0].opened.then(_ -> {}, _ -> {});

		theirs.close();
		accepted[0].close();

		// The peer is entitled to that number again. Wound back by hand because
		// create() deliberately never reuses one on its own; see __freeStreamId.
		@:privateAccess pair.serverChannels.__nextId = stream;

		var again = pair.serverChannels.create("second");
		Assert.equals(stream, again.id, "the test did not reopen the same stream");

		Assert.isTrue(pair.run(() -> accepted.length == 2),
			"the OPEN was refused on a stream whose channel had closed");
		Assert.equals("second", accepted[1].label);
	}

	/**
		Running out of stream numbers is reported, not wrapped.

		The counter ran past 65535 and kept going, while SctpDataChunk writes the
		number into a sixteen-bit field, so after 32768 channels it wrapped on
		the wire and collided with a live stream while this side went on keying
		by the untruncated value. Two channels, one stream, no complaint.
	**/
	public function testRunningOutOfStreamNumbersIsReportedNotWrapped():Void {
		if (unsupported()) return;

		var pair = Pair.open();

		// One number of this side's parity left.
		@:privateAccess pair.clientChannels.__nextId = DataChannelSet.MAX_STREAM_ID - 1;

		var last = pair.clientChannels.create("last");
		Assert.equals(DataChannelSet.MAX_STREAM_ID - 1, last.id);

		Assert.raises(() -> pair.clientChannels.create("one too many"), null,
			"creating past the sixteen-bit stream range wrapped instead of failing");
	}

	/**
		What is waiting on the peer's window is visible before it bites.

		A message handed over is not necessarily a message sent: it waits for
		room the peer has said it has. The queue that makes is bounded and
		`send` throws at the bound, so an application producing faster than
		the far end reads needs to be able to see how far behind it is
		without having to catch something first.
	**/
	public function testBufferedAmountShowsWhatIsWaitingOnThePeer():Void {
		if (unsupported()) return;

		var pair = Pair.open();
		var accepted:DataChannel = null;
		pair.serverChannels.onChannel = channel -> accepted = channel;

		var chat = pair.clientChannels.create("chat");
		pair.run(() -> chat.open && accepted != null);

		if (accepted == null) {
			Assert.fail("the channel never opened");
			return;
		}

		Assert.equals(0, chat.bufferedAmount, "nothing was sent yet and something is already queued");

		var got:String = null;
		accepted.onMessage = text -> got = text;

		chat.send("a message the peer has room for");
		pair.run(() -> got != null);

		// A peer that is keeping up leaves nothing behind.
		Assert.equals(0, chat.bufferedAmount, "the peer took the message and it is still counted as waiting");
	}

	public function testTextCrossesAsText():Void {
		if (unsupported()) return;

		var pair = Pair.open();
		var accepted:DataChannel = null;
		pair.serverChannels.onChannel = channel -> accepted = channel;

		var chat = pair.clientChannels.create("chat");
		pair.run(() -> chat.open && accepted != null);

		if (accepted == null) {
			Assert.fail("the channel never opened");
			return;
		}

		var got:String = null;
		accepted.onMessage = text -> got = text;

		chat.send("hello from the other side");
		pair.run(() -> got != null);

		Assert.equals("hello from the other side", got);
	}

	/**
		Bytes arrive as bytes, not as text that happens to hold them.

		Told apart on the wire by the payload protocol identifier, so a receiver
		knows which it got without inspecting the contents and guessing.
	**/
	public function testBytesCrossAsBytes():Void {
		if (unsupported()) return;

		var pair = Pair.open();
		var accepted:DataChannel = null;
		pair.serverChannels.onChannel = channel -> accepted = channel;

		var channel = pair.clientChannels.create("binary");
		pair.run(() -> channel.open && accepted != null);

		if (accepted == null) {
			Assert.fail("the channel never opened");
			return;
		}

		var asText:String = null;
		var asBytes:ByteArray = null;
		accepted.onMessage = text -> asText = text;
		// A copy: the payload is valid only during the call.
		accepted.onBytes = payload -> {
			asBytes = new ByteArray();
			payload.readBytes(asBytes);
			asBytes.position = 0;
		};

		var payload = new ByteArray();

		for (i in 0...256) {
			payload.writeByte(i);
		}

		payload.position = 0;
		channel.sendBytes(payload);
		pair.run(() -> asBytes != null);

		Assert.notNull(asBytes, "the binary message never arrived");
		Assert.isNull(asText, "a binary message was delivered as text");

		if (asBytes != null) {
			Assert.equals(256, asBytes.length);
		}
	}

	/**
		An empty message is a message.

		It has a payload protocol identifier of its own precisely because a
		zero-length payload is otherwise indistinguishable from no payload, and
		a channel that silently swallowed one would be losing messages an
		application deliberately sent.
	**/
	public function testAnEmptyMessageStillArrives():Void {
		if (unsupported()) return;

		var pair = Pair.open();
		var accepted:DataChannel = null;
		pair.serverChannels.onChannel = channel -> accepted = channel;

		var channel = pair.clientChannels.create("empty");
		pair.run(() -> channel.open && accepted != null);

		if (accepted == null) {
			Assert.fail("the channel never opened");
			return;
		}

		var received:Int = 0;
		var text:String = null;
		accepted.onMessage = value -> {
			received++;
			text = value;
		};

		channel.send("");
		pair.run(() -> received > 0);

		Assert.equals(1, received, "an empty message was swallowed");
		Assert.equals("", text);

		// And the binary flavour, which has an identifier of its own. Both
		// travel as one byte of zero, RFC 8831 section 6.6, since SCTP cannot
		// carry a message of no bytes, and this pair being two ends of the
		// same code, it cannot referee that wire shape: both ends once omitted
		// the byte, agreed with each other perfectly, and were discarded
		// without a word by a real browser. `ci/interop/run.js` is the referee;
		// what this holds is that an empty binary message is delivered empty.
		var bytesSeen:Int = 0;
		var bytesLength:Int = -1;
		accepted.onBytes = payload -> {
			bytesSeen++;
			bytesLength = payload.length;
		};

		channel.sendBytes(new crossbyte.io.ByteArray());
		pair.run(() -> bytesSeen > 0);

		Assert.equals(1, bytesSeen, "an empty binary message was swallowed");
		Assert.equals(0, bytesLength, "the placeholder byte leaked into the delivered payload");
	}

	/**
		Sending before the peer has acknowledged is refused.

		The alternatives are to buffer or to drop, and a caller cannot tell
		which happened. Saying no is the only answer that leaves them able to
		reason about it.
	**/
	public function testSendingBeforeTheChannelOpensIsRefused():Void {
		if (unsupported()) return;

		var pair = Pair.open();
		var channel = pair.clientChannels.create("early");

		Assert.isFalse(channel.open);
		Assert.raises(() -> channel.send("too soon"), ArgumentError);
		Assert.raises(() -> channel.sendBytes(new ByteArray()), ArgumentError);
	}

	/**
		Two channels do not hear each other's messages.

		They share an association and are separated only by stream number, so a
		receiver that routed on anything else would deliver every message to
		every channel.
	**/
	public function testChannelsDoNotCrossOver():Void {
		if (unsupported()) return;

		var pair = Pair.open();
		var accepted:Array<DataChannel> = [];
		pair.serverChannels.onChannel = channel -> accepted.push(channel);

		var first = pair.clientChannels.create("first");
		var second = pair.clientChannels.create("second");
		pair.run(() -> accepted.length == 2 && first.open && second.open);

		Assert.equals(2, accepted.length, "both channels should have been seen");

		if (accepted.length != 2) {
			return;
		}

		var onFirst:Array<String> = [];
		var onSecond:Array<String> = [];

		for (channel in accepted) {
			if (channel.label == "first") {
				channel.onMessage = text -> onFirst.push(text);
			} else {
				channel.onMessage = text -> onSecond.push(text);
			}
		}

		first.send("for the first");
		pair.run(() -> onFirst.length > 0);

		Assert.equals(1, onFirst.length);
		Assert.equals(0, onSecond.length, "a message reached a channel it was not sent on");
	}

	// ------------------------------------------------------------------
	// The DCEP messages themselves
	// ------------------------------------------------------------------

	public function testAnOpenMessageSurvivesTheRoundTrip():Void {
		var message = DcepMessage.open("a label", true, "a protocol");
		var decoded = DcepMessage.decode(message.encode());

		Assert.notNull(decoded);

		if (decoded == null) {
			return;
		}

		Assert.equals(DcepMessage.OPEN, decoded.messageType);
		Assert.equals("a label", decoded.label);
		Assert.equals("a protocol", decoded.protocol);
		Assert.isFalse(decoded.unordered);
	}

	/**
		The acknowledgement is one byte and nothing else.

		A parser that expected the OPEN header everywhere would read eleven
		bytes past the end of it.
	**/
	public function testTheAcknowledgementIsOneByte():Void {
		var encoded = DcepMessage.acknowledge().encode();

		Assert.equals(1, encoded.length);

		var decoded = DcepMessage.decode(encoded);
		Assert.notNull(decoded);

		if (decoded != null) {
			Assert.equals(DcepMessage.ACK, decoded.messageType);
		}
	}

	/**
		Label lengths are bytes, not characters.

		A label outside ASCII is longer in UTF-8 than it is in characters, and a
		peer counting the wrong one truncates it, or reads past it into the
		protocol field.
	**/
	public function testALabelIsMeasuredInBytes():Void {
		var message = DcepMessage.open("café", true, "");
		var decoded = DcepMessage.decode(message.encode());

		Assert.notNull(decoded);

		if (decoded != null) {
			Assert.equals("café", decoded.label, "a label with a multi-byte character did not survive");
		}
	}

	/**
		A peer opens no more than `maxPeerChannels` at once.

		There was no bound but the stream numbers: 3,000 OPENs with 1 KB
		labels left 3,000 channels and 3 MB of labels. One past the bound is
		refused as RFC 8832 has a channel refused, no acknowledgement, and
		the stream reset, which closes the peer's end, and once one of the
		peer's channels closes, the next is taken.
	**/
	public function testAPeerOpensNoMoreThanMaxPeerChannels():Void {
		if (unsupported()) return;

		var pair = Pair.open();
		var accepted:Array<DataChannel> = [];
		pair.clientChannels.onChannel = channel -> accepted.push(channel);
		pair.clientChannels.maxPeerChannels = 3;

		var theirs:Array<DataChannel> = [for (i in 0...5) pair.serverChannels.create("c" + i)];

		var closed:Array<String> = [];

		for (channel in theirs) {
			channel.opened.then(_ -> {}, _ -> {});
			channel.onClose = () -> closed.push(channel.label);
		}

		pair.run(() -> pair.clientChannels.refusedChannels == 2 && closed.length == 2 && pair.settled());

		Assert.equals(3, accepted.length, "the peer opened " + accepted.length + " channels against a limit of 3");
		Assert.equals(2, pair.clientChannels.refusedChannels);
		Assert.isTrue(theirs[0].open && theirs[1].open && theirs[2].open, "the channels within the limit did not open");
		Assert.isFalse(theirs[3].open || theirs[4].open, "a refused channel opened at the peer's end");
		Assert.equals("c3,c4", closed.join(","), "the refused channels were not the ones closed at the peer's end");

		// Channels this end opens are its own, and not counted.
		var mine = pair.clientChannels.create("mine");
		pair.run(() -> mine.open);
		Assert.isTrue(mine.open, "a channel this end opened was refused by the peer's limit");

		// One of the peer's goes, and another is taken in its place.
		accepted[0].close();
		pair.run(() -> pair.settled());

		var another = pair.serverChannels.create("another");
		another.opened.then(_ -> {}, _ -> {});
		pair.run(() -> another.open);
		Assert.isTrue(another.open, "a channel was refused once the peer was back under the limit");
		Assert.equals(4, accepted.length);
	}

	/**
		And names no channel with a label or protocol past `maxLabelSize`
		bytes; 0 lifts both bounds.
	**/
	public function testAPeersChannelNamesAreBounded():Void {
		if (unsupported()) return;

		var pair = Pair.open();
		var accepted:Array<DataChannel> = [];
		pair.clientChannels.onChannel = channel -> accepted.push(channel);
		pair.clientChannels.maxLabelSize = 8;

		var fits = pair.serverChannels.create("12345678", true, "abc");
		var longLabel = pair.serverChannels.create("123456789");
		// Eight characters and nine bytes: the bound is on what the wire carries.
		var longProtocol = pair.serverChannels.create("ok", true, "éabcdefg");

		var closed:Array<String> = [];

		for (channel in [fits, longLabel, longProtocol]) {
			channel.opened.then(_ -> {}, _ -> {});
			channel.onClose = () -> closed.push(channel.label);
		}

		pair.run(() -> pair.clientChannels.refusedChannels == 2 && fits.open && closed.length == 2 && pair.settled());

		Assert.equals(1, accepted.length);
		Assert.equals("12345678", accepted.length > 0 ? accepted[0].label : null);
		Assert.equals(2, pair.clientChannels.refusedChannels);
		Assert.equals("123456789,ok", closed.join(","), "the refused channels were not the ones closed at the peer's end");

		// No limit.
		pair.clientChannels.maxLabelSize = 0;
		pair.clientChannels.maxPeerChannels = 0;
		var long = pair.serverChannels.create(StringTools.lpad("", "L", 4000));
		long.opened.then(_ -> {}, _ -> {});
		pair.run(() -> long.open);
		Assert.isTrue(long.open, "a 4,000-byte label was refused with the limit lifted");
	}

	/**
		A label or protocol too long for the OPEN's sixteen-bit length is
		refused here, as the W3C API refuses one: it was written cut to its
		low bits, so the peer read the label short and the protocol out of
		its bytes.
	**/
	public function testALabelTooLongForTheWireIsRefused():Void {
		if (unsupported()) return;

		var pair = Pair.open();
		var longest = StringTools.lpad("", "x", DataChannelSet.MAX_NAME_SIZE);

		Assert.raises(() -> pair.clientChannels.create(longest + "x"), crossbyte.errors.ArgumentError);
		Assert.raises(() -> pair.clientChannels.create("ok", true, longest + "x"), crossbyte.errors.ArgumentError);

		var channel = pair.clientChannels.create(longest);
		Assert.equals(DataChannelSet.MAX_NAME_SIZE, channel.label.length);
	}

	public function testATruncatedOpenIsRefused():Void {
		var truncated = new ByteArray();
		truncated.writeByte(DcepMessage.OPEN);
		truncated.writeByte(0);
		truncated.position = 0;

		Assert.isNull(DcepMessage.decode(truncated));

		// A label longer than the message that carries it.
		var lying = new ByteArray();
		lying.endian = crossbyte.io.Endian.BIG_ENDIAN;
		lying.writeByte(DcepMessage.OPEN);
		lying.writeByte(0);
		lying.writeShort(0);
		lying.writeInt(0);
		lying.writeShort(400);
		lying.writeShort(0);
		lying.position = 0;

		Assert.isNull(DcepMessage.decode(lying), "a label claiming four hundred bytes in a twelve byte message was accepted");
	}
}

/** Two peers with an open association and channels on top. **/
private class Pair {
	public var clientChannels:DataChannelSet;
	public var serverChannels:DataChannelSet;

	private var client:SctpAssociation;
	private var server:SctpAssociation;
	private var clientData:SctpDataTransfer;
	private var serverData:SctpDataTransfer;
	private var toServer:Array<ByteArray> = [];
	private var toClient:Array<ByteArray> = [];
	private var now:Float = 0;

	public static function open():Pair {
		var pair = new Pair();
		pair.client = new SctpAssociation();
		pair.server = new SctpAssociation();

		pair.client.onSend = payload -> pair.toServer.push(payload);
		pair.server.onSend = payload -> pair.toClient.push(payload);

		pair.server.listen();
		pair.client.associate(0);

		for (_ in 0...50) {
			pair.deliver();

			if (pair.client.state == SctpAssociationState.ESTABLISHED && pair.server.state == SctpAssociationState.ESTABLISHED) {
				break;
			}
		}

		pair.clientData = new SctpDataTransfer(pair.client);
		pair.serverData = new SctpDataTransfer(pair.server);

		// The client of the DTLS handshake takes the even stream numbers; here
		// that is whichever peer opened the association.
		pair.clientChannels = new DataChannelSet(pair.clientData, true);
		pair.serverChannels = new DataChannelSet(pair.serverData, false);

		return pair;
	}

	private function new() {}

	private function deliver():Void {
		var outbound = toServer;
		var inbound = toClient;
		toServer = [];
		toClient = [];

		for (payload in outbound) {
			server.receive(payload, now);
		}

		for (payload in inbound) {
			client.receive(payload, now);
		}

		now += 0.25;
	}

	public function run(done:Void->Bool):Bool {
		for (_ in 0...200) {
			if (clientData != null) {
				clientData.poll(now);
			}

			if (serverData != null) {
				serverData.poll(now);
			}

			deliver();

			if (done()) {
				return true;
			}
		}

		return done();
	}

	/** Whether neither end has a stream reset waiting, in flight or unanswered. **/
	public function settled():Bool {
		for (data in [clientData, serverData]) {
			if (@:privateAccess data.__resetRequest != null || @:privateAccess data.__resetWanted.length > 0
				|| @:privateAccess data.__answersOwed.length > 0) {
				return false;
			}
		}

		return true;
	}
}
