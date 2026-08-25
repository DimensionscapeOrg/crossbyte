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

	The top of the stack, tested the way everything under it is -- two peers
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
		accepted.onBytes = payload -> asBytes = payload;

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
		peer counting the wrong one truncates it -- or reads past it into the
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
}
